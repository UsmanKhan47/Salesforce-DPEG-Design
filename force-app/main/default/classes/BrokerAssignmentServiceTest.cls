/**
 * Tests BrokerAssignmentService — the Broker Assignments (Property Management → Leasing)
 * write workflows extracted from BrokerAssignmentController in P6 controller thinning:
 * check-in stamp, listing close-out, native Note create, and the broker-replacement
 * snapshot-and-swap.
 *
 * Covers the happy paths plus both savepoint/rollback catch blocks (addNote's linked-note
 * failure and replaceBroker's swap failure), each forced with a deleted cross-reference Id
 * so the second DML in the unit of work fails after the first succeeds — proving the
 * savepoint rolls the first back. The service takes single-record inputs and does no
 * collection DML, so no 251-record bulk scenario applies (a per-record loop would breach
 * the 150 DML limit and would not exercise any bulkified path).
 *
 * @see force-app/main/default/classes/BrokerAssignmentService.cls
 */
@isTest
private class BrokerAssignmentServiceTest {

    @testSetup
    static void setup() {
        Property__c pr = TestDataFactory.createProperty(false);
        pr.Square_Footage__c = 42000;
        insert pr;
        Property_Asset__c pa = TestDataFactory.createPropertyAsset(pr.Id, false);
        pa.Name = 'Harbor Point';
        pa.Vacant_Area__c = 8000;
        insert pa;
        List<Contact> bk = TestDataFactory.createBrokerContacts(2, null, false);
        bk[0].LastName = 'Reyes'; bk[0].Broker_Firm__c = 'CBRE';
        bk[1].LastName = 'Okafor'; bk[1].Broker_Firm__c = 'JLL';
        insert bk;
        List<Broker_Assignment__c> a = TestDataFactory.createBrokerAssignments(2, pa.Id, bk[0].Id, false);
        a[0].Status__c = 'Active';
        a[1].Status__c = 'Active';
        insert a;
    }

    private static Broker_Assignment__c activeAssignment() {
        return [SELECT Id, Property_Asset__c, Broker__c FROM Broker_Assignment__c WHERE Status__c = 'Active' LIMIT 1];
    }
    private static Id secondBrokerId() {
        return [SELECT Id FROM Contact WHERE Is_Broker__c = true AND Broker_Firm__c = 'JLL' LIMIT 1].Id;
    }
    private static Id anyPropertyAssetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    // ───────────────────────── logCheckIn ─────────────────────────
    @isTest
    static void logCheckInStampsToday() {
        Broker_Assignment__c a = activeAssignment();
        Test.startTest();
        BrokerAssignmentService.logCheckIn(a.Id);
        Test.stopTest();
        Broker_Assignment__c after = [SELECT Last_Check_In_Date__c FROM Broker_Assignment__c WHERE Id = :a.Id];
        Assert.areEqual(Date.today(), after.Last_Check_In_Date__c, 'Check-in stamps today onto Last Check-In Date');
    }

    // ───────────────────────── closeOut ─────────────────────────
    @isTest
    static void closeOutWithExplicitEndDate() {
        Broker_Assignment__c a = activeAssignment();
        Date ed = Date.today().addDays(-2);
        Test.startTest();
        BrokerAssignmentService.closeOut(a.Id, 'Fully Leased', ed, 'Leased Up');
        Test.stopTest();
        Broker_Assignment__c after = [SELECT Status__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id = :a.Id];
        Assert.areEqual('Fully Leased', after.Status__c, 'Terminal status is set');
        Assert.areEqual(ed, after.Listing_End_Date__c, 'Explicit end date is honoured');
        Assert.areEqual('Leased Up', after.Reason_Ended__c, 'Reason ended is set');
    }

    @isTest
    static void closeOutNullEndDateDefaultsToday() {
        Broker_Assignment__c a = activeAssignment();
        Test.startTest();
        BrokerAssignmentService.closeOut(a.Id, 'Disposed', null, 'Performance Issue');
        Test.stopTest();
        Broker_Assignment__c after = [SELECT Status__c, Listing_End_Date__c FROM Broker_Assignment__c WHERE Id = :a.Id];
        Assert.areEqual('Disposed', after.Status__c, 'Terminal status is set');
        Assert.areEqual(Date.today(), after.Listing_End_Date__c, 'A null end date defaults to today');
    }

