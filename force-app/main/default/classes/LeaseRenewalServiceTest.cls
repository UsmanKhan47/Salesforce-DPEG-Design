/**
 * Tests LeaseRenewalService — the extracted write workflow behind
 * LeaseRenewalController.addUpdate (P6 controller thinning). Covers: a human contact method
 * appending a timeline entry AND resetting the tenant-contact clock; a 'System' note
 * appending an entry WITHOUT resetting the clock (the if-branch's false side); and both
 * typed-validation rejections (blank outcome, missing/invalid method).
 *
 * addUpdate is inherently single-record (one child insert + one parent update, mirroring the
 * pre-thinning controller), so there is no collection DML and thus no 251-record bulk case;
 * the platform DmlException on a save failure is exercised via the controller's write-catch
 * test (deleted parent Id) in LeaseRenewalControllerTest.
 */
@isTest
private class LeaseRenewalServiceTest {

    /** A single Active renewal with Last_Contact_Date__c cleared so clock changes are observable. */
    private static Lease_Renewal__c newRenewal() {
        Property__c pr = TestDataFactory.createProperty(true);
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, true);
        Lease_Renewal__c r = TestDataFactory.createLeaseRenewal(pa.Id, false);
        r.Last_Contact_Date__c = null;
        insert r;
        return r;
    }

    @isTest
    static void addUpdate_humanMethod_logsEntryAndStampsContact() {
        Lease_Renewal__c r = newRenewal();

        Test.startTest();
        LeaseRenewalService.addUpdate(r.Id, 'Call', '  Reached the owner about terms.  ');
        Test.stopTest();

        List<Renewal_Activity__c> acts = [
            SELECT Method__c, Details__c FROM Renewal_Activity__c WHERE Lease_Renewal__c = :r.Id
        ];
        System.assertEquals(1, acts.size(), 'One timeline entry appended');
        System.assertEquals('Call', acts[0].Method__c, 'Method recorded');
        System.assertEquals('Reached the owner about terms.', acts[0].Details__c, 'Details trimmed');
        System.assertEquals(Date.today(),
            [SELECT Last_Contact_Date__c FROM Lease_Renewal__c WHERE Id = :r.Id].Last_Contact_Date__c,
            'A human method resets the tenant-contact clock');
    }

    @isTest
    static void addUpdate_systemMethod_logsEntryButDoesNotStampContact() {
        Lease_Renewal__c r = newRenewal();

        Test.startTest();
        LeaseRenewalService.addUpdate(r.Id, 'System', 'Renewal window opened by Yardi sync.');
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :r.Id],
            'A System note is still logged');
        System.assertEquals(null,
            [SELECT Last_Contact_Date__c FROM Lease_Renewal__c WHERE Id = :r.Id].Last_Contact_Date__c,
            'A System note is not tenant contact and never stamps the clock');
    }

    @isTest
    static void addUpdate_blankDetails_throwsTypedExceptionAndWritesNothing() {
        Lease_Renewal__c r = newRenewal();

        Boolean threw = false;
        try {
            LeaseRenewalService.addUpdate(r.Id, 'Call', '   ');
        } catch (LeaseRenewalService.RenewalUpdateException e) {
            threw = true;
        }
        System.assert(threw, 'A blank outcome is rejected with the typed exception');
        System.assertEquals(0, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :r.Id],
            'Nothing is written when validation fails');
    }

    @isTest
    static void addUpdate_invalidMethod_throwsTypedException() {
        Lease_Renewal__c r = newRenewal();

        Boolean threw = false;
        try {
            LeaseRenewalService.addUpdate(r.Id, 'Fax', 'Details are fine but the method is not.');
        } catch (LeaseRenewalService.RenewalUpdateException e) {
            threw = true;
        }
        System.assert(threw, 'An unknown contact method is rejected');
    }

    @isTest
    static void addUpdate_blankMethod_throwsTypedException() {
        Lease_Renewal__c r = newRenewal();

        Boolean threw = false;
        try {
            LeaseRenewalService.addUpdate(r.Id, '  ', 'Details present but no method chosen.');
        } catch (LeaseRenewalService.RenewalUpdateException e) {
            threw = true;
        }
        System.assert(threw, 'A blank method is rejected');
    }
}
