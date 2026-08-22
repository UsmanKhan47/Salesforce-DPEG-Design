/**
 * FSD 5.9.6 STEPS 3-6 - the nightly Case lifecycle - plus the feed-driven alerts of 5.9.7.
 *
 * LAYER - Service. Orchestration: calls `CaseSelector` for data, `DelinquencyEscalationDomain` for
 * every decision, `GroupNotifier` for alerts, and owns the Case DML. No inline SOQL. Every rule
 * lives in the domain; IF YOU FIND YOURSELF WRITING `60` OR `90` IN THIS FILE, STOP.
 *
 * === THE INVARIANT THIS CLASS EXISTS TO PROTECT ===
 * FSD 5.9.2: "a failed or partial sync can never destroy follow-up history". Enforced structurally
 * rather than by discipline: the update path below constructs a BRAND NEW `Case` sObject carrying
 * ONLY the refresh, escalation and close fields, and never a queried record. So there is no way for
 * this service to write back a stale `Status`, blank a `Reason`, or touch a comment - the fields
 * simply are not in the payload. That also sidesteps the repo's stale-sObject-after-DML trap, where
 * reusing an in-memory record after a before-trigger DML re-sends stale literals.
 * It never touches CaseComment, and it never deletes a `Payment_Commitment__c`.
 *
 * === SEND FIRST, STAMP SECOND. THE ORDER IS THE DESIGN. ===
 * A notification is not transactional: once `send()` returns it is out, and no rollback recalls it.
 * The two orders fail in opposite directions and only one is recoverable:
 *   stamp then send - a failed send leaves a marker claiming the alert went out. Lost FOREVER, and
 *                     nothing anywhere records it. SILENT.
 *   send then stamp - a failed stamp leaves the Case un-escalated, so tomorrow alerts again. NOISY,
 *                     VISIBLE, self-correcting.
 * This class takes the second and stamps ONLY the Cases whose send actually succeeded, which is why
 * it calls `GroupNotifier.notifyWithOutcome` rather than the swallow-everything `notify`.
 * Precedent: `NdaExpiryAlertBatch` section 2.
 *
 * === NOTIFICATION TYPE ===
 * `Property_Mgmt_Update`, passed explicitly. `GroupNotifier` was parameterised on 2026-08-22 for
 * exactly this; its default is still `Acquisitions_Deal_Update` and a PM delinquency alert must not
 * arrive under that label - notification settings are per TYPE, so PM alerts would otherwise be
 * un-muteable independently of acquisitions ones.
 *
 * === GOVERNOR BUDGET, PER CHUNK OF 200 ===
 * SOQL: 1 guard read + up to 3 for `GroupNotifier` recipient/type resolution (cached for the whole
 * transaction, so it is 3 TOTAL and not 3 per call) = 4, against 200. DML: at most 3 - insert new
 * Cases, update existing Cases, update mirror rows. Trigger cascade: each Case DML fires Case
 * triggers in 200-record batches, so at chunk size 200 that is 1 firing per statement, not N.
 * The counters below are captured INSIDE this method so a test can assert on them; asserting
 * `Limits.getQueries()` after `Test.stopTest()` is silently vacuous because stopTest restores the
 * pre-test counters.
 *
 * @see DelinquencyEscalationDomain.cls (every threshold and every decision)
 * @see CaseSelector.cls                (the sharing-proof duplicate guard)
 */
