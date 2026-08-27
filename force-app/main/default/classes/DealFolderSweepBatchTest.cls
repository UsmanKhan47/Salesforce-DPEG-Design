/**
 * Tests for DealFolderSweepBatch — the retry/recovery engine for SharePoint deal folders.
 *
 * ═══ 🔴 `Database.executeBatch` MAY BE CALLED AT MOST ONCE PER TEST METHOD, AND ONLY WITH A SCOPE
 * LARGE ENOUGH TO COVER EVERY MATCHING ROW ═══
 * Measured precedent in this repo (`AttachmentCarrierSweepBatchTest`'s header, "Ceiling 1"): if the
 * locator returns more rows than the scope passed to `executeBatch`, the platform needs a SECOND
 * `execute()` invocation inside `Test.stopTest()`, and throws
 * `System.UnexpectedException: No more than one executeBatch can be called from within a test
 * method` the instant that would happen. So every test here either (a) keeps its fixture row count
 * at or below the scope it passes, or (b) — for the 251-row mandate — passes an OVERSIZED scope
 * (251) so the whole locator lands in one chunk, exactly as that precedent does. Consequently a
 * "run the batch twice" scenario is expressed as ONE run whose fixture is seeded to look like the
 * state AFTER an earlier successful pass (`sweepBatch_alreadyFolderedButStaleStatus_...` below),
 * never as two `executeBatch` calls in one method.
 *
 * ═══ WHY THIS BATCH CAN SAFELY TAKE AN OVERSIZED SCOPE WHERE `AttachmentCarrierSweepBatch` COULD
 * NOT ═══
 * That sibling class had to drop its bulk fixture to 150 rows because its per-row work issues its
 * own SOQL with no internal cap, so 251 rows in one chunk would overflow the 200-query async
 * ceiling. `DealFolderService.createFolders` is different: it caps itself at
 * `MAX_PROPERTIES_PER_TRANSACTION` (10) REGARDLESS of how many Ids the batch hands it in one call
 * (deferring the rest, untouched), so handing it all 251 in one oversized chunk still costs only
 * 1 SOQL, 70 callouts and 1 DML — comfortably safe. This suite therefore proves the literal 251-row
 * mandate directly, at the batch layer, rather than needing to fall back to the selector layer the
 * way the sibling class does.
 *
 * @see DealFolderSweepBatch.cls
 * @see AttachmentCarrierSweepBatchTest.cls (the precedent for both the ceiling and the workaround)
 * @author Unit Testing Agent
 */
@isTest
private class DealFolderSweepBatchTest {

    private static final String SITE_ID = 'contoso-site';

    private static void enableSharePoint(String siteId) {
        insert new SharePoint_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Is_Enabled__c = true, Site_ID__c = siteId);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BASIC RECOVERY — Pending and Failed rows are both in the work queue
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void sweepBatch_pendingRow_createsAndStampsTheFolder() {
        enableSharePoint(SITE_ID);
        Property__c property = TestDataFactory.createProperty(true);
        update new Property__c(Id = property.Id, SharePoint_Folder_Status__c = 'Pending');
        Test.setMock(HttpCalloutMock.class, new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('sweep-item-1', 'https://contoso.sharepoint.com/x/sweep-1')));

