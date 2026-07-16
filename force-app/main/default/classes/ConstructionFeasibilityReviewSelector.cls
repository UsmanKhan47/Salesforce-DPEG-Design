/**
 * Selector for Construction_Feasibility_Review__c. Encapsulates ALL SOQL against
 * Construction_Feasibility_Review__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer:
 * OpportunityDocStatusController — Deal Summary card's Construction Feasibility row
 * (latest-related, read-for-display). Custom object — USER_MODE (P3 FLS gap = 0).
 *
 * selectLatestByOpportunityId returns a List (0 or 1 rows) so the caller's
 * `for (Construction_Feasibility_Review__c con : ...)` loop is preserved
 * byte-for-byte — the original inline query was consumed by a for-loop.
 *
 * @see agent-output/p4-selector-design.md (§3 #13, §5)
 */
public with sharing class ConstructionFeasibilityReviewSelector {

    /**
     * The most recently created Construction Feasibility Review related to an
     * Opportunity.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return A list of 0 or 1 reviews (ORDER BY CreatedDate DESC LIMIT 1); empty
     *         when the input is null or the Opportunity has none.
     */
    public static List<Construction_Feasibility_Review__c> selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return new List<Construction_Feasibility_Review__c>();
        }
        return [
            SELECT Id, Stage__c, CreatedDate
            FROM Construction_Feasibility_Review__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }
}
