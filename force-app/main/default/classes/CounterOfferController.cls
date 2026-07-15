/**
 * Backs the loiCounterOffer LWC on the Opportunity LOI tab. Each counter offer is
 * a Counter_Offer__c child of the LOI (the full negotiation history: direction,
 * price, cap rate, date, response). Saving also stamps the latest terms onto the
 * parent LOI and flips its Ball_In_Court__c - a seller counter puts the ball in
 * OUR court, our counter puts it in the seller's.
 */
public with sharing class CounterOfferController {

    @AuraEnabled(cacheable=true)
    public static List<Counter_Offer__c> getCounterOffers(Id loiId) {
        if (loiId == null) {
            return new List<Counter_Offer__c>();
        }
        return [
            SELECT Id, Name, Direction__c, Counter_Price__c, Counter_Cap_Rate__c,
                   Counter_Date__c, Counter_Response__c, Revision_Number__c,
                   Subsequent_Version__c, CreatedDate
            FROM Counter_Offer__c
            WHERE LOI__c = :loiId
            ORDER BY CreatedDate DESC, Name DESC
        ];
    }

    @AuraEnabled
    public static void saveCounterOffer(Id loiId, String direction, Decimal counterPrice,
                                        Decimal counterCapRate, Date counterDate, String counterResponse,
                                        String revisionNumber, String subsequentVersion) {
        if (loiId == null) {
            throw new AuraHandledException('No primary LOI is set on this deal.');
        }
        if (direction != 'Seller' && direction != 'Ours') {
            throw new AuraHandledException('Pick who made this counter (Seller or Ours).');
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