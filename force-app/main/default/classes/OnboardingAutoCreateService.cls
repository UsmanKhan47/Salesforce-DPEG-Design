/**
 * Opens the PM `Onboarding__c` record for every `Property_Asset__c` whose
 * `Closing_Date__c` has just transitioned to non-null — i.e. every property DPEG has
 * actually finished acquiring — and tells the Property Management team about it.
 *
 * ═══ 🔴 THE DISCRIMINATOR IS THE LOAD-BEARING FACT OF THIS FEATURE ═══
 * "Fully acquired" is expressed as `Property_Asset__c.Closing_Date__c != null`, and
 * that is a MEASURED choice, not a convenient one. `Property_Asset__c.Status__c` is a
 * two-value picklist (`Active` / `Disposed`) that reads `Active` from birth, so it
 * cannot distinguish an acquired asset from a seeded one. `Closing_Date__c` can,
 * because:
 *   - `PropertyAssetService.cls` (`ensureOnClosedWon` -> `createAssets`) is its ONLY
 *     writer anywhere in the codebase, and it writes `Opportunity.CloseDate` there
 *     when a deal enters Closed Won;
 *   - `TestDataFactory.createPropertyAssets` does NOT set it;
 *   - none of the nine seed scripts sets it (every `Closing_Date__c` hit in
 *     `scripts/` is `Disposition__c.Closing_Date__c`, a different object).
 * So a seeded or hand-built asset mints no Onboarding, by construction rather than by
 * a filter someone has to remember. ⚠ THIS IS NOT THE SAME AS "the existing test
 * suite is immune": any test that drives an Opportunity to Closed Won goes through
 * `PropertyAssetService` and WILL now produce an Onboarding. That is correct
 * behaviour, and it is why this service is written never to be able to break such a
 * save — see the next block.
 *
 * ═══ 🔴 THIS CODE MUST NEVER ROLL BACK AN OPPORTUNITY CLOSE (D-ON-1) ═══
 * The whole cascade is: user saves Opportunity -> OpportunityReviewTriggerHandler ->
 * PropertyAssetService inserts the asset -> Property_Asset__c trigger -> here. A throw
 * anywhere in this class escapes as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolls
 * back the deal close. A broken onboarding checklist must not stop Acquisitions
 * closing a signed deal. Three layers enforce that:
 *   1. `Database.insert(..., allOrNone = FALSE, ...)` — one bad row cannot take the
 *      others, or the close, with it.
 *   2. Every `SaveResult` failure is logged and alerted, never rethrown.
 *   3. The whole body is wrapped so an unexpected exception (a validation rule, a
 *      required field added later, a `LimitException` in the notifier) degrades to a
 *      log + alert instead of a rollback.
 * ⚠ HONEST LIMIT: this is best-effort, not a guarantee. An UNCATCHABLE platform
 * failure — the `System.UnexpectedException: ContentPublication Limit exceeded` class
 * of error this repo has already been bitten by, or a governor limit consumed to zero
 * before we are reached — still aborts the transaction. Moving this work into a
 * Queueable would make the isolation structural rather than defensive; that is
 * recorded as the recommended follow-up and is deliberately NOT done here, because
 * D-ON-1 specified the synchronous `allOrNone = false` shape.
 *
 * ═══ 🔴 `Status__c` IS SET EXPLICITLY, AND THAT IS NOT REDUNDANT ═══
 * `Onboarding__c` is Private OWD and the ONLY sharing rule on it shares rows where
 * `Status__c != ''` to `DPEG_Property_Mgmt_Team`. An Onboarding created with a blank
 * Status is therefore INVISIBLE TO THE ENTIRE PM TEAM — the record exists, the
 * notification arrives, and clicking it shows an insufficient-access page. The
 * picklist's own default happens to be `In Progress` today, which is exactly why this
 * must be written explicitly: a future admin reordering the picklist would silently
 * hide every auto-created onboarding. Both `'In Progress'` and `'Property Set up'`
 * are members of their restricted picklists (verified against the `valueSet` blocks),
 * so neither can fail the DML.
 *
 * GOVERNOR BUDGET: 1 SOQL + 1 DML per trigger chunk for the Onboardings, plus at most
 * 3 SOQL for the notifier (cached for the rest of the transaction), CONSTANT in asset
 * count. A chunk with no closing asset costs ZERO queries and ZERO DML — the guard
 * returns before any read.
 *
 * @see force-app/main/default/classes/PropertyAssetService.cls (the only writer of the discriminator)
 * @see force-app/main/default/classes/OnboardingSelector.cls (the idempotency read)
 * @see force-app/main/default/classes/OnboardingFanoutService.cls (what the new Onboarding triggers next)
 */
