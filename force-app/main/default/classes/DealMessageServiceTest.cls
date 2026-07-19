/**
 * Tests DealMessageService — the extracted write + parent-resolution workflow behind
 * DealMessageController.addMessage (P6 controller thinning). Covers: parentFieldFor on all
 * three supported parents and its UnsupportedParentException; addMessage inserting on the
 * derived lookup with explicit values (trimming) and with blank optionals (Note / Internal /
 * null defaults — the true side of each ternary); and both ValidationException rejections
 * (null record, blank details).
 *
 * addMessage is inherently single-record (one insert mirroring the pre-thinning controller),
 * so there is no collection DML and thus no 251-record bulk case; the platform DmlException
 * on a save failure is exercised via the controller's write-catch test (deleted parent Id) in
 * DealMessageControllerTest.
 */
@isTest
private class DealMessageServiceTest {

    @isTest
    static void parentFieldFor_supportedParents_returnsObjectApiName() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(o.Id, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(o.Id, true);

        System.assertEquals('LOI__c', DealMessageService.parentFieldFor(loi.Id), 'LOI resolves to its own lookup');
        System.assertEquals('Underwriting__c', DealMessageService.parentFieldFor(uw.Id), 'Underwriting resolves');
        System.assertEquals('Contract_Review__c', DealMessageService.parentFieldFor(cr.Id), 'Contract Review resolves');
    }

    @isTest
    static void parentFieldFor_unsupportedObject_throwsUnsupportedParent() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);

        Boolean threw = false;
        try {
            DealMessageService.parentFieldFor(o.Id);
        } catch (DealMessageService.UnsupportedParentException e) {
            threw = true;
        }
        System.assert(threw, 'Opportunity is not a supported message-tracker parent');
    }

    @isTest
    static void addMessage_withExplicitValues_insertsTrimmedMessageOnDerivedParent() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(o.Id, true);

        Test.startTest();
        DealMessageService.addMessage(cr.Id, 'Email', 'Received', '  Seller counsel sent redline  ', '  v3  ');
        Test.stopTest();

        List<Deal_Message__c> msgs = [
            SELECT Method__c, Direction__c, Details__c, Revision__c, Contract_Review__c, Entry_DateTime__c
            FROM Deal_Message__c WHERE Contract_Review__c = :cr.Id
        ];
        System.assertEquals(1, msgs.size(), 'One message logged on the Contract Review');
        System.assertEquals('Email', msgs[0].Method__c, 'Explicit method kept');
        System.assertEquals('Received', msgs[0].Direction__c, 'Explicit direction kept');
        System.assertEquals('Seller counsel sent redline', msgs[0].Details__c, 'Details trimmed');
        System.assertEquals('v3', msgs[0].Revision__c, 'Revision trimmed');
        System.assertEquals(cr.Id, msgs[0].Contract_Review__c, 'Parent set on the derived lookup');
        System.assertNotEquals(null, msgs[0].Entry_DateTime__c, 'Entry stamp set');
    }

    @isTest
    static void addMessage_withBlankOptionals_appliesDefaults() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Test.startTest();
        DealMessageService.addMessage(loi.Id, '  ', '  ', 'Broker called with feedback', '  ');
        Test.stopTest();

        Deal_Message__c m = [
            SELECT Method__c, Direction__c, Revision__c, LOI__c
            FROM Deal_Message__c WHERE LOI__c = :loi.Id
        ];
        System.assertEquals('Note', m.Method__c, 'Blank method defaults to Note');
        System.assertEquals('Internal', m.Direction__c, 'Blank direction defaults to Internal');
        System.assertEquals(null, m.Revision__c, 'Blank revision stored as null');
        System.assertEquals(loi.Id, m.LOI__c, 'Parent set on the derived LOI lookup');
    }

    @isTest
    static void addMessage_nullRecord_throwsValidation() {
        Boolean threw = false;
        try {
            DealMessageService.addMessage(null, 'Note', 'Internal', 'details', null);
        } catch (DealMessageService.ValidationException e) {
            threw = true;
        }
        System.assert(threw, 'A null record is rejected before any DML');
    }

    @isTest
    static void addMessage_blankDetails_throwsValidationAndWritesNothing() {
        Opportunity o = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Boolean threw = false;
        try {
            DealMessageService.addMessage(loi.Id, 'Note', 'Internal', '   ', null);
        } catch (DealMessageService.ValidationException e) {
            threw = true;
        }
        System.assert(threw, 'Blank details are rejected');
        System.assertEquals(0, [SELECT COUNT() FROM Deal_Message__c WHERE LOI__c = :loi.Id],
            'Nothing is written when validation fails');
    }
}
