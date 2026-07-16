/**
 * Backs the psaVersionLog LWC on the Opportunity Contract tab and the Contract
 * Review record page. Each PSA draft/counter is a PSA_Version__c child of the
 * Contract Review (the full version history); saving also flips the parent's
 * Ball_In_Court__c (seller version -> Us, our version -> Seller), derives
 * Negotiation_Status__c (first seller version = Initial Draft), and bumps
 * Latest_Version__c.
 */
public with sharing class PsaVersionController {

    @AuraEnabled(cacheable=true)
    public static List<PSA_Version__c> getVersions(Id contractReviewId) {
        // SOQL relocated to PsaVersionSelector per ARCHITECTURE.md §2; the selector's
        // null guard preserves the empty-list-on-null contract.
        return PsaVersionSelector.selectByContractReviewId(contractReviewId);
    }

    @AuraEnabled
    public static void saveVersion(Id contractReviewId, String direction, Date versionDate,
                                   String summary, String documentUrl) {
        if (contractReviewId == null) {
            throw new AuraHandledException('No Contract Review is linked to this deal yet.');
        }
        if (direction != 'Seller' && direction != 'Ours') {
            throw new AuraHandledException('Pick who sent this version (Seller or Ours).');
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