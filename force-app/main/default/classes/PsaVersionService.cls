/**
 * Service for the PSA version-log write workflow.
 *
 * Owns the business logic behind PsaVersionController.saveVersion (P6 controller
 * thinning): validate the version, append a PSA_Version__c to the Contract Review's
 * version history, then derive and stamp the parent's Ball_In_Court__c
 * (seller version -> Us, our version -> Seller), Negotiation_Status__c (first seller
 * version = Initial Draft, otherwise Seller/Buyer Counter), and Latest_Version__c. Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this DML and these business
 * rules are Service work, not Controller work — the controller now only marshals input,
 * delegates here, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to PsaVersionSelector (the prior-version count) — this service
 * holds no inline SOQL. It throws a typed PsaVersionException for a user-actionable rule
 * violation (surfaced verbatim) and the raw platform DmlException on a save failure; the
 * AuraHandledException boundary lives in the controller, NOT here, so the service stays
 * UI-agnostic (also callable from Flow / Apex).
 *
 * TRANSACTIONALITY: the append + parent stamp are two DML statements with no explicit
 * Savepoint — intentionally matching the pre-thinning behaviour. A failed stamp is rolled
 * back with the appended PSA_Version__c by the platform when the controller's
 * AuraHandledException goes unhandled at the @AuraEnabled entry point.
 *
 * @see force-app/main/default/classes/PsaVersionController.cls (thin caller)
 * @see force-app/main/default/classes/PsaVersionSelector.cls (all SOQL)
 */
public with sharing class PsaVersionService {

    /**
     * Raised for a user-actionable business-rule violation whose message is user-safe
     * and surfaced verbatim to the LWC: no Contract Review linked, or an unrecognised
     * version direction. Distinct from an unexpected platform DmlException, which the
     * controller maps to a fixed generic message instead.
     */
    public class PsaVersionException extends Exception {}

    /**
     * Records one PSA version against a Contract Review and derives the parent's
     * negotiation state.
     *
     * @param contractReviewId the parent Contract_Review__c (required)
     * @param direction        who sent the version — 'Seller' or 'Ours' (required)
     * @param versionDate      the version date; defaults to today when null
     * @param summary          the version summary/notes
     * @param documentUrl      link to the PSA document
     * @throws PsaVersionException when contractReviewId is null or direction is not Seller/Ours
     * @throws System.DmlException on a platform save failure
     */
    public static void saveVersion(Id contractReviewId, String direction, Date versionDate,
            String summary, String documentUrl) {
        if (contractReviewId == null) {
            throw new PsaVersionException('No Contract Review is linked to this deal yet.');
        }
        if (direction != 'Seller' && direction != 'Ours') {
            throw new PsaVersionException('Pick who sent this version (Seller or Ours).');
        }
        Integer priorCount = PsaVersionSelector.countByContractReviewId(contractReviewId);

        insert new PSA_Version__c(
            Contract_Review__c = contractReviewId,
            Direction__c = direction,
            Version_Date__c = (versionDate == null) ? Date.today() : versionDate,
            Summary__c = summary,
            Document_URL__c = documentUrl
        );

        Boolean fromSeller = direction == 'Seller';
        String status;
        if (priorCount == 0 && fromSeller) {
            status = 'Initial Draft'; // the seller drafts first (Section 15)
        } else {
            status = fromSeller ? 'Seller Counter' : 'Buyer Counter';
        }
        update new Contract_Review__c(
            Id = contractReviewId,
            Ball_In_Court__c = fromSeller ? 'Us' : 'Seller',
            Negotiation_Status__c = status,
            Latest_Version__c = priorCount + 1
        );
    }
}
