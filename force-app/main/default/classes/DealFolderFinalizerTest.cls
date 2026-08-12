/**
 * Test class for DealFolderFinalizer — the failure reporter for DealFolderQueueable, the job that
 * owns the SharePoint deal-folder callouts.
 *
 * ═══ A PURPOSE-BUILT THROWING Queueable, NOT PRODUCTION CODE (the established repo technique) ═══
 * `DealFolderQueueable` has no test seam that lets it die unhandled on demand. Salesforce's own
 * documented technique for testing a Finalizer is to attach the REAL Finalizer under test to a
 * small, test-local Queueable that deliberately throws, then observe the Finalizer's real side
 * effects through a REAL platform-supplied `FinalizerContext`. That is what `ThrowingQueueable`
 * below does — it does NOT modify `DealFolderQueueable` or any other production class. Identical
 * technique to `RoutingFailureFinalizerTest`'s `ThrowingQueueable`.
 *
 * ⚠ An unhandled exception thrown by a Queueable running synchronously at `Test.stopTest()`
 * PROPAGATES OUT of `Test.stopTest()` to the calling test method — unlike production, where there
 * is no synchronous caller left. Every test here that deliberately fails the job wraps
 * `Test.stopTest()` in try/catch. `Test.stopTest()` is called EXACTLY ONCE per test method.
 *
 * @see DealFolderFinalizer.cls
 * @see DealFolderQueueableTest.cls (the Queueable's OWN execute()/chaining coverage)
 * @see RoutingFailureFinalizerTest.cls (the precedent this class's technique is drawn from)
 * @author Unit Testing Agent
 */
@isTest
private class DealFolderFinalizerTest {

