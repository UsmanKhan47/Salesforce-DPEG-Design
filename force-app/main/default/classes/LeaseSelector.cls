/**
 * Selector for Lease__c — all SOQL against Lease__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
 *
 * P4 cleanup wave F1. Relocates the one Lease__c query out of
 * LeaseInquiryController.getLeaseSummary.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). Legal_Owner__r.Name traverses a
 * custom User lookup; the lookup field is enforced under USER_MODE (gap 0) and
 * User.Name is standard / always-readable, so the traversal is safe.
 *
 * NOT-FOUND CONTRACT: an inquiry with no Lease yet is a normal state, so
 * selectMostRecentByInquiryId returns SObject-or-null (list-then-null), mirroring
 * WireSelector.selectMostRecentByDispositionId rather than throwing.
 *
 * @see force-app/main/default/classes/WireSelector.cls (list-then-null precedent)
 */
public with sharing class LeaseSelector {

    /**
     * Most-recently-created Lease__c for one inquiry — backs
     * LeaseInquiryController.getLeaseSummary. An inquiry with no Lease is normal, so
     * this returns null rather than throwing.
     *
     * @param inquiryId Lease_Inquiry__c Id to read the latest Lease for.
     * @return The most recently created Lease__c for the inquiry
     *         (ORDER BY CreatedDate DESC LIMIT 1), or null when the input is null or
     *         the inquiry has no Lease.
     */
    public static Lease__c selectMostRecentByInquiryId(Id inquiryId) {
        if (inquiryId == null) {
            return null;
        }
        List<Lease__c> leases = [
            SELECT Id, Name, Stage__c, Legal_Owner__r.Name,
                   Target_Execution_Date__c, Executed_Date__c
            FROM Lease__c
            WHERE Lease_Inquiry__c = :inquiryId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return leases.isEmpty() ? null : leases[0];
    }
}
