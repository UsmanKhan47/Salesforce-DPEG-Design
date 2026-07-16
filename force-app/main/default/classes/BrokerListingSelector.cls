/**
 * Selector for Broker_Listing__c. Encapsulates ALL SOQL against Broker_Listing__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumer:
 *   - BrokerListingController.getListing (the active listing card on the
 *     Disposition record page).
 *
 * MODE — the single query uses `WITH USER_MODE` (API 67). Broker_Listing__c is a
 * custom object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and
 * enforces the running user's sharing + FLS. There is no guest path here, so no
 * SYSTEM_MODE appears.
 *
 * NOT-FOUND CONTRACT — read-for-display: a Disposition may have no listing yet,
 * which is normal, so this returns SObject-or-null. The dispositionId is bound
 * straight into the WHERE clause, mirroring the exact query semantics of the
 * relocated getListing statement (which had no pre-query null guard).
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class BrokerListingSelector {

    /**
     * Most-recent Broker Listing for one Disposition — backs
     * BrokerListingController.getListing. A Disposition with no listing yet is a
     * normal state, so this returns null rather than throwing.
     *
     * ORDER BY is `CreatedDate DESC` only, preserving getListing's original
     * ordering verbatim (no Id tiebreak was present, so none is added). The field
     * list — including the Disposition__r.Property_Asset__r.Name grandparent path
     * — is the exact set BrokerListingController.ListingRow maps, so it must not be
     * narrowed.
     *
     * @param dispositionId Disposition__c Id to read the latest listing for.
     * @return The most recently created Broker_Listing__c for the Disposition
     *         (ORDER BY CreatedDate DESC LIMIT 1), or null when none exists.
     * @example
     * Broker_Listing__c bl =
     *     BrokerListingSelector.selectMostRecentByDispositionId(dispId);
     */
    public static Broker_Listing__c selectMostRecentByDispositionId(Id dispositionId) {
        List<Broker_Listing__c> listings = [
            SELECT Id, Disposition__r.Property_Asset__r.Name,
                   Broker_Firm__c, Contact_Name__c, List_Date__c,
                   Call_For_Offers_Date__c, Days_On_Market__c, Listing_Status__c,
                   Offers_Received__c
            FROM Broker_Listing__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return listings.isEmpty() ? null : listings[0];
    }
}
