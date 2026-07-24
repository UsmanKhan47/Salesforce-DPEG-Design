/**
 * Read-only @AuraEnabled controller for the Broker-Protection competing-submissions UI
 * (CHUNK 2): given a winning Lead, return every broker submission logged against it
 * (the winner plus later duplicates) for the LWC timeline on the Lead record page.
 *
 * LAYER — thin controller. It holds no SOQL and no business logic: it delegates to
 * CompetingBrokerSubmissionSelector (all SOQL lives in the selector, WITH USER_MODE)
 * and maps any failure to a user-safe AuraHandledException at the LWC boundary per
 * ARCHITECTURE.md §5, using the repo-standard ahe() helper (matches
 * BrokerPortalController). cacheable=true because this is a pure read.
 */
public with sharing class CompetingSubmissionController {

    /**
     * All competing broker submissions tied to one winning Lead, oldest first.
     *
     * @param leadId The winning Lead's Id.
     * @return The Competing_Broker_Submission__c rows for that lead; an empty list when
     *         there are none.
     * @throws AuraHandledException with a user-safe message on any read failure.
     * @example
     * // from LWC: import getSubmissions from '@salesforce/apex/CompetingSubmissionController.getSubmissions';
     */
    @AuraEnabled(cacheable=true)
    public static List<Competing_Broker_Submission__c> getSubmissions(Id leadId) {
        try {
            return CompetingBrokerSubmissionSelector.selectByWinningLead(leadId);
        } catch (Exception e) {
            throw ahe(e.getMessage());
        }
    }

    /**
     * Build a user-safe AuraHandledException carrying `msg` as its display message
     * (AuraHandledException otherwise surfaces a generic "Script-thrown exception" to
     * the client). Mirrors BrokerPortalController.ahe.
     *
     * @param msg The user-facing message.
     * @return The AuraHandledException to throw.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
