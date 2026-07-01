@isTest
private class BrokerAssignmentControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active', Vacant_Area__c=8000);
        insert pa;
        List<Contact> bk = new List<Contact>{
            new Contact(LastName='Webb', Email='mw@x.com', Phone='1', Is_Broker__c=true, Broker_Firm__c='Lee'),
            new Contact(LastName='Nair', Email='pn@x.com', Phone='2', Is_Broker__c=true, Broker_Firm__c='CBRE')
        };
        insert bk;
        Date t = Date.today();
        insert new List<Broker_Assignment__c>{
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-40), Last_Check_In_Date__c=t.addDays(-30)), // overdue
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[1].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-25), Last_Check_In_Date__c=t.addDays(-17)), // dueSoon
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-10), Last_Check_In_Date__c=t.addDays(-3)),  // onTrack
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[1].Id, Status__c='Fully Leased', Listing_Start_Date__c=t.addDays(-300), Listing_End_Date__c=t.addDays(-120), Reason_Ended__c='Leased Up', Last_Check_In_Date__c=t.addDays(-125)),
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Disposed', Listing_Start_Date__c=t.addDays(-400), Listing_End_Date__c=t.addDays(-250), Reason_Ended__c='Performance Issue', Last_Check_In_Date__c=t.addDays(-255))
        };
    }
    @isTest static void kpis() {
        BrokerAssignmentController.Kpis k = BrokerAssignmentController.getKpis();
        System.assertEquals(5, k.total);
        System.assertEquals(3, k.active);
        System.assertEquals(1, k.overdue, 'only the 30-day-idle Active is > 21');
        System.assertEquals(1, k.leased);
    }
    @isTest static void alerts() {
        BrokerAssignmentController.Alerts a = BrokerAssignmentController.getAlerts();
        System.assertEquals(1, a.overdue);
        System.assertEquals(1, a.dueSoon);
        System.assertEquals(1, a.onTrack);
        System.assertEquals(3, a.active);
    }
    @isTest static void portfolio() {
        BrokerAssignmentController.Portfolio p = BrokerAssignmentController.getPortfolio();
        System.assertEquals(5, p.total);
        System.assertEquals(3, p.active);
        System.assertEquals(1, p.leased);
        System.assertEquals(1, p.disposed);
    }
    @isTest static void rowsAndDetailAndHistory() {
        List<BrokerAssignmentController.Row> rows = BrokerAssignmentController.getAssignments();
        System.assertEquals(5, rows.size());
        Id anId = rows[0].id;
        BrokerAssignmentController.Detail d = BrokerAssignmentController.getDetail(anId);
        System.assertEquals('Westgate Plaza', d.propertyName);
        System.assertEquals(5, d.history.size(), 'all 5 share one Property Asset');
        System.assertEquals(42000, d.grossSqFt);
        System.assertEquals(8000, d.vacantArea, 'vacancy spans from the Property Asset');
        System.assertEquals(34000, d.leasedArea, 'leased = gross 42000 − vacant 8000 (formula)');
        System.assertNotEquals(null, d.activeDays);
    }
    @isTest static void scorecard() {
        List<BrokerAssignmentController.BrokerCard> cards = BrokerAssignmentController.getScorecard();
        System.assertEquals(2, cards.size());
        Integer totals = 0; for (BrokerAssignmentController.BrokerCard c : cards) totals += c.total;
        System.assertEquals(5, totals);
    }
    @isTest static void brokerTotals() {
        List<BrokerAssignmentController.BrokerTotal> t = BrokerAssignmentController.getBrokerTotals();
        System.assertEquals(2, t.size());
        for (BrokerAssignmentController.BrokerTotal bt : t) System.assertEquals(1, bt.totalProperties, 'all assignments share one Property Asset');
    }
    @isTest static void logCheckInUpdates() {
        Broker_Assignment__c a = [SELECT Id FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Test.startTest(); BrokerAssignmentController.logCheckIn(a.Id); Test.stopTest();
        Broker_Assignment__c after = [SELECT Last_Check_In_Date__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        System.assertEquals(Date.today(), after.Last_Check_In_Date__c);
    }
    @isTest static void closeOutChangesStatus() {
        Broker_Assignment__c a = [SELECT Id FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Test.startTest(); BrokerAssignmentController.closeOut(a.Id, 'Fully Leased', Date.today(), 'Leased Up'); Test.stopTest();
        Broker_Assignment__c after = [SELECT Status__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        System.assertEquals('Fully Leased', after.Status__c);
        System.assertEquals('Leased Up', after.Reason_Ended__c);
        System.assertEquals(Date.today(), after.Listing_End_Date__c);
    }
    @isTest static void replaceBrokerOpensNewKeepsOld() {
        Broker_Assignment__c a = [SELECT Id, Property_Asset__c FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Contact nb = [SELECT Id FROM Contact WHERE Is_Broker__c=true AND Email='pn@x.com' LIMIT 1];
        Test.startTest();
        Id newId = BrokerAssignmentController.replaceBroker(a.Id, nb.Id, Date.today(), 'Performance Issue');
        Test.stopTest();
        Broker_Assignment__c oldA = [SELECT Status__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        Broker_Assignment__c newA = [SELECT Status__c, Broker__c, Property_Asset__c, Listing_Start_Date__c FROM Broker_Assignment__c WHERE Id=:newId];
        System.assertEquals('Disposed', oldA.Status__c);
        System.assertEquals(Date.today(), oldA.Listing_End_Date__c);
        System.assertEquals('Active', newA.Status__c);
        System.assertEquals(nb.Id, newA.Broker__c);
        System.assertEquals(a.Property_Asset__c, newA.Property_Asset__c);
    }
    @isTest static void getBrokerOptionsReturnsBrokers() {
        System.assertEquals(2, BrokerAssignmentController.getBrokerOptions().size());
    }
}
