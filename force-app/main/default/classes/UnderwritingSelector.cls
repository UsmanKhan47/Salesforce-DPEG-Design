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

    /**
     * Underwritings related to a set of Opportunities — backs
     * OpportunityReviewService.createReviewRecords idempotency (drop any deal that
     * already has an Underwriting so entering the Underwriting stage never opens a
     * second). Added by Module A2: the A2 service repoint needs a bulk, set-based
     * existence read that A1's single-record methods do not provide. Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Underwritings with Id and Opportunity__c populated; empty when the
     *         input is null or empty.
     */
    public static List<Underwriting__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Underwriting__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM Underwriting__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * The Ids of Underwritings related to a set of Opportunities — backs
     * ApprovalAuditService, which on principal sign-off advances each related
     * Underwriting to Approved (it needs only Id to build the update). Added by P4
     * cleanup wave G.
     *
     * DELIBERATELY DISTINCT from selectByOpportunityIds (which also selects
     * Opportunity__c): the audit read needs ONLY Id, and this selector's per-caller
     * "minimal field list" philosophy keeps the USER_MODE FLS surface as small as the
     * caller requires. The original ApprovalAuditService query was `SELECT Id`; adding
     * Opportunity__c here would widen the FLS surface (that custom lookup is
     * FLS-controlled) and could throw USER_MODE where the Id-only read would not.
     * Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Underwritings with Id populated; an empty list when the input is null
     *         or empty (never null).
     */
    public static List<Underwriting__c> selectIdsByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Underwriting__c>();
        }
        return [
            SELECT Id
            FROM Underwriting__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }
}
