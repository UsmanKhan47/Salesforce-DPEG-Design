/**
 * Tests OnboardingAutoCreateService + PropertyAssetTrigger + PropertyAssetTriggerHandler —
 * opening the PM onboarding record when a property acquisition closes.
 *
 * ═══ 🔴 THE MOST IMPORTANT TEST IN THIS CLASS IS THE NEGATIVE ONE ═══
 * `bulk251AssetsWithNoClosingDate_createsNothingAtZeroCost` is the regression guard for the
 * ENTIRE rest of the repo's test suite and for all nine seed scripts. This feature keys on
 * `Property_Asset__c.Closing_Date__c != null`, and `TestDataFactory.createPropertyAssets` — the
 * ancestor of every asset in the ~66 test classes that touch the object — leaves it blank. If
 * the discriminator ever widens to "any asset", every one of those classes starts minting
 * Onboardings and 45-item checklists, and this is the test that says so first.
 *
 * ═══ WHAT THESE TESTS CANNOT PROVE, STATED SO IT IS NOT ASSUMED ═══
 * The idempotency read is `WITH SYSTEM_MODE` inside a `private without sharing` inner class,
 * and the insert is `AccessLevel.SYSTEM_MODE`. Running as an administrator, "it worked" passes
 * whether or not any of those three decisions is present, so none is falsifiable from Apex.
 * They rest on measured repo state (`Onboarding__c.sharingModel = Private`; the single sharing
 * rule keys on `Status__c != ''`; the closing persona holds read-only PM access) recorded in
 * `OnboardingSelector.IdempotencyReads`, and are proved by a post-deploy gate run as a real
 * Transactions persona.
 *
 * ⚠ Tests drive the TRIGGER (ordinary DML on `Property_Asset__c`), not the service method
 * directly, wherever the behaviour under test is one a real save must exhibit. Calling the
 * service directly would prove the function while leaving the wiring — the thing that did not
 * exist before this change — untested.
 *
 * `.claude/rules/bulk-test-rule.md` applies at 251; no content object is involved.
 */
@isTest
private class OnboardingAutoCreateServiceTest {

    /** .claude/rules/bulk-test-rule.md — 251 forces a SECOND trigger chunk. */
    private static final Integer BULK_N = 251;

    /**
     * ⚠ `Tasks_Fanned_Out__c` IS DELIBERATELY NOT IN THIS FIELD LIST, even though one test below
     * asserts it. Every field named here becomes a dependency of EVERY test that calls this
     * helper: a field that has not landed in the target org yet turns an unrelated assertion
     * into `System.QueryException: No such column`, which reads as a schema error rather than as
     * the deploy-ordering problem it actually is. The one test that needs the flag queries it
     * inline instead.
     */
    private static List<Onboarding__c> onboardingsFor(Set<Id> assetIds) {
        return [
            SELECT Id, Property_Asset__c, Stage__c, Status__c, Start_Date__c,
                   Target_Completion_Date__c
            FROM Onboarding__c
            WHERE Property_Asset__c IN :assetIds
        ];
    }

    private static Set<Id> idsOf(List<Property_Asset__c> assets) {
        return new Map<Id, Property_Asset__c>(assets).keySet();
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE HAPPY PATH — read back, field by field
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * An asset INSERTED with a Closing Date opens exactly one Onboarding, with every value the
     * PM team depends on. Read back from the database: the insert is SYSTEM_MODE and the
     * service returns nothing, so the in-memory list is not evidence.
     */
    @isTest
    static void insertingAClosingAssetOpensTheOnboardingWithEveryIntendedValue() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, false);
        asset.Closing_Date__c = Date.today().addDays(-3);
        OnboardingAutoCreateService.resetRunCounters();

        Test.startTest();
        insert asset;
        Test.stopTest();

