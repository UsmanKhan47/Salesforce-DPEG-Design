/**
 * Backs the loiCounterOffer LWC on the Opportunity LOI tab. Each counter offer is
 * a Counter_Offer__c child of the LOI (the history); saving also stamps the latest
 * price/response back onto the parent LOI so the LOI tab's Counter Price reflects it.
 */
public with sharing class CounterOfferController {

    @AuraEnabled(cacheable=true)
    public static List<Counter_Offer__c> getCounterOffers(Id loiId) {
        if (loiId == null) {
            return new List<Counter_Offer__c>();
        }
        return [
            SELECT Id, Name, Counter_Price__c, Counter_Response__c, CreatedDate
            FROM Counter_Offer__c
            WHERE LOI__c = :loiId
            ORDER BY CreatedDate DESC, Name DESC
        ];
    }

    @AuraEnabled
    public static void saveCounterOffer(Id loiId, Decimal counterPrice, String counterResponse) {
        if (loiId == null) {
            throw new AuraHandledException('No primary LOI is set on this deal.');
        }
        insert new Counter_Offer__c(
            LOI__c = loiId,
            Counter_Price__c = counterPrice,
            Counter_Response__c = counterResponse
        );
        // Reflect the latest counter on the parent LOI (drives the LOI tab Counter Price field).
        update new LOI__c(
            Id = loiId,
            Counter_Price__c = counterPrice,
            Counter_Response__c = counterResponse
        );
    }
}