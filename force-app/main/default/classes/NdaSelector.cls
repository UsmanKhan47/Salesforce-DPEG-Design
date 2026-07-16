/**
 * Selector for NDA__c. Encapsulates ALL SOQL against NDA__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer: OpportunityDocStatusController
 * (the Deal Summary card's NDA row). NDA__c is a custom object — USER_MODE (P3
 * custom-field FLS gap = 0). No SYSTEM_MODE / guest path in A1.
 *
 * NOT-FOUND CONTRACT — read-for-display: both consumer lookups (designated
 * Primary_NDA__c, else most-recent related NDA) treat "no NDA" as a normal state,
 * so both methods return SObject-or-null.
 *
 * DESIGN DEVIATION (noted in the A1 hand-off report): the P4 design §4 Skeleton C
 * proposed one dynamic `selectOneByClause(String tail, Id pid)` fed an allow-listed
 * WHERE fragment from the controller. That is replaced here by two static, named
 * methods. Rationale: (1) apex-layering-rule (non-negotiable) requires the selector
 * to own its full query text — passing a WHERE fragment from the controller is the
 * controller "writing its own query"; (2) it removes an avoidable dynamic-SOQL
 * string concatenation the analyzer flags as injection surface. Behavior
 * (primary-else-latest, null-on-empty) is preserved byte-for-byte.
 *
 * @see agent-output/p4-selector-design.md (§3 #8, §5)
 */
public with sharing class NdaSelector {

    /**
     * The NDA designated as an Opportunity's primary NDA (Primary_NDA__c lookup).
     *
     * @param ndaId NDA__c Id (the deal's Primary_NDA__c); null-safe.
     * @return The NDA with the Deal Summary field set, or null when the input is
     *         null or the row does not exist.
     */
    public static NDA__c selectById(Id ndaId) {
        if (ndaId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created NDA related to an Opportunity — the fallback when
     * no primary NDA is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related NDA (ORDER BY CreatedDate DESC LIMIT 1), or null
     *         when the input is null or the Opportunity has no NDA.
     */
    public static NDA__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}