    // ───────────────────────── addNote ─────────────────────────
    @isTest
    static void addNoteCreatesLinkedNote() {
        Broker_Assignment__c a = activeAssignment();
        Test.startTest();
        BrokerAssignmentService.addNote(a.Id, 'Tour confirmed Friday.');
        Test.stopTest();
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :a.Id];
        Assert.areEqual(1, links.size(), 'One note linked to the record');
        ContentNote n = [SELECT Title FROM ContentNote WHERE Id = :links[0].ContentDocumentId];
        Assert.areEqual('Tour confirmed Friday.', n.Title, 'Title derives from the short body');
    }

    @isTest
    static void addNoteTruncatesLongTitle() {
        Broker_Assignment__c a = activeAssignment();
        String body = 'This particular note body is definitely longer than the fifty character title cap.';
        Test.startTest();
        BrokerAssignmentService.addNote(a.Id, body);
        Test.stopTest();
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :a.Id];
        ContentNote n = [SELECT Title FROM ContentNote WHERE Id = :links[0].ContentDocumentId];
        Assert.areEqual(50, n.Title.length(), 'Title is capped at 50 chars');
    }

    @isTest
    static void addNoteBlankThrowsTypedException() {
        Broker_Assignment__c a = activeAssignment();
        Boolean threw = false;
        Test.startTest();
        try {
            BrokerAssignmentService.addNote(a.Id, '   ');
        } catch (BrokerAssignmentService.BrokerAssignmentException e) {
            threw = true;
            Assert.areEqual('Note cannot be empty.', e.getMessage(), 'Typed validation carries the user-safe message');
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A blank body throws BrokerAssignmentException before any DML');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentNote], 'Nothing is persisted on a blank body');
    }

    @isTest
    static void addNoteRollsBackOnLinkFailure() {
        // A deleted record Id makes the ContentDocumentLink insert fail AFTER the ContentNote
        // insert succeeds — the savepoint must roll the note back so it is never orphaned.
        Broker_Assignment__c doomed = TestDataFactory.createBrokerAssignment(anyPropertyAssetId(), secondBrokerId(), true);
        Id deletedId = doomed.Id;
        delete doomed;
        Integer notesBefore = [SELECT COUNT() FROM ContentNote];

        Boolean threw = false;
        Test.startTest();
        try {
            BrokerAssignmentService.addNote(deletedId, 'orphan attempt');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'The link failure propagates out of the service');
        Assert.areEqual(notesBefore, [SELECT COUNT() FROM ContentNote], 'The committed note is rolled back — no orphan');
    }

    // ───────────────────────── replaceBroker ─────────────────────────
    @isTest
    static void replaceBrokerSnapshotsOutgoingAndStaysActive() {
        Broker_Assignment__c a = activeAssignment();
        Id oldBroker = a.Broker__c;
        Id newBroker = secondBrokerId();
        Integer before = [SELECT COUNT() FROM Broker_Assignment__c];

        Test.startTest();
        Id sameId = BrokerAssignmentService.replaceBroker(a.Id, newBroker, Date.today(), 'Performance Issue', 'Handover complete');
        Test.stopTest();

        Assert.areEqual(a.Id, sameId, 'Returns the same assignment Id');
        Assert.areEqual(before + 1, [SELECT COUNT() FROM Broker_Assignment__c], 'The outgoing broker is snapshotted as one new record');
        Broker_Assignment__c rec = [SELECT Status__c, Broker__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id = :a.Id];
        Assert.areEqual('Active', rec.Status__c, 'The listing stays Active');
        Assert.areEqual(newBroker, rec.Broker__c, 'The broker is swapped to the incoming broker');
        Assert.isNull(rec.Listing_End_Date__c, 'Any prior end date is cleared');
        Broker_Assignment__c snap = [SELECT Status__c, Broker__c, Reason_Ended__c, Replacement_Notes__c
                                     FROM Broker_Assignment__c WHERE Status__c = 'Disposed' AND Broker__c = :oldBroker
                                     ORDER BY CreatedDate DESC LIMIT 1];
        Assert.areEqual('Disposed', snap.Status__c, 'The snapshot is a Disposed history record');
        Assert.areEqual('Performance Issue', snap.Reason_Ended__c, 'The snapshot carries the replacement reason');
        Assert.areEqual('Handover complete', snap.Replacement_Notes__c, 'The snapshot carries the replacement notes');
    }

    @isTest
    static void replaceBrokerNullEffectiveDefaultsToday() {
        Broker_Assignment__c a = activeAssignment();
        Test.startTest();
        BrokerAssignmentService.replaceBroker(a.Id, secondBrokerId(), null, 'Perf', 'Note');
        Test.stopTest();
        Broker_Assignment__c rec = [SELECT Listing_Start_Date__c, Last_Check_In_Date__c FROM Broker_Assignment__c WHERE Id = :a.Id];
        Assert.areEqual(Date.today(), rec.Listing_Start_Date__c, 'A null effective date defaults the start date to today');
        Assert.areEqual(Date.today(), rec.Last_Check_In_Date__c, 'The check-in clock resets to today');
    }

    @isTest
    static void replaceBrokerNoCurrentBrokerSkipsSnapshot() {
        // An assignment with no current broker: the snapshot branch is skipped and only
        // the swap update runs.
        Broker_Assignment__c noBroker = new Broker_Assignment__c(
            Property_Asset__c = anyPropertyAssetId(),
            Status__c = 'Active',
            Listing_Start_Date__c = Date.today().addDays(-5)
        );
        insert noBroker;
        Id incoming = secondBrokerId();
        Integer before = [SELECT COUNT() FROM Broker_Assignment__c];

        Test.startTest();
        BrokerAssignmentService.replaceBroker(noBroker.Id, incoming, Date.today(), 'r', 'n');
        Test.stopTest();

        Assert.areEqual(before, [SELECT COUNT() FROM Broker_Assignment__c], 'No snapshot is created when the outgoing broker is null');
        Broker_Assignment__c rec = [SELECT Broker__c, Status__c FROM Broker_Assignment__c WHERE Id = :noBroker.Id];
        Assert.areEqual(incoming, rec.Broker__c, 'The listing is swapped to the incoming broker');
        Assert.areEqual('Active', rec.Status__c, 'The listing stays Active');
    }

    @isTest
    static void replaceBrokerRollsBackOnSwapFailure() {
        Broker_Assignment__c a = activeAssignment();
        // A deleted Contact Id makes the swap update's Broker__c lookup fail AFTER the
        // snapshot insert succeeds — the savepoint must roll the snapshot back.
        Contact ghost = TestDataFactory.createBrokerContact(null, true);
        Id ghostId = ghost.Id;
        delete ghost;
        Integer before = [SELECT COUNT() FROM Broker_Assignment__c];

        Boolean threw = false;
        Test.startTest();
        try {
            BrokerAssignmentService.replaceBroker(a.Id, ghostId, Date.today(), 'r', 'n');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A bad broker lookup fails the swap update');
        Assert.areEqual(before, [SELECT COUNT() FROM Broker_Assignment__c], 'The snapshot is rolled back on swap failure');
    }
}
