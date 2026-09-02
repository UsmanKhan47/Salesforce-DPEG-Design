/**
 * Tests for DealFolderService — the SharePoint deal-folder orchestration service.
 *
 * ═══ TWO CALLING STYLES, DELIBERATELY MIXED ═══
 * Tests that must prove SYNC WIRING (the trigger really does stamp/enqueue correctly, and really
 * does not roll back a Closed Won) go THROUGH the real trigger: `TestDataFactory` fixtures +
 * `close()` (an `update` on `Opportunity.StageName`) + ONE `Test.startTest()/stopTest()` pair, the
 * same shape `PropertyAssetServiceTest` uses. Tests that isolate a single ASYNC-layer branch (the
 * budget guard, the disabled-mid-flight stamp, a partial subfolder failure) call
 * `DealFolderService.createFolders(ids)` DIRECTLY — that method is PUBLIC precisely because it is
 * meant to be invoked from an async context, and calling it directly from a test is simpler and
 * fully deterministic (no enqueue/chain timing to reason about). Both styles are legitimate; each
 * test's own name says which one it is.
 *
 * ═══ 🔴 THE CLAIM STAGE MOVED ON 2026-08-27, AND SO DID THE 251-RECORD FIXTURE ═══
 * `DealFolderService` used to key on entry to `Closed Won` alone; it now keys on entry to any
 * member of `CLAIM_STAGES` = { 'Under Review', 'Underwriting', 'About to Close', 'Closed Won' }.
 * 🔴 **BOTH 251-RECORD BULK TESTS WERE MOVED, NOT RENAMED.** Per `.claude/rules/bulk-test-rule.md`
 * the 251 mandate applies to the SYNCHRONOUS claim path (it is a trigger), and it must be met AT
 * THE STAGE THE CODE NOW KEYS ON. A fixture that still bulk-updated to `Closed Won` would still go
 * green while proving nothing about the path production actually takes — the exact vacuous-test
 * shape this suite has been bitten by before. They now drive `New` -> `Under Review`, the ordinary
 * route (the **Begin Review** action), which needs no signed NDA and no executed contract.
 * ⚠ The ASYNC path keeps its existing volume shape deliberately: 251 properties would demand
 * 1,757 callouts and would measure a state the job can never be in.
 *
 * ═══ 🔴 THE DUPLICATE-FOLDER FALSIFIER (§7 of the design doc) IS THE MOST IMPORTANT TEST HERE ═══
 * TWO tests carry that name now, and the SECOND one is new and is the more important of the pair:
 *   • `duplicateFolderFalsifier_bulk251...` — 251 deals whose properties ALREADY carry a
 *     `SharePoint_Folder_ID__c` enter a claim stage: ZERO callouts, ZERO enqueues. The guard that
 *     stops `conflictBehavior: rename` from quietly minting a second folder for every re-save,
 *     sweep pass or concurrent claim.
 *   • `walkedThroughAllFourClaimStages_claimsExactlyOnce_...` — 🔴 **the falsifier for the FOUR-
 *     STAGE SET ITSELF.** One deal walked through all four claim stages must claim EXACTLY ONCE:
 *     one enqueue, one idempotency read, one folder tree of seven callouts. If either half of the
 *     entry test in `enteringPropertyIds` were ever changed to compare a single stage, this test
 *     goes red with four enqueues and four reads instead of one. Nothing else in the suite can
 *     see that regression.
 *
 * ═══ ⚠ Test.startTest()/Test.stopTest() MAY BE CALLED ONLY ONCE PER TEST METHOD ═══
 * (measured elsewhere in this repo — a second call throws). Any scenario needing "attempt once,
 * fix the cause, retry" (the credential-denied → sweep-recovery story) is therefore necessarily
 * split across TWO test methods, one here proving the FIRST half (stamps Failed with the hint) and
 * one in `DealFolderSweepBatchTest` proving the SECOND half (the sweep recovers it).
 *
 * ═══ WHAT THIS SUITE CANNOT PROVE — SAID OUT LOUD, NOT HIDDEN ═══
 * `PropertySelector.selectFolderStateByIds` / `queryFolderSweep` run `WITH SYSTEM_MODE` inside a
 * `private without sharing` inner class specifically so the running principal's FLS and sharing
 * cannot change the answer — an admin-run `System.runAs` "it still works" assertion would pass
 * whether or not that inner class existed, and would falsify nothing (identical reasoning already
 * recorded in `PropertySelectorTest`'s header for `selectAssetSeedByIds`). What the decision rests
 * on is measured repo/org state (`Property__c` is `sharingModel = Private`; its one sharing rule is
 * an owner rule scoped to the `Acquisition` queue, which does not reach a `LeadConvertService`-owned
 * Property) recorded in the selector's own header, and is provable only by a real post-deploy gate
 * run as a genuinely under-provisioned persona (e.g. `DPEG_Transaction_Team`) — not from Apex.
 *
 * No @TestSetup: every method builds exactly the fixtures it needs, so a shared scaffold row can
 * never leak into a count-based assertion (same discipline as `PropertyAssetServiceTest`).
 *
 * @see DealFolderService.cls
 * @see PropertyAssetServiceTest.cls (the sibling precedent this suite's shape follows)
 * @author Unit Testing Agent
 */
@isTest
private class DealFolderServiceTest {

    /** .claude/rules/bulk-test-rule.md — 251 forces a SECOND Opportunity trigger chunk. */
    private static final Integer BULK_N = 251;
    private static final String CLOSED_WON = 'Closed Won';
    /** The ORDINARY claim stage — `StageAdvanceService.advance()` from 'New', i.e. Begin Review.
     *  It has no NDA gate and no contract gate, which is why the bulk fixture uses it. */
    private static final String UNDER_REVIEW = 'Under Review';
    private static final String UNDERWRITING = 'Underwriting';
    private static final String ABOUT_TO_CLOSE = 'About to Close';
    /** 🔴 A NON-claim stage that is reachable from 'New' in one save with no gates, used to prove a
     *  stage move that must cost NOTHING. 'Development Review' / 'Construction Review' would not
     *  do: they are record-type-restricted branches, and this repo has MEASURED that a restricted
     *  picklist IS enforced by DML, so writing one on the wrong record type throws. */
    private static final String DEAD_PASS = 'Dead/Pass';
    private static final String SITE_ID = 'contoso-site';

    // ═════════════════════════════════════════════════════════════════════════════════════
    // FIXTURE HELPERS
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Inserts `count` properties and `count` Opportunities, one Opportunity per property, already
     * prepared to cross the THREE Closed Won validation gates
     * (`NDA_Signed_Before_Deal_Progression`, `Contract_Signed_Before_Closed_Won` and, since
     * 2026-09-02, `Transaction_Closed_Before_Closed_Won`) — the identical fixture shape
     * `PropertyAssetServiceTest.dealsReadyToClose` uses, reproduced here rather than shared because
     * that helper is `private` to its own test class.
     *
     * 🔴 THE THIRD GATE IS SATISFIED BY WRITING THE PARENT FLAGS, NOT BY CREATING A
     * `Transaction__c`. `TestDataFactory.markTransactionClosed` is one field pair in one bulk DML;
     * a real Transaction per deal would fan out 82 checklist Tasks each and will not run at this
     * class's volumes. The full argument is at that helper's declaration — read it before
     * "improving" this.
     *
     * @param count      How many pairs.
     * @param properties Out-parameter: the inserted properties, index-aligned to the result.
     * @return The inserted, gate-ready Opportunities, left at 'New'.
     */
    private static List<Opportunity> dealsReadyToClose(Integer count, List<Property__c> properties) {
        properties.addAll(TestDataFactory.createProperties(count, false));
        insert properties;

        List<Opportunity> opps = TestDataFactory.createOpportunities(count, false);
        for (Integer i = 0; i < count; i++) {
            opps[i].Property__c = properties[i].Id;
        }
        insert opps;

        TestDataFactory.signPrimaryNda(opps);
        TestDataFactory.signContract(opps);
        TestDataFactory.markTransactionClosed(opps);
        return opps;
    }

