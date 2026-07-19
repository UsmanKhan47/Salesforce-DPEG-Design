/**
 * Tests DealMessageController: one tracker serving LOI, Underwriting, and
 * Contract Review parents; append-only history newest-first; unsupported
 * objects rejected; exactly-one-parent enforced by the object's VR.
 */
@isTest
private class DealMessageControllerTest {

    @isTest
    static void logsAndReadsOnAllThreeParents() {
        Opportunity o = TestDataFactory.createOpportunity(null, true); // StageName 'New'
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(o.Id, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(o.Id, true);

        Test.startTest();
        DealMessageController.addMessage(loi.Id, 'Email', 'Sent', 'LOI draft sent to broker', null);
        DealMessageController.addMessage(loi.Id, 'Call', 'Received', 'Broker called with feedback', null);
        DealMessageController.addMessage(uw.Id, 'Note', 'Internal', 'Waiting on the T-12', null);
        DealMessageController.addMessage(cr.Id, 'Email', 'Received', 'Seller counsel sent redline', 'v3');
        Test.stopTest();

        List<DealMessageController.Entry> loiLog = DealMessageController.getMessages(loi.Id);
        System.assertEquals(2, loiLog.size(), 'LOI keeps its own history');
        System.assertEquals('Broker called with feedback', loiLog[0].details, 'Newest first');
        System.assertEquals('Received', loiLog[0].direction, 'Direction captured');
        System.assertNotEquals(null, loiLog[0].enteredBy, 'Author captured');

        System.assertEquals(1, DealMessageController.getMessages(uw.Id).size(), 'Underwriting history isolated');
        List<DealMessageController.Entry> crLog = DealMessageController.getMessages(cr.Id);
        System.assertEquals(1, crLog.size(), 'Contract history isolated');
        System.assertEquals('v3', crLog[0].revision, 'Document revision captured on the Contract message');
    }

    @isTest
    static void rejectsUnsupportedObjectsAndBlankDetails() {
        Opportunity o = TestDataFactory.createOpportunity(null, true); // StageName 'New'

        Boolean threwObject = false;
        try {
            DealMessageController.addMessage(o.Id, 'Note', 'Internal', 'not allowed here', null);
        } catch (Exception e) {
            threwObject = true;
        }
        System.assert(threwObject, 'Opportunity is not a message-tracker parent');

        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        Boolean threwBlank = false;
        try {
            DealMessageController.addMessage(loi.Id, 'Note', 'Internal', '   ', null);
        } catch (Exception e) {
            threwBlank = true;
        }
        System.assert(threwBlank, 'Blank details are rejected');

        System.assertEquals(0, DealMessageController.getMessages(null).size(), 'Null id = empty log');
    }

    @isTest
    static void exactlyOneParentEnforced() {
        Opportunity o = TestDataFactory.createOpportunity(null, true); // StageName 'New'
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(o.Id, true);

        Boolean blockedNone = false;
        try {
            insert new Deal_Message__c(Details__c = 'orphan');
        } catch (DmlException e) {
            blockedNone = true;
        }
        System.assert(blockedNone, 'A message with no parent is blocked');

        Boolean blockedTwo = false;
        try {
            insert new Deal_Message__c(Details__c = 'double', LOI__c = loi.Id, Underwriting__c = uw.Id);
        } catch (DmlException e) {
            blockedTwo = true;
        }
        System.assert(blockedTwo, 'A message with two parents is blocked');
    }

    // ── P6 boundary coverage ─────────────────────────────────────────────────────
    // A valid-format but non-existent Id for the given type — the bare-user read throws on
    // Deal_Message__c object access under WITH USER_MODE before any row match.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: the selector's WITH USER_MODE query
    // against the custom Deal_Message__c object throws (no access), exercising getMessages'
    // read-failure catch (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6dm', Email = 'p6dm@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6DealMsg', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6dm.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers getMessages' read-failure catch: under a bare Standard User, the selector's
     * WITH USER_MODE query on Deal_Message__c throws (no object access) and the controller
     * maps it to a user-safe AuraHandledException. A fake LOI Id resolves the parent field
     * (describe is metadata, always available) before the selector throws. Its own method
     * because bareUser() inserts a User and this read does no record DML (no MIXED_DML).
     */
    @isTest
    static void getMessagesReadFailureThrowsAuraHandledException() {
        User u = bareUser();
        Id fakeLoiId = fakeId(LOI__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                DealMessageController.getMessages(fakeLoiId);
                Assert.fail('getMessages should throw under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getMessages maps read failure to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    /**
     * Covers addMessage's generic write-failure catch: a deleted LOI Id passes every guard
     * (non-null record, non-blank details, supported parent) then fails the Deal_Message__c
     * insert on the dead parent reference under admin — the deterministic way to reach the
     * generic catch (not the typed ValidationException / UnsupportedParentException branches).
     */
    @isTest
    static void addMessageWriteFailureThrowsAuraHandledException() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        Id deletedLoiId = loi.Id;
        delete loi;

        Test.startTest();
        Boolean threw = false;
        try {
            DealMessageController.addMessage(deletedLoiId, 'Note', 'Internal', 'Logged against a deleted LOI.', null);
            Assert.fail('addMessage on a deleted parent should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'write failure maps to AuraHandledException');
    }
}
