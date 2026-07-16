/**
 * Selector for Deal_Message__c. Encapsulates ALL SOQL against Deal_Message__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: DealMessageController
 * (the dealMessageLog LWC shared by the Messages tab on LOI, Underwriting, and
 * Contract Review record pages — one component/controller for all three parents).
 *
 * MODE — `WITH USER_MODE` via AccessLevel on the dynamic query (API 67).
 * Deal_Message__c is a custom object; P3 proved the custom-field FLS gap is 0, so
 * USER_MODE is safe. No guest path — no SYSTEM_MODE here.
 *
 * DYNAMIC-QUERY NOTES (P4 design §6):
 *   - The parent lookup is chosen at runtime from the record's SObjectType, so the
 *     WHERE column is a variable. `parentField` is validated against the
 *     PARENT_FIELDS allow-list below before concatenation — it is never free user
 *     input (the controller derives it from recordId.getSobjectType()), and the
 *     allow-list is a second, in-selector defense against injection.
 *   - The original inline query bound `:recordId` to a controller method-local.
 *     Relocating the query breaks that lexical scope, so the bind is passed
 *     explicitly via Database.queryWithBinds — a naive Database.query move would
 *     compile but fail at runtime with an unresolved bind.
 *
 * NOT-FOUND CONTRACT — read-for-display: a parent with no messages is normal, so
 * this returns an empty List (never null). The controller maps rows to Entry DTOs.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #14, §4 Skeleton C, §6)
 */
public with sharing class DealMessageSelector {

    /**
     * Deal_Message__c parent lookup API names this selector will filter on.
     * Mirrors DealMessageController.PARENT_FIELDS. Any value not in this set is
     * rejected before it reaches the query text.
     */
    private static final Set<String> PARENT_FIELDS = new Set<String>{
        'LOI__c', 'Underwriting__c', 'Contract_Review__c'
    };

    /**
     * Messages logged against one parent record (LOI / Underwriting / Contract
     * Review), newest first — backs DealMessageController.getMessages.
     *
     * @param parentField The Deal_Message__c lookup field to filter on; must be one
     *                    of LOI__c / Underwriting__c / Contract_Review__c.
     * @param recordId    Parent record Id (the value bound into the WHERE clause).
     * @return Deal_Message__c rows (with CreatedBy.Name populated) ordered by
     *         Entry_DateTime__c DESC, CreatedDate DESC, Id DESC; empty when the
     *         input is null/blank.
     * @throws System.QueryException when parentField is not an allow-listed parent
     *         lookup (defense-in-depth against a bad caller / injection).
     */
    public static List<Deal_Message__c> selectByParent(String parentField, Id recordId) {
        if (recordId == null || String.isBlank(parentField)) {
            return new List<Deal_Message__c>();
        }
        if (!PARENT_FIELDS.contains(parentField)) {
            throw new QueryException('Unsupported Deal_Message__c parent field: ' + parentField);
        }
        String soql =
            'SELECT Id, Method__c, Direction__c, Details__c, Revision__c, ' +
            'Entry_DateTime__c, CreatedDate, CreatedBy.Name ' +
            'FROM Deal_Message__c ' +
            'WHERE ' + parentField + ' = :recordId ' +
            'ORDER BY Entry_DateTime__c DESC, CreatedDate DESC, Id DESC';
        return Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );
    }
}
