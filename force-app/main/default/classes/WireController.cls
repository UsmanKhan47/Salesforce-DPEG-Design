public with sharing class WireController {

    public class WireRow {
        @AuraEnabled public String id;
        @AuraEnabled public Boolean verbalVerificationCompleted;
        @AuraEnabled public String verifierName;
        @AuraEnabled public String verifierPhone;
        @AuraEnabled public String verifiedDateTime;
        @AuraEnabled public String wireInstructionsSource;
        @AuraEnabled public Decimal confirmedWireAmount;
        @AuraEnabled public Integer fieldsComplete;
    }

    @AuraEnabled(cacheable=true)
    public static WireRow getWire(Id dispositionId) {
        List<Wire__c> wires = [
            SELECT Id, Verbal_Verification_Completed__c, Verifier_Name__c,
                   Verifier_Phone__c, Verified_DateTime__c, Wire_Instructions_Source__c,
                   Confirmed_Wire_Amount__c
            FROM Wire__c
            WHERE Disposition__c = :dispositionId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (wires.isEmpty()) return null;
        Wire__c w = wires[0];
        WireRow r = new WireRow();
        r.id = w.Id;
        r.verbalVerificationCompleted = w.Verbal_Verification_Completed__c;
        r.verifierName = w.Verifier_Name__c;
        r.verifierPhone = w.Verifier_Phone__c;
        r.verifiedDateTime = w.Verified_DateTime__c != null
            ? String.valueOf(w.Verified_DateTime__c) : null;
        r.wireInstructionsSource = w.Wire_Instructions_Source__c;
        r.confirmedWireAmount = w.Confirmed_Wire_Amount__c;
        Integer done = 0;
        if (w.Verbal_Verification_Completed__c) done++;
        if (w.Verifier_Name__c != null) done++;
        if (w.Verifier_Phone__c != null) done++;
        if (w.Verified_DateTime__c != null) done++;
        if (w.Wire_Instructions_Source__c != null) done++;
        if (w.Confirmed_Wire_Amount__c != null) done++;
        r.fieldsComplete = done;
        return r;
    }

    @AuraEnabled(cacheable=false)
    public static WireRow saveWire(Id dispositionId, String wireId,
            Boolean verbalDone, String verifierName, String verifierPhone,
            String wireSource, Decimal confirmedAmount) {
        Wire__c w;
        if (wireId != null) {
            w = [SELECT Id FROM Wire__c WHERE Id = :wireId LIMIT 1];
        } else {
            w = new Wire__c(Disposition__c = dispositionId);
        }
        w.Verbal_Verification_Completed__c = verbalDone == true;
        w.Verifier_Name__c = verifierName;
        w.Verifier_Phone__c = verifierPhone;
        w.Wire_Instructions_Source__c = wireSource;
        w.Confirmed_Wire_Amount__c = confirmedAmount;
        if (verbalDone == true && w.Verified_DateTime__c == null) {
            w.Verified_DateTime__c = Datetime.now();
        } else if (verbalDone != true) {
            w.Verified_DateTime__c = null;
        }
        upsert w;
        return getWire(dispositionId);
    }
}