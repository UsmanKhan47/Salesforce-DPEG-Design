/**
 * Tests LeadConvertTriggerHandler: the Lead after-update context routes to
 * LeadConvertService, so converting a Lead stamps the deal type and matching
 * record type onto the new Opportunity. Behaviour is asserted through lead
 * conversion, as it fires in production.
 */
@isTest
private class LeadConvertTriggerHandlerTest {

    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    @isTest
    static void afterUpdate_StampsConvertedOpportunity() {
        // Given: a Commercial Lead.
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Commercial Partners Inc';
        l.Deal_Type__c = 'Commercial';
        insert l;

        // When: the Lead is converted (fires the Lead after-update trigger).
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();

        // Then: the handler routed to LeadConvertService, stamping the Opportunity.
        Assert.isTrue(res.isSuccess(), 'Lead conversion should succeed');
        Opportunity o = [
            SELECT Deal_Type__c, RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual('Commercial', o.Deal_Type__c, 'Deal type carried to the Opportunity');
        Assert.areEqual('Commercial', o.RecordType.DeveloperName, 'Commercial record type applied');
    }

    /**
     * Bulk (.claude/rules/bulk-test-rule.md): 251 lead conversions in one
     * transaction. Database.convertLead caps one call's list, so 251 splits
     * across two calls (200 + 51) — the handler (and the Opportunity cascade it
     * feeds) therefore fires twice in one transaction.
     */
    @isTest
    static void bulk251ConversionsStampEveryOpportunity() {
        List<Lead> leads = TestDataFactory.createLeads(251, false);
        for (Integer i = 0; i < leads.size(); i++) {
            leads[i].Deal_Type__c = Math.mod(i, 2) == 0 ? 'Land' : 'Commercial';
        }
        insert leads;

        String status = convertedStatus();
        Test.startTest();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, 251, status);
        Test.stopTest();

        List<Lead> convertedLeads = [
            SELECT ConvertedOpportunityId FROM Lead WHERE Id IN :leads AND IsConverted = true
        ];
        Assert.areEqual(251, convertedLeads.size(), 'All 251 leads convert');

        Set<Id> oppIds = new Set<Id>();
        for (Lead l : convertedLeads) {
            oppIds.add(l.ConvertedOpportunityId);
        }
        List<Opportunity> converted = [
            SELECT Deal_Type__c, RecordType.DeveloperName FROM Opportunity WHERE Id IN :oppIds
        ];
        Assert.areEqual(251, converted.size(), 'Every converted lead produced its own Opportunity');
        for (Opportunity o : converted) {
            Assert.areNotEqual(null, o.Deal_Type__c, 'Deal type stamped on every deal');
            Assert.areNotEqual(null, o.RecordType.DeveloperName, 'Record type resolved for every deal');
        }
    }

    private static void convertChunk(List<Lead> leads, Integer fromIndex, Integer toIndex, String status) {
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
        for (Integer i = fromIndex; i < toIndex; i++) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leads[i].Id);
            lc.setConvertedStatus(status);
            converts.add(lc);
        }
        for (Database.LeadConvertResult r : Database.convertLead(converts, false)) {
            Assert.isTrue(r.isSuccess(), 'Each lead in the bulk chunk should convert successfully');
        }
    }
}
