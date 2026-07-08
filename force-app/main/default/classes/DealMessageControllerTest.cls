/**
 * Tests DealMessageController: one tracker serving LOI, Underwriting, and
 * Contract Review parents; append-only history newest-first; unsupported
 * objects rejected; exactly-one-parent enforced by the object's VR.
 */
@isTest
private class DealMessageControllerTest {

    @isTest
    static void logsAndReadsOnAllThreeParents() {
        Opportunity o = new Opportunity(Name = 'Msg Test', StageName = 'New',
            CloseDate = Date.today().addDays(30));
        insert o;
        LOI__c loi = new LOI__c(Opportunity__c = o.Id);
        insert loi;
        Underwriting__c uw = new Underwriting__c(Opportunity__c = o.Id, Stage__c = 'Requested');
        insert uw;
        Contract_Review__c cr = new Contract_Review__c(Opportunity__c = o.Id, Stage__c = 'PSA Drafting');
        insert cr;

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
        Opportunity o = new Opportunity(Name = 'Msg Reject', StageName = 'New',
            CloseDate = Date.today().addDays(30));
        insert o;

        Boolean threwObject = false;
        try {
            DealMessageController.addMessage(o.Id, 'Note', 'Internal', 'not allowed here', null);
        } catch (Exception e) {
            threwObject = true;
        }
        System.assert(threwObject, 'Opportunity is not a message-tracker parent');

        LOI__c loi = new LOI__c(Opportunity__c = o.Id);
        insert loi;
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
        Opportunity o = new Opportunity(Name = 'Msg VR', StageName = 'New',
            CloseDate = Date.today().addDays(30));
        insert o;
        LOI__c loi = new LOI__c(Opportunity__c = o.Id);
        insert loi;
        Underwriting__c uw = new Underwriting__c(Opportunity__c = o.Id);
        insert uw;

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
}
