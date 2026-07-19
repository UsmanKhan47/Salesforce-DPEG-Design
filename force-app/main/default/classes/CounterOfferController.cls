/**
 * Backs the loiCounterOffer LWC on the Opportunity LOI tab. Reads the counter-offer
 * negotiation history (Counter_Offer__c children of the LOI) and appends a new counter,
 * which also stamps the latest terms onto the parent LOI and flips its Ball_In_Court__c.
 *
 * All SOQL is delegated to CounterOfferSelector per ARCHITECTURE.md §2 — this controller
 * holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The append + LOI-stamp DML and the counter
 * business rules live in CounterOfferService per .claude/rules/apex-layering-rule.md;
 * saveCounterOffer() only marshals input, delegates, and maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). Every @AuraEnabled method
 * (read and write) maps failures the same way: platform detail goes to the debug log
 * (admin-only) and the user gets a message. A user-actionable rule violation
 * (CounterOfferException) is surfaced verbatim; an unexpected platform failure gets a
 * fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class CounterOfferController {

    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5) — raw DmlException
    // text leaks field API names and validation-rule internals.
    private static final String WRITE_FAILURE_MESSAGE =
        'This counter offer could not be saved. Refresh the page and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<Counter_Offer__c> getCounterOffers(Id loiId) {
        try {
            if (loiId == null) {
                return new List<Counter_Offer__c>();
            }
            return CounterOfferSelector.selectByLoiId(loiId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CounterOfferController.getCounterOffers on ' + loiId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static void saveCounterOffer(Id loiId, String direction, Decimal counterPrice,
                                        Decimal counterCapRate, Date counterDate, String counterResponse,
                                        String revisionNumber, String subsequentVersion) {
        try {
            CounterOfferService.saveCounterOffer(loiId, direction, counterPrice, counterCapRate,
                counterDate, counterResponse, revisionNumber, subsequentVersion);
        } catch (CounterOfferService.CounterOfferException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CounterOfferController.saveCounterOffer on LOI ' + loiId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
