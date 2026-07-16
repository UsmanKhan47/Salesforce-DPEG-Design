/**
 * Selector for Transaction__c. Encapsulates ALL SOQL against Transaction__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * Consumer: TaskFanoutService.fanOutNow (the Day-0 checklist fan-out).
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
}
