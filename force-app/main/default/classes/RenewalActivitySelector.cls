/**
 * Selector for Renewal_Activity__c — all SOQL against the renewal activity
 * timeline per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module B1. Design: agent-output/p4-selector-design.md §3 #4, §4.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). CreatedBy.Name is a standard,
 * non-permissionable relationship field (design §5) — always readable, safe under
 * USER_MODE. Timeline ordering tie-breaks on Name DESC for the frozen-clock gotcha
 * (same-transaction rows share Entry_DateTime__c), carried over from
 * LeaseRenewalController.getTimeline. Entry_DateTime__c is the post-D3-migration
 * timeline stamp (ARCHITECTURE.md §1 rule 9).
 *
 * Single-parent and bulk Set<Id> forms; the bulk method is mandated for
 * child-by-parent reads (.claude/rules/bulk-test-rule.md) and selects
 * Lease_Renewal__c so callers can group by parent.
 */
public with sharing class RenewalActivitySelector {

    /**
     * Timeline entries for one renewal, newest first. Backs
     * LeaseRenewalController.getTimeline.
     *
     * @param leaseRenewalId Parent Lease_Renewal__c Id.
     * @return Ordered Renewal_Activity__c for the parent (with CreatedBy.Name);
     *         empty list when the input is null.
     */
    public static List<Renewal_Activity__c> selectByLeaseRenewalId(Id leaseRenewalId) {
        if (leaseRenewalId == null) {
            return new List<Renewal_Activity__c>();
        }
        return [
            SELECT Id, Lease_Renewal__c, Method__c, Details__c, Entry_DateTime__c, CreatedBy.Name
            FROM Renewal_Activity__c
            WHERE Lease_Renewal__c = :leaseRenewalId
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }

    /**
     * Timeline entries for many renewals in one query — group the result by
     * Lease_Renewal__c to build per-parent timelines. Bulk form per ARCHITECTURE.md §2.
     *
     * @param leaseRenewalIds Parent Lease_Renewal__c Ids.
     * @return Ordered Renewal_Activity__c across all parents (with CreatedBy.Name);
     *         empty list when the input is null or empty.
     */
    public static List<Renewal_Activity__c> selectByLeaseRenewalIds(Set<Id> leaseRenewalIds) {
        if (leaseRenewalIds == null || leaseRenewalIds.isEmpty()) {
            return new List<Renewal_Activity__c>();
        }
        return [
            SELECT Id, Lease_Renewal__c, Method__c, Details__c, Entry_DateTime__c, CreatedBy.Name
            FROM Renewal_Activity__c
            WHERE Lease_Renewal__c IN :leaseRenewalIds
            WITH USER_MODE
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ];
    }
}