        Test.startTest();
        Database.executeBatch(new DealFolderSweepBatch(), DealFolderSweepBatch.SCOPE);
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_ID__c, SharePoint_Folder_URL__c, SharePoint_Folder_Status__c
                          FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c, '');
        Assert.areEqual('sweep-item-1', p.SharePoint_Folder_ID__c, '');
        Assert.areEqual('https://contoso.sharepoint.com/x/sweep-1', p.SharePoint_Folder_URL__c, '');
    }

    /**
     * 🔴 REQUIREMENT #7, SECOND HALF (the first half is
     * `DealFolderServiceTest.credentialDenied401_stampsFailedWithTheCredentialHint`). A row left
     * `Failed` by a credential-refused claim, carrying the credential hint, is picked up by the
     * sweep — running as a granted scheduling principal in production — and succeeds.
     *
     * ⚠ AMENDED 2026-08-27. This used to call "a Transactions-persona close" the canonical
     * scenario. It is not, since the claim moved to `CLAIM_STAGES`: the likeliest refusal is now
     * the `LOI_Approval` final-rejection field update running as the READ-ONLY APPROVER, with
     * `Transaction_Complete_Close` surviving only as a backstop at `Closed Won`.
     * 🔴 THE ERROR STRING BELOW IS A FIXTURE **INPUT**, NOT AN ASSERTION — which is exactly why it
     * went stale silently while this suite stayed green. It is a hand-written sample of what
     * `DealFolderService.HINT_CREDENTIAL` produces, and the sweep does not parse it; the test only
     * needs a `Failed` row that carries SOME durable hint. Keep it in step with the real constant
     * anyway, because a reader will take it for production copy.
     */
    @isTest
    static void sweepBatch_retriesAFailedRowCarryingTheCredentialHint_andSucceeds() {
        enableSharePoint(SITE_ID);
        Property__c property = TestDataFactory.createProperty(true);
        update new Property__c(
            Id = property.Id,
            SharePoint_Folder_Status__c = 'Failed',
            SharePoint_Folder_Error__c = 'FAILED to create the SharePoint deal folder: HTTP 401 — '
                + 'Access denied | LIKELY CAUSE: the user whose save advanced this deal has no '
                + 'access to the SharePoint external credential. SharePoint_Integration_Access is '
                + 'granted to DPEG_Junior_Analyst_PSG only...'
        );
        Test.setMock(HttpCalloutMock.class, new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('recovered-item', 'https://contoso.sharepoint.com/x/recovered')));

        Test.startTest();
        Database.executeBatch(new DealFolderSweepBatch(), DealFolderSweepBatch.SCOPE);
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_ID__c, SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
                          FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'DealFolderSweepBatch must pick up the Failed row and, once the credential works, create '
            + 'the folder on retry — this is the SharePoint feature\'s answer to a credential refusal, a dead job link or a deferred chunk');
        Assert.areEqual('recovered-item', p.SharePoint_Folder_ID__c, '');
        Assert.isNull(p.SharePoint_Folder_Error__c, 'A successful retry must clear the stale failure text');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // CONVERGENCE — a populated folder id means ZERO callouts, regardless of a stale status
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Simulates residual R3 (a folder was created but the stamp DML never landed, or a Finalizer
     * marked the row Failed after an earlier link had actually succeeded): the property already
     * carries a real folder id but its status is stale (`Failed`). The sweep must converge it to
     * `Created` with ZERO callouts — proven not merely by a request-count assertion but by a mock
     * that would FAIL every request, so a wrongly-made callout would flip the row back to Failed
     * rather than pass silently.
     */
    @isTest
    static void sweepBatch_alreadyFolderedButStaleStatus_convergesWithZeroCallouts() {
        enableSharePoint(SITE_ID);
        Property__c property = TestDataFactory.createProperty(true);
        update new Property__c(
            Id = property.Id,
            SharePoint_Folder_ID__c = 'already-exists-item',
            SharePoint_Folder_URL__c = 'https://contoso.sharepoint.com/x/already-exists',
            SharePoint_Folder_Status__c = 'Failed'
        );
        SharePointCalloutMock mock = new SharePointCalloutMock(500,
            SharePointCalloutMock.errorBody('must never be seen — proves the guard, not just the count'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Database.executeBatch(new DealFolderSweepBatch(), DealFolderSweepBatch.SCOPE);
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_ID__c, SharePoint_Folder_Status__c
                          FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'A populated folder id must converge the row to Created WITHOUT ever calling out — if a '
            + 'callout had been made, the 500-always mock would have flipped this back to Failed');
        Assert.areEqual('already-exists-item', p.SharePoint_Folder_ID__c, 'The original id survives untouched');
        Assert.areEqual(0, mock.requestCount, 'ZERO callouts — the strongest form of this assertion');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE LOCATOR EXCLUDES TERMINAL ROWS
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void sweepBatch_createdAndSkippedRows_areNeverTouchedByTheBatch() {
        enableSharePoint(SITE_ID);
        List<Property__c> properties = TestDataFactory.createProperties(4, true);
        // [0] Pending (owed), [1] Failed (owed), [2] Created (terminal), [3] Skipped (terminal)
        update new List<Property__c>{
            new Property__c(Id = properties[0].Id, SharePoint_Folder_Status__c = 'Pending'),
            new Property__c(Id = properties[1].Id, SharePoint_Folder_Status__c = 'Failed'),
            new Property__c(Id = properties[2].Id, SharePoint_Folder_ID__c = 'terminal-created-item',
                SharePoint_Folder_Status__c = 'Created'),
            new Property__c(Id = properties[3].Id, SharePoint_Folder_Status__c = 'Skipped',
                SharePoint_Folder_Error__c = 'SKIPPED: the integration is switched off.')
        };
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('locator-item', null)));

        Test.startTest();
        Database.executeBatch(new DealFolderSweepBatch(), DealFolderSweepBatch.SCOPE);
        Test.stopTest();

        Map<Id, Property__c> byId = new Map<Id, Property__c>([
            SELECT SharePoint_Folder_ID__c, SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
            FROM Property__c WHERE Id IN :properties
        ]);
        Assert.areEqual('Created', byId.get(properties[0].Id).SharePoint_Folder_Status__c,
            'The Pending row must be processed');
        Assert.areEqual('Created', byId.get(properties[1].Id).SharePoint_Folder_Status__c,
            'The Failed row must be processed too');
        Assert.areEqual('terminal-created-item', byId.get(properties[2].Id).SharePoint_Folder_ID__c,
            'A row already Created is excluded from the locator entirely and must be byte-for-byte untouched');
        Assert.areEqual('Skipped', byId.get(properties[3].Id).SharePoint_Folder_Status__c,
            'A Skipped row is excluded from the locator and must stay Skipped');
        Assert.isTrue(byId.get(properties[3].Id).SharePoint_Folder_Error__c.contains('switched off'),
            'Its original explanatory text must survive untouched');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 rows, .claude/rules/bulk-test-rule.md (no exemption claimed)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * See the class header for why `bulkRows` (251) is passed as the SCOPE, not the production
     * `DealFolderSweepBatch.SCOPE` (10) — Apex disallows a second in-test chunk, and this is the
     * only way to prove the LOCATOR selects and orders every one of 251 rows in a single test
     * method. It is SAFE here specifically because `DealFolderService.createFolders` caps real
     * work at `MAX_PROPERTIES_PER_TRANSACTION` regardless of how many Ids the batch hands it.
     */
    @isTest
    static void bulk251PendingProperties_locatorSelectsAllAndTheServicesOwnBudgetGuardProtectsTheChunk() {
        final Integer bulkRows = 251;
        enableSharePoint(SITE_ID);
        List<Property__c> properties = TestDataFactory.createProperties(bulkRows, true);
        List<Property__c> pendingStamps = new List<Property__c>();
        for (Property__c p : properties) {
            pendingStamps.add(new Property__c(Id = p.Id, SharePoint_Folder_Status__c = 'Pending'));
        }
        update pendingStamps;
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('bulk-sweep-item', null)));

        Assert.areEqual(bulkRows, [
            SELECT COUNT() FROM Property__c WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Pending'
        ], 'Precondition: all 251 properties are in the sweep\'s work queue before the batch runs');

        Test.startTest();
        Id jobId = Database.executeBatch(new DealFolderSweepBatch(), bulkRows);
        Test.stopTest();

        AsyncApexJob job = [SELECT Status, NumberOfErrors, JobItemsProcessed FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status,
            'The batch must complete cleanly with all 251 rows landing in ONE oversized chunk');
        Assert.areEqual(0, job.NumberOfErrors, '');
        Assert.areEqual(1, job.JobItemsProcessed,
            'Proves the LOCATOR handed the batch every one of the 251 rows in a single chunk');

        Integer createdCount = [
            SELECT COUNT() FROM Property__c WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Created'
        ];
        Integer stillPendingCount = [
            SELECT COUNT() FROM Property__c WHERE Id IN :properties AND SharePoint_Folder_Status__c = 'Pending'
        ];
        Assert.areEqual(DealFolderService.MAX_PROPERTIES_PER_TRANSACTION, createdCount,
            'The SERVICE\'S OWN internal budget guard caps real creation at 10, even though the batch '
            + 'handed it all 251 Ids in one call — this is what keeps an oversized chunk safe');
        Assert.areEqual(bulkRows - DealFolderService.MAX_PROPERTIES_PER_TRANSACTION, stillPendingCount,
            'The rest are left untouched — still Pending, in the queue for the next real (SCOPE = 10) pass');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // TRIVIAL / DEFENSIVE COVERAGE
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void start_returnsANonNullLocator() {
        Test.startTest();
        Database.QueryLocator locator = new DealFolderSweepBatch().start(null);
        Test.stopTest();

        Assert.isNotNull(locator, 'start() must always return a locator');
    }

    @isTest
    static void finish_completesWithoutThrowing() {
        Test.startTest();
        new DealFolderSweepBatch().finish(null);
        Test.stopTest();

        Assert.isTrue(true, 'finish() must complete cleanly — it only summarises via debug logging');
    }

    @isTest
    static void execute_nullOrEmptyScope_isANoOp() {
        Test.startTest();
        new DealFolderSweepBatch().execute(null, null);
        new DealFolderSweepBatch().execute(null, new List<Property__c>());
        Test.stopTest();

        Assert.isTrue(true, 'Must not throw for a null or empty scope');
    }
}