    /**
     * Inserts `count` properties and `count` Opportunities, one per property, left at 'New' with
     * NO stage-gate preparation at all.
     *
     * 🔴 THIS IS THE FIXTURE THE BULK TESTS USE, AND ITS CHEAPNESS IS THE POINT. Entering
     * 'Under Review' passes `NDA_Signed_Before_Deal_Progression` (whose OR list starts at
     * 'Underwriting') and `No_Backward_Stage_Movement` (rank 1 -> rank 2 is forward) with no
     * preparation, so 251 deals need no NDA signing and no contract signing — unlike
     * `dealsReadyToClose`, which exists for the tests that genuinely must reach `Closed Won`.
     *
     * @param count      How many pairs.
     * @param properties Out-parameter: the inserted properties, index-aligned to the result.
     * @return The inserted Opportunities, at 'New'.
     */
    private static List<Opportunity> dealsAtNew(Integer count, List<Property__c> properties) {
        properties.addAll(TestDataFactory.createProperties(count, false));
        insert properties;

        List<Opportunity> opps = TestDataFactory.createOpportunities(count, false);
        for (Integer i = 0; i < count; i++) {
            opps[i].Property__c = properties[i].Id;
        }
        insert opps;
        return opps;
    }

    /** Moves already-prepared deals to `stage` in ONE bulk DML. */
    private static void moveTo(List<Opportunity> opps, String stage) {
        for (Opportunity o : opps) {
            o.StageName = stage;
            // ⚠ Rejection_Reason__c BECAME MANDATORY ON Dead/Pass ON 2026-08-30
            // (Opportunity/validationRules/Rejection_Reason_Required_On_Dead). Without this,
            // `aStageMoveThatIsNotAClaimStage_costsNothing` — the suite's ONLY proof that a stage
            // move outside CLAIM_STAGES is free — fails on the fixture rather than on its subject.
            // It is set HERE, in the shared helper, so any future Dead/Pass move through `moveTo`
            // is covered too; every other stage is untouched.
            //
            // ⚠ 'Wrong Market' is present on BOTH surviving Opportunity record types — Land and
            // Retail (Commercial was deleted 2026-08-30). Re-verified that day in
            // objects/Opportunity/recordTypes/*.recordType-meta.xml). These fixtures set no
            // RecordTypeId, so the Master set applies — but the restricted picklist IS enforced by
            // DML in this org, so a value valid everywhere is the only safe choice in a helper.
            if (stage == DEAD_PASS) {
                o.Rejection_Reason__c = 'Wrong Market';
            }
        }
        update opps;
    }

    /** Moves already-prepared deals to Closed Won in one bulk DML. */
    private static void close(List<Opportunity> opps) {
        moveTo(opps, CLOSED_WON);
    }

