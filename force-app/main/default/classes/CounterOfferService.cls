/**
 * Service for the LOI counter-offer write workflow.
 *
 * Owns the business logic behind CounterOfferController.saveCounterOffer (P6 controller
 * thinning): validate the counter, append a Counter_Offer__c to the LOI's negotiation
 * history, then stamp the latest terms onto the parent LOI and flip Ball_In_Court__c (a
 * seller counter puts the ball in OUR court, our counter in the seller's). Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this DML and these business
 * rules are Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to CounterOfferSelector — this service holds no inline SOQL. It
 * throws a typed CounterOfferException for a user-actionable rule violation (surfaced
 * verbatim) and the raw platform DmlException on a save failure; the AuraHandledException
 * boundary lives in the controller, NOT here, so the service stays UI-agnostic (also
 * callable from Flow / Apex).
 *
 * TRANSACTIONALITY: the append + parent stamp are two DML statements with no explicit
 * Savepoint — intentionally matching the pre-thinning behaviour. If the stamp fails, the
 * AuraHandledException the controller re-throws is unhandled at the @AuraEnabled entry
 * point, so the platform rolls back the whole transaction (including the appended
 * Counter_Offer__c). No orphan child survives a failed stamp.
 *
 * @see force-app/main/default/classes/CounterOfferController.cls (thin caller)
 * @see force-app/main/default/classes/CounterOfferSelector.cls (all SOQL)
 */
public with sharing class CounterOfferService {

    /**
     * Raised for a user-actionable business-rule violation whose message is user-safe
     * and surfaced verbatim to the LWC: no primary LOI on the deal, or an unrecognised
     * counter direction. Distinct from an unexpected platform DmlException, which the
     * controller maps to a fixed generic message instead.
     */
    public class CounterOfferException extends Exception {}

    /**
     * Records one counter offer against an LOI and reflects it on the parent.
     *
     * @param loiId            the parent LOI__c (required)
     * @param direction        who made the counter — 'Seller' or 'Ours' (required)
     * @param counterPrice     the countered price
     * @param counterCapRate   the countered cap rate
     * @param counterDate      the counter date; defaults to today when null
     * @param counterResponse  the free-text response/notes
     * @param revisionNumber   the revision label (Text despite the "_Number" suffix)
     * @param subsequentVersion the subsequent-version label
     * @throws CounterOfferException when loiId is null or direction is not Seller/Ours
     * @throws System.DmlException   on a platform save failure
     */
    public static void saveCounterOffer(Id loiId, String direction, Decimal counterPrice,
            Decimal counterCapRate, Date counterDate, String counterResponse,
            String revisionNumber, String subsequentVersion) {
        if (loiId == null) {
            throw new CounterOfferException('No primary LOI is set on this deal.');
        }
        if (direction != 'Seller' && direction != 'Ours') {
            throw new CounterOfferException('Pick who made this counter (Seller or Ours).');
        }
        Date effectiveDate = (counterDate == null) ? Date.today() : counterDate;
        insert new Counter_Offer__c(
            LOI__c = loiId,
            Direction__c = direction,
            Counter_Price__c = counterPrice,
            Counter_Cap_Rate__c = counterCapRate,
            Counter_Date__c = effectiveDate,
            Counter_Response__c = counterResponse,
            Revision_Number__c = String.isBlank(revisionNumber) ? null : revisionNumber.trim(),
            Subsequent_Version__c = String.isBlank(subsequentVersion) ? null : subsequentVersion.trim()
        );

        // Reflect the latest counter on the parent LOI and flip whose turn it is.
        Boolean fromSeller = direction == 'Seller';
        LOI__c stamp = new LOI__c(
            Id = loiId,
            Counter_Price__c = counterPrice,
            Counter_Cap_Rate__c = counterCapRate,
            Counter_Response__c = counterResponse,
            Ball_In_Court__c = fromSeller ? 'Us' : 'Seller',
            LOI_Status__c = 'Countered'
        );
        if (fromSeller) {
            stamp.Counter_Received_Date__c = effectiveDate;
        }
        update stamp;
    }
}
