/**
 * Freezes a deal's market data at underwriting approval (FSD §18.3 / §18.4, tranche 2).
 *
 * Called as invocable Apex from `flows/Opportunity_UW_Approved_Notify` (action
 * `Snapshot_Market_Data`, chained after `Stamp_Approval_Audit`). It reads the LIVE market
 * block off the deal's `Property__c`, composes one labelled, ordered, human-readable text
 * block, and stamps `Opportunity.Market_Data_Snapshot__c` + `Market_Data_As_Of_Date__c`.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 1. FREEZE BY SNAPSHOT, NEVER BY LOCK — the shape of the answer
 * ═════════════════════════════════════════════════════════════════════════════
 * The obvious mechanism — a `Market_Data_Locked__c` checkbox plus validation rules
 * refusing edits to the market fields — was REJECTED on three independent grounds and
 * must not be reintroduced:
 *
 *   1. IT FREEZES THE WRONG SCOPE. The market fields live on `Property__c`, which is
 *      shared by every deal targeting that property (`PropertyAssetService`'s idempotency
 *      key is the Property for exactly this reason). Locking at deal A's approval freezes
 *      the data for deal B, which has not been underwritten at all.
 *   2. IT BLOCKS THE THING THIS FEATURE EXISTS TO ENABLE. §18.4's whole point is that an
 *      ASB spoke will one day keep these fields refreshed. A lock that prevents refresh is
 *      a lock that must be removed the day the integration ships.
 *   3. IT SOLVES THE WRONG PROBLEM. §18.3's stated intent is that later refreshes cannot
 *      silently change numbers principals already reviewed. That is an EVIDENTIARY
 *      requirement about what was reviewed — not a prohibition on the data moving.
 *
 * ⇒ The live layer keeps moving on `Property__c`; the reviewed numbers are COPIED, once,
 *   per deal, onto the `Opportunity`.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 2. 🔴 WHY THE VENUE IS THIS FLOW AND NEEDS NO QUEUEABLE — a live proof, not an inference
 * ═════════════════════════════════════════════════════════════════════════════
 * An approval-triggered flow runs as THE APPROVER, and in this org the approving
 * principals are deliberately READ-ONLY on Opportunity (`DPEG Principal PSG` grants Read,
 * not Edit — measured). ARCHITECTURE.md §2 records the 2026-08-05 incident where that
 * produced `System.TypeException: DML operation UPDATE not allowed on Opportunity`, which
 * is NOT a `DmlException`, escaped a narrow catch, and ROLLED BACK THE WHOLE APPROVAL so
 * the principal could not approve at all. Three facts close every part of that here, and
 * all three are properties of files already in this repo:
 *
 *   - `flows/Opportunity_UW_Approved_Notify` ALREADY carries
 *     `<runInMode>SystemModeWithoutSharing</runInMode>`.
 *   - `Opportunity.Underwriting_Approval` declares `finalApprovalRecordLock = false`, so
 *     the record is UNLOCKED when the final approval actions fire.
 *   - `ApprovalAuditService` ALREADY performs an Opportunity `update` from inside THIS
 *     EXACT FLOW and works today.
 *
 * 🔴 CONTRAST `LoiPrimaryStampQueueable` AND `DispositionNdaStampQueueable`, WHICH EXIST
 * ONLY BECAUSE THEIR RECORDS *ARE* LOCKED. Do not copy them here — a queueable would add
 * an async hop, a second transaction and a failure surface to solve a lock that this
 * approval process does not take.
 *
 * ⚠ BUT `runInMode` ON THE FLOW IS NOT SUFFICIENT ON ITS OWN, AND THAT IS MEASURED, NOT
 * ASSUMED. `ApprovalAuditService`'s own comment records that setting
 * `SystemModeWithoutSharing` did NOT lift the access mode — the stamp still silently wrote
 * nothing until `AccessLevel.SYSTEM_MODE` was stated AT THE DML. This class therefore does
 * the same. Do not revert to a bare `update` on the strength of the flow's configuration.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 3. 🔴 A RE-APPROVAL RE-SNAPSHOTS. IT IS DELIBERATELY *NOT* FILL-IF-BLANK.
 * ═════════════════════════════════════════════════════════════════════════════
 * This is the one place a reader is most likely to "fix" this class into a defect, so the
 * argument is recorded rather than the rule alone.
 *
 * The flow declares `doesRequireRecordChangedToMeetCriteria = true`, i.e. ENTRY semantics:
 * it fires on the TRANSITION into `Underwriting_Status__c = 'Approved by Principals'` and
 * not on any subsequent save. So a second snapshot can only happen after a genuine
 * reject → re-approve cycle — a SECOND REVIEW, of the data as it then stood.
 *
 * ⇒ Making this fill-if-blank would leave the second approval permanently misrepresented
 *   by the first approval's numbers. That is strictly worse than overwriting, because the
 *   record would then assert evidence that is false rather than merely superseded: the
 *   field's entire job is to say "these are the numbers the principals signed off", and on
 *   a re-approval the first freeze is no longer that.
 *
 * ⚠ AN APPEND-A-HISTORY VARIANT WAS CONSIDERED AND NOT BUILT. Appending each freeze would
 * preserve both reviews, but it is unbounded against a 32,768-character field, it makes
 * the field's meaning depend on how many approval cycles a deal happened to have, and no
 * requirement asks for the earlier freeze. If evidence of superseded reviews is ever
 * wanted, the answer is field history tracking or a child object — not an ever-growing
 * text block. `MarketDataSnapshotServiceTest.aSecondApprovalReSnapshots` is the permanent
 * falsifier against a fill-if-blank "optimisation".
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 4. 🔴 THE CATCH IS WIDE *AND* SELF-REPORTING — BOTH HALVES ARE LOAD-BEARING
 * ═════════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE.md §2 records BOTH sides of this trap:
 *
 *   - A `DmlException`-only catch let a `TypeException` escape and roll back an approval.
 *     ⇒ so this catches `Exception`. A `QueryException` is not a `DmlException` either,
 *       and the read above is exactly where one would come from.
 *   - 🔴 AND THE WIDENED CATCH ALONE WOULD HAVE BEEN *WORSE THAN THE BUG*, because the
 *     approval then succeeds while the stamp stays silently blank — a deal that looks
 *     approved-and-evidenced and is only the first of those.
 *
 * ⇒ On failure this writes the REASON INTO `Market_Data_Snapshot__c`
 *   (`"Market data snapshot failed: <message>"`) and still stamps the as-of date. A
 *   snapshot field that reports its own absence costs nothing and turns the one previously
 *   invisible failure into something a human reads on the record — and makes it QUERYABLE
 *   (post-deploy gate G5 looks for exactly this shape).
 *
 * IT NEVER RETHROWS. A market snapshot must never roll back an approval.
 *
 * ⚠ RESIDUAL, stated rather than hidden: if the DML ITSELF throws (rather than returning
 * failed `SaveResult`s) there is nothing left to report with, because the report travels
 * on the same statement. That is inherent and is the same posture `ApprovalAuditService`
 * takes; it is why `AccessLevel.SYSTEM_MODE` is stated at the DML rather than inherited.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 5. OTHER STATED RESIDUALS
 * ═════════════════════════════════════════════════════════════════════════════
 *   R1 — A DEAL WITH A NULL `Property__c` GETS THE LITERAL "no property linked" TEXT,
 *        NEVER A BLANK. Only `LeadConvertService` creates and links a `Property__c`, so a
 *        manually built deal has none. Same residual `PropertyAssetService` (R1) and
 *        `DealFolderService` (R1) carry — the difference is that here it is LEGIBLE on the
 *        record instead of being an absence.
 *   R2 — A deal approved BEFORE deploy day has no snapshot, for ever. Entry semantics see
 *        only transitions from deploy forward (`DealFolderService` R5's shape). No remedy
 *        is built; a one-off anonymous-Apex pass is the named option if it is ever wanted.
 *   R3 — The snapshot records what the PROPERTY held, not what a principal actually looked
 *        at. If a principal read a CoStar tab in a browser rather than the record, this is
 *        not evidence of that. §18.3's requirement is about the fields, so this is in
 *        scope of the ask — recorded so the field is not later over-claimed.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 6. GOVERNOR BUDGET — 1 SOQL / 1 DML PER INVOCATION, CONSTANT IN RECORD COUNT
 * ═════════════════════════════════════════════════════════════════════════════
 * Flow batches record-triggered interviews, so this receives a LIST. One selector call for
 * the whole set, one `Database.update` for the whole set, and no SOQL or DML inside any
 * loop. The failure path costs the SAME one DML — the self-reporting body rides the very
 * statement that would have carried the snapshot. Pinned at 251 by the test class; the
 * `.claude/rules/bulk-test-rule.md` per-transaction-singleton exemption does NOT apply,
 * because a Flow-invoked entry point genuinely receives batches.
 *
 * @see OpportunitySelector.selectMarketSnapshotSourceByIds (WITH SYSTEM_MODE — argued there)
 * @see ApprovalAuditService (the sibling invocable on the same flow, same DML posture)
 */
