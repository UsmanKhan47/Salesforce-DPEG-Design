@IsTest
private class BrokerPortalControllerTest {

    private static BrokerPortalController.DealSubmission validInput() {
        BrokerPortalController.DealSubmission d = new BrokerPortalController.DealSubmission();
        d.firstName = 'Jane';
        d.lastName = 'Broker';
        d.brokerageFirm = 'Acme Realty';
        d.email = 'jane@acme.com';
        d.phone = '555-1234';
        d.propertyAddress = '123 Main St, Dallas TX';
        d.assetType = 'Retail';
        d.dealType = 'Commercial';
        return d;
    }

    // ---- Task 3: getFormMetadata ----

    @IsTest
    static void getFormMetadata_returnsActiveOptions() {
        Test.startTest();
        BrokerPortalController.FormMetadata meta = BrokerPortalController.getFormMetadata();
        Test.stopTest();

        System.Assert.isFalse(meta.assetTypes.isEmpty(), 'Asset types should not be empty');
        Set<String> assetValues = new Set<String>();
        for (BrokerPortalController.PicklistOption o : meta.assetTypes) {
            assetValues.add(o.value);
        }
        System.Assert.isTrue(assetValues.contains('Retail'), 'Expected Retail asset type');

        Set<String> dealValues = new Set<String>();
        for (BrokerPortalController.PicklistOption o : meta.dealTypes) {
            dealValues.add(o.value);
        }
        System.Assert.isTrue(dealValues.contains('Commercial'), 'Expected Commercial deal type');
    }

    // ---- Task 4: happy path ----

    @IsTest
    static void submitDeal_happyPath_insertsStampedLead() {
        BrokerPortalController.DealSubmission d = validInput();

        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalController.submitDeal(d);
        Test.stopTest();

        System.Assert.isTrue(res.success, 'Should succeed');

        List<Lead> leads = [
            SELECT FirstName, LastName, Company, Broker_First__c, Email, Phone,
                   Property_Address__c, Asset_Type__c, Deal_Type__c,
                   LeadSource, Status, First_Seen_Date__c, OwnerId, Duplicate_Flag__c
            FROM Lead
        ];
        System.Assert.areEqual(1, leads.size(), 'Exactly one lead inserted');
        Lead l = leads[0];
        System.Assert.areEqual('Jane', l.FirstName, 'First name mapped');
        System.Assert.areEqual('Broker', l.LastName, 'Last name mapped');
        System.Assert.areEqual('Acme Realty', l.Company, 'Company = firm');
        System.Assert.areEqual('Acme Realty', l.Broker_First__c, 'Broker_First mirrors firm');
        System.Assert.areEqual('Retail', l.Asset_Type__c, 'Asset type mapped');
        System.Assert.areEqual('Broker Portal', l.LeadSource, 'LeadSource stamped server-side');
        System.Assert.areEqual('New', l.Status, 'Status stamped server-side');
        System.Assert.areNotEqual(null, l.First_Seen_Date__c, 'First Seen Date stamped server-side');
        System.Assert.isFalse(l.Duplicate_Flag__c, 'No duplicate expected');

        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Broker_Portal_Leads' LIMIT 1];
        System.Assert.areEqual(q.Id, l.OwnerId, 'Lead owned by the Broker Portal queue, not the guest user');
    }

    // ---- Task 5: validation + honeypot ----

