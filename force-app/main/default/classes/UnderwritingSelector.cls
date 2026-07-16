/**
 * Selector for Underwriting__c. Encapsulates ALL SOQL against Underwriting__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's Underwriting row
 *     (primary-else-latest, read-for-display, null-on-empty).
 *   - OpportunityApprovalController.resolveDealId — resolves the parent deal Id
 *     from a clicked Underwriting record (fetch-for-use, throws on miss).
 *
 * Underwriting__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0).
 *
 * Two not-found contracts coexist, so two method families exist:
 *   - selectById / selectLatestByOpportunityId : read-for-display -> return null.
 *   - selectOpportunityIdRequiredById          : fetch-for-use    -> single-row
 *     SOQL assignment; a miss throws native System.QueryException, matching the
 *     original `[SELECT Opportunity__c FROM Underwriting__c WHERE Id = :recordId
 *     LIMIT 1].Opportunity__c` assignment in resolveDealId.
 *
 * Field lists are deliberately per-caller (P4 design §4 note 4): the doc-status
 * reads select the card fields; the approval resolver selects only Id +
 * Opportunity__c, keeping the USER_MODE FLS surface minimal.
 *
 * @see agent-output/p4-selector-design.md (§3 #9, §5)
 */
public with sharing class UnderwritingSelector {

    /**
     * The Underwriting designated as an Opportunity's primary (Primary_Underwriting__c).
     *
     * @param underwritingId Underwriting__c Id; null-safe.
     * @return The record with the Deal Summary fields set, or null when the input
     *         is null or the row does not exist.
     */
    public static Underwriting__c selectById(Id underwritingId) {
        if (underwritingId == null) {
            return null;
        }
        List<Underwriting__c> rows = [
            SELECT Id, Name, Stage__c, My_Price__c, Verdict__c, CreatedDate
            FROM Underwriting__c
            WHERE Id = :underwritingId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created Underwriting related to an Opportunity — the
     * fallback when no primary is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related Underwriting (ORDER BY CreatedDate DESC LIMIT 1),
     *         or null when the input is null or the Opportunity has none.
     */
    public static Underwriting__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<Underwriting__c> rows = [
            SELECT Id, Name, Stage__c, My_Price__c, Verdict__c, CreatedDate
            FROM Underwriting__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Loads an Underwriting for parent-deal resolution — backs
     * OpportunityApprovalController.resolveDealId.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param underwritingId Underwriting__c Id; must reference an existing row.
     * @return The Underwriting with Id and Opportunity__c populated.
     * @throws System.QueryException when no Underwriting matches the Id.
     */
    public static Underwriting__c selectOpportunityIdRequiredById(Id underwritingId) {
        return [
            SELECT Id, Opportunity__c
            FROM Underwriting__c
            WHERE Id = :underwritingId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
