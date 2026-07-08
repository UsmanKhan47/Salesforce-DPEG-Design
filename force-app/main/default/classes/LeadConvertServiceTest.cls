@isTest
private class LeadConvertServiceTest {

    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    private static Opportunity convertLeadOfType(String dealType, String company) {
        Lead l = new Lead(LastName = 'Tester', Company = company, Status = 'New', Deal_Type__c = dealType);
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Database.LeadConvertResult res = Database.convertLead(lc);
        System.assert(res.isSuccess(), 'Lead conversion should succeed');
        return [
            SELECT Id, Deal_Type__c, RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :res.getOpportunityId()
        ];
    }

    @isTest
    static void stampsLandDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Land', 'Land Holdings LLC');
        Test.stopTest();
        System.assertEquals('Land', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Land', o.RecordType.DeveloperName, 'Should get the Land record type');
    }

    @isTest
    static void stampsCommercialDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Commercial', 'Commercial Partners Inc');
        Test.stopTest();
        System.assertEquals('Commercial', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Commercial', o.RecordType.DeveloperName, 'Should get the Commercial record type');
    }

    @isTest
    static void createsAndLinksPropertyFromLead() {
        Lead l = new Lead(
            LastName = 'Broker', Company = 'CBRE', Status = 'New',
            Deal_Type__c = 'Commercial',
            Property_Address__c = '123 Main St, El Paso, TX',
            Asset_Type__c = 'Retail',
            Guidance_Price__c = 8200000,
            Guidance_Cap_Rate__c = 6.25,
            Placer_AI_Link__c = 'https://placer.ai/abc',
            CoStar_Link__c = 'https://costar.com/xyz'
        );
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();
        System.assert(res.isSuccess(), 'Lead conversion should succeed');

        Opportunity o = [SELECT Id, Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        System.assertNotEquals(null, o.Property__c, 'Conversion should create and link a Property');

        Property__c p = [
            SELECT Name, Address__c, Asset_Type__c, Asking_Price__c, Cap_Rate_Asking__c, Placer_URL__c, CoStar_URL__c
            FROM Property__c WHERE Id = :o.Property__c
        ];
        System.assertEquals('123 Main St, El Paso, TX', p.Address__c, 'Address copied from lead');
        System.assertEquals('Retail', p.Asset_Type__c, 'Asset type copied from lead');
        System.assertEquals(8200000, p.Asking_Price__c, 'Asking Price comes from Guidance Price');
        System.assertEquals(6.25, p.Cap_Rate_Asking__c, 'Cap Rate Asking comes from Guidance Cap Rate');
        System.assertEquals('https://placer.ai/abc', p.Placer_URL__c, 'Placer URL copied from lead');
        System.assertEquals('https://costar.com/xyz', p.CoStar_URL__c, 'CoStar URL copied from lead');
    }

    @isTest
    static void stampsConvertingUserAsLeadApprover() {
        // Conversion IS the approval to underwrite: no checkbox gate, and the
        // converting user lands on the deal as Lead Approved By.
        Test.startTest();
        Opportunity o = convertLeadOfType('Commercial', 'Straight Through LLC');
        Test.stopTest();

        Opportunity fresh = [SELECT Lead_Approved_By__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(UserInfo.getUserId(), fresh.Lead_Approved_By__c,
            'Converting user stamped on the Opportunity as the lead approver');
    }

    @isTest
    static void qualifiedNeedsNoApprovalAndIntakeStampsApply() {
        Lead l = new Lead(LastName = 'Gatecheck', Company = 'Gate LLC', Status = 'New');
        insert l;

        // No approval gate: Qualified is reachable directly.
        l.Status = 'Qualified';
        update l;

        l = [SELECT Status, First_Seen_Date__c, DPEG_First__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Qualified', l.Status, 'Qualified requires no prior approval');
        System.assertNotEquals(null, l.First_Seen_Date__c, 'First Seen stamped on create for all channels');
        System.assertEquals(UserInfo.getUserId(), l.DPEG_First__c, 'DPEG First stamped from the owning user');
    }
}