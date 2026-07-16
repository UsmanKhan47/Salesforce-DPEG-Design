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
 * MODE — `AccessLevel.USER_MODE` (the dynamic-query equivalent of the illegal
 * `WITH USER_MODE` clause, per design §6). Transaction__c is custom; P3 proved
 * the custom-field FLS gap is 0, so USER_MODE enforces the running user's
 * sharing + FLS without stripping the selected fields. No guest path, no
 * SYSTEM_MODE.
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
            SELECT Status__c, Contract_Value__c, Earnest_Money__c, Earnest_At_Risk__c,
                   Contract_Executed_Date__c, Target_Close_Date__c, Wire_Approval_Due__c,
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
     * @return Active Transactions ordered by Name with the row field set
     *         populated; empty when none are Active.
     */
    public static List<Transaction__c> selectActiveRows() {
        return [
            SELECT Id, Name, Property_Name__c, Stage__c, Contract_Value__c,
                   Target_Close_Date__c, Tasks_Complete__c, Risk__c, Owner_Name__c
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
}
