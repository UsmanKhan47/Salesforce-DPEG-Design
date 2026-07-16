/**
 * Selector for the standard Contact object. Encapsulates ALL SOQL against Contact
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * Consumers:
 *   • BrokerAssignmentController.getBrokerOptions -> selectBrokersOrderedByName
 *     (P4, Module B2 — Property Management; internal, USER_MODE).
 *   • BrokerPortalController.brokerPriorityFor -> GuestReads
 *     .selectBrokerPriorityByEmailSystem (P4 cleanup wave — guest LWR deal-intake
 *     controller; SYSTEM_MODE + without sharing, nested class below).
 *
 * MODE — mixed, per method (each method's ApexDoc restates its own mode):
 *   • selectBrokersOrderedByName uses `WITH USER_MODE` (API 67). Design §5
 *     classifies the standard fields touched here: Name is permissionable=false
 *     (always readable). The query also selects the custom Contact.Broker_Firm__c
 *     and filters on the custom Contact.Is_Broker__c; BOTH are FLS-controlled custom
 *     fields granted by the DPEG_Acquisitions permission set (the only permset
 *     granting them — see the SelectorTest runAs proof). USER_MODE therefore
 *     enforces the running user's FLS on those custom fields.
 *   • GuestReads.selectBrokerPriorityByEmailSystem uses `WITH SYSTEM_MODE` (API 67)
 *     inside a `without sharing` inner class — the guest Broker-Portal intake path
 *     (see that class's ApexDoc).
 *
 * ⚠ SHARING — the broker-priority lookup is BEHAVIOR-PRESERVING WITHOUT SHARING (see
 * the nested `GuestReads` class). The outer ContactSelector stays `with sharing`;
 * only the guest lookup lives in the `without sharing` inner class so it sees the
 * broker Contact regardless of the guest user's sharing — exactly as the original
 * `without sharing` BrokerPortalController inline query did. Under `WITH SYSTEM_MODE`,
 * FLS is bypassed but record-level sharing follows the class keyword; a `with sharing`
 * selector would have silently scoped the lookup to the (minimal, unconfigured) guest
 * sharing and defaulted every broker to 'Standard' priority.
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

    /**
     * Guest-portal anti-abuse Contact reads that MUST run WITHOUT SHARING.
     *
     * `without sharing` — guest-portal read; must see the broker Contact regardless
     * of the site guest user's sharing, which is minimal and unconfigured (P3 guest
     * spike incomplete). Inner classes do NOT inherit the outer class's sharing, so
     * `without sharing` is declared explicitly here; the outer ContactSelector stays
     * `with sharing`. Apex forbids static methods on inner classes, so this is an
     * instance method — call
     * `new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(...)`.
     *
     * ⚠ PRE-PROMOTION: this preserves the INTENT (broker-priority visible to the
     * guest intake, as the original `without sharing` BrokerPortalController inline
     * query did), but the guest sharing/ownership model itself is still unverified —
     * the P3 guest-sharing spike must be completed before portal promotion.
     */
    public without sharing class GuestReads {

        /**
         * The most-recent broker Contact for an email — backs
         * BrokerPortalController.brokerPriorityFor, which copies the broker's
         * priority onto each lead they submit so intake can be worked priority-first.
         * Selects Broker_Priority__c and filters the custom Is_Broker__c, mirroring
         * the original inline query exactly (field set, LIMIT 1, email trim on bind).
         *
         * SYSTEM_MODE (API 67) bypasses FLS; the enclosing `without sharing` bypasses
         * record sharing — together reproducing the original all-fields/all-records
         * guest read.
         *
         * @param email The broker's email; matched case-sensitively against
         *              Contact.Email after trim. Null/blank returns null.
         * @return The matching broker Contact with Broker_Priority__c populated, or
         *         null when the input is blank or no broker Contact has that email.
         * @example
         * Contact broker = new ContactSelector.GuestReads()
         *     .selectBrokerPriorityByEmailSystem(email);
         */
        public Contact selectBrokerPriorityByEmailSystem(String email) {
            if (String.isBlank(email)) {
                return null;
            }
            String trimmedEmail = email.trim();
            List<Contact> brokers = [
                SELECT Broker_Priority__c
                FROM Contact
                WHERE Email = :trimmedEmail AND Is_Broker__c = true
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return brokers.isEmpty() ? null : brokers[0];
        }
    }
}
