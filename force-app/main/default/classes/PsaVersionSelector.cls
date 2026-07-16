/**
 * Selector for PSA_Version__c. Encapsulates ALL SOQL against PSA_Version__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: PsaVersionController
 * (the psaVersionLog LWC — full PSA draft/counter history + prior-count for the
 * Ball_In_Court__c / Negotiation_Status__c derivation on save).
 *
 * MODE — every query is `WITH USER_MODE` (API 67). PSA_Version__c is a custom
 * object; P3 proved the custom-field FLS gap is 0, so USER_MODE enforces the
 * running user's sharing + FLS and cannot throw on the selected fields. There is
 * no guest path for PSA versions — no SYSTEM_MODE here.
 *
 * NOT-FOUND CONTRACT — read-for-display: both callers treat "no versions" as a
 * normal state, so the list method returns an empty List and the count method
 * returns 0 (never null).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #7, §4, §5)
 */
public with sharing class PsaVersionSelector {

    /**
     * Full PSA version history for one Contract Review, newest first — backs
     * PsaVersionController.getVersions (the psaVersionLog timeline).
     *
     * @param contractReviewId Parent Contract_Review__c Id; null-safe.
     * @return PSA_Version__c rows ordered by CreatedDate DESC, Name DESC; empty
     *         when the input is null or the Contract Review has no versions.
     * @example
     * List<PSA_Version__c> versions = PsaVersionSelector.selectByContractReviewId(crId);
     */
    public static List<PSA_Version__c> selectByContractReviewId(Id contractReviewId) {
        if (contractReviewId == null) {
            return new List<PSA_Version__c>();
        }
        return [
            SELECT Id, Name, Direction__c, Version_Date__c, Summary__c, Document_URL__c, CreatedDate
            FROM PSA_Version__c
            WHERE Contract_Review__c = :contractReviewId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Name DESC
        ];
    }

    /**
     * Count of existing PSA versions for a Contract Review — backs
     * PsaVersionController.saveVersion (priorCount == 0 && from-seller => the seller
     * drafts first = "Initial Draft"; otherwise it is a counter, and priorCount + 1
     * is the new Latest_Version__c).
     *
     * @param contractReviewId Parent Contract_Review__c Id; null-safe.
     * @return The number of PSA versions already logged (0 when the input is null
     *         or none exist).
     */
    public static Integer countByContractReviewId(Id contractReviewId) {
        if (contractReviewId == null) {
            return 0;
        }
        return [
            SELECT COUNT()
            FROM PSA_Version__c
            WHERE Contract_Review__c = :contractReviewId
            WITH USER_MODE
        ];
    }
}