    /** The org's converted Lead status — never hardcoded; it differs per org. */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    /** Inserts the org-default `SharePoint_Config__c` row, enabled, with the given site id. */
    private static void enableSharePoint(String siteId) {
        insert new SharePoint_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Is_Enabled__c = true,
            Site_ID__c = siteId
        );
    }

    /** Re-queries every SharePoint field for the given properties, ordered by Name. */
    private static List<Property__c> propertiesFor(List<Property__c> properties) {
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();
        return [
            SELECT Id, Name, SharePoint_Folder_ID__c, SharePoint_Folder_URL__c,
                   SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
            FROM Property__c
            WHERE Id IN :ids
            ORDER BY Name
        ];
    }

    /** Simulates the credential-denied transport failure a running user with no External
     *  Credential Principal Access produces. */
    private class ThrowingCalloutMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            throw new CalloutException('Unable to resolve external credential principal for user');
        }
    }

    /** A trivial no-op Queueable that exists ONLY to consume a slot in
     *  `Limits.getQueueableJobs()` — mirrors `EmailMessageTriggerHandlerTest`'s identical filler
     *  precedent for the EAC pipeline's own `System.enqueueJob` guard. */
    private class NoOpQueueable implements Queueable {
        public void execute(QueueableContext ctx) {
            // Deliberately empty. Its only job is to occupy one of the 50 queueable slots.
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 sanitizeFolderName — A PURE FUNCTION. Every rule, in the order the header documents.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** The exact example from the method's own Javadoc — the illegal-char replacement, whitespace
     *  collapse and trailing-dot strip working together on one realistic marketing-text name. */
    @isTest
    static void sanitize_javadocExample_matchesExactly() {
        Assert.areEqual('1400 Royal Ln Suite B',
            DealFolderService.sanitizeFolderName('  1400 Royal Ln / Suite B... '), '');
    }

    /** Every character in the illegal set, each replaced with a space (not deleted), so two words
     *  either side of a slash still read as two words rather than merging into one. */
    @isTest
    static void sanitize_everyIllegalCharacter_replacedWithSpaceAndCollapsed() {
        // A " * : < > ? / \ | between each letter — one instance of each of the nine illegal chars.
        String input = 'A"B*C:D<E>F?G/H\\I|J';
        Assert.areEqual('A B C D E F G H I J', DealFolderService.sanitizeFolderName(input), '');
    }

    @isTest
    static void sanitize_controlCharacter_convertedToSpace() {
        String input = 'A' + String.fromCharArray(new List<Integer>{ 7 }) + 'B'; // BEL, 0x07
        Assert.areEqual('A B', DealFolderService.sanitizeFolderName(input), '');
    }

    @isTest
    static void sanitize_leadingAndTrailingWhitespace_trimmed() {
        Assert.areEqual('Magnolia Crossing',
            DealFolderService.sanitizeFolderName('   Magnolia Crossing   '), '');
    }

    @isTest
    static void sanitize_trailingDotsAndSpaces_stripped() {
        Assert.areEqual('Magnolia Crossing',
            DealFolderService.sanitizeFolderName('Magnolia Crossing... '), '');
    }

    @isTest
    static void sanitize_leadingTildeDollarPrefix_stripped() {
        Assert.areEqual('Temp Deal Folder',
            DealFolderService.sanitizeFolderName('~$Temp Deal Folder'), '');
    }

    @isTest
    static void sanitize_repeatedLeadingTildeDollarPrefix_allStripped() {
        Assert.areEqual('Config', DealFolderService.sanitizeFolderName('~$~$Config'), '');
    }

    @isTest
    static void sanitize_overLength_clampedToMaxNameChars() {
        String result = DealFolderService.sanitizeFolderName('A'.repeat(250));
        Assert.areEqual(200, result.length(), 'MAX_NAME_CHARS is 200 — see the class header');
    }

    /** 🔴 THE ORDER-OF-OPERATIONS PIN. The clamp runs BEFORE the trailing-dot strip specifically so
     *  a dot landing exactly at the cut point is still removed — reversing the order would leave a
     *  name SharePoint rejects. Constructed so the 200-char clamp lands exactly on a '.'. */
    @isTest
    static void sanitize_clampLandingOnATrailingDot_stripsItAfterClamping() {
        String raw = 'A'.repeat(199) + '.' + 'A'.repeat(50); // clamp(0,200) ends exactly on the dot
        String result = DealFolderService.sanitizeFolderName(raw);
        Assert.areEqual(199, result.length(),
            'The dot introduced AT the clamp point must still be stripped afterwards');
        Assert.isFalse(result.endsWith('.'), 'Actual: ' + result);
    }

    @isTest
    static void sanitize_reservedNames_rejectedCaseInsensitively() {
        List<String> reserved = new List<String>{
            'CON', 'con', 'PRN', 'AUX', 'NUL', 'COM1', 'com1', 'LPT9', 'DESKTOP.INI', 'desktop.ini', '.LOCK'
        };
        for (String name : reserved) {
            Assert.areEqual('', DealFolderService.sanitizeFolderName(name),
                name + ' is a reserved name and must sanitize to empty');
        }
    }

    @isTest
    static void sanitize_vtiPrefix_rejectedCaseInsensitively() {
        Assert.areEqual('', DealFolderService.sanitizeFolderName('_vti_something'), '');
        Assert.areEqual('', DealFolderService.sanitizeFolderName('_VTI_Something'), '');
    }

    @isTest
    static void sanitize_wholeStringIllegal_sanitizesToEmpty() {
        Assert.areEqual('', DealFolderService.sanitizeFolderName('***///:::'), '');
    }

    @isTest
    static void sanitize_nullOrBlank_returnsEmptyNeverNull() {
        Assert.areEqual('', DealFolderService.sanitizeFolderName(null), '');
        Assert.areEqual('', DealFolderService.sanitizeFolderName('     '), '');
    }

    @isTest
    static void sanitize_ordinaryPropertyName_isUnaffected() {
        Assert.areEqual('Magnolia Crossing',
            DealFolderService.sanitizeFolderName('Magnolia Crossing'), '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE DUPLICATE-FOLDER FALSIFIER — the single most valuable test in this suite
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 251 deals ENTER A CLAIM STAGE against 251 properties that ALREADY carry a SharePoint folder —
     * simulating a re-marketed property, a concurrent second deal on the same property, or a sweep
     * pass arriving after a prior success. The idempotency guard must find them all already
     * foldered and do NOTHING external.
     *
     * ⚠ MOVED 2026-08-27 from a bulk `Closed Won` update to a bulk `Under Review` update. The
     * record count (251, two trigger chunks) and every assertion below are unchanged — only the
     * stage moved, because that is the stage the code now keys on.
     */
    @isTest
    static void duplicateFolderFalsifier_bulk251ClaimStageEntryAgainstAlreadyFolderedProperties_zeroCalloutsZeroEnqueues() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-never-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);
        enableSharePoint(SITE_ID);

        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsAtNew(BULK_N, properties);

        List<Property__c> alreadyFoldered = new List<Property__c>();
        for (Integer i = 0; i < properties.size(); i++) {
            alreadyFoldered.add(new Property__c(
                Id = properties[i].Id,
                SharePoint_Folder_ID__c = 'existing-item-' + i,
                SharePoint_Folder_URL__c = 'https://contoso.sharepoint.com/x/existing-' + i,
                SharePoint_Folder_Status__c = 'Created'
            ));
        }
        update alreadyFoldered;

        DealFolderService.resetRunCounters();
        Test.startTest();
        // 251-record CLAIM-STAGE entry ('New' -> 'Under Review') — TWO trigger chunks (200 + 51)
        moveTo(opps, UNDER_REVIEW);
        Test.stopTest();

        Assert.areEqual(0, DealFolderService.runCalloutCount,
            'THE DUPLICATE-FOLDER FALSIFIER: every property already had a folder — ZERO callouts');
        Assert.areEqual(0, DealFolderService.runEnqueueCount,
            'and ZERO async jobs enqueued — there is nothing owed in either chunk');
        Assert.areEqual(0, mock.requestCount,
            'Corroborated at the transport layer: the mock must never be invoked at all');
        Assert.areEqual(2, DealFolderService.runInvocations,
            'The sync path still ran once per trigger chunk — it just found nothing owed, so no '
            + 'async invocation ever follows');
        Assert.areEqual(2, DealFolderService.runQueryCount,
            'One idempotency read per chunk (2), and no async read follows either');
        Assert.areEqual(0, DealFolderService.runDmlCount,
            'Every property was ALREADY "Created" — there is nothing to converge, so zero DML too');

        List<Property__c> after = propertiesFor(properties);
        for (Property__c p : after) {
            Assert.areEqual('Created', p.SharePoint_Folder_Status__c, '');
            Assert.isTrue(p.SharePoint_Folder_ID__c.startsWith('existing-item-'),
                'The original folder id must survive UNTOUCHED — no duplicate was minted. Actual: '
                + p.SharePoint_Folder_ID__c);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 251-RECORD BULK CLOSE — fresh properties, real (mocked) folder creation, constant budget
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 251 FRESH deals (no pre-existing folders) ENTER A CLAIM STAGE in one transaction. Proves
     * three things at once: (1) exactly ONE enqueue per trigger chunk — 2 total, never 251; (2) the sync path's
     * SOQL/DML is CONSTANT per invocation; (3) each of the two chained-off async jobs is bounded
     * to `MAX_PROPERTIES_PER_TRANSACTION` (10) properties (70 callouts), deferring the remainder
     * rather than attempting all of them and risking an uncatchable LimitException.
     *
     * ⚠ MOVED 2026-08-27 from a bulk `Closed Won` update to a bulk `New` -> `Under Review` update,
     * per `.claude/rules/bulk-test-rule.md`: the 251 mandate binds on the SYNCHRONOUS trigger path,
     * so it has to be met at the stage that path now keys on. Every number below is unchanged —
     * the arithmetic is a function of the record count and the callout budget, not of the stage.
     *
     * The arithmetic, so a future reader does not have to re-derive it:
     *   251 records -> 2 trigger chunks (200 + 51) -> 2 sync invocations, 2 enqueues
     *   Each of the 2 enqueued jobs runs (chaining is suppressed under @isTest) -> 2 async invocations
     *   runInvocations = 4 (2 sync + 2 async);  runQueryCount = 4 (1 per invocation)
     *   runDmlCount    = 4 (1 per invocation, since every invocation has something to stamp)
     *   runCalloutCount = 140 (2 jobs x 10 properties x 7 callouts)
     *   runFoldersCreated = 20; runSubfoldersCreated = 120; runDeferred = 190 + 41 = 231
     * Do not shrink the record count and do not relax the budget to make this pass.
     */
    @isTest
    static void bulk251EnteringAClaimStage_enqueuesExactlyTwoChunksOnAConstantBudget() {
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('created-item', 'https://contoso.sharepoint.com/x/created'));
        Test.setMock(HttpCalloutMock.class, mock);
        enableSharePoint(SITE_ID);

        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsAtNew(BULK_N, properties);

        DealFolderService.resetRunCounters();
        Test.startTest();
        moveTo(opps, UNDER_REVIEW);
        Test.stopTest();

        Assert.areEqual(2, DealFolderService.runEnqueueCount,
            '251 Opportunities is 2 trigger chunks -> exactly ONE enqueue per chunk, NEVER one per deal');
        Assert.areEqual(4, DealFolderService.runInvocations,
            '2 sync (one per chunk) + 2 async (one per chained job, chaining suppressed under @isTest)');
        Assert.areEqual(4, DealFolderService.runQueryCount,
            'CONSTANT 1 SOQL per invocation regardless of chunk size. If this reds because the '
            + 'number grew with the record count, a query moved into a loop');
        Assert.areEqual(4, DealFolderService.runDmlCount,
            'CONSTANT 1 bulk DML per invocation (2 sync Pending-stamps + 2 async Created-stamps)');
        Assert.areEqual(140, DealFolderService.runCalloutCount,
            '2 jobs x 10 properties (MAX_PROPERTIES_PER_TRANSACTION) x 7 callouts (1 parent + 6 subfolders)');
        Assert.areEqual(20, DealFolderService.runFoldersCreated, '10 properties processed per job x 2 jobs');
        Assert.areEqual(120, DealFolderService.runSubfoldersCreated, '20 parents x 6 subfolders each');
        Assert.areEqual(231, DealFolderService.runDeferred,
            '(200 - 10) from chunk 1 job + (51 - 10) from chunk 2 job = 190 + 41');

        List<Property__c> after = propertiesFor(properties);
        Integer createdCount = 0;
        Integer pendingCount = 0;
        for (Property__c p : after) {
            if ('Created'.equals(p.SharePoint_Folder_Status__c)) {
                createdCount++;
                Assert.areEqual('created-item', p.SharePoint_Folder_ID__c, '');
            } else if ('Pending'.equals(p.SharePoint_Folder_Status__c)) {
                pendingCount++;
            }
        }
        Assert.areEqual(20, createdCount,
            'Exactly 20 properties (10 per job) were actually processed within the callout budget');
        Assert.areEqual(231, pendingCount,
            'The rest stay Pending — untouched, deferred, and picked up by the next sweep pass');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE SYNCHRONOUS PATH NEVER THROWS — worst-case inputs, one at a time
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** A deal with no Property__c is SKIPPED, not thrown on — the deal must still close. */
    @isTest
    static void nullProperty_isSkippedNotThrown_dealStillCloses_andIsCounted() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(3, true);
        TestDataFactory.signPrimaryNda(opps);
        TestDataFactory.signContract(opps);
        // The third Closed Won gate (2026-09-02). These deals are built inline rather than
        // through dealsReadyToClose, so they need the preparation of their own.
        TestDataFactory.markTransactionClosed(opps);
        for (Opportunity o : opps) {
            Assert.isNull(o.Property__c, 'Precondition: a manually built deal has no Property');
        }

        DealFolderService.resetRunCounters();
        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        for (Opportunity o : [SELECT StageName FROM Opportunity WHERE Id IN :opps]) {
            Assert.areEqual(CLOSED_WON, o.StageName, 'A missing Property must never block a close');
        }
        Assert.areEqual(3, DealFolderService.runSkippedNoProperty, 'The skip is counted, per deal');
        Assert.areEqual(0, DealFolderService.runQueryCount,
            'With nothing to claim the guard returns before any read');
        Assert.areEqual(0, DealFolderService.runDmlCount, 'and writes nothing');
        Assert.areEqual(0, DealFolderService.runEnqueueCount, 'and enqueues nothing');
    }

    /** A property whose Name sanitizes to nothing usable must not block the close either. */
    @isTest
    static void unnamableProperty_neverThrows_dealClosesAndIsStampedSkipped() {
        enableSharePoint(SITE_ID);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);
        update new Property__c(Id = properties[0].Id, Name = '***///:::');

        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('unused', null)));
        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON, [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName,
            'An unnamable property must never block a close');
        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Skipped', p.SharePoint_Folder_Status__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('nothing SharePoint accepts'),
            'Actual: ' + p.SharePoint_Folder_Error__c);
    }

    /** The integration switched OFF must not block a close. */
    @isTest
    static void configDisabled_neverThrows_dealClosesAndIsStampedSkipped() {
        insert new SharePoint_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Is_Enabled__c = false, Site_ID__c = SITE_ID);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON, [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName, '');
        Assert.areEqual('Skipped', propertiesFor(properties)[0].SharePoint_Folder_Status__c, '');
    }

    /** 🔴 No org-default row AT ALL — the baseline state of a fresh org/scratch org. Must not
     *  block a close, and must not fall back to any hardcoded site id (design D7). */
    @isTest
    static void configAbsentEntirely_neverThrows_dealClosesAndIsStampedSkipped_noHardcodedFallback() {
        // Deliberately NO SharePoint_Config__c row inserted anywhere in this test.
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-never-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON, [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName, '');
        Assert.areEqual('Skipped', propertiesFor(properties)[0].SharePoint_Folder_Status__c, '');
        Assert.areEqual(0, mock.requestCount,
            'PROOF THERE IS NO HARDCODED SITE-ID FALLBACK: with no configuration at all, ZERO '
            + 'callouts must be made — a fallback here is how production folders end up in a POC library');
    }

    /** A Graph callout that returns 500 must not block a close. */
    @isTest
    static void calloutThat500s_neverThrows_dealClosesAndIsStampedFailed() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(500, SharePointCalloutMock.errorBody('Internal server error')));
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON, [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName, '');
        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('HTTP 500'), 'Actual: ' + p.SharePoint_Folder_Error__c);
    }

    /** A transport-level exception (the credential-grant shape) must not block a close. */
    @isTest
    static void transportExceptionOnCallout_neverThrows_dealCloses() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class, new ThrowingCalloutMock());
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON, [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName, '');
        Assert.areEqual('Failed', propertiesFor(properties)[0].SharePoint_Folder_Status__c, '');
    }

    /**
     * 🔴 THE BELT-AND-SUSPENDERS TEST: several worst-case properties, closing in ONE bulk update,
     * with a mock that succeeds for some names and fails for others. None of them may take any of
     * the others — or the transaction — down.
     */
    @isTest
    static void mixedWorstCaseInputsInOneBulkClose_noneThrowAndEveryDealCloses() {
        enableSharePoint(SITE_ID);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(4, properties);
        // [0] a normal name (succeeds), [1] unnamable, [2] a 500 failure, [3] normal (succeeds)
        update new Property__c(Id = properties[1].Id, Name = '///***');
        Opportunity noPropertyDeal = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.signPrimaryNda(new List<Opportunity>{ noPropertyDeal });
        TestDataFactory.signContract(new List<Opportunity>{ noPropertyDeal });
        // The third Closed Won gate (2026-09-02) — the fifth deal is built inline, so it needs
        // the preparation dealsReadyToClose gave the other four.
        TestDataFactory.markTransactionClosed(new List<Opportunity>{ noPropertyDeal });
        opps.add(noPropertyDeal);

        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('mixed-ok', null));
        mock.withOverride(properties[2].Name, 500, SharePointCalloutMock.errorBody('boom'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        close(opps); // 5 deals, one bulk DML — must NOT throw
        Test.stopTest();

        for (Opportunity o : [SELECT StageName FROM Opportunity WHERE Id IN :opps]) {
            Assert.areEqual(CLOSED_WON, o.StageName,
                'Every deal must close regardless of what happened to its SharePoint folder');
        }
        Map<Id, Property__c> byId = new Map<Id, Property__c>(propertiesFor(properties));
        Assert.areEqual('Created', byId.get(properties[0].Id).SharePoint_Folder_Status__c, '');
        Assert.areEqual('Skipped', byId.get(properties[1].Id).SharePoint_Folder_Status__c, '');
        Assert.areEqual('Failed', byId.get(properties[2].Id).SharePoint_Folder_Status__c, '');
        Assert.areEqual('Created', byId.get(properties[3].Id).SharePoint_Folder_Status__c, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // STAGE-ENTRY DETECTION
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 DIAGNOSED 2026-08-11 — this test used to read the class-static run counters AFTER
     * `Test.stopTest()` and expected `runInvocations == 1`. That is wrong for a reason that has
     * nothing to do with the re-save being tested: `close(opps)` above ALREADY enqueues a
     * `DealFolderQueueable` for this property (the ordinary, correct synchronous behaviour of a
     * deal ENTERING Closed Won). `Test.startTest()`/`Test.stopTest()` may be called only once per
     * test method (measured elsewhere in this suite), so that pending job cannot be drained before
     * the re-save is measured — it drains at the SAME `Test.stopTest()` call this test already
     * uses, and its execution legitimately increments the very counters `resetRunCounters()` had
     * just zeroed. `runInvocations` therefore reads 2 by design: one synchronous call for the
     * re-save (which the GUARD declines — zero query/DML/enqueue) and one ASYNC call for the
     * original close's job settling — a real invocation, just not one caused by this test's re-save.
     * Reading the statics after `stopTest()` conflates the two. This is the identical trap
     * `EmailThreadAdopterServiceTest`'s header documents for its own trigger-fired queueable:
     * counter assertions must snapshot into locals INSIDE the test, before any unrelated async
     * settle can contaminate them.
     *
     * The fix below does two things, neither of which is "expect 2 instead of 1":
     *   1. Snapshots the re-save's OWN contribution into locals immediately after `update opps;`,
     *      before `Test.stopTest()` lets the unrelated original-close job run — isolating exactly
     *      what the re-save cost, which is what this test is actually meant to prove.
     *   2. Asserts the property that matters per the class's own "duplicate-folder falsifier"
     *      contract: after the original job finally settles, the property carries exactly ONE
     *      folder (`CALLOUTS_PER_PROPERTY` total callouts, `Created` status) — never a second,
     *      renamed folder from a phantom re-claim.
     */
    @isTest
    static void reSavingAnAlreadyClosedDeal_costsNothing() {
        enableSharePoint(SITE_ID);
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('resave-item', null));
        Test.setMock(HttpCalloutMock.class, mock);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);
        close(opps); // ENTERS Closed Won — legitimately stamps Pending and enqueues ONE job

        DealFolderService.resetRunCounters();
        Test.startTest();
        opps[0].Description = 'unrelated later edit';
        update opps; // still Closed Won — did NOT just enter it

        // Snapshot NOW, before Test.stopTest() drains the ORIGINAL close()'s pending queueable —
        // see the class-header diagnosis above for why reading the statics after stopTest() would
        // silently count that unrelated settle as though this re-save caused it.
        Integer invocationsFromResave = DealFolderService.runInvocations;
        Integer queriesFromResave = DealFolderService.runQueryCount;
        Integer dmlFromResave = DealFolderService.runDmlCount;
        Integer enqueuesFromResave = DealFolderService.runEnqueueCount;
        Integer calloutsFromResave = DealFolderService.runCalloutCount;
        Test.stopTest(); // drains the ORIGINAL close()'s job — unrelated to the assertions below

        Assert.areEqual(1, invocationsFromResave,
            'the re-save itself invoked the sync entry point exactly once — it is the GUARD that declines');
        Assert.areEqual(0, queriesFromResave, 'a save that enters no stage costs ZERO queries');
        Assert.areEqual(0, dmlFromResave, 'and zero DML');
        Assert.areEqual(0, enqueuesFromResave,
            'and zero enqueues — the re-save must never queue a second job for a property already claimed');
        Assert.areEqual(0, calloutsFromResave,
            'and zero callouts from the re-save itself — it never reaches the async layer at all');

        // The property that matters: exactly ONE folder exists, from the original close's settle —
        // the re-save must never mint a second, renamed duplicate under conflictBehavior: rename.
        Property__c p = [
            SELECT SharePoint_Folder_Status__c, SharePoint_Folder_ID__c
            FROM Property__c WHERE Id = :properties[0].Id
        ];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'the ORIGINAL close\'s async job — not the re-save — created the one and only folder');
        Assert.areEqual(DealFolderService.CALLOUTS_PER_PROPERTY, mock.requestCount,
            'exactly one folder tree was ever built for this property — a re-save that queued a '
            + 'second job would double this count');
    }

    /**
     * ⚠ REWRITTEN 2026-08-27, AND THE OLD VERSION WOULD NOW BE ACTIVELY WRONG. It moved a deal to
     * 'Under Review' and asserted that cost NOTHING. 'Under Review' is now the ORDINARY claim
     * stage, so that assertion would fail — and had it merely been deleted, the suite would have
     * lost its only proof that a stage move OUTSIDE the set is free. It moves to 'Dead/Pass'
     * instead: a real stage, reachable from 'New' in one save with no gates, and deliberately not a
     * claim stage.
     */
    @isTest
    static void aStageMoveThatIsNotAClaimStage_costsNothing() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsAtNew(1, properties);

        DealFolderService.resetRunCounters();
        Test.startTest();
        moveTo(opps, DEAD_PASS);
        Test.stopTest();

        Assert.areEqual(1, DealFolderService.runInvocations,
            'The trigger still routed the save here — it is the SET MEMBERSHIP TEST that declines');
        Assert.areEqual(0, DealFolderService.runQueryCount,
            'Dead/Pass is not in CLAIM_STAGES, so no idempotency read is worth paying for');
        Assert.areEqual(0, DealFolderService.runDmlCount, '');
        Assert.areEqual(0, DealFolderService.runEnqueueCount, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE FOUR-STAGE SET ITSELF — the two tests that falsify a one-stage prior check
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PRIOR-STAGE SET-MEMBERSHIP FALSIFIER. `enteringPropertyIds` tests BOTH halves against
     * `CLAIM_STAGES`:
     *
     *     CLAIM_STAGES.contains(o.StageName)
     *       && (prior == null || !CLAIM_STAGES.contains(prior.StageName))
     *
     * If the PRIOR half were ever written against a single stage — the obvious-looking
     * `!CLOSED_WON.equals(prior.StageName)`, or `'Under Review'.equals(...)` — then an ordinary
     * 'Under Review' -> 'Underwriting' move would register as a FRESH ENTRY and spend one SOQL on
     * EVERY deal in the org, forever, for nothing. Nothing else in this suite sees that: the folder
     * would still be correct, the callout count would still be zero (the id guard catches it one
     * layer later), and only the query counter moves. That is why this test asserts the QUERY
     * COUNT rather than an outcome.
     *
     * ⚠ SharePoint is deliberately left UNCONFIGURED. That makes the first entry stamp `Skipped`
     * and enqueue NOTHING, so there is no pending Queueable to settle at `Test.stopTest()` and
     * contaminate the counters — the trap `reSavingAnAlreadyClosedDeal_costsNothing` had to work
     * around with local snapshots. The set-membership question is unaffected by config: a fresh
     * entry costs its SOQL whether the integration is on or off.
     */
    @isTest
    static void moveBetweenTwoClaimStages_isNotAFreshEntry_costsZeroSoql() {
        // Deliberately NO SharePoint_Config__c row — see the header note above.
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsAtNew(1, properties);
        TestDataFactory.signPrimaryNda(opps); // 'Underwriting' is behind the NDA gate

        moveTo(opps, UNDER_REVIEW); // the REAL claim-stage entry — outside the measurement
        Assert.areEqual('Skipped',
            propertiesFor(properties)[0].SharePoint_Folder_Status__c,
            'Precondition: the first entry really did reach the service (config off -> Skipped). '
            + 'If this is null the deal never entered a claim stage and the test below is vacuous.');

        DealFolderService.resetRunCounters();
        Test.startTest();
        moveTo(opps, UNDERWRITING); // member -> member: NOT an entry
        Test.stopTest();

        // 🔴 TWO, NOT ONE — MEASURED 2026-08-27, AND THE REASON MAKES THIS TEST STRONGER.
        // One update statement routes here TWICE: entering 'Underwriting' makes
        // OpportunityReviewService insert an Underwriting__c and then `update uwStamps` to stamp
        // Primary_Underwriting__c back onto the Opportunity, which RE-FIRES the after-update
        // trigger in the same transaction. On that second routing the prior stage and the new
        // stage are BOTH 'Underwriting' — a member -> member pair, so it must be a no-op too.
        // That is a second, free falsifier for the same bug: a prior test written against a single
        // stage would treat the stamp-back re-fire as a fresh entry as well.
        Assert.areEqual(2, DealFolderService.runInvocations,
            'The trigger routed this ONE update statement here twice — the save itself, plus '
            + 'OpportunityReviewService stamping Primary_Underwriting__c back onto the deal');
        Assert.areEqual(0, DealFolderService.runQueryCount,
            'THE FALSIFIER: Under Review -> Underwriting is a move BETWEEN two members of '
            + 'CLAIM_STAGES and must register NO fresh entry. A non-zero count here means the '
            + 'PRIOR-stage half of the entry test stopped using the set, and every deal in the org '
            + 'is now paying a needless SOQL on an ordinary forward move.');
        Assert.areEqual(0, DealFolderService.runDmlCount, 'and no stamp');
        Assert.areEqual(0, DealFolderService.runEnqueueCount, 'and no job');
    }

    /**
     * 🔴 THE FOUR-STAGE DUPLICATE-FOLDER FALSIFIER — the most important test in this class.
     *
     * One deal is walked through ALL FOUR claim stages in four separate saves:
     *   'New' -> 'Under Review' -> 'Underwriting' -> 'About to Close' -> 'Closed Won'
     * and must claim EXACTLY ONCE. Entries 2, 3 and 4 must cost ZERO extra enqueues, ZERO extra
     * idempotency reads and ZERO extra callouts.
     *
     * ═══ WHY THIS IS THE TEST THAT PROTECTS THE DESIGN DECISION ═══
     * `CLAIM_STAGES` has four members precisely so that three skip routes (the
     * `Opportunity_Initiate_Underwriting` before-save jump, `advanceTo`'s unvalidated target, and
     * the `Transaction_Complete_Close` flow) cannot leave a deal without a folder — WITHOUT paying
     * for four folders on every ordinary deal. That trade is only safe because entries 2-4 are
     * free. If they were not, widening the set would have quadrupled Graph traffic and, under
     * `conflictBehavior: rename`, produced 'Magnolia Crossing 1', ' 2' and ' 3' beside the real
     * folder — the outcome this whole feature treats as the worst available.
     *
     * ⚠ THE SYNC COUNTERS ARE SNAPSHOTTED BEFORE `Test.stopTest()`, on purpose: stopTest drains the
     * one enqueued Queueable, whose own invocation legitimately increments the same statics. Same
     * trap, and same fix, as `reSavingAnAlreadyClosedDeal_costsNothing`.
     */
    @isTest
    static void walkedThroughAllFourClaimStages_claimsExactlyOnce_zeroExtraCalloutsAndEnqueues() {
        enableSharePoint(SITE_ID);
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('walk-item', 'https://contoso.sharepoint.com/x/walk'));
        Test.setMock(HttpCalloutMock.class, mock);

        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsAtNew(1, properties);
        TestDataFactory.signPrimaryNda(opps); // gates Underwriting, About to Close AND Closed Won
        TestDataFactory.signContract(opps);   // gates Closed Won

        DealFolderService.resetRunCounters();
        Test.startTest();
        moveTo(opps, UNDER_REVIEW);    // entry 1 — the ONLY one that may do work
        moveTo(opps, UNDERWRITING);    // entry 2 — member -> member, not an entry
        moveTo(opps, ABOUT_TO_CLOSE);  // entry 3 — member -> member, not an entry

        // 🔴 THIS CALL MUST SIT **HERE**, BETWEEN THE THIRD AND FOURTH HOPS, AND MOVING IT ABOVE
        // `Test.startTest()` SILENTLY BREAKS THE TEST. MEASURED: deploy 0Afiw000000VWV3CAO,
        // 2026-09-02, where it sat with the other two fixture calls above and this method was the
        // ONE failure in the whole class — `FIELD_CUSTOM_VALIDATION_EXCEPTION … until its
        // transaction is closed` at the CLOSED_WON hop, from a fixture that had already prepared
        // the gate.
        //
        // Why: this walk is the only method in this class that passes THROUGH 'About to Close',
        // and entering that stage runs `ContractExecutionService.openTransactionsOnAboutToClose`,
        // which AUTO-CREATES a real `Transaction__c` at `Status__c = 'Active'`. Its trigger runs
        // `DealTransactionGateService.recalculate`, which recomputes both flags FROM THE DATABASE
        // and overwrites whatever the fixture wrote — exactly the "NOT idempotent against later
        // Transaction DML" failure mode `TestDataFactory.markTransactionClosed`'s own header warns
        // about. A pre-walk call is therefore dead by the time hop 4 needs it.
        //
        // ⚠ AND IT STILL MUST NOT CREATE OR CLOSE A REAL `Transaction__c`. Closing the auto-created
        // one would fire `flows/Transaction_Complete_Close`, which would close the deal from INSIDE
        // the fixture and make hop 4 a no-op re-save — destroying the four-entry walk this method
        // exists to measure. Writing the two parent flags is the whole point of that helper; read
        // its declaration before changing this.
        TestDataFactory.markTransactionClosed(opps);

        moveTo(opps, CLOSED_WON);      // entry 4 — member -> member, not an entry

        // Snapshot the SYNCHRONOUS contribution before stopTest() drains the one enqueued job.
        Integer syncEnqueues = DealFolderService.runEnqueueCount;
        Integer syncQueries = DealFolderService.runQueryCount;
        Integer syncDml = DealFolderService.runDmlCount;
        Integer syncInvocations = DealFolderService.runInvocations;
        Test.stopTest();

        // 🔴 SEVEN, NOT FOUR — AND IT WAS FIVE UNTIL 2026-09-02. MEASURED, validate
        // `0Afiw000000VWlBCAW`: `Expected: 5, Actual: 7`. Four stage saves plus THREE re-entrant
        // Opportunity updates, every one of them a real save this service is legitimately asked
        // about:
        //   1. entering 'Underwriting' makes OpportunityReviewService insert an Underwriting__c
        //      and then `update` the deal to stamp Primary_Underwriting__c   (the original +1)
        //   2. entering 'About to Close' auto-creates a Transaction__c, whose trigger runs
        //      DealTransactionGateService.recalculate — which writes Has_Open_Transaction__c on
        //      the deal, re-firing the after-update trigger              (+1, new on 2026-09-02)
        //   3. the markTransactionClosed call above is itself an Opportunity update
        //                                                               (+1, new on 2026-09-02)
        // The stage is UNCHANGED on all three, so none of them is a fresh claim-stage entry and
        // none may cost an enqueue, a query or a stamp — which is exactly what the four
        // assertions below pin. The service being ASKED seven times and still claiming ONCE is a
        // strictly stronger result than the four-save story alone.
        //
        // ⚠ If this number moves again, some OTHER automation started re-saving the deal. Read
        // the assertions below before adjusting it — the claim count is what this test protects,
        // and this number is only the context in which that count has to hold.
        Assert.areEqual(7, syncInvocations,
            'Four stage saves plus THREE re-entrant Opportunity updates (Primary_Underwriting__c '
            + 'stamp-back, the transaction-gate flag recompute from the auto-created Transaction, '
            + 'and markTransactionClosed itself). If this number changes, some OTHER automation '
            + 'started re-saving the deal — re-read the assertions below before adjusting it, '
            + 'because the claim count is what this test actually protects.');
        Assert.areEqual(1, syncEnqueues,
            'THE FALSIFIER: exactly ONE folder job for four claim-stage saves. Four enqueues here '
            + 'would mean the prior-stage test stopped using CLAIM_STAGES, and every deal in the '
            + 'org would build (and, under conflictBehavior: rename, KEEP) four folder trees.');
        Assert.areEqual(1, syncQueries,
            'and exactly ONE idempotency read — only the first save registered an entry');
        Assert.areEqual(1, syncDml, 'and exactly ONE Pending stamp');

        Assert.areEqual(DealFolderService.CALLOUTS_PER_PROPERTY, mock.requestCount,
            'EXACTLY ONE folder tree (1 parent + 6 subfolders) was ever built for this property, '
            + 'across all four claim stages');
        Assert.areEqual(1, DealFolderService.runFoldersCreated, '');
        Assert.areEqual(6, DealFolderService.runSubfoldersCreated, '');

        Opportunity after = [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id];
        Assert.areEqual(CLOSED_WON, after.StageName,
            'and the deal really did walk the whole pipeline — if it stopped early, the stages '
            + 'above were never actually entered and every assertion here is vacuous');
        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c, '');
        Assert.areEqual('walk-item', p.SharePoint_Folder_ID__c, 'ONE folder id, never a second');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 OQ-2 — WHERE Database.convertLead LANDS. A NAMED MEASUREMENT, NOT AN INFERENCE.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE DESIGN ESTABLISHED THIS BY INFERENCE AND EXPLICITLY REFUSED TO SHIP ON IT.
     * `Opportunity.StageName` has no default on either active record type (the ui-api
     * picklist-values payload returns an empty `defaultValue` for both Land and Retail) and 'New'
     * is first in every business process — from which the design INFERRED that
     * `Database.convertLead` lands a converted deal on 'New'. Picklist ORDER is not a measurement,
     * so this test performs a real conversion and asserts the landing stage.
     *
     * ═══ 🔴 WHY THE ANSWER DECIDES SOMETHING, RATHER THAN BEING TRIVIA ═══
     * 'New' is NOT in `CLAIM_STAGES`, so a converted deal claims nothing during conversion and
     * claims later, on its first Begin Review click — a single-record UI save by a deal driver who
     * holds `SharePoint_Integration_Access`.
     * **If conversion landed on 'Under Review' instead, every converted deal would claim its folder
     * INSIDE the `Database.convertLead` transaction** — i.e. inside the already governor-tight
     * Broker Protection pipeline, as the PIPELINE principal rather than a deal driver. That is a
     * different governor picture (convertLead already caps at 200 per call and the pipeline runs
     * inside a Queueable) and a different CREDENTIAL picture, and the Item 1 design covers neither.
     * 🔴 IF THIS TEST EVER GOES RED WITH 'Under Review', DO NOT PATCH IT BY UPDATING THE EXPECTED
     * VALUE. Stop and re-open the design.
     */
    @isTest
    static void oq2_convertedLeadLandsOnNew_soNoFolderIsClaimedInsideConvertLead() {
        enableSharePoint(SITE_ID);
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-never-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);

        Lead l = TestDataFactory.createLead(false);
        l.LastName = 'Tester';
        l.Company = 'Convert Landing LLC';
        l.Deal_Type__c = 'Retail';
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        DealFolderService.resetRunCounters();
        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();

        Assert.isTrue(res.isSuccess(), 'Precondition: the conversion itself must succeed');
        Opportunity converted = [
            SELECT Id, StageName, Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual('New', converted.StageName,
            'OQ-2, MEASURED: Database.convertLead must land the Opportunity on New. If this reads '
            + '"Under Review" the deal now claims its SharePoint folder INSIDE the convertLead '
            + 'transaction, as the Broker Protection pipeline principal — a governor and '
            + 'credential picture the Item 1 design does not cover. STOP and re-open the design; '
            + 'do not update this expected value.');

        Assert.areEqual(0, DealFolderService.runQueryCount,
            'and therefore NO claim happened during conversion — not one idempotency read');
        Assert.areEqual(0, DealFolderService.runEnqueueCount, 'and no folder job was enqueued');
        Assert.areEqual(0, mock.requestCount, 'and SharePoint was never contacted');

        Assert.isNotNull(converted.Property__c,
            'Precondition for the assertion below: LeadConvertService really did create a Property');
        Property__c p = [
            SELECT SharePoint_Folder_Status__c, SharePoint_Folder_ID__c
            FROM Property__c WHERE Id = :converted.Property__c
        ];
        Assert.isNull(p.SharePoint_Folder_Status__c,
            'A NULL status is the correct resting state for a just-converted deal — and note it is '
            + 'INVISIBLE to PropertySelector.queryFolderSweep, so the folder is owed to the first '
            + 'Begin Review click and to nothing else.');
        Assert.isNull(p.SharePoint_Folder_ID__c, '');
    }

    /** A record INSERTED directly at Closed Won (data load / migration) counts as ENTERING. */
    @isTest
    static void dealInsertedDirectlyAtClosedWon_alsoClaimsAFolder() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('insert-path-item', null)));
        Property__c property = TestDataFactory.createProperty(true);
        Opportunity opp = TestDataFactory.createOpportunity(null, false);
        opp.Property__c = property.Id;
        opp.StageName = CLOSED_WON;

        Test.startTest();
        insert opp;
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_Status__c FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'Inserting AT Closed Won IS entering it — a data load must not skip the folder claim');
    }

    /** TWO deals closing against ONE property in the SAME chunk must claim (and enqueue for) that
     *  property only ONCE — the de-duplication is structural (Set<Id>), not incidental. */
    @isTest
    static void twoDealsOnOnePropertyInOneChunk_claimTheFolderOnlyOnce() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('shared-item', null)));
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(2, properties);
        opps[1].Property__c = properties[0].Id;
        update opps;

        DealFolderService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        Assert.areEqual(1, DealFolderService.runEnqueueCount,
            'One chunk, one property owed (deduped) -> exactly one enqueue');
        Assert.areEqual(7, DealFolderService.runCalloutCount,
            'Exactly one folder tree (1 parent + 6 subfolders) for the one distinct property');
        Property__c shared = [SELECT SharePoint_Folder_Status__c FROM Property__c WHERE Id = :properties[0].Id];
        Assert.areEqual('Created', shared.SharePoint_Folder_Status__c, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 W-B — THE ENQUEUE GUARD ITSELF, PINNED (code re-review finding)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `claimFolders`'s own 17-line comment calls `Limits.getQueueableJobs() <
     * Limits.getLimitQueueableJobs()` "the ONLY thing standing between this feature and a
     * rolled-back deal close" and explicitly forbids tightening it into an unconditional enqueue —
     * yet before this test, DELETING that `if` wrapper made no test go red. This is the falsifier.
     *
     * Every queueable slot is filled BEFORE the close, so `claimFolders`'s own enqueue attempt
     * finds zero headroom left — deliberately, via `System.enqueueJob(new NoOpQueueable())`, never
     * the real `DealFolderQueueable` (which would itself attempt real work at `Test.stopTest()` and
     * confuse what this test is isolating).
     *
     * ═══ WHY THIS GENUINELY FALSIFIES REMOVING THE `if` ═══
     * `System.enqueueJob` at the 50-job cap raises `System.LimitException`, and SP-R1 (cited in
     * this class's own header, and reproduced by `EmailMessageTriggerHandlerTest`'s identical
     * guard) measured that an Apex limit exception of that family is NOT intercepted by
     * `catch (Exception)` — which is exactly the shape wrapping this call one level up in
     * `ensureOnClaimStageEntry`. So an unconditional enqueue here would throw straight through that catch
     * and take the whole `update opps` below down with it. Concretely: if a future change deletes
     * the `if` guard, `close(opps)` on the line below THROWS instead of returning, this test method
     * itself goes red (an uncaught exception fails the test), and none of the assertions after it
     * even run. That is a stronger falsifier than an assertion could be on its own — the guard's
     * absence breaks the test's own control flow, not just a checked value.
     *
     * Both halves of "skipping is safe" are asserted, because either alone would be insufficient:
     * the enqueue must actually have been suppressed (`runEnqueueCount == 0`), AND the
     * skipped property must be recoverable rather than silently lost (`SharePoint_Folder_Status__c`
     * still reads the sweeper's OWN work-queue value, `'Pending'` — see
     * `PropertySelector.queryFolderSweep`'s locator). The Opportunity reaching `Closed Won` proves
     * the transaction did not roll back — the never-throw rule this whole class exists to uphold.
     *
     * ⚠ `@SuppressWarnings` mirrors `EmailMessageTriggerHandlerTest`'s precedent — deliberately
     * consuming the queueable limit in a loop is the only way to reach the guard's skip branch.
     */
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    @isTest
    static void queueableSlotsExhausted_enqueueGuardSkipsInsteadOfThrowing_dealStillClosesAndStaysPending() {
        enableSharePoint(SITE_ID);
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        DealFolderService.resetRunCounters();
        Test.startTest();
        Integer cap = Limits.getLimitQueueableJobs();
        while (Limits.getQueueableJobs() < cap) {
            System.enqueueJob(new NoOpQueueable());
        }
        Assert.areEqual(cap, Limits.getQueueableJobs(),
            'Precondition: every queueable slot must be consumed, or this test proves nothing');

        // Reaching this line at all, and returning from it, is half the proof — see the header.
        // An unguarded enqueue inside claimFolders() would throw System.LimitException here and
        // roll back this Closed Won update along with it.
        close(opps);
        Test.stopTest();

        Assert.areEqual(0, DealFolderService.runEnqueueCount,
            'THE GUARD MUST HAVE SUPPRESSED THE ENQUEUE — every slot was already consumed before '
            + 'claimFolders() ran, so System.enqueueJob must never have been called');
        Assert.areEqual(CLOSED_WON,
            [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName,
            'The deal close itself must survive a fully-exhausted queueable budget — nothing rolled back');
        Assert.areEqual('Pending', propertiesFor(properties)[0].SharePoint_Folder_Status__c,
            'Skipping the enqueue is SAFE, not merely non-fatal, ONLY because Pending is '
            + 'DealFolderSweepBatch\'s own work queue (PropertySelector.queryFolderSweep\'s locator '
            + 'is SharePoint_Folder_Status__c IN (\'Pending\',\'Failed\')) — the row stays '
            + 'recoverable by the scheduled sweep rather than silently and permanently lost.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // CONFIG SAFETY — the async layer's OWN re-check (config can change between claim and job)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Exercises `skipAllAsDisabled` directly — the async-side branch that fires if the setting
     *  is switched off between the sync claim and the job actually running. */
    @isTest
    static void createFolders_calledWithConfigDisabled_stampsSkippedAndMakesZeroCallouts() {
        // Deliberately NO SharePoint_Config__c row — mirrors "disabled or unconfigured" uniformly.
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('should-not-be-used', null));
        Test.setMock(HttpCalloutMock.class, mock);
        Property__c property = TestDataFactory.createProperty(true);

        DealFolderService.resetRunCounters();
        Test.startTest();
        List<Id> deferred = DealFolderService.createFolders(new List<Id>{ property.Id });
        Test.stopTest();

        Assert.isTrue(deferred.isEmpty(), 'Nothing is deferred — it is SKIPPED outright, never retried blindly');
        Assert.areEqual('Skipped', [SELECT SharePoint_Folder_Status__c FROM Property__c WHERE Id = :property.Id]
            .SharePoint_Folder_Status__c, '');
        Assert.areEqual(0, mock.requestCount, 'Never guess a site id — zero callouts');
        Assert.areEqual(1, DealFolderService.runSkippedDisabled, '');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE CALLOUT-COUNT BUDGET GUARD — direct call, deterministic
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `hasBudgetForOneProperty`'s COUNT check, isolated: manually burn callout headroom down to
     * fewer than `CALLOUTS_PER_PROPERTY` (7) remaining, in the SAME governor transaction as the
     * `createFolders` call under test, then prove the property is DEFERRED rather than attempted —
     * the guard that converts what would otherwise be an uncatchable `LimitException` into one
     * more chained link.
     */
    @isTest
    static void createFolders_calloutBudgetNearlyExhausted_defersRatherThanRisking() {
        enableSharePoint(SITE_ID);
        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('burn-id', 'https://contoso.sharepoint.com/x/burn'));
        Test.setMock(HttpCalloutMock.class, mock);
        Property__c property = TestDataFactory.createProperty(true);
        // This test calls DealFolderService.createFolders(...) DIRECTLY, bypassing claimFolders() —
        // the ONLY code that stamps Pending on the sync path. TestDataFactory leaves the status
        // NULL, so without this stamp the property would already be non-Pending going in and the
        // "left EXACTLY as it was — still Pending" assertion below would prove nothing. Seed the
        // fixture to the state claimFolders() would have already put it in by the time an async job
        // ever sees it.
        update new Property__c(Id = property.Id, SharePoint_Folder_Status__c = 'Pending');

        DealFolderService.resetRunCounters();
        Test.startTest();
        SharePointCalloutService burner = new SharePointCalloutService();
        for (Integer i = 0; i < 95; i++) {
            burner.createFolder(SITE_ID, null, null, 'Burn ' + i);
        }
        // Fewer than 5 of the 100-per-transaction callout budget remain — less than the 7 one
        // property's folder tree needs.
        List<Id> deferred = DealFolderService.createFolders(new List<Id>{ property.Id });
        Test.stopTest();

        Assert.areEqual(1, deferred.size(),
            'With fewer than 7 callouts of headroom left, the property must be DEFERRED');
        Assert.areEqual(property.Id, deferred[0], '');
        Assert.areEqual(0, DealFolderService.runFoldersCreated, 'Nothing was attempted for this property');
        Assert.areEqual(1, DealFolderService.runDeferred, '');
        Assert.areEqual('Pending',
            [SELECT SharePoint_Folder_Status__c FROM Property__c WHERE Id = :property.Id].SharePoint_Folder_Status__c,
            'A deferred property is left EXACTLY as it was — still Pending for the next link/sweep. '
            + 'NOTE: a NULL-status property is invisible to PropertySelector.queryFolderSweep '
            + '(locator is SharePoint_Folder_Status__c IN (\'Pending\',\'Failed\')), so "deferred rows '
            + 'are recoverable" holds only because the synchronous claimFolders() path stamps Pending '
            + 'BEFORE any async job runs — this fixture reproduces that coupling deliberately.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // RESIDUAL R2 — PARTIAL SUBFOLDER FAILURE IS TERMINAL "Created", NOT "Failed"
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 PINNED SO A FUTURE "FIX" HAS TO JUSTIFY ITSELF. The parent folder succeeds; one of the
     * six lifecycle subfolders is refused. The property must stamp "Created", NOT "Failed" — the
     * parent id IS the idempotency guard, so re-running the six subfolder calls under
     * `conflictBehavior: rename` would produce a duplicate like "01 - NDA 1" rather than repairing
     * anything (design residual R2).
     */
    @isTest
    static void createFolders_oneSubfolderRefused_parentStampedCreatedNotFailed() {
        enableSharePoint(SITE_ID);
        Property__c property = TestDataFactory.createProperty(true); // Name = 'Test Property 0'

        SharePointCalloutMock mock = new SharePointCalloutMock(201,
            SharePointCalloutMock.successBody('parent-item-1', 'https://contoso.sharepoint.com/x/parent'));
        mock.withOverride('04 - PSA', 500, SharePointCalloutMock.errorBody('blocked by a retention policy'));
        Test.setMock(HttpCalloutMock.class, mock);

        DealFolderService.resetRunCounters();
        Test.startTest();
        List<Id> deferred = DealFolderService.createFolders(new List<Id>{ property.Id });
        Test.stopTest();

        Assert.isTrue(deferred.isEmpty(), '');
        Property__c p = [
            SELECT SharePoint_Folder_ID__c, SharePoint_Folder_URL__c, SharePoint_Folder_Status__c,
                   SharePoint_Folder_Error__c
            FROM Property__c WHERE Id = :property.Id
        ];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'A refused SUBFOLDER after a successful PARENT must stamp Created, never Failed');
        Assert.areEqual('parent-item-1', p.SharePoint_Folder_ID__c, 'The parent folder id must still be stored');
        Assert.areEqual('https://contoso.sharepoint.com/x/parent', p.SharePoint_Folder_URL__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('04 - PSA'),
            'The missing subfolder must be NAMED so a human can create it by hand. Actual: '
            + p.SharePoint_Folder_Error__c);
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('by hand'), 'Actual: ' + p.SharePoint_Folder_Error__c);
        Assert.areEqual(1, DealFolderService.runFoldersCreated, '');
        Assert.areEqual(5, DealFolderService.runSubfoldersCreated, 'Five of the six subfolders succeeded');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // RESIDUAL R4 — A webUrl OVER 255 CHARS IS OMITTED, NOT TRUNCATED
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void createFolders_webUrlLongerThan255Chars_isOmittedNotStored_andNoted() {
        enableSharePoint(SITE_ID);
        Property__c property = TestDataFactory.createProperty(true);
        String longUrl = 'https://contoso.sharepoint.com/sites/x/' + 'y'.repeat(230); // > 255 chars
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(201, SharePointCalloutMock.successBody('item-long-url', longUrl)));

        Test.startTest();
        DealFolderService.createFolders(new List<Id>{ property.Id });
        Test.stopTest();

        Property__c p = [
            SELECT SharePoint_Folder_ID__c, SharePoint_Folder_URL__c, SharePoint_Folder_Status__c,
                   SharePoint_Folder_Error__c
            FROM Property__c WHERE Id = :property.Id
        ];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'The folder DID get created — an oversized URL must not fail the whole property');
        Assert.areEqual('item-long-url', p.SharePoint_Folder_ID__c, '');
        Assert.isNull(p.SharePoint_Folder_URL__c,
            'A URL over 255 chars must be OMITTED, not truncated — half a URL is worse than none');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('too long'), 'Actual: ' + p.SharePoint_Folder_Error__c);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // CREDENTIAL-DENIED PATH — first half (see DealFolderSweepBatchTest for the recovery half)
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `SharePoint_Integration_Access` is granted to `DPEG_Junior_Analyst_PSG` only, so any deal
     * closed via the Transactions persona's route runs this job as a user with no credential grant
     * and every callout is refused with 401/403. This must land VISIBLY on the property, with a
     * hint naming the exact known gap — never silently.
     */
    @isTest
    static void credentialDenied401_stampsFailedWithTheCredentialHint() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class, new SharePointCalloutMock(401,
            SharePointCalloutMock.errorBody('The user has no access to the requested resource')));
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps);
        Test.stopTest();

        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('HTTP 401'), 'Actual: ' + p.SharePoint_Folder_Error__c);
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('LIKELY CAUSE'),
            'The credential-gap hint must be present for a 401. Actual: ' + p.SharePoint_Folder_Error__c);
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('SharePoint_Integration_Access'),
            'The hint must name the EXACT permission set gap. Actual: ' + p.SharePoint_Folder_Error__c);
        Assert.isNull(p.SharePoint_Folder_ID__c, 'No folder was actually created');
    }

    @isTest
    static void credentialDenied403_alsoStampsFailedWithTheCredentialHint() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(403, SharePointCalloutMock.errorBody('Forbidden')));
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps);
        Test.stopTest();

        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('LIKELY CAUSE'), 'Actual: ' + p.SharePoint_Folder_Error__c);
    }

    /** A 500 (an ordinary Graph failure, NOT the credential shape) must NOT carry the credential
     *  hint — conflating the two would send an operator chasing the wrong fix. */
    @isTest
    static void ordinary500Failure_doesNotCarryTheCredentialHint() {
        enableSharePoint(SITE_ID);
        Test.setMock(HttpCalloutMock.class,
            new SharePointCalloutMock(500, SharePointCalloutMock.errorBody('transient Graph error')));
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, properties);

        Test.startTest();
        close(opps);
        Test.stopTest();

        Property__c p = propertiesFor(properties)[0];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c, '');
        Assert.isFalse(p.SharePoint_Folder_Error__c.contains('LIKELY CAUSE'),
            'A 500 is an ordinary Graph failure, not the credential shape — the hint must not appear. '
            + 'Actual: ' + p.SharePoint_Folder_Error__c);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // markFailed — the Finalizer's write path, isolated
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void markFailed_onAPendingRow_stampsFailedWithTheMessage() {
        Property__c property = TestDataFactory.createProperty(true);
        update new Property__c(Id = property.Id, SharePoint_Folder_Status__c = 'Pending');

        Test.startTest();
        DealFolderService.markFailed(new List<Id>{ property.Id }, 'the job died mid-flight');
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
                          FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Failed', p.SharePoint_Folder_Status__c, '');
        Assert.isTrue(p.SharePoint_Folder_Error__c.contains('the job died mid-flight'), '');
    }

    /** 🔴 THE RE-READ-BEFORE-WRITE GUARANTEE. An EARLIER chained link may already have committed a
     *  folder id for this property by the time a LATER link dies. `markFailed` must not drag an
     *  already-`Created` row back to `Failed`. */
    @isTest
    static void markFailed_onAnAlreadyCreatedRow_doesNotDowngradeIt() {
        Property__c property = TestDataFactory.createProperty(true);
        update new Property__c(
            Id = property.Id,
            SharePoint_Folder_ID__c = 'already-created-item',
            SharePoint_Folder_Status__c = 'Created'
        );

        Test.startTest();
        DealFolderService.markFailed(new List<Id>{ property.Id }, 'a later link in the same payload died');
        Test.stopTest();

        Property__c p = [SELECT SharePoint_Folder_ID__c, SharePoint_Folder_Status__c, SharePoint_Folder_Error__c
                          FROM Property__c WHERE Id = :property.Id];
        Assert.areEqual('Created', p.SharePoint_Folder_Status__c,
            'An already-Created row must NEVER be dragged back to Failed');
        Assert.areEqual('already-created-item', p.SharePoint_Folder_ID__c, '');
        Assert.isNull(p.SharePoint_Folder_Error__c, 'No failure note should be written over a real success');
    }

    @isTest
    static void markFailed_nullOrEmptyIds_isANoOp() {
        Test.startTest();
        DealFolderService.markFailed(null, 'unused');
        DealFolderService.markFailed(new List<Id>(), 'unused');
        Test.stopTest();

        Assert.isTrue(true, 'Must not throw for a null or empty payload');
    }
}