    private static void assertRejected(BrokerPortalController.DealSubmission d, String scenario) {
        Boolean threw = false;
        try {
            BrokerPortalController.submitDeal(d);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.Assert.isTrue(threw, 'Expected rejection for: ' + scenario);
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No lead should be inserted for: ' + scenario);
    }

    @IsTest
    static void submitDeal_missingLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = '   ';
        Test.startTest();
        assertRejected(d, 'blank last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = '';
        Test.startTest();
        assertRejected(d, 'blank firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = 'not-an-email';
        Test.startTest();
        assertRejected(d, 'invalid email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidAssetType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.assetType = 'Spaceship';
        Test.startTest();
        assertRejected(d, 'invalid asset type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_honeypotFilled_skipsInsert() {
        BrokerPortalController.DealSubmission d = validInput();
        d.website = 'http://spam.example';
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalController.submitDeal(d);
        Test.stopTest();
        System.Assert.isTrue(res.success, 'Honeypot returns benign success so bots learn nothing');
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'Honeypot blocks the insert');
    }

    // ---- Broker priority copy ----

    @IsTest
    static void submitDeal_knownHighPriorityBroker_copiesPriority() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.FirstName = 'Jane';
        broker.LastName = 'Broker';
        broker.Email = 'jane@acme.com';
        broker.Broker_Priority__c = 'High';
        insert broker;

        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // same email as the broker contact
        Test.stopTest();
        Lead created = [SELECT Broker_Priority__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.areEqual('High', created.Broker_Priority__c, 'Priority copied from the broker contact');
    }

    @IsTest
    static void submitDeal_unknownBroker_defaultsToStandardPriority() {
        Test.startTest();
        BrokerPortalController.submitDeal(validInput());
        Test.stopTest();
        Lead created = [SELECT Broker_Priority__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.areEqual('Standard', created.Broker_Priority__c, 'Unknown brokers default to Standard');
    }

    // ---- Task 6: duplicate flagging ----

    @IsTest
    static void submitDeal_openDuplicate_setsFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Existing';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '123 Main St, Dallas TX';
        existing.Status = 'New';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // same address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isTrue(created.Duplicate_Flag__c, 'Open same-address lead should flag a duplicate');
    }

    @IsTest
    static void submitDeal_closedDuplicate_doesNotSetFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Old';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '123 Main St, Dallas TX';
        existing.Status = 'Disqualified';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // same address, but existing is closed
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Closed same-address lead should not flag a duplicate');
    }

    @IsTest
    static void submitDeal_differentAddress_doesNotSetFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Existing';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '999 Elsewhere Ave';
        existing.Status = 'New';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        Test.startTest();
        BrokerPortalController.submitDeal(validInput()); // different address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Different address should not flag a duplicate');
    }

    @IsTest
    static void submitDeal_missingPropertyAddress_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.propertyAddress = '';
        Test.startTest();
        assertRejected(d, 'blank property address');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = '';
        Test.startTest();
        assertRejected(d, 'blank email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidDealType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.dealType = 'Banana';
        Test.startTest();
        assertRejected(d, 'invalid deal type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthPropertyAddress_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        String longAddr = '';
        for (Integer i = 0; i < 256; i++) { longAddr += 'x'; }
        d.propertyAddress = longAddr;
        Test.startTest();
        assertRejected(d, 'over-length property address');
        Test.stopTest();
    }

    // ---- P6 boundary: an unexpected Lead-insert failure surfaces as a generic AuraHandledException ----

    @IsTest
    static void submitDeal_insertFails_surfacesGenericAhe() {
        // WHAT THIS PINS: when the service's insert throws a DmlException, the thinned
        // controller must map it to a user-safe AuraHandledException — never a raw DML
        // string to an unauthenticated guest. The reason the insert fails is irrelevant
        // to that contract.
        //
        // ⚠ MECHANISM CHANGED 2026-08-03 — this test previously seeded a same-identity
        // "blocker" Lead and relied on "this org's active Lead duplicate rule (Block)".
        // That never worked: Standard_Lead_Duplicate_Rule is isActive=false in the repo
        // (deactivated in e1f5a9f, 2026-07-25) AND live on usman-dpeg, and even when active
        // it is actionOnInsert=Allow / operationsOnInsert=Alert,Report — an ALERT rule, not
        // a Block rule. Both inserts succeeded, nothing threw, and the assertion failed.
        // See BrokerPortalServiceTest.submitDeal_insertFails_propagatesDmlException for the
        // full finding.
        //
        // The failure is now forced through the @TestVisible queue seam production already
        // exposes: a Contact Id is a valid Id that Lead.OwnerId cannot accept (only a User
        // or a Queue), so the service's insert throws an org-independent DmlException, which
        // is exactly the input this controller contract consumes.
        Contact notAValidOwner = TestDataFactory.createContact(null, true);
        BrokerPortalService.queueResolved = true;
        BrokerPortalService.cachedQueueId = notAValidOwner.Id;

        Boolean threw = false;
        Test.startTest();
        try {
            BrokerPortalController.submitDeal(validInput());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.Assert.isTrue(threw, 'A failed Lead insert should surface as AuraHandledException');
    }
}
