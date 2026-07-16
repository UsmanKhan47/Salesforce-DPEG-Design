/**
 * Selector for Contract_Review__c. Encapsulates ALL SOQL against Contract_Review__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's Contract Review row
 *     (latest-related only; the card has no primary-contract-review lookup).
 *   - OpportunityApprovalController.resolveDealId — resolves the parent deal Id
 *     from a clicked Contract Review record (fetch-for-use, throws on miss).
 *
 * Contract_Review__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0).
 *
 * selectLatestByOpportunityId returns a List (0 or 1 rows) so the caller's
 * `for (Contract_Review__c cr : ...)` loop is preserved byte-for-byte — the
 * original inline query was consumed by a for-loop, not a single assignment.
 * selectOpportunityIdRequiredById uses a single-row assignment that throws native
 * System.QueryException on a miss, matching the original resolveDealId query.
 *
 * @see agent-output/p4-selector-design.md (§3 #11, §5)
 */
public with sharing class ContractReviewSelector {

    /**
     * The most recently created Contract Review related to an Opportunity.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return A list of 0 or 1 Contract Reviews (ORDER BY CreatedDate DESC LIMIT 1);
     *         empty when the input is null or the Opportunity has none.
     */
    public static List<Contract_Review__c> selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return new List<Contract_Review__c>();
        }
        return [
            SELECT Id, Stage__c, Contract_Value__c, PSA_Date__c, Execution_Date__c
            FROM Contract_Review__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    /**
     * Loads a Contract Review for parent-deal resolution — backs
     * OpportunityApprovalController.resolveDealId.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param contractReviewId Contract_Review__c Id; must reference an existing row.
     * @return The Contract Review with Id and Opportunity__c populated.
     * @throws System.QueryException when no Contract Review matches the Id.
     */
    public static Contract_Review__c selectOpportunityIdRequiredById(Id contractReviewId) {
        return [
            SELECT Id, Opportunity__c
            FROM Contract_Review__c
            WHERE Id = :contractReviewId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