        List<Onboarding__c> created = onboardingsFor(new Set<Id>{ asset.Id });
        Assert.areEqual(1, created.size(), 'A closing asset opens exactly one Onboarding');
        Assert.areEqual(asset.Id, created[0].Property_Asset__c,
            'parented to the asset — the whole PM checklist hangs off that lookup');
        Assert.areEqual('Property Set up', created[0].Stage__c,
            'opened at the first stage of the Path, not at a blank one');
        // 🔴 THE SHARING TRAP. Onboarding__c is Private OWD and its ONLY sharing rule shares
        // rows where Status__c != '' to DPEG_Property_Mgmt_Team. A blank status here means the
        // record exists, the notification arrives, and clicking it shows an access error.
        Assert.areEqual('In Progress', created[0].Status__c,
            'Status is set EXPLICITLY — a blank Status__c fails the only sharing rule on the '
            + 'object and hides the new Onboarding from the entire PM team');
        Assert.areEqual(Date.today(), created[0].Start_Date__c,
            'Start Date is the day the acquisition landed — every checklist due date is offset '
            + 'from it');
        Assert.areEqual(Date.today().addDays(90), created[0].Target_Completion_Date__c,
            'Target is Start + TARGET_COMPLETION_DAYS (the largest shipped Due_Day_Offset__c), '
            + 'so Is_Past_Target__c has something to compare against and the dashboard ORDER BY '
            + 'Target_Completion_Date__c NULLS LAST keeps its sort key');

