@isTest
private class LeaseInquiryControllerTest {

    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active', Vacant_Area__c=8000);
        insert pa;
        Contact bk = new Contact(LastName='Webb', Email='mw@x.com', Phone='1', Is_Broker__c=true, Broker_Firm__c='Lee & Associates');
        insert bk;
        // Insert fires the Stage Timer (sets Stage_Start_Date) and Open Log (creates 1 activity) flows.
        insert new Lease_Inquiry__c(
            Tenant_Name__c='Sunrise Cafe', Broker__c=bk.Id, Property_Asset__c=pa.Id,
            Space_Required__c=1800, Initial_Notes__c='Toured the end-cap; wants to move fast.'
        );
    }

    private static Lease_Inquiry__c theInquiry() {
        return [SELECT Id, Stage__c, Ball_In_Court__c, Status__c, Stage_Start_Date__c FROM Lease_Inquiry__c LIMIT 1];
    }

    @isTest static void openingEntryAndStageTimer() {
        Lease_Inquiry__c inq = theInquiry();
        System.assertEquals(Date.today(), inq.Stage_Start_Date__c, 'Stage Timer flow stamps today on create');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(1, v.entries.size(), 'Open Log flow seeds one opening entry');
        System.assertEquals('Inquiry Received', v.stage);
        System.assertEquals('Landlord', v.ballInCourt);
        System.assertEquals(false, v.closed);
        System.assertEquals(true, v.canAdvance);
        System.assertEquals('LOI Received', v.nextStage);
        System.assertEquals('Toured the end-cap; wants to move fast.', v.entries[0].details);
    }

    @isTest static void addUpdateAppendsAndSetsBall() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        Id sameId = LeaseInquiryController.addUpdate(inq.Id, '  Countered at $30/sq ft  ', 'Tenant', false);
        Test.stopTest();
        System.assertEquals(inq.Id, sameId);
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(2, v.entries.size(), 'One entry appended to the opening entry');
        // Find the appended entry by content (ordering is by Entry_Date, which is
        // frozen and therefore not distinguishable within a test transaction).
        LeaseInquiryController.Entry appended;
        for (LeaseInquiryController.Entry e : v.entries) {
            if (e.details == 'Countered at $30/sq ft') {
                appended = e;
            }
        }
        System.assertNotEquals(null, appended, 'Appended entry is present and trimmed');
        System.assertEquals('Tenant', appended.ball);
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('Tenant', after.Ball_In_Court__c, 'Parent ball in court is updated');
        System.assertEquals('Inquiry Received', after.Stage__c, 'Stage unchanged when not advancing');
    }

    @isTest static void addUpdateAdvancesStage() {
        Lease_Inquiry__c inq = theInquiry();
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'LOI received, forwarded to landlord.', 'Landlord', true);
        Test.stopTest();
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('LOI Received', after.Stage__c, 'Stage advances to the next step');
        System.assertEquals(Date.today(), after.Stage_Start_Date__c, 'Stage Timer flow resets the timer on advance');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(2, v.entries.size());
    }

    @isTest static void addUpdateBlankDetailsThrows() {
        Lease_Inquiry__c inq = theInquiry();
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(inq.Id, '   ', 'Tenant', false);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank details is rejected');
    }

    @isTest static void addUpdateNullInquiryThrows() {
        Boolean threw = false;
        try {
            LeaseInquiryController.addUpdate(null, 'anything', 'Tenant', false);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }

    @isTest static void closedInquiryDoesNotAdvance() {
        Lease_Inquiry__c inq = theInquiry();
        inq.Stage__c = 'Lease Signed';
        inq.Status__c = 'Closed Won';
        update inq;
        Test.startTest();
        LeaseInquiryController.addUpdate(inq.Id, 'Post-close note.', 'Tenant', true);
        Test.stopTest();
        Lease_Inquiry__c after = theInquiry();
        System.assertEquals('Lease Signed', after.Stage__c, 'Closed inquiry never advances');
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(inq.Id);
        System.assertEquals(true, v.closed);
        System.assertEquals(false, v.canAdvance);
        System.assertEquals(null, v.nextStage);
    }

    @isTest static void getLogNullReturnsEmpty() {
        LeaseInquiryController.LogView v = LeaseInquiryController.getLog(null);
        System.assertEquals(0, v.entries.size());
    }

    @isTest static void homeKpis() {
        LeaseInquiryController.HomeKpis k = LeaseInquiryController.getHomeKpis();
        System.assertEquals(1, k.active, 'one active inquiry in setup');
        System.assertEquals(1, k.waitingLandlord, 'ball defaults to Landlord');
        System.assertEquals(0, k.stalled, 'stage started today, not stalled');
        System.assertEquals(0, k.signed);
    }

    @isTest static void recentInquiries() {
        List<LeaseInquiryController.InquiryRow> rows = LeaseInquiryController.getRecentInquiries();
        System.assertEquals(1, rows.size());
        System.assertEquals('Sunrise Cafe', rows[0].tenant);
        System.assertEquals('Inquiry Received', rows[0].stage);
        System.assertEquals(false, rows[0].closed);
    }

    @isTest static void pipelineByStage() {
        List<LeaseInquiryController.StageCount> out = LeaseInquiryController.getPipelineByStage();
        System.assertEquals(6, out.size(), 'one bucket per stage');
        System.assertEquals('Inquiry Received', out[0].stage);
        System.assertEquals(1, out[0].count, 'the one active inquiry sits in Inquiry Received');
    }

    @isTest static void attention() {
        // The setup inquiry has the ball with the Landlord → surfaces in attention.
        List<LeaseInquiryController.InquiryRow> rows = LeaseInquiryController.getAttention();
        System.assertEquals(1, rows.size());
        System.assertEquals('Sunrise Cafe', rows[0].tenant);
    }
}
