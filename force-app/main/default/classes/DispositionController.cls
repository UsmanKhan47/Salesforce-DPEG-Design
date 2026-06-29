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
        List<Disposition__c> existing = [
            SELECT Id FROM Disposition__c
            WHERE Property_Asset__c = :assetId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        Disposition__c d = new Disposition__c(Property_Asset__c = assetId);
        insert d;
        return d.Id;
    }

    @AuraEnabled(cacheable=true)
    public static DispositionRow getClosingSummary(Id dispositionId) {
        Disposition__c d = [
            SELECT Id, Property_Asset__r.Name, Disposition_Stage__c,
                   PSA_Executed__c, Title_Company__c, Closing_Statement_Uploaded__c,
                   (SELECT Id FROM Wires__r LIMIT 1)
            FROM Disposition__c
            WHERE Id = :dispositionId
            LIMIT 1
        ];
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