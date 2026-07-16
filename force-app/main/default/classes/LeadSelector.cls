/**
 * Selector for Lead. Encapsulates ALL SOQL against Lead per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module A2 (Acquisitions — Deal Support). Consumer: BrokerPortalNotifier
 * (the guest/automation Broker-Portal lead-intake notification path).
 *
 * ── CREATION NOTE (design mismatch, code is source of truth) ──────────────────
 * The P4 design (§7) assumed Module A1 would create LeadSelector with USER_MODE
 * internal methods for LeadFunnelController, and that A2 would only ADD the guest
 * SYSTEM_MODE method here. A1 shipped without LeadSelector and left
 * LeadFunnelController's 5 inline Lead queries unmigrated. A2 therefore CREATES
 * this class to host its one required method. The internal USER_MODE funnel
 * methods (and the LeadFunnelController repoint) remain A1's responsibility and
 * are intentionally NOT added here — that repoint is out of A2's scope.
 *
 * MODE — this class is `with sharing` per ARCHITECTURE.md §2 (mandatory on every
 * selector). selectByIdsSystem uses `WITH SYSTEM_MODE` (API 67), justified: it is
 * called only from BrokerPortalNotifier in the guest/automation context of the
 * public Broker Portal. Per the P4 design §5 the guest path is not placed under
 * USER_MODE unverified (guest FLS lives on the non-deployable Guest Profile; P3's
 * guest spike never completed). SYSTEM_MODE bypasses FLS on the read; when future
 * internal funnel methods are added they must use `WITH USER_MODE` and this class
 * keeps its `with sharing` keyword.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see agent-output/p4-selector-design.md (§3 #17, §5)
 */
public with sharing class LeadSelector {

    /**
     * Leads by Id for the Broker-Portal new-lead notification — backs
     * BrokerPortalNotifier.notifyNewLeads (builds the notification title/body from
     * Name / Company / Property_Address__c). Bulk-safe.
     *
     * SYSTEM_MODE: guest/automation path (see class header). Selected fields
     * (Name/Company are permissionable=false; Property_Address__c is a granted
     * custom field) would pass USER_MODE, but per policy the guest path is
     * explicitly SYSTEM_MODE and kept separate from any internal USER_MODE method.
     *
     * @param leadIds Lead Ids to load; null/empty-safe.
     * @return Leads with Id, Name, Company, Property_Address__c populated; empty
     *         when the input is null or empty.
     */
    public static List<Lead> selectByIdsSystem(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Name, Company, Property_Address__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH SYSTEM_MODE
        ];
    }
}
