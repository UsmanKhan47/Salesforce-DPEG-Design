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

    /**
     * NDAs related to a set of Opportunities — backs OpportunityReviewService.ensureNda
     * idempotency (drop any deal that already has an NDA so a second is never opened).
     * Added by Module A2: the A2 OpportunityReviewService repoint needs a bulk,
     * set-based existence read that A1's single-record methods do not provide.
     * Bulk-safe (one query for the whole set).
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return NDAs with Id and Opportunity__c populated; empty when the input is
     *         null or empty.
     */
    public static List<NDA__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<NDA__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM NDA__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * Loads an NDA for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error, not a normal state. A single-row SOQL assignment throws native
     * System.QueryException, matching OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ NDA__c's stage field is `Status__c`, NOT `Stage__c` — it is the only one of the five
     * stage-controlled acquisitions children shaped that way, which is why
     * RecordStageAdvanceService carries the field name per object.
     *
     * Field list is deliberately MINIMAL (Id + the stage field) per this selector's per-caller
     * philosophy: the advance write touches nothing else, so widening it would only enlarge the
     * USER_MODE FLS surface and create denials the action does not need.
     *
     * @param ndaId NDA__c Id; must reference an existing row.
     * @return The NDA with Id and Status__c populated.
     * @throws System.QueryException when no NDA matches the Id.
     */
    public static NDA__c selectStageRequiredById(Id ndaId) {
        return [
            SELECT Id, Status__c
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
