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
 *   - DealTransactionGateService.recalculate (the "a deal cannot close until its
 *     transaction is closed" gate — aggregateStatusCountsByOpportunityIds, added
 *     2026-09-02; the class's FIRST sharing escape, see MODE below).
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
 * THREE methods are `AccessLevel.SYSTEM_MODE` / `WITH SYSTEM_MODE`, each justified
 * at its own declaration, all on an AUTOMATION PATH where USER_MODE THROWS rather
 * than degrades and one missing FLS grant becomes a rolled-back user save:
 *   • selectForChecklistFanout              <- ChecklistFanoutService, ChecklistRollupService
 *   • selectForCriticalDates                <- CriticalDateService, from a script AND (added
 *                                              2026-09-02) from ChecklistOutcomeService when an
 *                                              ordinary user completes checklist item A5
 *   • aggregateStatusCountsByOpportunityIds <- DealTransactionGateService, from TransactionTrigger
 *                                              (added 2026-09-02)
 *
 * ⚠ AMENDED 2026-08-31 — this block previously ended "No guest path, no
 * SYSTEM_MODE." That was true when written and is NO LONGER TRUE. ARCHITECTURE §2
 * makes these headers the authoritative inventory of which reads escape and why,
 * so a stale one is worse than none: it tells the next governor or security review
 * that no exemption exists here. Read the METHOD, not this summary, for the
 * reasoning — the mode is a property of the method, never of the class.
 *
 * ⚠ SCOPE OF THE BYPASS: SYSTEM_MODE lifts CRUD/FLS and NEVER sharing. This class
 * stays `with sharing`, and TWO of the three exempt methods
 * (selectForChecklistFanout, selectForCriticalDates) therefore still return only
 * rows the running user can already see.
 *
 * 🔴 AMENDED 2026-09-02 — AND THAT SENTENCE IS NO LONGER TRUE OF ALL OF THEM. It
 * used to read "…so both exempt methods still return only rows the running user can
 * already see", which is exactly the kind of stale summary the paragraph above warns
 * about. `aggregateStatusCountsByOpportunityIds` ALSO ESCAPES SHARING, through the
 * `private without sharing` inner class `DealCloseGateReads`. That is a SEPARATE,
 * separately-measured decision from its mode — `Transaction__c` OWD is Private on
 * both models and a sharing-filtered count INVERTS the deal-close gate rather than
 * degrading it. The argument is at that method's declaration; do not summarise it
 * here and do not extend the inner class to a second query.
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
     * close before it is re-wired).
     * 🔴 AMENDED 2026-09-02 — THIS SAID "`CriticalDateService.ensureFor` has ONE production caller
     * today: `scripts/seed-critical-dates.apex`." THERE ARE NOW TWO. Phase 5's
     * `ChecklistOutcomeService.applyForCompletedItems` calls it when an ORDINARY USER completes
     * checklist item A5, one deal at a time. Still not a trigger, but no longer operator-only.
     * The exemption still stands, and on stronger ground rather than weaker: the read is performed
     * ON A PRINCIPAL'S BEHALF (a bulk projection over deals the operator did not individually ask
     * for), and `USER_MODE` THROWS rather than degrades - one ungranted custom field would abort the
     * whole script mid-run rather than skipping a column. It is also the mode the arm will need
     * again the day it is re-wired, and flipping it twice would be churn.
     * ⚠ THE "A THROW ROLLS BACK THE USER'S OWN SAVE" CONSEQUENCE IS NO LONGER DORMANT. This said it
     * was, and would return only with the trigger arm. On the A5 path it is ALREADY LIVE: this read
     * runs inside the same transaction as the user's checklist completion, so a throw here rolls
     * back their tick. `allOrNone = false` on the downstream insert protects against ONE BAD ROW; it
     * does not protect against this read throwing.
     * ⚠ Sharing is NOT lifted, and it now cuts two ways. On the SCRIPT path an operator only
     * projects dates for deals they can SEE, silently — the script's header carries the "run as an
     * administrator" warning for that reason. On the A5 path the saving user can by definition see
     * their own deal, so the silent-partial risk does not arise there.
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
     * How many Transactions each supplied deal owns, split by `Status__c` — backs
     * `DealTransactionGateService.recalculate`, which turns the answer into the two Opportunity
     * flags the "a deal cannot close until its transaction closes" validation rule reads
     * (added 2026-09-02).
     *
     * ── 🔴 MODE = `WITH SYSTEM_MODE`. AUTOMATION PATH, AND THE ONLY ONE OF THE THREE THAT IS A
     * TRIGGER PATH ─────────────────────────────────────────────────────────────────────────────
     * This runs from `TransactionTrigger`'s after contexts as whoever saved the Transaction. Under
     * `WITH USER_MODE` one missing FLS grant does not degrade — it raises
     * `System.QueryException: No such column`, which inside an after-trigger escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back that user's own save. Every DPEG
     * persona is on `Minimum Access` and `Transaction__c.Status__c` / `Opportunity__c` are granted
     * only by the two Transaction permission sets, so a persona who can create or edit a
     * Transaction through some other route (a data load, a queue-owned record, an admin fix) but
     * lacks one of those two grants would silently kill the gate. ARCHITECTURE.md §2's
     * automation-path exception is exactly this case.
     *
     * ── 🔴 SHARING = `without sharing`, VIA THE NARROW `DealCloseGateReads` INNER CLASS BELOW.
     * THIS IS A SEPARATE DECISION FROM THE MODE AND IT WAS MEASURED, NOT ASSUMED ────────────────
     * `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing, and `Transaction__c`'s OWD is **Private**
     * on both the internal and external model (measured on `usman-dpeg` via
     * `EntityDefinition.InternalSharingModel` / `ExternalSharingModel`, 2026-09-02). A
     * sharing-filtered count therefore returns only the Transactions the SAVER can see, and the
     * failure INVERTS the gate rather than degrading it:
     *
     *   an OPEN transaction the saver cannot see  ->  `Has_Open_Transaction__c` computed FALSE
     *                                             ->  the deal becomes closable WITH AN OPEN
     *                                                 TRANSACTION, which is the one outcome the
     *                                                 whole feature exists to prevent.
     *
     * There is a second and independent argument: these are STORED DERIVED FIELDS on the parent.
     * A sharing-filtered recompute would make their value depend on WHICH USER happened to save a
     * Transaction last, which is incoherent for a field a validation rule reads on everyone's
     * behalf. Deals routinely carry Transactions owned by the Transactions queue while the deal
     * driver owns the deal, so the two-principal case is the ORDINARY case here, not an edge one.
     *
     * ⚠ It widens nothing a user can observe. Nothing leaves the inner class but two booleans
     * about record COUNTS, already implied by the validation rule's own refusal message.
     *
     * ── GROUP COUNT ARITHMETIC (the 2,000-row aggregate cap) ────────────────────────────────────
     * An aggregate query returns at most 2,000 groups. The worst case here is a full 200-record
     * trigger chunk in which every row was RE-PARENTED, contributing an old and a new deal —
     * 400 deals — times the three `Status__c` values (`Draft` / `Active` / `Closed`) = 1,200
     * groups. 🔴 If `Transaction__c.Status__c` ever gains a fourth value this arithmetic must be
     * re-derived: at six values the worst case is 2,400 and this query starts truncating SILENTLY,
     * which again inverts the gate rather than breaking it. The two-key GROUP BY is chosen over a
     * plain row query precisely because its ceiling depends on a number this class controls (deals
     * x status values) instead of on how many Transactions a deal happens to own.
     *
     * @param opportunityIds Parent Opportunity Ids to count under (bound with IN).
     * @return One AggregateResult per (Opportunity, Status) pair, aliased `oppId` / `txnStatus` /
     *         `txnCount`; an empty list when opportunityIds is null/empty.
     * @example
     * for (AggregateResult r
     *         : TransactionSelector.aggregateStatusCountsByOpportunityIds(dealIds)) {
     *     Id dealId = (Id) r.get('oppId');
     *     String status = (String) r.get('txnStatus');
     * }
     */
    public static List<AggregateResult> aggregateStatusCountsByOpportunityIds(
        Set<Id> opportunityIds
    ) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<AggregateResult>();
        }
        return new DealCloseGateReads().statusCountsByOpportunityIds(opportunityIds);
    }

    /**
     * 🔴 THE SHARING ESCAPE FOR THE DEAL-CLOSE GATE, AND NOTHING ELSE.
     *
     * `without sharing` is confined to this inner class so it applies to ONE query. The enclosing
     * `TransactionSelector` stays `with sharing` and must: it backs the Active-Transactions
     * dashboard's four user-facing reads, whose entire job is to respect what the running user may
     * see. This is the `OpportunitySelector.NdaGateReads` /
     * `InboundEmailStagingSelector.RoutingReads` shape ARCHITECTURE.md §2 prescribes.
     *
     * The full justification — including the 2026-09-02 OWD measurement that established it was
     * necessary, and why the failure it prevents INVERTS rather than degrades — is at
     * `aggregateStatusCountsByOpportunityIds`'s own declaration. Read it before touching this.
     *
     * ⚠ DO NOT ADD A SECOND METHOD HERE. Every query that lands in this class silently inherits an
     * escape argued for a different one. A new read that needs the same treatment needs its OWN
     * inner class and its OWN measurement — that is the point of keeping these narrow.
     */
    private without sharing class DealCloseGateReads {

        /**
         * The gate's count, read without sharing so a Transaction owned by the Transactions queue
         * is still counted when the deal driver is the one saving.
         *
         * @param opportunityIds Parent deals to count under; never null/empty (the wrapper guards).
         * @return One row per (Opportunity, Status) pair.
         */
        private List<AggregateResult> statusCountsByOpportunityIds(Set<Id> opportunityIds) {
            return [
                SELECT Opportunity__c oppId, Status__c txnStatus, COUNT(Id) txnCount
                FROM Transaction__c
                WHERE Opportunity__c IN :opportunityIds
                WITH SYSTEM_MODE
                GROUP BY Opportunity__c, Status__c
            ];
        }
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
