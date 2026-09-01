/**
 * Selector for Transaction__c. Encapsulates ALL SOQL against Transaction__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * Consumers:
 *   - TaskFanoutService.fanOutNow (the Day-0 checklist fan-out; dynamic
 *     condition-field read below).
 *   - TransactionController (Active-Transactions dashboard: KPI header, task
 *     summary, stage donut, and the row table — the four static reads below).
 *   - ContractExecutionService.handleExecution (idempotency guard: which
 *     executed deals already own a Transaction — selectByOpportunityIds).
 *   - RecordStageAdvanceService.load (the Advance Stage quick action —
 *     selectStageRequiredById, added 2026-08-12).
 *   - ChecklistFanoutService.fanOutNow (the Phase 2 checklist fan-out —
 *     selectForChecklistFanout, added 2026-08-31).
 *   - ChecklistRollupService.recalc (the dual-model guard read: it refuses to
 *     write the four Transaction__c counters unless Checklist_Fanned_Out__c is
 *     true — selectForChecklistFanout, added 2026-08-31).
 *   - CriticalDateService (selectForCriticalDates, added 2026-08-31).
 *
 * WHY A DYNAMIC QUERY LIVES HERE (design §6): the fan-out reads a fixed base
 * field set PLUS an arbitrary set of conditional-gating fields whose API names
 * come from Task_Group_Def__mdt.Condition_Field__c rows (e.g. Loan_Required__c).
 * Because those field names are data, not compile-time constants, the SELECT is
 * built dynamically. Two safeguards make that safe:
 *
 *   1. DESCRIBE ALLOWLIST — every condition field is validated against the live
 *      Transaction__c describe before it is concatenated. A typo'd or renamed
 *      CMDT row is silently skipped rather than injected, so a bad admin row
 *      cannot break the SELECT (defense-in-depth) and only real field API names
 *      ever reach the query string (injection-safe).
 *   2. BOUND Id SET — the record filter is a bound `:ids` map entry via
 *      Database.queryWithBinds, never string-concatenated.
 *
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │ MODE INVENTORY — THIS CLASS DELIBERATELY MIXES USER_MODE AND SYSTEM_MODE.  │
 * └───────────────────────────────────────────────────────────────────────────┘
 * DEFAULT IS `AccessLevel.USER_MODE` / `WITH USER_MODE` — every method NOT named
 * below uses it. Transaction__c is custom; P3 proved the custom-field FLS gap is
 * 0, so USER_MODE enforces the running user's sharing + FLS without stripping the
 * selected fields. (The dynamic reads use the `AccessLevel` enum because the
 * `WITH USER_MODE` clause is illegal in a dynamic query — design §6.)
 *
 * TWO methods are `AccessLevel.SYSTEM_MODE`, each justified at its own
 * declaration, both on an AUTOMATION PATH where USER_MODE THROWS rather than
 * degrades and one missing FLS grant becomes a rolled-back user save:
 *   • selectForChecklistFanout  <- ChecklistFanoutService, ChecklistRollupService
 *   • selectForCriticalDates    <- CriticalDateService, from TransactionTrigger
 *
 * ⚠ AMENDED 2026-08-31 — this block previously ended "No guest path, no
 * SYSTEM_MODE." That was true when written and is NO LONGER TRUE. ARCHITECTURE §2
 * makes these headers the authoritative inventory of which reads escape and why,
 * so a stale one is worse than none: it tells the next governor or security review
 * that no exemption exists here. Read the METHOD, not this summary, for the
 * reasoning — the mode is a property of the method, never of the class.
 *
 * ⚠ SCOPE OF THE BYPASS: SYSTEM_MODE lifts CRUD/FLS and NEVER sharing. This class
 * stays `with sharing`, so both exempt methods still return only rows the running
 * user can already see.
 *
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see agent-output/p4-selector-design.md (§3 #15, §4, §5, §6)
 */