public with sharing class OnboardingAutoCreateService {

    /** Opening stage. Member of `Onboarding__c.Stage__c`'s restricted value set. */
    @TestVisible private static final String STAGE_PROPERTY_SETUP = 'Property Set up';

    /**
     * Opening status. Member of `Onboarding__c.Status__c`'s restricted value set, and
     * the value the sharing rule keys on being non-blank. See the class header.
     */
    @TestVisible private static final String STATUS_IN_PROGRESS = 'In Progress';

    /**
     * Days from `Start_Date__c` to `Target_Completion_Date__c` on an auto-created
     * onboarding.
     *
     * ⚠ ASSUMPTION, NOT A CLIENT-SUPPLIED SLA (design OQ-5 is unanswered). 90 is the
     * largest `Due_Day_Offset__c` in the 45 shipped `Onboarding_Task_Def__mdt` rows
     * ("Set up lockbox services"), so the target date is the first date by which every
     * checklist item is due rather than an invented round number. Change it here, in
     * one place, when the client supplies a real target. Leaving the field NULL was
     * rejected: `Is_Past_Target__c` would then be permanently false and
     * `OnboardingSelector.selectActive`'s `ORDER BY Target_Completion_Date__c NULLS
     * LAST` would lose its sort key for every auto-created row.
     */
    @TestVisible private static final Integer TARGET_COMPLETION_DAYS = 90;

    /** Recipient group for both the success alert and the failure alert. */
    @TestVisible private static final String PM_GROUP = 'DPEG_Property_Mgmt_Team';

    /**
     * Notification type for PM alerts. Parameterised into `GroupNotifier` in this same
     * change — before it, every alert this class sent would have been branded
     * "Acquisitions – Deal Update" in the PM team's bell.
     */
    @TestVisible private static final String PM_NOTIF_TYPE = 'Property_Mgmt_Update';

    // ═════════════════════════════════════════════════════════════════════════════
    // RUN COUNTERS — test instrumentation for the governor-budget and skip-path
    // assertions. MEASURED `Limits` deltas, not a hand tally, so a query added inside
    // a selector is still visible here.
    // ═════════════════════════════════════════════════════════════════════════════

    /** Times the trigger handler called this service, including no-op chunks. */
    @TestVisible private static Integer runInvocations = 0;
    /** SOQL queries this service consumed, measured via `Limits`. Cumulative. */
    @TestVisible private static Integer runQueryCount = 0;
    /** DML statements this service consumed, measured via `Limits`. Cumulative. */
    @TestVisible private static Integer runDmlCount = 0;
    /** Onboardings successfully created. Cumulative. */
    @TestVisible private static Integer runCreated = 0;
    /** Assets skipped because they already had an Onboarding. Cumulative. */
    @TestVisible private static Integer runSkippedExisting = 0;
    /** Rows the platform refused. Cumulative. A non-zero value here is a real defect to chase. */
    @TestVisible private static Integer runFailed = 0;

    /** Zeroes every counter. Test-only; each test that asserts a budget calls it first. */
    @TestVisible
    private static void resetRunCounters() {
        runInvocations = 0;
        runQueryCount = 0;
        runDmlCount = 0;
        runCreated = 0;
        runSkippedExisting = 0;
        runFailed = 0;
    }

    /**
     * Creates the Onboarding for every asset whose `Closing_Date__c` just became
     * non-null.
     *
     * TRANSITION, not "is set": on update an asset that already had a Closing Date and
     * is re-saved for any other reason does nothing. On insert (`oldMap == null`) an
     * asset created WITH a Closing Date counts as transitioning — that is the shape
     * `PropertyAssetService` produces and the shape a data load arrives in. This is the
     * same stage-ENTRY reading `PropertyAssetService.ensureOnClosedWon` and
     * `ContractExecutionService.openTransactionsOnAboutToClose` both use.
     *
     * @param newAssets Trigger.new.
     * @param oldMap    Trigger.oldMap on update; null on insert.
     */
    public static void ensureOnClosing(List<Property_Asset__c> newAssets, Map<Id, Property_Asset__c> oldMap) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        runInvocations++;
        try {
            createOnboardings(newAssets, oldMap);
        } catch (Exception e) {
            // 🔴 SWALLOWED ON PURPOSE — D-ON-1. A missing onboarding checklist is a PM
            // problem; a rolled-back Closed Won is an Acquisitions outage. Never rethrow.
            reportFailure('Onboarding auto-create failed for a closing property asset: '
                + e.getTypeName() + ': ' + e.getMessage(), null);
        }
        runQueryCount += Limits.getQueries() - queriesBefore;
        runDmlCount += Limits.getDmlStatements() - dmlBefore;
    }

    /**
     * The work: filter to the transition, guard on idempotency, build, insert, notify.
     * Bulk-safe and CONSTANT in asset count — one selector call, one bulk DML, one
     * batched notify, nothing inside a loop.
     *
     * @param newAssets Trigger.new.
     * @param oldMap    Trigger.oldMap on update; null on insert.
     */
    private static void createOnboardings(List<Property_Asset__c> newAssets, Map<Id, Property_Asset__c> oldMap) {
        if (newAssets == null || newAssets.isEmpty()) {
            return;
        }
        Map<Id, Property_Asset__c> closing = new Map<Id, Property_Asset__c>();
        for (Property_Asset__c a : newAssets) {
            if (a.Closing_Date__c == null) {
                continue;
            }
            if (oldMap != null) {
                Property_Asset__c prior = oldMap.get(a.Id);
                if (prior != null && prior.Closing_Date__c != null) {
                    continue; // already had one — not a transition
                }
            }
            closing.put(a.Id, a);
        }
        // THE EARLY RETURN THAT KEEPS AN ORDINARY ASSET SAVE AT ZERO COST.
        if (closing.isEmpty()) {
            return;
        }

        // SOQL 1 of 1 — the idempotency read. SYSTEM_MODE + without sharing, argued in
        // the selector: on a Private-OWD object a sharing-filtered guard would report
        // "no onboarding exists" and mint a SECOND one for the same asset.
        for (Onboarding__c existing : OnboardingSelector.selectByPropertyAssetIds(closing.keySet())) {
            if (closing.remove(existing.Property_Asset__c) != null) {
                runSkippedExisting++;
            }
        }
        if (closing.isEmpty()) {
            return;
        }

        Date startDate = Date.today();
        List<Onboarding__c> toInsert = new List<Onboarding__c>();
        for (Id assetId : closing.keySet()) {
            toInsert.add(new Onboarding__c(
                Property_Asset__c = assetId,
                Stage__c = STAGE_PROPERTY_SETUP,
                Status__c = STATUS_IN_PROGRESS,
                Start_Date__c = startDate,
                Target_Completion_Date__c = startDate.addDays(TARGET_COMPLETION_DAYS)
            ));
        }

        // DML 1 of 1. SYSTEM_MODE because the running user is the deal driver, who holds
        // read-only DPEG_PropertyMgmt_View and cannot create an Onboarding__c.
        // 🔴 allOrNone = FALSE — see the class header. One bad row must not take the
        // Opportunity close with it.
        List<Database.SaveResult> results = Database.insert(toInsert, false, AccessLevel.SYSTEM_MODE);

        List<GroupNotifier.Request> alerts = new List<GroupNotifier.Request>();
        List<String> failures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            if (sr.isSuccess()) {
                runCreated++;
                alerts.add(buildAlert(
                    'New property onboarding opened',
                    'A property acquisition has closed and its onboarding checklist has been opened. '
                        + 'Open the record to review the checklist and assign an onboarding lead.',
                    sr.getId()
                ));
            } else {
                runFailed++;
                failures.add(String.valueOf(toInsert[i].Property_Asset__c) + ': ' + firstError(sr));
            }
        }

        if (!failures.isEmpty()) {
            reportFailure('Onboarding auto-create refused ' + failures.size()
                + ' record(s): ' + String.join(failures, ' | '), null);
        }
        if (!alerts.isEmpty()) {
            // ONE batched call carrying one Request per new Onboarding. NEVER send() in a
            // loop — GroupNotifier's own header measures a looping caller at 3 fresh
            // queries per record (9 per Opportunity, 1,800 for a 200-record chunk), and
            // the batched entry point is the guardrail against exactly that.
            GroupNotifier.notify(alerts);
        }
    }

    /**
     * Builds one PM-branded notification request.
     *
     * @param title    Notification title.
     * @param body     Notification body.
     * @param targetId Record the notification links to.
     * @return The request.
     */
    private static GroupNotifier.Request buildAlert(String title, String body, Id targetId) {
        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = PM_GROUP;
        r.title = title;
        r.body = body;
        r.targetRecordId = targetId;
        r.notificationType = PM_NOTIF_TYPE;
        return r;
    }

    /**
     * Records a failure without letting it reach the caller.
     *
     * ⚠ WHERE THIS GOES, AND WHAT IS MISSING. There is no error-log object and no
     * platform-admin public group in this org, so the sink is (a) an ERROR-level debug
     * line, which survives in the debug log and in any log-capture tooling, and (b) —
     * only when a target record exists — a notification to the PM team, who are the
     * people who will actually notice a missing checklist. A dedicated admin group and
     * a durable error sink are recorded in the HUB FILE REQUESTS; until one exists,
     * this is the honest ceiling and is deliberately not dressed up as more.
     *
     * A notification with a NULL target cannot be sent (`CustomNotification.setTargetId`
     * requires one), so a whole-transaction failure degrades to the debug line alone.
     *
     * @param message  What went wrong.
     * @param targetId Record to link the alert to, or null when there is none.
     */
    private static void reportFailure(String message, Id targetId) {
        System.debug(LoggingLevel.ERROR, 'OnboardingAutoCreateService: ' + message);
        if (targetId == null) {
            return;
        }
        GroupNotifier.notify(new List<GroupNotifier.Request>{
            buildAlert('Onboarding auto-create failed', message, targetId)
        });
    }

    /**
     * First error message off a failed SaveResult, defensively.
     * @param sr The failed result.
     * @return A readable message; never null.
     */
    private static String firstError(Database.SaveResult sr) {
        List<Database.Error> errors = sr.getErrors();
        return (errors == null || errors.isEmpty())
            ? 'unknown error'
            : errors[0].getStatusCode() + ' ' + errors[0].getMessage();
    }
}
