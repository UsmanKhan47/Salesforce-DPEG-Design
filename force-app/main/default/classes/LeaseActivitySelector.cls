/**
 * Selector for Lease_Activity__c — all SOQL against the Lease Activity Tracker's
 * append-only negotiation log per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md.
 *
 * P4 cleanup wave F1. Relocates the one Lease_Activity__c query out of
 * LeaseInquiryController.getLog. Distinct from RenewalActivitySelector
 * (Renewal_Activity__c) — different object, different tracker.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). Logged_By__r.Name traverses a
 * custom User lookup; the lookup field itself is enforced under USER_MODE (gap 0)
 * and User.Name is a standard, always-readable field, so the traversal is safe.
 *
 * ORDER: newest first on Entry_DateTime__c (the post-D3-migration timeline stamp —
 * ARCHITECTURE.md §1 rule 9; the old Entry_Date__c was dropped), tie-broken on
 * Name DESC for same-transaction rows that share Entry_DateTime__c (frozen-clock
 * gotcha), exactly as the relocated LeaseInquiryController.getLog query did.
 *
 * Single-parent and bulk Set<Id> forms; the bulk method is mandated for
 * child-by-parent reads (.claude/rules/bulk-test-rule.md) and selects
 * Lease_Inquiry__c so callers can group by parent.
 *
 * @see force-app/main/default/classes/RenewalActivitySelector.cls (sibling template)
 */
public with sharing class LeaseActivitySelector {

    /**
     * Log entries for one inquiry, newest first. Backs LeaseInquiryController.getLog.
     *
     * @param inquiryId Parent Lease_Inquiry__c Id.
     * @return Ordered Lease_Activity__c for the parent (with Logged_By__r.Name);
     *         empty list when the input is null.
     */
    public static List<Lease_Activity__c> selectByInquiryId(Id inquiryId) {
        if (inquiryId == null) {
            return new List<Lease_Activity__c>();
        }
        return [
            SELECT Id, Lease_Inquiry__c, Details__c, Ball_In_Court__c,
                   Entry_DateTime__c, Logged_By__r.Name
            FROM Lease_Activity__c
            WHERE Lease_Inquiry__c = :inquiryId
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }

    /**
     * Log entries for many inquiries in one query — group the result by
     * Lease_Inquiry__c to build per-parent timelines. Bulk form per
     * .claude/rules/bulk-test-rule.md and ARCHITECTURE.md §2.
     *
     * @param inquiryIds Parent Lease_Inquiry__c Ids.
     * @return Ordered Lease_Activity__c across all parents (with Logged_By__r.Name);
     *         empty list when the input is null or empty.
     */
    public static List<Lease_Activity__c> selectByInquiryIds(Set<Id> inquiryIds) {
        if (inquiryIds == null || inquiryIds.isEmpty()) {
            return new List<Lease_Activity__c>();
        }
        return [
            SELECT Id, Lease_Inquiry__c, Details__c, Ball_In_Court__c,
                   Entry_DateTime__c, Logged_By__r.Name
            FROM Lease_Activity__c
            WHERE Lease_Inquiry__c IN :inquiryIds
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }
}
