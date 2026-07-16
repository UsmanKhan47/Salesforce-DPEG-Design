public with sharing class DispositionController {

    public class DispositionRow {
        @AuraEnabled public String id;
        @AuraEnabled public String assetName;
        @AuraEnabled public String stage;
        @AuraEnabled public Boolean psaExecuted;
        @AuraEnabled public String titleCompany;
        @AuraEnabled public Boolean closingStatementUploaded;
        @AuraEnabled public Boolean wireCreated;
    }

    @AuraEnabled(cacheable=false)
    public static String findOrCreate(Id assetId) {
        Disposition__c existing = DispositionSelector.selectMostRecentByPropertyAssetId(assetId);
        if (existing != null) {
            return existing.Id;
        }
        Disposition__c d = new Disposition__c(Property_Asset__c = assetId);
        insert d;
        return d.Id;
    }

    @AuraEnabled(cacheable=true)
    public static DispositionRow getClosingSummary(Id dispositionId) {
        Disposition__c d = DispositionSelector.selectClosingSummaryById(dispositionId);
        DispositionRow row = new DispositionRow();
        row.id = d.Id;
        row.assetName = d.Property_Asset__r != null ? d.Property_Asset__r.Name : '';
        row.stage = d.Disposition_Stage__c;
        row.psaExecuted = d.PSA_Executed__c;
        row.titleCompany = d.Title_Company__c;
        row.closingStatementUploaded = d.Closing_Statement_Uploaded__c;
        row.wireCreated = !d.Wires__r.isEmpty();
        return row;
    }
}