public with sharing class MarketDataSnapshotService {

    /** Raised only by the test seam below; never by ordinary operation. */
    public class MarketDataSnapshotException extends Exception {}

    /**
     * R1's text. A deal with no Property gets THIS, not a blank — an empty field is
     * indistinguishable from "the snapshot never ran", which is the state this whole class
     * exists to make impossible.
     */
    @TestVisible
    private static final String NO_PROPERTY_TEXT =
        'No property linked to this deal - no market data to snapshot.';

    /** Section 4's self-reporting prefix. Tests match on this, so do not reword casually. */
    @TestVisible
    private static final String FAILURE_PREFIX = 'Market data snapshot failed: ';

    /** Written for an Id the read did not return (deleted, or never existed). */
    @TestVisible
    private static final String NOT_READ_TEXT = 'the deal could not be read.';

    /** Rendered for any market value that is null. Distinguishes "looked, empty" from "not asked". */
    private static final String NOT_SET = '(not set)';

    /**
     * `Market_Data_Snapshot__c`'s declared length.
     *
     * ⚠ The composed block is ~25 short lines and cannot realistically approach this, so
     * the clamp is DEFENSIVE rather than expected. It is here because the alternative
     * failure is bad out of proportion to its likelihood: an over-long value makes the row
     * fail with `STRING_TOO_LONG`, and because the failure REPORT travels on that same
     * statement, the deal would end up with no snapshot AND no explanation.
     */
    @TestVisible
    private static final Integer MAX_SNAPSHOT_CHARS = 32768;

    /**
     * Test seam — forces the read leg to throw so the self-reporting catch of section 4 is
     * FALSIFIABLE. Without it that branch is unreachable from a test (the query cannot be
     * made to fail on demand) and the "wide catch is not enough" rule would be an
     * unverified comment. Mirrors `SharePointConfig.simulateMissingRecord` /
     * `TransactionActionPermissionService.simulateLookupFailure`.
     */
    @TestVisible
    private static Boolean simulateReadFailure = false;

    /** Input DTO. `recordId` is the name `flows/Opportunity_UW_Approved_Notify` binds. */
    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The deal whose market data is frozen.' required=true)
        public Id recordId;
    }

    /**
     * Output DTO, INDEX-ALIGNED to the input list.
     *
     * ⚠ The flow does not read it today, and it is returned anyway: `.claude/rules/
     * invocable-rule.md` requires `List` in / `List` out, and an outcome a future caller
     * can branch on costs nothing to return and cannot be retrofitted without changing the
     * signature every existing Flow is bound to.
     */
    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Message')
        public String message;
    }

    /**
     * Freezes the market data for each supplied deal.
     *
     * 🔴 `List` IN / `List` OUT IS MANDATORY, NOT STYLE. Flow batches record-triggered
     * interviews and hands the whole batch to one invocation; a single-record signature
     * SILENTLY DROPS every record but the first (`.claude/rules/invocable-rule.md`).
     * `ApprovalAuditService` on this same flow is the in-repo precedent.
     *
     * @param requests One per deal entering underwriting approval; null/empty safe.
     * @return One Result per input request, in input order. Never null.
     */
    @InvocableMethod(
        label='Snapshot Market Data'
        description='Freezes the live market data on the deal Property onto the Opportunity at underwriting approval.'
    )
    public static List<Result> snapshotMarketData(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        // Index-aligned scaffolding. Pre-filled so an early return below still hands back a
        // list the caller can index safely — a SHORT list would silently misattribute
        // outcomes to the wrong deals.
        List<Id> requestedIds = new List<Id>();
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) {
            Id recordId = (r == null) ? null : r.recordId;
            requestedIds.add(recordId);
            if (recordId != null) {
                ids.add(recordId);
            }
            results.add(buildResult(false, 'No record Id supplied.'));
        }
        if (ids.isEmpty()) {
            return results;
        }

        // ONE Date for the whole invocation. Calling Date.today() per record would let a
        // batch straddling midnight stamp two different as-of dates for one approval wave.
        Date asOf = Date.today();

        Map<Id, String> bodyById = new Map<Id, String>();
        String failureBody = null;
        try {
            if (simulateReadFailure) {
                throw new MarketDataSnapshotException('Simulated read failure (test seam).');
            }
            // SOQL 1 of 1. WITH SYSTEM_MODE — argued at the selector method, not here.
            for (Opportunity o : OpportunitySelector.selectMarketSnapshotSourceByIds(ids)) {
                bodyById.put(
                    o.Id,
                    (o.Property__c == null) ? NO_PROPERTY_TEXT : compose(o, asOf)
                );
            }
        } catch (Exception e) {
            // Section 4: wide AND self-reporting. Every requested deal gets the reason,
            // because a read failure is a property of the query, not of one row.
            failureBody = clip(FAILURE_PREFIX + e.getMessage());
        }

        List<Id> updateIds = new List<Id>(ids);
        List<Opportunity> updates = new List<Opportunity>();
        for (Id recordId : updateIds) {
            String body = (failureBody != null) ? failureBody : bodyById.get(recordId);
            if (body == null) {
                // The read succeeded but returned no row for this Id. Report it rather than
                // skipping: a skipped deal is indistinguishable from one never requested.
                body = clip(FAILURE_PREFIX + NOT_READ_TEXT);
            }
            updates.add(new Opportunity(
                Id = recordId,
                Market_Data_Snapshot__c = body,
                Market_Data_As_Of_Date__c = asOf
            ));
        }

        Set<Id> savedIds = new Set<Id>();
        Map<Id, String> errorById = new Map<Id, String>();
        try {
            // DML 1 of 1. SYSTEM_MODE because the approver holds Read and NOT Edit on
            // Opportunity here, and because both target fields are Metadata-API-deployed
            // customs with no FLS for anyone. allOrNone = false so one bad row cannot take
            // the whole approval wave with it.
            List<Database.SaveResult> saveResults =
                Database.update(updates, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (saveResults[i].isSuccess()) {
                    savedIds.add(updateIds[i]);
                } else {
                    errorById.put(updateIds[i], firstError(saveResults[i]));
                }
            }
        } catch (Exception e) {
            // Never rethrow — see section 4. This is the residual with nothing left to
            // report through, so it goes to the debug log exactly as ApprovalAuditService does.
            System.debug(LoggingLevel.WARN,
                'MarketDataSnapshotService: snapshot write failed: ' + e.getMessage());
            for (Id recordId : updateIds) {
                errorById.put(recordId, e.getMessage());
            }
        }

        for (Integer i = 0; i < requestedIds.size(); i++) {
            Id recordId = requestedIds[i];
            if (recordId == null) {
                continue;
            }
            if (!savedIds.contains(recordId)) {
                results[i] = buildResult(false, errorById.get(recordId));
            } else if (failureBody != null) {
                // The row saved, but what it saved is a failure report, not a snapshot.
                results[i] = buildResult(false, failureBody);
            } else {
                results[i] = buildResult(true, 'Market data snapshot stamped.');
            }
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Composition
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The frozen block: a header naming the source property and the freeze date, then one
     * `Label: value` line per market field, grouped by provider.
     *
     * ⚠ EVERY VALUE IS RENDERED WITH `String.valueOf`, NEVER WITH `format()`. A
     * `Decimal.format()` / `Datetime.format()` value is LOCALE- AND TIME-ZONE-DEPENDENT, so
     * the same approval would freeze different-looking text depending on who pressed the
     * button — which is a poor property for a record whose entire job is to be evidence.
     * `String.valueOf` on a Date yields `yyyy-MM-dd` and on a Datetime yields GMT
     * `yyyy-MM-dd HH:mm:ss`; both are stable and comparable.
     *
     * ⚠ A NULL VALUE RENDERS AS `(not set)` RATHER THAN AS AN OMITTED LINE. An omitted line
     * cannot be told apart from a field this composer forgot, and the whole point of the
     * block is that a reader can trust what is NOT there.
     */
    private static String compose(Opportunity o, Date asOf) {
        Property__c p = o.Property__r;
        List<String> lines = new List<String>();

        lines.add('MARKET DATA SNAPSHOT');
        lines.add('Frozen at underwriting approval on ' + String.valueOf(asOf) + '.');
        // `compose` is reached ONLY when o.Property__c is non-null, so the query guarantees
        // Property__r is populated — no null guard is needed and adding one would imply a
        // state this method cannot be in.
        lines.add('Source property: ' + blankToDash(p.Name));
        lines.add('These are the market values as they stood when the principals approved this deal.');
        lines.add('The live values continue to change on the Property record; this copy does not.');
        lines.add('');
        lines.add('-- PLACER.AI --');
        lines.add(line('Data Source', p.Placer_Data_Source__c));
        lines.add(line('Last Synced', p.Placer_Last_Synced_DateTime__c));
        lines.add(line('Sync Status', p.Placer_Fetch_Status__c));
        lines.add(line('State Rank', p.Placer_State_Rank__c));
        lines.add(line('State Percentile', p.Placer_State_Percentile__c));
        lines.add(line('MSA Rank', p.Placer_MSA_Rank__c));
        lines.add(line('National Rank', p.Placer_National_Rank__c));
        lines.add(line('Monthly Visits', p.Monthly_Visits__c));
        lines.add(line('Trade Area Population', p.Trade_Area_Population__c));
        lines.add(line('Peak Hour', p.Peak_Hour__c));
        lines.add(line('YoY Growth', p.YoY_Growth__c));
        lines.add(line('Comp Monthly Visits', p.Comp_Monthly_Visits__c));
        lines.add('');
        lines.add('-- COSTAR --');
        lines.add(line('Data Source', p.CoStar_Data_Source__c));
        lines.add(line('Last Synced', p.CoStar_Last_Synced_DateTime__c));
        lines.add(line('Sync Status', p.CoStar_Fetch_Status__c));
        lines.add(line('% Leased', p.CoStar_Pct_Leased__c));
        lines.add(line('Location Score', p.CoStar_Location_Score__c));
        lines.add(line('Asking Rent PSF', p.CoStar_Asking_Rent_PSF__c));
        lines.add(line('Market Rent PSF', p.Market_Rent_PSF__c));
        lines.add(line('Exit Cap Rate', p.CoStar_Exit_Cap_Rate__c));
        lines.add(line('Market Cap Rate', p.Market_Cap_Rate__c));
        lines.add(line('Occupancy Rate (Market)', p.Occupancy_Rate_Market__c));
        lines.add(line('Days On Market (Avg)', p.Days_On_Market_Avg__c));
        lines.add('');
        // Stated, not silently omitted — see the FIELD SET note on the selector method.
        lines.add('Not included: Comp Sales and Visitor Demographics (free-text narrative fields);');
        lines.add('read them on the Property record if they are needed.');

        return clip(String.join(lines, '\n'));
    }

    /** `Label: value`, with a null rendering as `(not set)` rather than as an empty tail. */
    private static String line(String label, Object value) {
        return label + ': ' + (value == null ? NOT_SET : String.valueOf(value));
    }

    private static String blankToDash(String value) {
        return String.isBlank(value) ? NOT_SET : value;
    }

    /** Defensive length clamp — see MAX_SNAPSHOT_CHARS. */
    private static String clip(String value) {
        if (value == null || value.length() <= MAX_SNAPSHOT_CHARS) {
            return value;
        }
        String marker = '\n[truncated]';
        return value.substring(0, MAX_SNAPSHOT_CHARS - marker.length()) + marker;
    }

    private static String firstError(Database.SaveResult saveResult) {
        List<Database.Error> errors = saveResult.getErrors();
        return (errors == null || errors.isEmpty())
            ? 'The snapshot could not be saved.'
            : errors[0].getMessage();
    }

    private static Result buildResult(Boolean success, String message) {
        Result r = new Result();
        r.success = success;
        r.message = message;
        return r;
    }
}