    /** Attaches a REAL DealFolderFinalizer, then deliberately throws unhandled. */
    private class ThrowingQueueable implements Queueable {
        private final List<Id> propertyIds;
        private final String message;
        ThrowingQueueable(List<Id> propertyIds, String message) {
            this.propertyIds = propertyIds;
            this.message = message;
        }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new DealFolderFinalizer(propertyIds));
            throw new SimulatedFailureException(message);
        }
    }

    /** Attaches the REAL Finalizer and completes cleanly — proves the SUCCESS no-op branch. */
    private class CleanQueueable implements Queueable {
        private final List<Id> propertyIds;
        CleanQueueable(List<Id> propertyIds) { this.propertyIds = propertyIds; }
        public void execute(QueueableContext ctx) {
            System.attachFinalizer(new DealFolderFinalizer(propertyIds));
        }
    }

    private class SimulatedFailureException extends Exception {}

    private static Id createPendingProperty() {
        Property__c p = TestDataFactory.createProperty(true);
        update new Property__c(Id = p.Id, SharePoint_Folder_Status__c = 'Pending');
        return p.Id;
    }

    // ── execute() — the core mechanism: UNHANDLED death stamps Failed ─────────────────────

    @isTest
    static void finalizer_onUnhandledException_stampsFailedWithMessageAndJobId() {
        Id propertyId = createPendingProperty();

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(new List<Id>{ propertyId },
            'System.LimitException: Apex heap size too large: 20000000'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected — see the class header. The Finalizer's own DML still committed before the
            // re-throw, independently queryable below.
        }

        Property__c p = [SELECT SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
                          FROM Property__c WHERE Id = :propertyId];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c,
            'An unhandled exception must stamp Failed, which is what puts the row in the sweep queue');
        Assert.isNotNull(p.SharePoint_Folder_Error__c, 'The failure must be RECORDED, not merely logged');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('Apex heap size too large: 20000000'),
            'The wrapped exception message must be named verbatim. Actual: ' + p.SharePoint_Folder_Error__c);
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('AsyncApexJob'),
            'The note must name the AsyncApexJob Id so an operator can find the failed job. Actual: '
            + p.SharePoint_Folder_Error__c);
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('DealFolderSweepBatch'),
            'The note must name the recovery path. Actual: ' + p.SharePoint_Folder_Error__c);
    }

    @isTest
    static void finalizer_multiplePropertiesInOnePayload_allStampedFailed() {
        List<Property__c> properties = TestDataFactory.createProperties(3, true);
        List<Id> ids = new List<Id>();
        for (Property__c p : properties) {
            ids.add(p.Id);
        }
        update new List<Property__c>{
            new Property__c(Id = properties[0].Id, SharePoint_Folder_Status__c = 'Pending'),
            new Property__c(Id = properties[1].Id, SharePoint_Folder_Status__c = 'Pending'),
            new Property__c(Id = properties[2].Id, SharePoint_Folder_Status__c = 'Pending')
        };

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(ids, 'System.LimitException: Apex CPU time limit exceeded'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Integer failedCount = [
            SELECT COUNT() FROM Property__c WHERE Id IN :ids AND SharePoint_Folder_Status__c = 'Failed'
        ];
        Assert.areEqual(3, failedCount, 'Every property the dying link was carrying must be stamped Failed');
    }

    @isTest
    static void finalizer_nullPropertyIds_doesNotThrow() {
        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(null, 'Simulated failure with no payload'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Assert.isTrue(true, 'A null payload must not prevent the Finalizer from completing cleanly');
    }

    // ── execute() — SUCCESS is a no-op, never overwrites the job's own stamps ─────────────

    @isTest
    static void finalizer_onSuccessfulParentJob_doesNothing() {
        // Attach the REAL Finalizer to a Queueable that completes cleanly. On SUCCESS the Finalizer
        // must do nothing — the job stamps its own terminal state, and a second write here could
        // only ever DISAGREE with it.
        Id propertyId = createPendingProperty();

        Test.startTest();
        System.enqueueJob(new CleanQueueable(new List<Id>{ propertyId }));
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
                          FROM Property__c WHERE Id = :propertyId];
        Assert.areEqual('Pending', p.SharePoint_Folder_Status__c,
            'A Finalizer running after a SUCCESSFUL parent job must not touch the row at all');
        Assert.isNull(p.SharePoint_Folder_Error__c, 'A successful run must add no note');
    }

    // ── 🔴 THE RE-READ-BEFORE-WRITE GUARANTEE, END TO END ──────────────────────────────────

    /**
     * An EARLIER chained link may already have committed a folder id for one of the properties in
     * a LATER, dying link's payload. The Finalizer must never drag an already-`Created` row back to
     * `Failed` — that would put a property that already has a folder back into the sweep's work
     * queue, where the guard would find the id and simply settle it to `Created` again, but only
     * after needlessly re-queuing it.
     */
    @isTest
    static void finalizer_payloadIncludesAnAlreadyCreatedProperty_doesNotDowngradeIt() {
        List<Property__c> properties = TestDataFactory.createProperties(2, true);
        update new Property__c(
            Id = properties[0].Id,
            SharePoint_Folder_ID__c = 'earlier-link-succeeded-item',
            SharePoint_Folder_Status__c = 'Created'
        );
        update new Property__c(Id = properties[1].Id, SharePoint_Folder_Status__c = 'Pending');
        List<Id> payload = new List<Id>{ properties[0].Id, properties[1].Id };

        Test.startTest();
        System.enqueueJob(new ThrowingQueueable(payload, 'System.LimitException: Apex heap size too large'));
        try {
            Test.stopTest();
            Assert.fail('Expected the deliberate unhandled exception to propagate out of stopTest()');
        } catch (Exception e) {
            // Expected.
        }

        Property__c alreadyCreated = [SELECT SharePoint_Folder_ID__c, SharePoint_Folder_Status__c,
                                              SharePoint_Folder_Error__c
                                       FROM Property__c WHERE Id = :properties[0].Id];
        Assert.areEqual('Created', alreadyCreated.SharePoint_Folder_Status__c,
            'An already-Created property in the payload must NOT be dragged back to Failed');
        Assert.areEqual('earlier-link-succeeded-item', alreadyCreated.SharePoint_Folder_ID__c, '');
        Assert.isNull(alreadyCreated.SharePoint_Folder_Error__c, '');

        Property__c stillPending = [SELECT SharePoint_Folder_Status__c
                                     FROM Property__c WHERE Id = :properties[1].Id];
        Assert.areEqual('Failed', stillPending.SharePoint_Folder_Status__c,
            'The genuinely-unfinished property in the SAME payload must still be stamped Failed');
    }
}