        Assert.areEqual(1, OnboardingAutoCreateService.runCreated, 'the create is counted');
        Assert.areEqual(0, OnboardingAutoCreateService.runFailed, 'and nothing was refused');
    }

    /**
     * THE UPDATE PATH. An asset created WITHOUT a Closing Date and given one later — a manual
     * correction, a data load, a future acquisition route — still gets its Onboarding. This is
     * the residual the design flagged as a gap under an after-insert-only trigger; it is closed
     * rather than accepted.
     */
    @isTest
    static void stampingAClosingDateOnAnExistingAssetOpensTheOnboarding() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, true);
        Assert.areEqual(0, onboardingsFor(new Set<Id>{ asset.Id }).size(),
            'Precondition: an asset with no Closing Date has no Onboarding, so the assertion '
            + 'below cannot pass because one already existed');

        Test.startTest();
        update new Property_Asset__c(Id = asset.Id, Closing_Date__c = Date.today());
        Test.stopTest();

        Assert.areEqual(1, onboardingsFor(new Set<Id>{ asset.Id }).size(),
            'The transition to non-null is what fires, whether it happens at insert or later');
    }

    /**
     * TRANSITION, NOT "IS SET". Re-saving an asset that ALREADY had a Closing Date does nothing
     * — no second Onboarding, and no cost. Without this reading, every edit to every acquired
     * property in the org would re-enter the service.
     */
    @isTest
    static void reSavingAnAlreadyClosedAssetDoesNothingAtZeroCost() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, false);
        asset.Closing_Date__c = Date.today();
        insert asset;
        Assert.areEqual(1, onboardingsFor(new Set<Id>{ asset.Id }).size(), 'Precondition: one exists');

        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        update new Property_Asset__c(Id = asset.Id, NOI__c = 99999);
        Test.stopTest();

        Assert.areEqual(1, onboardingsFor(new Set<Id>{ asset.Id }).size(),
            'Still exactly one Onboarding');
        Assert.areEqual(1, OnboardingAutoCreateService.runInvocations,
            'The service still ran — it is the GUARD that declines, not the routing');
        Assert.areEqual(0, OnboardingAutoCreateService.runQueryCount,
            'A save with no Closing-Date transition costs ZERO queries; the filter returns before '
            + 'any read');
        Assert.areEqual(0, OnboardingAutoCreateService.runDmlCount, 'and zero DML');
    }

    /**
     * 🔴 IDEMPOTENCY. An asset that already carries an Onboarding — hand-created, seeded, or
     * from an earlier acquisition — gets no second one. This is the branch a sharing-scoped
     * idempotency read would silently skip, producing a duplicate rather than a silence.
     */
    @isTest
    static void anAssetThatAlreadyHasAnOnboardingGetsNoSecondOne() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, true);
        Onboarding__c preexisting = TestDataFactory.createOnboarding(asset.Id, true);

        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        update new Property_Asset__c(Id = asset.Id, Closing_Date__c = Date.today());
        Test.stopTest();

        List<Onboarding__c> all = onboardingsFor(new Set<Id>{ asset.Id });
        Assert.areEqual(1, all.size(), 'The asset still has exactly one Onboarding');
        Assert.areEqual(preexisting.Id, all[0].Id, 'and it is the pre-existing one, untouched');
        Assert.areEqual(1, OnboardingAutoCreateService.runSkippedExisting, 'the skip is counted');
        Assert.areEqual(1, OnboardingAutoCreateService.runQueryCount,
            'The guard short-circuits after the idempotency read — nothing else is paid for');
        Assert.areEqual(0, OnboardingAutoCreateService.runDmlCount, 'and nothing is written');
    }

    /**
     * 🔴 THE DISCRIMINATOR. An asset with NO Closing Date — the shape `TestDataFactory` and all
     * nine seed scripts produce — mints nothing and costs nothing.
     */
    @isTest
    static void anAssetWithNoClosingDateCreatesNothingAtZeroCost() {
        OnboardingAutoCreateService.resetRunCounters();

        Test.startTest();
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, true);
        Test.stopTest();

        Assert.areEqual(0, onboardingsFor(new Set<Id>{ asset.Id }).size(),
            'A seeded or hand-built asset is NOT an acquisition and opens no Onboarding');
        Assert.areEqual(1, OnboardingAutoCreateService.runInvocations, 'The trigger did route to us');
        Assert.areEqual(0, OnboardingAutoCreateService.runQueryCount,
            'but the filter returned before any read — an ordinary asset save is free');
        Assert.areEqual(0, OnboardingAutoCreateService.runDmlCount, 'and wrote nothing');
    }

    /** Null and empty collections are no-ops, not NullPointerExceptions. */
    @isTest
    static void nullAndEmptyInputAreNoOps() {
        OnboardingAutoCreateService.resetRunCounters();

        Test.startTest();
        OnboardingAutoCreateService.ensureOnClosing(null, null);
        OnboardingAutoCreateService.ensureOnClosing(new List<Property_Asset__c>(), null);
        Test.stopTest();

        Assert.areEqual(2, OnboardingAutoCreateService.runInvocations, 'Both calls were counted');
        Assert.areEqual(0, OnboardingAutoCreateService.runQueryCount, 'and neither read anything');
        Assert.areEqual(0, OnboardingAutoCreateService.runCreated, 'nor created anything');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 assets, TWO trigger chunks, a CONSTANT budget
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `.claude/rules/bulk-test-rule.md` in full: 251 closing assets in ONE DML forces a second
     * 200-record trigger chunk.
     *
     * 🔴 THE BUDGET ASSERTION IS THE HIGHER-VALUE HALF. The row count would still pass if
     * someone rewrote this to query per asset — right up until a real 200-deal close blew the
     * SOQL limit and rolled back every close in the chunk. The arithmetic:
     *   251 assets -> 2 chunks (200 + 51)        -> runInvocations = 2
     *   1 idempotency read per chunk             -> runQueryCount = 2
     *   1 bulk Onboarding insert per chunk       -> runDmlCount   = 2
     * Both totals are independent of the record count; only the invocation count scales, and it
     * scales with CHUNKS, not assets.
     *
     * ⚠ THE WARM-UP INSERT IS NOT INCIDENTAL — DO NOT DELETE IT. `GroupNotifier` caches the
     * notification type, the recipient group and its members STATICALLY for the transaction,
     * and its one-time cost is 3 queries or 2 depending on whether the group exists in the
     * target org (`GroupMemberSelector.selectByGroupIds` short-circuits on an empty Id set). An
     * unwarmed measurement would therefore be org-dependent, and the "fix" would be to loosen
     * the assertion. Paying that cost BEFORE the counters are reset makes what is measured
     * purely the per-chunk cost, and keeps the number exact.
     */
    @isTest
    static void bulk251ClosingAssets_opensEveryOnboardingOnAConstantBudget() {
        Property_Asset__c warmUp = TestDataFactory.createPropertyAsset(null, false);
        warmUp.Closing_Date__c = Date.today();
        insert warmUp; // warms GroupNotifier's static caches — see the note above

        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(BULK_N, null, false);
        for (Property_Asset__c a : assets) {
            a.Closing_Date__c = Date.today();
        }
        OnboardingAutoCreateService.resetRunCounters();

        Test.startTest();
        insert assets;
        Test.stopTest();

        Set<Id> assetIds = idsOf(assets);
        List<Onboarding__c> created = onboardingsFor(assetIds);
        Assert.areEqual(BULK_N, created.size(), 'All 251 closing assets open an Onboarding each');

        Set<Id> parented = new Set<Id>();
        for (Onboarding__c o : created) {
            parented.add(o.Property_Asset__c);
            Assert.areEqual('In Progress', o.Status__c,
                'EVERY row carries an explicit Status — one blank one is one record invisible to '
                + 'the whole PM team');
            Assert.areEqual('Property Set up', o.Stage__c, 'and every row opens at the first stage');
        }
        Assert.areEqual(BULK_N, parented.size(),
            'Each of the 251 assets has its OWN Onboarding — no duplicates, no orphans');

        Assert.areEqual(2, OnboardingAutoCreateService.runInvocations,
            '251 records is two trigger chunks (200 + 51)');
        Assert.areEqual(BULK_N, OnboardingAutoCreateService.runCreated, 'and all 251 were created');
        Assert.areEqual(0, OnboardingAutoCreateService.runFailed,
            'with nothing refused — a non-zero here is a real defect, not test noise');
        Assert.areEqual(2, OnboardingAutoCreateService.runQueryCount,
            'ONE idempotency read per chunk — 2 chunks = 2 queries, with the notifier\'s one-time '
            + 'cost already warmed. CONSTANT in asset count; if this reds because it grew with '
            + '251, a query moved into a per-record loop');
        Assert.areEqual(2, OnboardingAutoCreateService.runDmlCount,
            'CONSTANT 1 bulk insert per chunk — 2 chunks = 2 statements');
    }

    /**
     * 🔴 THE REGRESSION GUARD FOR THE WHOLE REPO. 251 assets with NO Closing Date — exactly what
     * `TestDataFactory.createPropertyAssets` and all nine seed scripts produce — create ZERO
     * Onboardings and cost ZERO queries and ZERO DML.
     *
     * If this reds, the discriminator has widened and the ~66 existing test classes that touch
     * `Property_Asset__c` have all silently started minting Onboardings and 45-item checklists.
     */
    @isTest
    static void bulk251AssetsWithNoClosingDate_createsNothingAtZeroCost() {
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(BULK_N, null, false);
        OnboardingAutoCreateService.resetRunCounters();

        Test.startTest();
        insert assets;
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Onboarding__c WHERE Property_Asset__c IN :assets],
            'ZERO Onboardings for 251 ordinary assets — this is what keeps the existing suite and '
            + 'every seed script immune BY CONSTRUCTION rather than by a filter someone remembers');
        Assert.areEqual(2, OnboardingAutoCreateService.runInvocations,
            'The trigger still routed both chunks — it is the FILTER that declines');
        Assert.areEqual(0, OnboardingAutoCreateService.runQueryCount,
            'and 251 ordinary asset inserts cost ZERO queries');
        Assert.areEqual(0, OnboardingAutoCreateService.runDmlCount, 'and ZERO DML');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE END-TO-END CASCADE
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * The auto-created Onboarding is picked up by the `Onboarding_Task_Fanout` flow, so a closed
     * acquisition ends with an actual checklist rather than an empty record. This is the only
     * test that walks the whole handoff — asset close -> Onboarding -> flow -> queueable ->
     * Tasks — and it is what would catch the two halves being individually correct but never
     * wired together.
     *
     * ⚠ The definition count is INJECTED, not read from the org: the 45 production rows are
     * loaded asynchronously by a script rather than deployed, so an org-count assertion would
     * be green or red depending on which org the suite runs in.
     */
    @isTest
    static void aClosingAssetEndsUpWithAnActualChecklist() {
        OnboardingFanoutService.taskDefsOverride = TestDataFactory.buildOnboardingTaskDefs(4);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(null, false);
        asset.Closing_Date__c = Date.today();

        Test.startTest();
        insert asset;
        Test.stopTest(); // the flow's enqueued fan-out job runs here

        List<Onboarding__c> created = onboardingsFor(new Set<Id>{ asset.Id });
        Assert.areEqual(1, created.size(), 'One Onboarding was opened');
        Assert.isTrue(
            [SELECT Tasks_Fanned_Out__c FROM Onboarding__c WHERE Id = :created[0].Id].Tasks_Fanned_Out__c,
            'and it was flagged, so a later re-save cannot mint a duplicate checklist');
        Assert.areEqual(4,
            [SELECT COUNT() FROM Task WHERE Onboarding__c = :created[0].Id],
            'The checklist actually exists — the full cascade (asset close -> Onboarding -> Flow '
            + '-> Queueable -> Tasks) is wired end to end');
    }
}
