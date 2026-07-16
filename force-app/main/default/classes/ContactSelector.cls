/**
 * Selector for the standard Contact object. Encapsulates ALL SOQL against Contact
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4, Module B2 — Property Management. In-scope consumer:
 *   • BrokerAssignmentController.getBrokerOptions -> selectBrokersOrderedByName
 * (The deferred guest BrokerPortalController will later reuse this selector for its
 * Email lookup; that method is NOT built here — it is out of scope for B2.)
 *
 * MODE — `WITH USER_MODE` (API 67). Design §5 classifies the standard fields
 * touched here: Name is permissionable=false (always readable). The query also
 * selects the custom Contact.Broker_Firm__c and filters on the custom
 * Contact.Is_Broker__c; BOTH are FLS-controlled custom fields granted by the
 * DPEG_Acquisitions permission set (the only permset granting them — see the
 * SelectorTest runAs proof). USER_MODE therefore enforces the running user's FLS
 * on those custom fields. There is NO guest/automation path on this method, so no
 * `SYSTEM_MODE` appears here.
 *
 * ⚠ DESIGN NOTE (flagged to the orchestrator): design §5 characterises this query
 * as "selects Name only", but the relocated getBrokerOptions query genuinely
 * selects Broker_Firm__c (for the option label) and filters Is_Broker__c — both
 * custom, FLS-controlled fields. A running user WITHOUT a permset that grants those
 * two Contact fields will hit a USER_MODE QueryException here. See the report.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/TaskSelector.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §4, §5)
 */
public with sharing class ContactSelector {

    /**
     * Broker Contacts (Is_Broker__c = true) ordered by Name — backs
     * BrokerAssignmentController.getBrokerOptions, which renders each as a
     * "Name · Firm" picklist option. Selects Broker_Firm__c so the caller can build
     * that label; the field set and `ORDER BY Name` mirror the original inline query.
     *
     * @return Broker Contacts (Id, Name, Broker_Firm__c) ordered by Name; an empty
     *         list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersOrderedByName();
     */
    public static List<Contact> selectBrokersOrderedByName() {
        return [
            SELECT Id, Name, Broker_Firm__c
            FROM Contact
            WHERE Is_Broker__c = true
            WITH USER_MODE
            ORDER BY Name
        ];
    }
}