public with sharing class DelinquencyCaseService {

    /** Recipients. Both groups exist in `usman-dpeg` (verified 2026-08-22). */
    @TestVisible private static final String GROUP_PM = 'DPEG_Property_Mgmt_Team';
    @TestVisible private static final String GROUP_PRINCIPALS = 'Principals';
    /** Deployed notification type. Never let this fall back to the acquisitions default. */
    @TestVisible private static final String NOTIF_TYPE = 'Property_Mgmt_Update';

    /** `Case.Status` values on the Delinquency record type (restricted by the record type). */
    @TestVisible private static final String STATUS_IDENTIFIED = 'Identified';
    @TestVisible private static final String STATUS_RESOLVED = 'Resolved';
    private static final String RT_DELINQUENCY = 'Delinquency';

    /**
     * Level 3 is the WRITE-OFF rung and it is a one-way marker, exactly like levels 1 and 2. Reusing
     * `Escalation_Level__c` rather than adding a `Write_Off_Notified__c` field is deliberate: the
     * ladder already has "never re-fire the same alert" semantics, a new field would need schema this
     * stream is not permitted to add, and a write-off IS an escalation - it is the rung above 90 days.
     */
    @TestVisible private static final Integer LEVEL_WRITE_OFF = 3;

    /** Query count measured INSIDE the last `processSummaries` call. Test assertion surface. */
    @TestVisible private static Integer lastRunQueryCount = 0;
    /** DML count measured INSIDE the last `processSummaries` call. Test assertion surface. */
    @TestVisible private static Integer lastRunDmlCount = 0;

    /** Tally for `Sync_Run__c`. */
    public class LifecycleResult {
        public Integer casesOpened = 0;
        public Integer casesEscalated = 0;
        public Integer casesClosed = 0;
    }

    /** One decided outcome, held until the notifications have actually been sent. */
    private class Pending {
        Case caseUpdate;
        Integer notifyIndex = -1;
        Boolean isEscalation = false;
        /**
         * True when this update RESOLVES the Case (step 6). Carried here rather than inferred from
         * `caseUpdate.Status` at the far end, so the mirror flag and the audit counter are both
         * decided by the same flag the close path actually set.
         */
        Boolean isClosure = false;
        /** The mirror row this outcome belongs to - the key whose `Has_Open_...` flag it governs. */
        Id summaryId;
    }

    /**
     * Run steps 3-6 over one chunk of mirror rows, with no reason data available.
     *
     * THIS IS THE PRODUCTION PATH TODAY, AND THE REASON IS A KNOWN SCHEMA GAP - see the two-argument
     * overload. An auto-created Case therefore lands with `Reason` and `Resolution_Path__c` BLANK.
     * That is the correct behaviour given the gap, not a shortcut: FSD 5.9.5 exists because roughly a
     * third of DPEG's delinquency notes are billing corrections, so defaulting an unknown reason to
     * Non-payment (and therefore to the Collect path) would put tenants on a collections track for
     * charges DPEG should never have billed - the single failure 5.9.5 is written to prevent. The
     * live `Reason_Matches_Resolution_Path` validation rule is deliberately inert while either field
     * is blank, so a blank pair does not block the sync's own insert.
     *
     * @param summaries Mirror rows written by this run; null/empty safe.
     * @return Counters for the audit row; never null.
     */
    public static LifecycleResult processSummaries(List<Receivables_Summary__c> summaries) {
        return processSummaries(summaries, new Map<String, String>());
    }

    /**
     * Run steps 3-6 over one chunk of mirror rows, given the delinquency reason per AR key.
     *
     * === WHY THIS OVERLOAD EXISTS AND IS NOT YET REACHED IN PRODUCTION ===
     * `ReceivablesFeedDTO.delinquencyReason` carries the feed's reason, but there is NOWHERE TO PUT
     * IT: `Receivables_Summary__c` has no reason field, and the batch reads the mirror rather than
     * the feed, so the value is lost between ingest and lifecycle. Closing that gap needs ONE new
     * field - `Receivables_Summary__c.Delinquency_Reason__c`, a picklist mirroring the four
     * `Case.Reason` delinquency values - which this stream is not permitted to create. It is raised
     * as a schema handoff rather than invented.
     *
     * Until then this overload is the seam: the mapping is live, tested, and reachable the moment a
     * carrier exists, instead of the reason logic being deleted and rebuilt later from memory.
     *
     * @param summaries      Mirror rows; null/empty safe.
     * @param reasonByArKey  `Case.Reason` value per `Yardi_AR_Id__c`; null/empty safe. A value that
     *                       is not one of the four FSD 5.9.5 reasons is DISCARDED rather than
     *                       written - the Delinquency record type restricts `Reason` and restricted
     *                       picklists ARE enforced at DML on this project, so an unrecognised value
     *                       would fail the insert and take the whole chunk with it.
     * @return Counters for the audit row; never null.
     */
    public static LifecycleResult processSummaries(
        List<Receivables_Summary__c> summaries,
        Map<String, String> reasonByArKey
    ) {
        LifecycleResult result = new LifecycleResult();
        Map<String, String> reasons =
            (reasonByArKey == null) ? new Map<String, String>() : reasonByArKey;
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        if (summaries == null || summaries.isEmpty()) {
            lastRunQueryCount = 0;
            lastRunDmlCount = 0;
            return result;
        }

        // ── STEP 3: the duplicate guard. One read, sharing-proof, keyed on the AR id. ────────────
        Set<String> arKeys = new Set<String>();
        for (Receivables_Summary__c summary : summaries) {
            if (String.isNotBlank(summary.Yardi_AR_Id__c)) {
                arKeys.add(summary.Yardi_AR_Id__c);
            }
        }
        Map<String, Case> openCaseByKey = new Map<String, Case>();
        for (Case existing : CaseSelector.selectOpenDelinquencyByArKeys(arKeys)) {
            // Oldest-first ordering from the selector: keep the FIRST, which carries the real
            // follow-up history, rather than whichever the database returned last.
            if (!openCaseByKey.containsKey(existing.Yardi_AR_Id__c)) {
                openCaseByKey.put(existing.Yardi_AR_Id__c, existing);
            }
        }

        Decimal thresholdAmount = ReceivablesSyncConfig.openingThresholdAmount();
        Decimal thresholdMonths = ReceivablesSyncConfig.openingThresholdMonths();

        List<Case> newCases = new List<Case>();
        List<Receivables_Summary__c> newCaseSummaries = new List<Receivables_Summary__c>();
        List<Pending> pendings = new List<Pending>();
        List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
        Map<Id, Boolean> hasOpenCaseBySummaryId = new Map<Id, Boolean>();

        for (Receivables_Summary__c summary : summaries) {
            Case existing = openCaseByKey.get(summary.Yardi_AR_Id__c);
            if (existing == null) {
                // ── STEP 4: open, but only when a configured threshold is actually crossed ───────
                Boolean crosses = DelinquencyEscalationDomain.crossesOpeningThreshold(
                    summary.Total_Outstanding_Amount__c, summary.Months_Outstanding__c,
                    thresholdAmount, thresholdMonths);
                hasOpenCaseBySummaryId.put(summary.Id, crosses);
                if (crosses) {
                    newCases.add(buildNewCase(summary, reasons.get(summary.Yardi_AR_Id__c)));
                    newCaseSummaries.add(summary);
                }
                continue;
            }
            // Provisionally true. A closure flips it back to false below, but ONLY once the close
            // DML has actually succeeded - see the loop after `updateCases`.
            hasOpenCaseBySummaryId.put(summary.Id, true);
            buildExistingCaseOutcome(summary, existing, pendings, requests);
        }

        // ── Insert new Cases BEFORE notifying, so the alert can link to a real record ────────────
        if (!newCases.isEmpty()) {
            List<Database.SaveResult> inserts = new CaseWrites().insertCases(newCases);
            for (Integer i = 0; i < inserts.size(); i++) {
                if (inserts[i].isSuccess()) {
                    result.casesOpened++;
                    requests.add(buildRequest(GROUP_PM, 'Delinquency Case opened',
                        openedBody(newCaseSummaries[i]), inserts[i].getId()));
                } else {
                    // The mirror row must not claim a Case that does not exist.
                    hasOpenCaseBySummaryId.put(newCaseSummaries[i].Id, false);
                }
            }
        }

        // ── SEND, then stamp only what actually went out ─────────────────────────────────────────
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);

        List<Case> caseUpdates = new List<Case>();
        for (Pending pending : pendings) {
            if (pending.isEscalation) {
                Boolean sent = pending.notifyIndex >= 0 && pending.notifyIndex < outcomes.size()
                    && outcomes[pending.notifyIndex] == true;
                if (!sent) {
                    // Drop the escalation stamp so tomorrow retries. Keep the balance refresh:
                    // refreshing is not an alert and must not be held hostage to one.
                    pending.caseUpdate.Escalation_Level__c = null;
                    pending.caseUpdate.Escalation_Basis_Days__c = null;
                    pending.caseUpdate.Escalated_DateTime__c = null;
                } else {
                    result.casesEscalated++;
                }
            }
            caseUpdates.add(pending.caseUpdate);
        }
        if (!caseUpdates.isEmpty()) {
            // ── STEP 6's SECOND HALF: a closed Case must stop counting as an open one ────────────
            // `Has_Open_Delinquency_Case__c` is a sync-written Checkbox rather than a formula
            // (design D-AR-7: a formula cannot traverse from a stateless mirror to its Cases), so
            // NOTHING clears it except this. Leaving it set after an auto-close made the section 6.1
            // "Delinquent Tenants" tile over-count permanently - and worse, the mirror then claimed
            // an open Case for a tenant who no longer had one, which is the same claim the duplicate
            // guard's projection makes, so a tenant who re-delinquented read as already-handled.
            //
            // Gated on the SaveResult, not on the decision. `updateCases` is `allOrNone = false`, so
            // a refused close returns silently; flipping the flag on intent alone would produce a
            // mirror saying "no open Case" beside a Case that is still open - a worse state than the
            // over-count, because it is invisible rather than merely wrong.
            List<Database.SaveResult> closes = new CaseWrites().updateCases(caseUpdates);
            for (Integer i = 0; i < pendings.size() && i < closes.size(); i++) {
                if (pendings[i].isClosure == true && closes[i].isSuccess()) {
                    hasOpenCaseBySummaryId.put(pendings[i].summaryId, false);
                    result.casesClosed++;
                }
            }
        }

        // ── The sync-written projection the section 6.1 tile counts on ──────────────────────────
        List<Receivables_Summary__c> summaryUpdates = new List<Receivables_Summary__c>();
        for (Receivables_Summary__c summary : summaries) {
            Boolean hasOpen = hasOpenCaseBySummaryId.get(summary.Id) == true;
            if (summary.Has_Open_Delinquency_Case__c != hasOpen) {
                summaryUpdates.add(new Receivables_Summary__c(
                    Id = summary.Id, Has_Open_Delinquency_Case__c = hasOpen));
            }
        }
        if (!summaryUpdates.isEmpty()) {
            new CaseWrites().updateSummaries(summaryUpdates);
        }

        lastRunQueryCount = Limits.getQueries() - queriesBefore;
        lastRunDmlCount = Limits.getDmlStatements() - dmlBefore;
        return result;
    }

    /**
     * Steps 3, 5 and 6 for a Case that already exists: refresh, then either escalate or close.
     *
     * Decides only. `casesClosed` and the mirror's `Has_Open_Delinquency_Case__c` are settled by the
     * caller AFTER the DML, from the `SaveResult`, because `allOrNone = false` means a decision here
     * is not evidence that anything was written.
     *
     * @param summary  The mirror row.
     * @param existing The open Case.
     * @param pendings Accumulator for the decided updates.
     * @param requests Accumulator for the notifications.
     */
    private static void buildExistingCaseOutcome(
        Receivables_Summary__c summary,
        Case existing,
        List<Pending> pendings,
        List<GroupNotifier.Request> requests
    ) {
        Pending pending = new Pending();
        pending.summaryId = summary.Id;
        // A FRESH sObject - never the queried one. See the invariant in the class header.
        Case update0 = new Case(Id = existing.Id);
        update0.Current_Balance_Amount__c = summary.Total_Outstanding_Amount__c;
        update0.Current_Days_Past_Due__c = summary.Days_Past_Due__c;

        if (DelinquencyEscalationDomain.isBalanceCleared(summary.Total_Outstanding_Amount__c)) {
            // ── STEP 6: auto-close. Comments, commitments and field history are untouched. ──────
            update0.Status = STATUS_RESOLVED;
            update0.Auto_Closed_By_Sync__c = true;
            // A close is the payment the FSD's "never drops without a payment" wording contemplates,
            // so the ladder resets and a re-delinquenting tenant starts from level 0.
            update0.Escalation_Level__c = DelinquencyEscalationDomain.LEVEL_NONE;
            update0.Escalation_Basis_Days__c = null;
            pending.isClosure = true;
            requests.add(buildRequest(GROUP_PM, 'Delinquency Case auto-closed',
                'Balance cleared for ' + tenantLabel(summary) + '. Case resolved by the nightly sync; '
                + 'the full follow-up timeline is retained.', existing.Id));
            pending.caseUpdate = update0;
            pendings.add(pending);
            return;
        }

        // ── STEP 5: escalate. One-way, with the correction re-arm. ──────────────────────────────
        DelinquencyEscalationDomain.Decision decision = DelinquencyEscalationDomain.evaluate(
            existing.Escalation_Level__c, existing.Escalation_Basis_Days__c,
            (summary.Days_Past_Due__c == null) ? null : summary.Days_Past_Due__c.intValue());

        update0.Escalation_Level__c = decision.newLevel;
        update0.Escalation_Basis_Days__c = decision.newBasisDays;

        if (decision.shouldAlert == true) {
            update0.Escalated_DateTime__c = System.now();
            pending.isEscalation = true;
            pending.notifyIndex = requests.size();
            Boolean isNinety = decision.newLevel >= DelinquencyEscalationDomain.LEVEL_90_DAY;
            // 60 days notifies PM. 90 days notifies PM AND Principals - FSD 5.9.7 rows 2 and 3.
            requests.add(buildRequest(GROUP_PM,
                (isNinety ? '90+ day delinquency' : '60+ day delinquency'),
                escalationBody(summary, decision.newBasisDays), existing.Id));
            if (isNinety) {
                requests.add(buildRequest(GROUP_PRINCIPALS, '90+ day delinquency - principal review',
                    escalationBody(summary, decision.newBasisDays), existing.Id));
            }
        } else if (decision.isRearmed == true) {
            // Yardi corrected the aging downward. No alert, but the ladder is re-armed so a genuine
            // future slide alerts again. Without this the Case would be permanently silent.
            update0.Escalated_DateTime__c = null;
        }

        pending.caseUpdate = update0;
        pendings.add(pending);
    }

    /**
     * Step 4's new Case.
     *
     * @param summary       The mirror row that crossed the threshold.
     * @param feedReason    The feed's `Case.Reason`, or null. An unrecognised value is discarded
     *                      along with the path, because the record type restricts `Reason` and a
     *                      restricted picklist IS enforced at DML - writing a stray value would fail
     *                      the insert for the whole chunk, not just this row.
     * @return An unsaved Case on the Delinquency record type.
     */
    private static Case buildNewCase(Receivables_Summary__c summary, String feedReason) {
        Case newCase = new Case();
        // Reason and path are set TOGETHER or not at all. The live validation rule requires them to
        // agree, and `resolutionPathFor` returning null is exactly the "unrecognised or blank" signal.
        String resolutionPath = DelinquencyEscalationDomain.resolutionPathFor(feedReason);
        if (resolutionPath != null) {
            newCase.Reason = feedReason;
            newCase.Resolution_Path__c = resolutionPath;
        }
        newCase.RecordTypeId = delinquencyRecordTypeId();
        newCase.Status = STATUS_IDENTIFIED;
        newCase.Subject = 'Delinquency - ' + tenantLabel(summary);
        newCase.Yardi_AR_Id__c = summary.Yardi_AR_Id__c;
        newCase.Receivables_Summary__c = summary.Id;
        newCase.Unit__c = summary.Unit__c;
        newCase.Property_Asset__c = summary.Property_Asset__c;
        newCase.Balance_At_Open_Amount__c = summary.Total_Outstanding_Amount__c;
        newCase.Days_Past_Due_At_Open__c = summary.Days_Past_Due__c;
        newCase.Current_Balance_Amount__c = summary.Total_Outstanding_Amount__c;
        newCase.Current_Days_Past_Due__c = summary.Days_Past_Due__c;
        newCase.Escalation_Level__c = DelinquencyEscalationDomain.LEVEL_NONE;
        newCase.Auto_Closed_By_Sync__c = false;
        newCase.Reopened_Count__c = 0;
        if (summary.Responsible_Property_Manager__c != null) {
            newCase.OwnerId = summary.Responsible_Property_Manager__c;
        }
        return newCase;
    }

    /**
     * Builds one notification request under the PM notification type.
     *
     * @param groupName Public group DeveloperName.
     * @param title     Notification title.
     * @param body      Notification body.
     * @param targetId  Record the notification links to.
     * @return The request.
     */
    private static GroupNotifier.Request buildRequest(String groupName, String title, String body, Id targetId) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = groupName;
        request.title = title;
        request.body = body;
        request.targetRecordId = targetId;
        request.notificationType = NOTIF_TYPE;
        return request;
    }

    /**
     * @param summary The mirror row.
     * @return A human label for the tenant, never blank.
     */
    private static String tenantLabel(Receivables_Summary__c summary) {
        return String.isNotBlank(summary.Tenant_Name__c) ? summary.Tenant_Name__c : summary.Yardi_AR_Id__c;
    }

    /**
     * @param summary The mirror row.
     * @return Body text for the "Case opened" alert.
     */
    private static String openedBody(Receivables_Summary__c summary) {
        return tenantLabel(summary) + ' crossed the delinquency opening threshold. Outstanding: '
            + summary.Total_Outstanding_Amount__c + '; days past due: ' + summary.Days_Past_Due__c
            + '; months of rent: ' + summary.Months_Outstanding__c + '.';
    }

    /**
     * @param summary   The mirror row.
     * @param basisDays The aging the level was computed against.
     * @return Body text for an escalation alert.
     */
    private static String escalationBody(Receivables_Summary__c summary, Integer basisDays) {
        return tenantLabel(summary) + ' is ' + basisDays + ' days past due. Outstanding: '
            + summary.Total_Outstanding_Amount__c + '; months of rent: '
            + summary.Months_Outstanding__c + '.';
    }

    /**
     * @return The Delinquency record type Id, or null when the record type is not deployed. Null is
     *         surfaced rather than swallowed: without the record type the Case's Status and Reason
     *         picklists are unrestricted and the whole lifecycle writes into the wrong shape.
     */
    private static Id delinquencyRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.Case
            .getRecordTypeInfosByDeveloperName()
            .get(RT_DELINQUENCY);
        return (info == null || !info.isAvailable()) ? null : info.getRecordTypeId();
    }

    /**
     * THE CASE AND MIRROR WRITES, ESCAPED.
     *
     * `Case` OWD is Private and delinquency Cases are owned by individual property managers, while
     * the nightly job runs as one scheduling principal. `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS
     * - which the 22 Metadata-API-deployed Case custom fields need - and NEVER lifts sharing.
     * Without this escape every UPDATE to a Case owned by somebody else is refused, and because the
     * DML is `allOrNone = false` the refusal becomes a `SaveResult` nobody reads: balances stop
     * refreshing, escalations stop stamping, and the job reports a clean run every night.
     */
    private without sharing class CaseWrites {

        private List<Database.SaveResult> insertCases(List<Case> cases) {
            return Database.insert(cases, false, AccessLevel.SYSTEM_MODE);
        }

        private List<Database.SaveResult> updateCases(List<Case> cases) {
            return Database.update(cases, false, AccessLevel.SYSTEM_MODE);
        }

        private List<Database.SaveResult> updateSummaries(List<Receivables_Summary__c> summaries) {
            return Database.update(summaries, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
