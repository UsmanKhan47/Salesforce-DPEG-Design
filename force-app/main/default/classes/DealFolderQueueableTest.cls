/**
 * Tests for DealFolderQueueable — the async venue and self-chain for SharePoint deal-folder
 * creation.
 *
 * ═══ EVERY TEST DRIVES A REAL `System.enqueueJob` + `Test.stopTest()` ═══
 * `execute()`'s first statement is `System.attachFinalizer(...)`, which the platform only permits
 * from inside a genuinely executing Queueable — calling `.execute(null)` directly from a test
 * method is not equivalent to a real async execution and is not used here (same reasoning
 * `RoutingFailureFinalizerTest`'s header records for the sibling Finalizer class).
 *
 * ═══ THE CHAINING DECISION IS ASSERTED ON `lastRunChainedIds`, NOT ON A SECOND ENQUEUE ═══
 * Chaining a Queueable from a Queueable throws `System.AsyncException: Maximum stack depth has been
 * reached` inside `@isTest` — a platform behaviour, not a bug — so `execute()` guards the real
 * `System.enqueueJob` call with `Test.isRunningTest()` and exposes the DECISION on a static. These
 * tests assert the decision; they cannot and do not assert that the platform performed a second
 * enqueue.
 *
 * @see DealFolderQueueable.cls
 * @see DealFolderFinalizerTest.cls (the Finalizer's own failure-path coverage)
 * @author Unit Testing Agent
 */
@isTest
private class DealFolderQueueableTest {

    private static void enableSharePoint(String siteId) {
        insert new SharePoint_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Is_Enabled__c = true, Site_ID__c = siteId);
    }

    private static List<Id> propertyIdsOf(List<Property__c> properties) {
        List<Id> ids = new List<Id>();
        for (Property__c p : properties) {
            ids.add(p.Id);
        }
        return ids;
    }

    @isTest
    static void execute_withinBudget_processesAllAndChainsNothing() {
        enableSharePoint('contoso-site');
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('queueable-item', null)));
        List<Property__c> properties = TestDataFactory.createProperties(3, true);

        Test.startTest();
        System.enqueueJob(new DealFolderQueueable(propertyIdsOf(properties)));
        Test.stopTest();

        Assert.isNotNull(DealFolderQueueable.lastRunChainedIds, '');
        Assert.isTrue(DealFolderQueueable.lastRunChainedIds.isEmpty(),
            'All 3 properties fit within MAX_PROPERTIES_PER_TRANSACTION (10) — nothing left to chain');

        Integer createdCount = [
            SELECT COUNT() FROM Property__c
            WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Created'
        ];
        Assert.areEqual(3, createdCount, 'All three properties must have been processed by this one link');
    }

    /**
     * 15 properties exceed `MAX_PROPERTIES_PER_TRANSACTION` (10). The real chain is suppressed
     * under `@isTest`, but the DECISION — which 5 properties would have been carried forward — must
     * still be recorded, and the job must complete without throwing.
     */
    @isTest
    static void execute_exceedsMaxPerTransaction_chainSuppressedUnderTest_decisionStillRecorded() {
        enableSharePoint('contoso-site');
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('queueable-item', null)));
        List<Property__c> properties = TestDataFactory.createProperties(15, true);
        // This queueable is enqueued DIRECTLY here, bypassing DealFolderService.claimFolders() — the
        // ONLY code that stamps Pending on the sync path. TestDataFactory leaves every status NULL,
        // so without this stamp the "5 left ... still Pending" assertion below would be comparing
        // against a value nothing ever set. Seed all 15 fixtures to the state claimFolders() would
        // already have put them in by the time this job runs in production.
        List<Property__c> pendingStamps = new List<Property__c>();
        for (Property__c p : properties) {
            pendingStamps.add(new Property__c(Id = p.Id, SharePoint_Folder_Status__c = 'Pending'));
        }
        update pendingStamps;

        Test.startTest();
        System.enqueueJob(new DealFolderQueueable(propertyIdsOf(properties)));
        Test.stopTest(); // must NOT throw — the chain attempt is guarded by Test.isRunningTest()

        Assert.areEqual(5, DealFolderQueueable.lastRunChainedIds.size(),
            '15 properties - 10 processed in this link = 5 left to (suppressed-under-test) chain');

        Integer createdCount = [
            SELECT COUNT() FROM Property__c
            WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Created'
        ];
        Integer pendingCount = [
            SELECT COUNT() FROM Property__c
            WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Pending'
        ];
        Assert.areEqual(10, createdCount, 'Only the first 10 (MAX_PROPERTIES_PER_TRANSACTION) are processed');
        Assert.areEqual(5, pendingCount,
            'The rest are left EXACTLY as they were — still Pending, recoverable by the daily sweep '
            + 'even though the chain link itself never ran. NOTE: a NULL-status property is invisible '
            + 'to PropertySelector.queryFolderSweep (locator is SharePoint_Folder_Status__c IN '
            + '(\'Pending\',\'Failed\')), so "recoverable" holds only because the synchronous '
            + 'claimFolders() path stamps Pending before any async job — this fixture reproduces that '
            + 'coupling deliberately.');
    }

    @isTest
    static void execute_nullPropertyIds_treatedAsEmptyList_completesCleanly() {
        Test.startTest();
        System.enqueueJob(new DealFolderQueueable(null));
        Test.stopTest(); // must NOT throw

        Assert.isTrue(DealFolderQueueable.lastRunChainedIds.isEmpty(),
            'A null payload must be treated as empty and produce no chain decision at all');
    }

    @isTest
    static void execute_emptyPropertyIds_completesCleanlyWithNoWork() {
        Test.startTest();
        System.enqueueJob(new DealFolderQueueable(new List<Id>()));
        Test.stopTest(); // must NOT throw

        Assert.isTrue(DealFolderQueueable.lastRunChainedIds.isEmpty(), '');
    }
}
