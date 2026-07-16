/**
 * Selector for Development_Feasibility_Review__c. Encapsulates ALL SOQL against
 * Development_Feasibility_Review__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer:
 * OpportunityDocStatusController — Deal Summary card's Development Feasibility row
 * (latest-related, read-for-display). Custom object — USER_MODE (P3 FLS gap = 0).
 *
 * selectLatestByOpportunityId returns a List (0 or 1 rows) so the caller's
 * `for (Development_Feasibility_Review__c dev : ...)` loop is preserved
 * byte-for-byte — the original inline query was consumed by a for-loop.
 *
 * @see agent-output/p4-selector-design.md (§3 #12, §5)
 */
public with sharing class DevelopmentFeasibilityReviewSelector {

    /**
     * The most recently created Development Feasibility Review related to an
     * Opportunity.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return A list of 0 or 1 reviews (ORDER BY CreatedDate DESC LIMIT 1); empty
     *         when the input is null or the Opportunity has none.
     */
    public static List<Development_Feasibility_Review__c> selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return new List<Development_Feasibility_Review__c>();
        }
        return [
            SELECT Id, Stage__c, CreatedDate
            FROM Development_Feasibility_Review__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    /**
     * Development Feasibility Reviews related to a set of Opportunities — backs
     * OpportunityReviewService.createReviewRecords idempotency (drop any deal that
     * already has a Development review so the stage/input-needed trigger never opens
     * a second). Added by Module A2: the A2 service repoint needs a bulk, set-based
     * existence read that A1's single-record method does not provide. Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Reviews with Id and Opportunity__c populated; empty when the input is
     *         null or empty.
     */
    public static List<Development_Feasibility_Review__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Development_Feasibility_Review__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM Development_Feasibility_Review__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }
}
