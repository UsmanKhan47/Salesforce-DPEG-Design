/**
 * Selector for BOV_Submission__c. Encapsulates ALL SOQL against
 * BOV_Submission__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumer:
 *   - BovController.getSubmissions (the broker-outreach matrix on the Disposition
 *     record page).
 *
 * MODE — the single query uses `WITH USER_MODE` (API 67). BOV_Submission__c is a
 * custom object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe
 * and enforces the running user's sharing + FLS. There is no guest path for the
 * Disposition module, so no SYSTEM_MODE appears here.
 *
 * NOT-FOUND CONTRACT — read-for-display: a Disposition with no BOV submissions is
 * a normal state, so the list method returns its natural empty List, never null.
 * The dispositionId is bound straight into the WHERE clause, mirroring the exact
 * query semantics of the relocated getSubmissions statement (which had no
 * pre-query null guard).
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 */
public with sharing class BovSubmissionSelector {

    /**
     * All BOV submissions for one Disposition, highest-scoring first — backs the
     * broker-outreach matrix (BovController.getSubmissions).
     *
     * BOV_Score__c is a Number, so the ORDER BY is a numeric sort (DESC NULLS
     * LAST); unscored submissions fall to the bottom. The field list is the exact
     * set BovController.BovRow maps, so narrowing it would reintroduce a
     * "row retrieved via SOQL without querying the requested field" defect.
     *
     * @param dispositionId Disposition__c Id whose submissions to read.
     * @return The matching BOV_Submission__c records ordered by BOV_Score__c
     *         DESC NULLS LAST; an empty list when the Disposition has none (or
     *         when dispositionId is null).
     * @example
     * List<BOV_Submission__c> subs =
     *     BovSubmissionSelector.selectByDispositionId(dispId);
     */
    public static List<BOV_Submission__c> selectByDispositionId(Id dispositionId) {
        return [
            SELECT Id, Broker_Firm__c, Contact_Name__c, BOV_Amount__c,
                   Commission_Rate__c, Days_To_Market__c, Hist_Success_Rate__c,
                   Cap_Rate__c, BOV_Score__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY BOV_Score__c DESC NULLS LAST
        ];
    }
}
