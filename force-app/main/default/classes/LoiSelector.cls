/**
 * Selector for LOI__c. Encapsulates ALL SOQL against LOI__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's LOI row
 *     (primary-else-latest, read-for-display, null-on-empty).
 *   - OpportunityApprovalController.resolveDealId — resolves the parent deal Id
 *     from a clicked LOI record (fetch-for-use, throws on miss).
 *
 * LOI__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0).
 *
 * Two not-found contracts (see UnderwritingSelector for the shared rationale):
 * selectById / selectLatestByOpportunityId return null; selectOpportunityIdRequiredById
 * throws native System.QueryException on a miss, matching the original
 * `[SELECT Opportunity__c FROM LOI__c WHERE Id = :recordId LIMIT 1].Opportunity__c`.
 *
 * @see agent-output/p4-selector-design.md (§3 #10, §5)
 */
public with sharing class LoiSelector {

    /**
     * The LOI designated as an Opportunity's primary (Primary_LOI__c lookup).
     *
     * @param loiId LOI__c Id; null-safe.
     * @return The record with the Deal Summary fields set, or null when the input
     *         is null or the row does not exist.
     */
    public static LOI__c selectById(Id loiId) {
        if (loiId == null) {
            return null;
        }
        List<LOI__c> rows = [
            SELECT Id, Name, LOI_Status__c, Offer_Price__c, Offer_Cap_Rate__c, Submitted_Date__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created LOI related to an Opportunity — the fallback when
     * no primary is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related LOI (ORDER BY CreatedDate DESC LIMIT 1), or null
     *         when the input is null or the Opportunity has none.
     */
    public static LOI__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<LOI__c> rows = [
            SELECT Id, Name, LOI_Status__c, Offer_Price__c, Offer_Cap_Rate__c, Submitted_Date__c
            FROM LOI__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Loads an LOI for parent-deal resolution — backs
     * OpportunityApprovalController.resolveDealId.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param loiId LOI__c Id; must reference an existing row.
     * @return The LOI with Id and Opportunity__c populated.
     * @throws System.QueryException when no LOI matches the Id.
     */
    public static LOI__c selectOpportunityIdRequiredById(Id loiId) {
        return [
            SELECT Id, Opportunity__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads an LOI for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error. Single-row SOQL assignment -> native System.QueryException, matching
     * OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ `Stage__c` is the Path field and is NOT `LOI_Status__c` — the approval audit writes the
     * latter, this action writes the former. Widening this method to select or write LOI_Status__c
     * would silently couple the quick action to the approval's field.
     *
     * Field list is deliberately MINIMAL (Id + Stage__c) — see the per-caller note in the class
     * header.
     *
     * @param loiId LOI__c Id; must reference an existing row.
     * @return The LOI with Id and Stage__c populated.
     * @throws System.QueryException when no LOI matches the Id.
     */
    public static LOI__c selectStageRequiredById(Id loiId) {
        return [
            SELECT Id, Stage__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