public with sharing class TransactionSelector {

    /**
     * Fields the fan-out always needs regardless of CMDT configuration.
     * Id/OwnerId are standard non-permissionable; the two custom fields are
     * granted by the deployed permsets (P3).
     */
    private static final List<String> BASE_FIELDS = new List<String>{
        'Id', 'OwnerId', 'Contract_Executed_Date__c', 'Tasks_Fanned_Out__c'
    };

    /**
     * The Status__c value that marks a live deal on the Active-Transactions
     * dashboard. Extracted to a constant because it drives the WHERE clause of
     * three of the dashboard reads below (task summary, stage donut, row table).
     */
    private static final String STATUS_ACTIVE = 'Active';

    /**
     * Loads Transactions by Id, selecting the fan-out base fields plus any valid
     * conditional-gating fields, keyed by Id for the caller's map-based iteration.
     * Backs TaskFanoutService.fanOutNow, which reads each returned Transaction's
     * conditional field via SObject.get(fieldName).
     *
     * @param transactionIds  Transaction__c Ids to load (bound as `:ids`).
     * @param conditionFields Extra field API names to add to the SELECT (from the
     *                        CMDT Condition_Field__c rows); each is describe-validated
     *                        and de-duplicated before use. May be null/empty.
     * @return Map of Transaction Id -> Transaction__c with the requested fields
     *         populated; an empty map when transactionIds is null/empty.
     * @example
     * Map<Id, Transaction__c> txns = TransactionSelector.selectByIdsWithConditionFields(
     *     new Set<Id>(transactionIds), condFields);
     */
    public static Map<Id, Transaction__c> selectByIdsWithConditionFields(
        Set<Id> transactionIds,
        Set<String> conditionFields
    ) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new Map<Id, Transaction__c>();
        }

        // Build a DISTINCT, describe-validated field list. Base fields first;
        // condition fields only if they resolve to a real Transaction__c field.
        Set<String> selectedLower = new Set<String>();
        List<String> fields = new List<String>();
        for (String baseField : BASE_FIELDS) {
            if (selectedLower.add(baseField.toLowerCase())) {
                fields.add(baseField);
            }
        }
        if (conditionFields != null && !conditionFields.isEmpty()) {
            Map<String, Schema.SObjectField> fieldMap =
                Schema.SObjectType.Transaction__c.fields.getMap();
            for (String conditionField : conditionFields) {
                if (String.isBlank(conditionField)) {
                    continue;
                }
                String trimmed = conditionField.trim();
                String key = trimmed.toLowerCase();
                if (fieldMap.containsKey(key) && selectedLower.add(key)) {
                    fields.add(trimmed);
                }
            }
        }

        String query =
            'SELECT ' + String.join(fields, ', ') +
            ' FROM Transaction__c' +
            ' WHERE Id IN :ids';
        List<Transaction__c> rows = (List<Transaction__c>) Database.queryWithBinds(
            query,
            new Map<String, Object>{ 'ids' => transactionIds },
            AccessLevel.USER_MODE
        );
        return new Map<Id, Transaction__c>(rows);
    }

    /**
     * Fields the CHECKLIST fan-out always needs, regardless of CMDT configuration.
     *
     * 🔴 A SEPARATE LIST FROM `BASE_FIELDS`, AND MERGING THE TWO WOULD BREAK THE LIVE TASK FAN-OUT.
     * `selectByIdsWithConditionFields` above runs in `USER_MODE` and is called by
     * `TaskFanoutService`, which is deployed and enforcing. Adding `Checklist_Fanned_Out__c` - a
     * field that arrives with ZERO FieldPermissions for anybody, System Administrator included - to
     * that list would make the LEGACY fan-out throw `System.QueryException: No such column` for
     * every calling user the day this deploys. Additive means additive.
     */
    private static final List<String> CHECKLIST_BASE_FIELDS = new List<String>{
        'Id', 'OwnerId', 'Contract_Executed_Date__c', 'Checklist_Fanned_Out__c', 'Stage__c'
    };

    /**
     * Fields `CriticalDateService` needs to apply the pinning and coherence rules lifted from
     * `scripts/seed-critical-dates.apex`.
     */
    private static final List<String> CRITICAL_DATE_FIELDS = new List<String>{
        'Id', 'Stage__c', 'Status__c', 'Target_Close_Date__c', 'Feasibility_Deadline__c',
        'Feasibility_Missed__c', 'Loan_Required__c'
    };

    /**
     * Loads Transactions for the CHECKLIST fan-out and reconcile - the base fields above plus any
     * describe-validated conditional-gating fields from `Task_Group_Def__mdt.Condition_Field__c`.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` (the dynamic-query equivalent of `WITH SYSTEM_MODE`) - AUTOMATION
     * PATH, AND DELIBERATELY DIFFERENT FROM `selectByIdsWithConditionFields` ABOVE, WHICH IS
     * `USER_MODE`. Three facts make that difference a correctness requirement rather than a
     * preference:
     *   • The caller is `ChecklistFanoutService`, driven from a Queueable and ultimately from a
     *     record-triggered Flow that declares no `runInMode` - a read performed ON the deal driver's
     *     behalf, never at their request.
     *   • `USER_MODE` THROWS rather than degrades. One missing FLS grant raises
     *     `System.QueryException: No such column`, which inside the fan-out chain aborts the whole
     *     job. That exact failure rolled back an entire 82-row Day-0 fan-out in this org on
     *     2026-08-05 (see `TaskSelector`'s header).
     *   • `Checklist_Fanned_Out__c` is brand new and, like every Metadata-API-deployed field, has
     *     FieldPermissions rows for NOBODY on the day it deploys - so a `USER_MODE` read of it would
     *     fail for every principal, not an unlucky few.
     * ⚠ SYSTEM_MODE lifts CRUD/FLS and NEVER sharing, and it is not widened here. A principal who
     * cannot see a deal gets no row, and the fan-out then does nothing for it - a loud absence
     * rather than a silent partial checklist.
     *
     * ⚠ ALSO USED BY `ChecklistRollupService` AS ITS DUAL-MODEL GUARD READ, with an EMPTY condition
     * set. That is not a misuse: the guard needs exactly `Checklist_Fanned_Out__c` and nothing else,
     * and reusing this method keeps the field list in one place.
     *
     * @param transactionIds  Transaction Ids to load (bound as `:ids`).
     * @param conditionFields Extra field API names from the CMDT rows; each is describe-validated
     *                        and de-duplicated before use. May be null/empty.
     * @return Map of Transaction Id -> Transaction__c; an empty map when transactionIds is
     *         null/empty.
     * @example
     * Map<Id, Transaction__c> deals =
     *     TransactionSelector.selectForChecklistFanout(dealIds, conditionFields);
     */
    public static Map<Id, Transaction__c> selectForChecklistFanout(
        Set<Id> transactionIds,
        Set<String> conditionFields
    ) {
        return queryByIds(transactionIds, CHECKLIST_BASE_FIELDS, conditionFields,
            AccessLevel.SYSTEM_MODE);
    }

    /**
     * Loads Transactions for `CriticalDateService.ensureFor`.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` - AUTOMATION PATH, BUT NOT A TRIGGER PATH ANY MORE. This said
     * "Fired from `TransactionTrigger`'s after-update context" until 2026-09-01, when that arm was
     * REMOVED by user decision (see `TransactionTriggerHandler.afterUpdate` for the gates that must
     * close before it is re-wired). `CriticalDateService.ensureFor` has ONE production caller today:
     * `scripts/seed-critical-dates.apex`.
     * The exemption still stands, and on stronger ground rather than weaker: the read is performed
     * ON A PRINCIPAL'S BEHALF (a bulk projection over deals the operator did not individually ask
     * for), and `USER_MODE` THROWS rather than degrades - one ungranted custom field would abort the
     * whole script mid-run rather than skipping a column. It is also the mode the arm will need
     * again the day it is re-wired, and flipping it twice would be churn.
     * ⚠ RE-READ THIS IF THE TRIGGER ARM RETURNS: the "a throw rolls back the user's own deal save"
     * consequence is currently DORMANT, not gone. It comes straight back with the arm.
     * ⚠ Sharing is NOT lifted. That matters MORE on the script path than it did on the trigger path,
     * where the saving user could by definition see their own deal: an operator running the seed
     * script only projects dates for deals they can SEE, silently. The script's own header carries
     * the "run as an administrator" warning for exactly this reason.
     *
     * @param transactionIds Transaction Ids to load.
     * @return Map of Transaction Id -> Transaction__c with the coherence-gate fields populated.
     * @example
     * Map<Id, Transaction__c> deals = TransactionSelector.selectForCriticalDates(dealIds);
     */
    public static Map<Id, Transaction__c> selectForCriticalDates(Set<Id> transactionIds) {
        return queryByIds(transactionIds, CRITICAL_DATE_FIELDS, null, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Shared dynamic-query builder for the three by-Id reads above. Two safeguards make the dynamic
     * SELECT safe, exactly as the original `selectByIdsWithConditionFields` established: every extra
     * field name is validated against the live `Transaction__c` describe before it is concatenated
     * (so a typo'd or renamed CMDT row is skipped rather than injected), and the record filter is a
     * BOUND `:ids` map entry via `Database.queryWithBinds`, never string concatenation.
     *
     * @param transactionIds Ids to load.
     * @param baseFields     The always-selected field list for this caller.
     * @param extraFields    Optional describe-validated additions; may be null/empty.
     * @param mode           The access level to run the query under.
     * @return Map of Id -> Transaction__c; empty when transactionIds is null/empty.
     */
    private static Map<Id, Transaction__c> queryByIds(
        Set<Id> transactionIds,
        List<String> baseFields,
        Set<String> extraFields,
        AccessLevel mode
    ) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return new Map<Id, Transaction__c>();
        }
        Set<String> selectedLower = new Set<String>();
        List<String> fields = new List<String>();
        for (String baseField : baseFields) {
            if (selectedLower.add(baseField.toLowerCase())) {
                fields.add(baseField);
            }
        }
        if (extraFields != null && !extraFields.isEmpty()) {
            Map<String, Schema.SObjectField> fieldMap =
                Schema.SObjectType.Transaction__c.fields.getMap();
            for (String extraField : extraFields) {
                if (String.isBlank(extraField)) {
                    continue;
                }
                String trimmed = extraField.trim();
                String key = trimmed.toLowerCase();
                if (fieldMap.containsKey(key) && selectedLower.add(key)) {
                    fields.add(trimmed);
                }
            }
        }
        String query =
            'SELECT ' + String.join(fields, ', ') +
            ' FROM Transaction__c' +
            ' WHERE Id IN :ids';
        List<Transaction__c> rows = (List<Transaction__c>) Database.queryWithBinds(
            query,
            new Map<String, Object>{ 'ids' => transactionIds },
            mode
        );
        return new Map<Id, Transaction__c>(rows);
    }

    /**
     * All Transactions with the fields the dashboard KPI header aggregates in
     * memory — backs TransactionController.getKpis. Intentionally UNFILTERED:
     * the active-count / in-contract-value / earnest-at-risk / wire-approvals /
     * time-to-close tiles count only Active rows, but the missed-feasibility
     * tile is a year-to-date count ACROSS every Transaction, so the caller must
     * see all rows and branch in Apex.
     *
     * @return Every Transaction with the KPI field set populated; empty when
     *         there are no Transactions.
     * @example
     * for (Transaction__c t : TransactionSelector.selectForKpis()) { ... }
     */
    public static List<Transaction__c> selectForKpis() {
        return [
            SELECT Status__c, Contract_Value__c, Earnest_Money__c, Is_Earnest_At_Risk__c,
                   Contract_Executed_Date__c, Target_Close_Date__c, Is_Wire_Approval_Due__c,
                   Feasibility_Missed__c, Feasibility_Deadline__c
            FROM Transaction__c
            WITH USER_MODE
        ];
    }

    /**
     * Active Transactions with their task-rollup fields — backs
     * TransactionController.getTaskSummary (the sidebar task posture cards).
     *
     * @return Active Transactions with Tasks_Total__c / Tasks_Complete__c /
     *         Tasks_Overdue__c / Wire_Open_Risks__c populated; empty when none
     *         are Active.
     */
    public static List<Transaction__c> selectActiveForTaskSummary() {
        return [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c
            FROM Transaction__c
            WHERE Status__c = :STATUS_ACTIVE
            WITH USER_MODE
        ];
    }

    /**
     * Stage of every Active Transaction — backs TransactionController
     * .getStageBreakdown (the sidebar donut), which counts by Stage__c in memory.
     *
     * @return Active Transactions with Stage__c populated; empty when none are
     *         Active.
     */
    public static List<Transaction__c> selectActiveStages() {
        return [
            SELECT Stage__c
            FROM Transaction__c
            WHERE Status__c = :STATUS_ACTIVE
            WITH USER_MODE
        ];
    }

    /**
     * Active Transactions, name-ordered, with the columns the Active-Transactions
     * table renders — backs TransactionController.getActiveTransactions.
     *
     * ── 🔴 `Property__r.Name` IS THE PROPERTY COLUMN'S REAL SOURCE (added 2026-08-12) ──
     * `Property_Name__c` is a plain Text(120) field that NOTHING IN THE APPLICATION
     * POPULATES: ContractExecutionService creates every Transaction with the
     * `Property__c` LOOKUP and never the text twin, so the dashboard's Property
     * column rendered `—` on every application-created row (measured org-wide: zero
     * Transactions carry a non-blank value). The lookup traversal is the fix.
     *
     * ⚠ `Property_Name__c` STAYS IN THE SELECT and is NOT deleted. It holds the five
     * names scripts/seed-transactions.apex writes (those seeded rows set the text
     * field and NOT the lookup, so a lookup-only read would blank the exact rows that
     * show data today — the fix would invert on the demo data), and FIVE report files
     * read it directly. The controller coalesces: lookup first, text second. Retiring
     * the text field and repointing those reports is a separate, tracked change.
     *
     * ⚠ THE TRAVERSAL ADDS A CRUD DEPENDENCY, NOT MERELY AN FLS ONE. `WITH USER_MODE`
     * THROWS rather than degrades, so a persona that can read Transaction__c but has
     * no read on the `Property__c` OBJECT kills this whole query and with it the
     * entire Active Transactions LWC. `DPEG_Transaction_Team` composes
     * `DPEG_Property_View`, and `Transaction__c.Property__c` is granted readable by
     * both `DPEG_Transaction_Edit` and `DPEG_Transaction_View` (verified 2026-08-12);
     * `Property__c.Name` is a standard Name field, on which FLS cannot be configured.
     * Re-check those three facts before adding any further parent traversal here.
     *
     * ⚠ `Tasks_Total__c` IS SELECTED PER ROW AND THAT IS THE POINT (added 2026-08-12).
     * TaskFanoutService writes `Tasks_Total__c = createdForTxn` — the count actually
     * created for THAT Transaction, gated by that Transaction's own condition fields
     * (Loan_Required__c and friends from Task_Group_Def__mdt.Condition_Field__c) — so
     * the denominator genuinely differs between rows and NO CONSTANT CAN BE RIGHT.
     * The LWC used to hardcode 75 while the record page's Tasks_Display__c formula
     * showed 82; both were wrong. Do not reintroduce a fixed total anywhere.
     * ⚠ It is NULL on a Transaction created but not yet fanned out
     * (`Tasks_Fanned_Out__c = false`), which every consumer must null-guard.
     * Both permission sets already grant it readable (verified 2026-08-12) — worth
     * confirming precisely because USER_MODE throws rather than degrades.
     *
     * @return Active Transactions ordered by Name with the row field set
     *         populated; empty when none are Active.
     */
    public static List<Transaction__c> selectActiveRows() {
        return [
            SELECT Id, Name, Property_Name__c, Property__r.Name, Stage__c, Contract_Value__c,
                   Target_Close_Date__c, Tasks_Complete__c, Tasks_Total__c, Risk__c, Owner_Name__c
            FROM Transaction__c
            WHERE Status__c = :STATUS_ACTIVE
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * Transactions that belong to any of the supplied Opportunities — backs the
     * idempotency guard in ContractExecutionService.handleExecution (a deal that
     * already owns a Transaction is not handed off a second time). Only
     * Opportunity__c is selected because that is all the caller de-duplicates on.
     *
     * @param opportunityIds Parent Opportunity Ids to match (bound with IN).
     * @return Transactions whose Opportunity__c is in the set (Opportunity__c
     *         populated); an empty list when opportunityIds is null/empty.
     * @example
     * List<Transaction__c> existing =
     *     TransactionSelector.selectByOpportunityIds(executedOppIds);
     */
    public static List<Transaction__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Transaction__c>();
        }
        return [
            SELECT Opportunity__c
            FROM Transaction__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * Loads a Transaction for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance (added 2026-08-12).
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it
     * back, so a miss is an error, not a normal state. A single-row SOQL assignment
     * throws native System.QueryException, matching NdaSelector /
     * UnderwritingSelector / ContractReviewSelector.selectStageRequiredById and
     * OpportunitySelector.selectStageRequiredById.
     *
     * 🔴 `RecordTypeId` IS DELIBERATELY NOT SELECTED, AND THAT IS A COMPILE FACT
     * RATHER THAN A PREFERENCE. `Transaction__c` HAS NO RECORD TYPES (there is no
     * `objects/Transaction__c/recordTypes/` folder, verified in the org 2026-08-12),
     * and a custom object with zero record types has no `RecordTypeId` field at all —
     * selecting it would not degrade, it would fail to compile. The three
     * record-type-free siblings (`Underwriting__c`, `Construction_Feasibility_Review__c`,
     * `Development_Feasibility_Review__c`) omit it for exactly this reason, and
     * RecordStageAdvanceService.recordTypeIdOf reads through
     * getPopulatedFieldsAsMap() precisely so an unselected field is `null` rather
     * than an SObjectException. The service then takes its single-sequence branch.
     * ⚠ If `Transaction__c` is ever GIVEN record types, this field becomes mandatory
     * here — omitting it then would silently route every Transaction to the default
     * sequence with no error anywhere.
     *
     * Field list is deliberately MINIMAL (Id + the stage field) per this selector's
     * per-caller philosophy: the advance write touches nothing else, and under
     * `WITH USER_MODE` every extra field is another way for this read to throw.
     *
     * @param transactionId Transaction__c Id; must reference an existing row.
     * @return The Transaction with Id and Stage__c populated.
     * @throws System.QueryException when no Transaction matches the Id.
     * @example
     * Transaction__c txn = TransactionSelector.selectStageRequiredById(recordId);
     */
    public static Transaction__c selectStageRequiredById(Id transactionId) {
        return [
            SELECT Id, Stage__c
            FROM Transaction__c
            WHERE Id = :transactionId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
