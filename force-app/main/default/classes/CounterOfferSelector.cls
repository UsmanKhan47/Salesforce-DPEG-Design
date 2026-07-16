/**
 * Selector for Counter_Offer__c. Encapsulates ALL SOQL against Counter_Offer__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumer:
 *   - CounterOfferController.getCounterOffers (the loiCounterOffer LWC history on
 *     the Opportunity LOI tab).
 *
 * MODE — the single query uses `WITH USER_MODE` (API 67). Counter_Offer__c is a
 * custom object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and
 * enforces the running user's sharing + FLS. There is no guest path here, so no
 * SYSTEM_MODE appears.
 *
 * NOT-FOUND CONTRACT — read-for-display: an LOI with no counter offers is normal,
 * so this returns its natural empty List, never null. CounterOfferController
 * retains its own null-loiId guard (it short-circuits to an empty list before
 * calling this method), so this selector mirrors that intent and is never called
 * with a null Id from that caller.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class CounterOfferSelector {

    /**
     * All counter offers for one LOI, newest first — backs
     * CounterOfferController.getCounterOffers (the negotiation-history table).
     *
     * ORDER BY `CreatedDate DESC, Name DESC` is preserved verbatim from the
     * relocated query: same-transaction rows share a CreatedDate, and Name is an
     * AutoNumber, so the Name DESC tiebreak keeps the newest revision on top.
     * Revision_Number__c is TEXT despite its "_Number" suffix (TestDataFactory ⚠2)
     * — it is selected as-is for display. The field list is the exact set the
     * loiCounterOffer LWC binds, so it must not be narrowed.
     *
     * @param loiId LOI__c Id whose counter offers to read.
     * @return The matching Counter_Offer__c records ordered by CreatedDate DESC,
     *         Name DESC; an empty list when the LOI has none (or when loiId is
     *         null).
     * @example
     * List<Counter_Offer__c> offers = CounterOfferSelector.selectByLoiId(loiId);
     */
    public static List<Counter_Offer__c> selectByLoiId(Id loiId) {
        return [
            SELECT Id, Name, Direction__c, Counter_Price__c, Counter_Cap_Rate__c,
                   Counter_Date__c, Counter_Response__c, Revision_Number__c,
                   Subsequent_Version__c, CreatedDate
            FROM Counter_Offer__c
            WHERE LOI__c = :loiId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Name DESC
        ];
    }
}
