/**
 * Tests for BrokerPortalService — the guest Broker-Portal deal-intake business logic.
 *
 * Covers the happy path, honeypot, every validation branch, the routing-not-configured
 * branch (forced via the @TestVisible queue cache), duplicate flagging, broker-priority
 * copy, and Lead-insert failure propagation (DmlException). Runs the service directly to
 * assert its UI-agnostic contract: user-actionable failures throw the typed
 * SubmissionException; the Lead insert failure propagates as DmlException. The service
 * never throws AuraHandledException — that boundary is the controller's job.
 */
@IsTest
private class BrokerPortalServiceTest {

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

    /** Asserts the submission is rejected with a SubmissionException and inserts no Lead. */
    private static void assertRejected(BrokerPortalController.DealSubmission d, String scenario) {
        Boolean threw = false;
        try {
            BrokerPortalService.submitDeal(d);
        } catch (BrokerPortalService.SubmissionException e) {
            threw = true;
        }
        System.Assert.isTrue(threw, 'Expected SubmissionException for: ' + scenario);
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No lead should be inserted for: ' + scenario);
    }

    // ---- Happy path ----

    @IsTest
    static void submitDeal_happyPath_insertsStampedLead() {
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalService.submitDeal(validInput());
        Test.stopTest();

        System.Assert.isTrue(res.success, 'Should succeed');
        System.Assert.isNotNull(res.message, 'Confirmation message returned');

        List<Lead> leads = [
            SELECT FirstName, LastName, Company, Broker_First__c, Email, Phone,
                   Property_Address__c, Asset_Type__c, Deal_Type__c,
                   LeadSource, Status, First_Seen_Date__c, OwnerId,
                   Duplicate_Flag__c, Broker_Priority__c
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
        System.Assert.areEqual('Standard', l.Broker_Priority__c, 'Unknown broker defaults to Standard');

        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Broker_Portal_Leads' LIMIT 1];
        System.Assert.areEqual(q.Id, l.OwnerId, 'Lead owned by the Broker Portal queue, not the guest user');
    }

    // ---- Honeypot ----

    @IsTest
    static void submitDeal_honeypotFilled_skipsInsert() {
        BrokerPortalController.DealSubmission d = validInput();
        d.website = 'http://spam.example';
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalService.submitDeal(d);
        Test.stopTest();
        System.Assert.isTrue(res.success, 'Honeypot returns benign success so bots learn nothing');
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'Honeypot blocks the insert');
    }

    // ---- Validation branches ----

    @IsTest
    static void submitDeal_nullInput_rejected() {
        Test.startTest();
        assertRejected(null, 'null submission');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirstName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.firstName = '  ';
        Test.startTest();
        assertRejected(d, 'blank first name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = '';
        Test.startTest();
        assertRejected(d, 'blank last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = null;
        Test.startTest();
        assertRejected(d, 'blank firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingAddress_rejected() {
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
    static void submitDeal_invalidEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = 'not-an-email';
        Test.startTest();
        assertRejected(d, 'invalid email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_blankAssetType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.assetType = '';
        Test.startTest();
        assertRejected(d, 'blank asset type');
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
    static void submitDeal_invalidDealType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.dealType = 'Banana';
        Test.startTest();
        assertRejected(d, 'invalid deal type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthFirstName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.firstName = 'x'.repeat(41);
        Test.startTest();
        assertRejected(d, 'over-length first name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = 'x'.repeat(81);
        Test.startTest();
        assertRejected(d, 'over-length last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = 'x'.repeat(256);
        Test.startTest();
        assertRejected(d, 'over-length firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        // Valid-format email that exceeds the 80-char cap (long local part).
        d.email = 'a'.repeat(75) + '@ex.com';
        Test.startTest();
        assertRejected(d, 'over-length email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthPhone_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.phone = '5'.repeat(41);
        Test.startTest();
        assertRejected(d, 'over-length phone');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthAddress_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.propertyAddress = 'x'.repeat(256);
        Test.startTest();
        assertRejected(d, 'over-length property address');
        Test.stopTest();
    }

    // ---- Routing (queue not configured) ----

    @IsTest
    static void submitDeal_queueNotConfigured_rejected() {
        // Force the queue lookup to resolve to null (queue "not configured") without
        // deleting the org's routing queue.
        BrokerPortalService.queueResolved = true;
        BrokerPortalService.cachedQueueId = null;

        Test.startTest();
        assertRejected(validInput(), 'routing queue not configured');
        Test.stopTest();
    }

    // ---- Duplicate flagging ----

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
        BrokerPortalService.submitDeal(validInput()); // same address
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
        BrokerPortalService.submitDeal(validInput()); // same address, but existing is closed
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
        BrokerPortalService.submitDeal(validInput()); // different address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Different address should not flag a duplicate');
    }

    // ---- Broker-priority copy ----

    @IsTest
    static void submitDeal_knownHighPriorityBroker_copiesPriority() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.FirstName = 'Jane';
        broker.LastName = 'Broker';
        broker.Email = 'jane@acme.com';
        broker.Broker_Priority__c = 'High';
        insert broker;

        Test.startTest();
        BrokerPortalService.submitDeal(validInput()); // same email as the broker contact
        Test.stopTest();
        Lead created = [SELECT Broker_Priority__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.areEqual('High', created.Broker_Priority__c, 'Priority copied from the broker contact');
    }

    // ---- Lead-insert failure propagates as DmlException (not swallowed by the service) ----

    @IsTest
    static void submitDeal_insertFails_propagatesDmlException() {
        // A Lead with the same broker identity trips this org's active Lead duplicate
        // rule (Block), so the portal insert fails with a DmlException the service must
        // NOT swallow (the controller maps it to a generic message).
        Lead blocker = TestDataFactory.createLead(false);
        blocker.FirstName = 'Jane';
        blocker.LastName = 'Broker';
        blocker.Company = 'Acme Realty';
        blocker.Email = 'jane@acme.com';
        blocker.Property_Address__c = '456 Blocker Rd';
        blocker.Status = 'New';
        insert blocker;

        Boolean threwDml = false;
        Test.startTest();
        try {
            BrokerPortalService.submitDeal(validInput());
        } catch (DmlException e) {
            threwDml = true;
        }
        Test.stopTest();
        System.Assert.isTrue(threwDml, 'A blocked Lead insert should surface as an un-swallowed DmlException');
    }
}
