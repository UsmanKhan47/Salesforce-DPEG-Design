/**
 * Selector for the standard Contact object. Encapsulates ALL SOQL against Contact
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * Consumers:
 *   • BrokerAssignmentController.getBrokerOptions -> selectBrokersOrderedByName
 *     (P4, Module B2 — Property Management; internal, USER_MODE).
 *   • BrokerController.getBrokerHub -> selectBrokersRankedByClosedVolume +
 *     selectTopBrokersByActiveListings (P4 cleanup wave F2 — the Broker Hub page;
 *     internal, USER_MODE. Module B missed this class; see the ⚠ FLS note below).
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
 *   • selectBrokersRankedByClosedVolume and selectTopBrokersByActiveListings use
 *     `WITH USER_MODE`. They select Name (permissionable=false) plus SEVEN custom
 *     Contact fields (Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
 *     Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c)
 *     and filter Is_Broker__c / Active_Listings__c. Those custom fields are covered by
 *     the P3 blanket "custom-field FLS gap = 0" verdict (design §5) but are NOT
 *     itemised in design §5's Contact FLS table — see the ⚠ DESIGN NOTE below.
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
 * ⚠ DESIGN NOTE (flagged to the orchestrator): design §5 characterises the Contact
 * queries as "selects Name only", but two relocated queries genuinely select custom,
 * FLS-controlled fields:
 *   - getBrokerOptions -> selectBrokersOrderedByName selects Broker_Firm__c and
 *     filters Is_Broker__c.
 *   - getBrokerHub -> selectBrokersRankedByClosedVolume /
 *     selectTopBrokersByActiveListings select SEVEN custom Broker_* fields and filter
 *     Is_Broker__c / Active_Listings__c. RentRollController/BrokerController were never
 *     in the design's §2 inventory (Module B built BrokerAssignment and missed them),
 *     so those seven fields were never itemised in §5's Contact FLS table — they rely
 *     solely on the P3 blanket "custom-field FLS gap = 0" measurement, not a per-field
 *     check. A running user WITHOUT a permset granting those Contact fields will hit a
 *     USER_MODE QueryException here. See the report.
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
     * All broker Contacts (Is_Broker__c = true) ranked by Closed_Volume__c — backs
     * BrokerController.getBrokerHub, which uses this both as the full broker list and to
     * derive the header stats (firm count, active-broker count, listing/offer/volume
     * totals). Ordered by Closed_Volume__c DESC NULLS LAST, then Name ASC, and selects
     * the seven Broker_* stat fields, mirroring the original inline query exactly.
     *
     * @return Broker Contacts (Id, Name, and the seven Broker_* fields) ranked by closed
     *         volume; an empty list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersRankedByClosedVolume();
     */
    public static List<Contact> selectBrokersRankedByClosedVolume() {
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE Is_Broker__c = true
            WITH USER_MODE
            ORDER BY Closed_Volume__c DESC NULLS LAST, Name ASC
        ];
    }

    /**
     * Top broker Contacts with at least one active listing, ranked for the "top brokers"
     * widget — backs BrokerController.getBrokerHub. Filters Is_Broker__c = true AND
     * Active_Listings__c > 0, orders by Active_Listings__c DESC then Closed_Volume__c
     * DESC NULLS LAST, and caps the result at maxRows. Field set matches
     * selectBrokersRankedByClosedVolume so the caller maps both lists identically.
     *
     * @param maxRows Maximum rows to return (the caller's TOP_LIMIT). A null or
     *                non-positive value yields an empty list without querying.
     * @return Up to maxRows broker Contacts with active listings, ranked; an empty list
     *         when maxRows is null/non-positive or no broker has active listings (never null).
     * @example
     * List<Contact> top = ContactSelector.selectTopBrokersByActiveListings(6);
     */
    public static List<Contact> selectTopBrokersByActiveListings(Integer maxRows) {
        if (maxRows == null || maxRows <= 0) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE Is_Broker__c = true AND Active_Listings__c > 0
            WITH USER_MODE
            ORDER BY Active_Listings__c DESC, Closed_Volume__c DESC NULLS LAST
            LIMIT :maxRows
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
