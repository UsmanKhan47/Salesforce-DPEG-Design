/**
 * @description Tests `DispositionAssetDisposalService` — Conversion 6 (BA story 49): reaching
 * `Disposition_Stage__c = 'Sale Closes'` marks the parent `Property_Asset__c.Status__c` as
 * `'Disposed'`, which takes the sold building off the Sell Meter and out of eight dashboard
 * reports that have carried an `Active` filter — inert — for weeks.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE ONE TEST THIS CLASS EXISTS FOR IS `nonOwnerPrincipal_...`, AND EVERY OTHER TEST HERE
 *    PASSES WHETHER OR NOT THE FEATURE WORKS IN PRODUCTION.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The production caller is the `Closing_Approval` APPROVER: the approval's `finalApprovalActions`
 * sets a semaphore -> `DispositionTrigger` -> `System.enqueueJob` -> `DispositionApprovalAdvance
 * Queueable`, and **a Queueable runs as its ENQUEUING user**. `Property_Asset__c` is OWD Private,
 * its single sharing rule shares only to `DPEG_Property_Mgmt_Team`, and `DPEG_Disposition_Edit`
 * grants the object `allowRead = true / allowEdit = false / viewAllRecords = false /
 * modifyAllRecords = false` (measured in the permission set, 2026-09-02).
 *
 * So a disposition principal can neither SEE nor EDIT the asset. Every other test in this class
 * runs as the test-running admin, who owns the fixture and has Modify All Data — i.e. every one of
 * them passes with BOTH sharing escapes removed. A suite without a non-owner test would prove the
 * feature works for exactly the one principal who never triggers it.
 *
 * ⚠ AND THE TWO ESCAPES FAIL DIFFERENTLY, WHICH IS WHY THE NON-OWNER TEST ASSERTS TWO THINGS:
 *   - a sharing-filtered READ (`PropertyAssetSelector.DisposalReads`) returns no row, the caller
 *     finds nothing to update, and the asset is SILENTLY never disposed — no exception, no failed
 *     job, no marker anywhere;
 *   - a sharing-refused WRITE (`AssetDisposalWrites`) throws, loudly.
 * A test that only asserted "no exception" would pass with the read escape removed.
 *
 * ── ⚠ `System.runAs` AND THE ASYNC HOP: THE SERVICE IS CALLED DIRECTLY, NOT THROUGH THE QUEUEABLE
 * `Test.stopTest()` drains the queue as the TEST-RUNNING user, NOT as the `runAs` user — measured
 * on this repo 2026-08-21 and written up at length in `DispositionApprovalAdvanceServiceTest`. A
 * non-owner test built around `enqueue -> stopTest` inside `System.runAs` is the admin path
 * wearing a `runAs` block, and it passes with both escapes deleted. This class therefore calls
 * `markAssetsDisposed` DIRECTLY inside `runAs` with a synthetic trigger context, which is the only
 * shape in which the running user is genuinely the non-owner at the moment of the read and the
 * write. `endToEndThroughTheRealTrigger...` covers the wiring separately, as the admin.
 *
 * ── BULK: `.claude/rules/bulk-test-rule.md` APPLIES IN FULL, NO EXEMPTION ────────────────────
 * Trigger-driven. Two 251-record tests, and they prove different things:
 *   `bulk251...AtConstantCost`     251 dispositions across 251 DISTINCT assets through a direct
 *                                  service call: EXACTLY 1 query and 1 DML, asserted as exact
 *                                  numbers. The point is CONSTANCY, not that 251 rows produced
 *                                  251 writes.
 *   `bulk251ThroughTheRealTrigger` one `update` of 251 rows, which forces a SECOND trigger chunk
 *                                  (chunks are 200). Completing with all 251 assets disposed is
 *                                  the falsifier for "the hook only fires on the first chunk".
 *                                  Its budget assertion is a CEILING, not a number, because other
 *                                  automation shares that transaction.
 *
 * ⚠ 251 DISPOSITIONS ON 251 DISTINCT ASSETS, NOT ON ONE SHARED ASSET. A shared-asset fixture
 * dedupes to a single row inside the service, so it would report 1 query and 1 DML for a
 * per-record implementation too — the assertion would be measuring the fixture, not the code.
 *
 * @see force-app/main/default/classes/DispositionAssetDisposalService.cls
 * @see force-app/main/default/classes/PropertyAssetSelector.cls (selectStatusByIds + DisposalReads)
 * @see force-app/main/default/classes/DispositionApprovalAdvanceServiceTest.cls (the runAs pattern)
 * @author Salesforce Developer
 */
@isTest
private class DispositionAssetDisposalServiceTest {

    private static final Integer BULK_N = 251;
    private static final String STAGE_CLOSING = 'Closing';
    private static final String STAGE_SALE_CLOSES = 'Sale Closes';
    private static final String STATUS_ACTIVE = 'Active';
    private static final String STATUS_DISPOSED = 'Disposed';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static String assetStatus(Id id) {
        return [SELECT Status__c FROM Property_Asset__c WHERE Id = :id].Status__c;
    }

    /** A saved Disposition parked at `stage` on the given asset. */
    private static Disposition__c dispositionAt(Id parentAssetId, String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            parentAssetId, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    /**
     * A synthetic after-update trigger context: every disposition moved from `from` to `to`.
     *
     * ⚠ IT BUILDS SHELLS RATHER THAN RE-USING THE SAVED RECORDS. Reusing an in-memory sObject
     * after DML re-sends stale literals — a defect this repo has found passing VACUOUSLY four
     * times out of six instances. The service reads exactly two fields off `Trigger.new`
     * (`Property_Asset__c` and `Disposition_Stage__c`), so a shell carrying only those is both
     * sufficient and honest about what the production context supplies.
     */
    private static void routeStageChange(
        List<Disposition__c> saved,
        String fromStage,
        String toStage
    ) {
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : saved) {
            newList.add(new Disposition__c(
                Id = d.Id,
                Property_Asset__c = d.Property_Asset__c,
                Disposition_Stage__c = toStage
            ));
            oldMap.put(d.Id, new Disposition__c(
                Id = d.Id,
                Property_Asset__c = d.Property_Asset__c,
                Disposition_Stage__c = fromStage
            ));
        }
        DispositionAssetDisposalService.markAssetsDisposed(newList, oldMap);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE WRITE ITSELF
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void enteringSaleClosesDisposesTheParentAsset() {
        Id parentAssetId = assetId();
        Disposition__c d = dispositionAt(parentAssetId, STAGE_CLOSING);
        Assert.areEqual(STATUS_ACTIVE, assetStatus(parentAssetId),
            'PRECONDITION: the factory creates the asset Active');

        Test.startTest();
        routeStageChange(new List<Disposition__c>{ d }, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Test.stopTest();

        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId),
            'Reaching Sale Closes must mark the sold building Disposed — this is the single write '
            + 'that turns eight already-shipped report filters from decoration into behaviour');
    }

    /**
     * 🔴 THE TRANSITION, NOT THE VALUE. A row already at `Sale Closes` that is saved again for any
     * unrelated reason is not an entry, and must not re-write the asset — which is what keeps
     * `PropertyAssetTrigger` from firing on a save that changes nothing.
     *
     * ⚠ THE ASSERTION IS THE QUERY AND DML COUNT, NOT THE STATUS. The status reads `Disposed`
     * either way, so a status-only assertion passes for an implementation that writes on every
     * save. ZERO queries is also the stronger claim: it proves the early return happens BEFORE the
     * selector, not after it.
     */
    @isTest
    static void aReSaveAtSaleClosesCostsNothingAtAll() {
        Id parentAssetId = assetId();
        Disposition__c d = dispositionAt(parentAssetId, STAGE_CLOSING);
        routeStageChange(new List<Disposition__c>{ d }, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId),
            'PRECONDITION: the first entry disposed it');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        routeStageChange(new List<Disposition__c>{ d }, STAGE_SALE_CLOSES, STAGE_SALE_CLOSES);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'ZERO queries on a re-save. A 1 here means the early return moved BELOW the selector '
            + 'call, so every Disposition save in the org that touches a Sale-Closes row now pays '
            + 'for a query it cannot use.');
        Assert.areEqual(0, dmlUsed, 'and ZERO DML — nothing changed, so nothing is written');
        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId), 'and it is still Disposed');
    }

    /**
     * 🔴 IDEMPOTENCY ACROSS TWO DISPOSITIONS ON ONE ASSET — the case the status re-read exists for,
     * and the one the transition guard alone CANNOT catch.
     *
     * A portfolio sold in parts, or a building re-listed after a failed sale, legitimately carries
     * two Dispositions pointing at the same `Property_Asset__c`. The second one entering
     * `Sale Closes` IS a genuine transition, so the transition guard lets it through; only the
     * status re-read stops a redundant write. ⚠ The observable difference is ZERO DML, not the
     * status — which reads `Disposed` either way.
     */
    @isTest
    static void aSecondDispositionOnAnAlreadyDisposedAssetWritesNothing() {
        Id parentAssetId = assetId();
        Disposition__c first = dispositionAt(parentAssetId, STAGE_CLOSING);
        Disposition__c second = dispositionAt(parentAssetId, STAGE_CLOSING);
        routeStageChange(new List<Disposition__c>{ first }, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId),
            'PRECONDITION: the first disposition disposed the shared asset');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        routeStageChange(new List<Disposition__c>{ second }, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'ONE query — this IS a real transition, so the status must be read to find out that '
            + 'there is nothing to do');
        Assert.areEqual(0, dmlUsed,
            '🔴 AND ZERO DML. A 1 here means the status re-read was dropped as "redundant with the '
            + 'transition guard": it is not, and the cost is a pointless PropertyAssetTrigger '
            + 'firing on every subsequent sale of an already-disposed building.');
    }

    /**
     * Two dispositions on the SAME asset entering `Sale Closes` in ONE chunk collapse to one row.
     * ⚠ Without the `Set<Id>`, `Database.update` receives the same Id twice in one list and throws
     * `DUPLICATE_VALUE` — which under `allOrNone = true` rolls back the whole save.
     */
    @isTest
    static void twoDispositionsOnOneAssetInOneChunkProduceOneWrite() {
        Id parentAssetId = assetId();
        List<Disposition__c> pair = new List<Disposition__c>{
            dispositionAt(parentAssetId, STAGE_CLOSING),
            dispositionAt(parentAssetId, STAGE_CLOSING)
        };

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        routeStageChange(pair, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed, 'One statement for the pair');
        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId), 'and the asset is Disposed');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // THE FALSIFIERS — saves that must cost NOTHING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ZERO-COST FALSIFIER. `DispositionTrigger` fires on EVERY Disposition write in the org,
     * so a save that does not enter `Sale Closes` must reach neither the selector nor the DML — at
     * any volume. This is the assertion that stops this feature quietly adding a query and a
     * statement to every disposition edit anyone makes.
     */
    @isTest
    static void bulk251SavesThatDoNotEnterSaleClosesCostNothing() {
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, assetId(), true);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        routeStageChange(dispositions, 'Disposition Readiness', STAGE_CLOSING);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, 'A save that enters no terminal stage costs no query');
        Assert.areEqual(0, dmlUsed, 'and no DML');
        Assert.areEqual(STATUS_ACTIVE, assetStatus(assetId()),
            'and the asset is untouched — 251 dispositions moved to Closing, none of them sold');
    }

    /**
     * A disposition with no parent asset must be skipped rather than throwing.
     *
     * ⚠ THE STATE IS UNREACHABLE IN PRODUCTION — `Property_Asset_Required_On_Save` refuses it — so
     * this is asserted against a SYNTHETIC context rather than a saved row. The guard exists
     * because a null here would be a NullPointerException inside an after-update trigger, i.e. a
     * refused approval, and "the validation rule prevents it" is a promise made by a file this
     * class cannot see.
     */
    @isTest
    static void aDispositionWithNoAssetIsSkippedRatherThanThrowing() {
        Disposition__c orphan = dispositionAt(assetId(), STAGE_CLOSING);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        DispositionAssetDisposalService.markAssetsDisposed(
            new List<Disposition__c>{
                new Disposition__c(
                    Id = orphan.Id,
                    Property_Asset__c = null,
                    Disposition_Stage__c = STAGE_SALE_CLOSES
                )
            },
            null
        );
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, 'A parentless disposition costs nothing and throws nothing');
        Assert.areEqual(STATUS_ACTIVE, assetStatus(assetId()), 'and nothing was disposed');
    }

    @isTest
    static void nullAndEmptyInputsAreSafe() {
        Test.startTest();
        DispositionAssetDisposalService.markAssetsDisposed(null, null);
        DispositionAssetDisposalService.markAssetsDisposed(new List<Disposition__c>(), null);
        Test.stopTest();

        Assert.areEqual(STATUS_ACTIVE, assetStatus(assetId()),
            'Neither a null nor an empty list may reach the selector or the DML');
    }

    /**
     * An INSERT directly at `Sale Closes` counts as an entry (`prior == null`), matching
     * `DispositionStageEntryService`'s convention on the same trigger context.
     *
     * 🔴 THE STATE IS ALL BUT UNREACHABLE IN PRODUCTION AND THAT IS RECORDED HERE RATHER THAN
     * ASSUMED: `Wire_Complete_Before_Sale_Closes` fires on `OR(ISNEW(), ISCHANGED(...))`, so a row
     * created at `Sale Closes` is refused unless `Wire_Verification_Completed__c` is already true —
     * which a brand-new record cannot be. This is therefore asserted through a SYNTHETIC insert
     * context, not through real DML, because real DML cannot reach it. The behaviour is wired
     * anyway so that the two after-context hooks do not disagree about what an insert means.
     */
    @isTest
    static void anInsertAtSaleClosesCountsAsAnEntry() {
        Id parentAssetId = assetId();
        Disposition__c d = dispositionAt(parentAssetId, STAGE_CLOSING);

        Test.startTest();
        DispositionAssetDisposalService.markAssetsDisposed(
            new List<Disposition__c>{
                new Disposition__c(
                    Id = d.Id,
                    Property_Asset__c = parentAssetId,
                    Disposition_Stage__c = STAGE_SALE_CLOSES
                )
            },
            null // insert context
        );
        Test.stopTest();

        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId),
            'prior == null is an entry, exactly as DispositionStageEntryService treats it');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 🔴 THE NON-OWNER PRINCIPAL — the only test that can fail for the real reason
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE TEST THIS CLASS EXISTS FOR. Read the class header first.
     *
     * `createNonOwnerDispositionApprover` is a `Minimum Access - Salesforce` user holding
     * `DPEG_Base_Access` + `DPEG_Disposition_Edit` + `DPEG_Acquisition_Edit`. Measured in
     * `DPEG_Disposition_Edit` on 2026-09-02, its `Property_Asset__c` block reads
     * `allowRead = true`, `allowEdit = false`, `viewAllRecords = false`,
     * `modifyAllRecords = false`. The asset is created in `@testSetup` and therefore OWNED BY THE
     * TEST-RUNNING ADMIN, on an object whose OWD is Private and whose single sharing rule shares
     * only to `DPEG_Property_Mgmt_Team`.
     *
     * So this persona has, on the asset: no read at RECORD level, and no edit at ANY level. Both
     * escapes are load-bearing and the control below proves the first one is real rather than
     * assumed — an `assertNotVisible` that passed for the wrong reason (say, because the fixture
     * never created the asset) would make the whole test vacuous.
     */
    @isTest
    static void nonOwnerPrincipal_disposesTheAssetItCanNeitherSeeNorEdit() {
        Id parentAssetId = assetId();
        Disposition__c d = dispositionAt(parentAssetId, STAGE_CLOSING);
        User principal = TestDataFactory.createNonOwnerDispositionApprover('dad1');

        System.runAs(principal) {
            // ── CONTROL 1: the sharing filter is REAL for this persona. ──────────────────────
            // 🔴 IF THIS EVER RETURNS A ROW THE WHOLE TEST GOES VACUOUS — a persona that can see
            // the asset would pass with `DisposalReads`'s `without sharing` deleted, and the
            // silent-no-op failure mode this class is built around would ship unnoticed.
            List<Property_Asset__c> visible = [
                SELECT Id FROM Property_Asset__c WHERE Id = :parentAssetId WITH USER_MODE
            ];
            Assert.areEqual(0, visible.size(),
                'CONTROL: a disposition principal must NOT be able to see this asset under '
                + 'sharing. If they can, DPEG_Disposition_Edit has gained viewAllRecords on '
                + 'Property_Asset__c, or the PM sharing rule has widened — either way this test '
                + 'no longer proves anything and must be re-pointed at a persona that cannot.');

            // ── CONTROL 2: and cannot edit it either. ────────────────────────────────────────
            List<UserRecordAccess> access = [
                SELECT RecordId, HasReadAccess, HasEditAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :parentAssetId
            ];
            Assert.areEqual(1, access.size(),
                'UserRecordAccess returns exactly one row per (user, record) pair');
            Assert.isFalse(access[0].HasEditAccess,
                'CONTROL: no record-level edit. With edit, AssetDisposalWrites could be deleted '
                + 'and this test would still pass.');

            Test.startTest();
            routeStageChange(new List<Disposition__c>{ d }, STAGE_CLOSING, STAGE_SALE_CLOSES);
            Test.stopTest();
        }

        // Re-read as the admin — the principal cannot see the row to assert on it.
        Assert.areEqual(STATUS_DISPOSED, assetStatus(parentAssetId),
            '🔴 THE ASSET WAS NOT DISPOSED. Two distinct causes and they are worth telling apart: '
            + 'if PropertyAssetSelector.DisposalReads lost its `without sharing`, the read returned '
            + 'nothing, the service found nothing to update and returned SUCCESSFULLY — that is '
            + 'the silent production failure this whole class is built around. If '
            + 'AssetDisposalWrites lost its `without sharing` or its SYSTEM_MODE, this test would '
            + 'have thrown instead of reaching this line. Both are fixed in the same place: '
            + 'ARCHITECTURE.md §2, "SYSTEM_MODE bypasses CRUD/FLS ONLY".');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BULK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 251 dispositions on 251 DISTINCT assets: exactly ONE query and ONE DML.
     *
     * ⚠ DISTINCT ASSETS, DELIBERATELY. A fixture where all 251 dispositions share one asset
     * dedupes to a single row inside the service, so 1 query and 1 DML would be reported by a
     * per-record implementation too — the assertion would be measuring the fixture. Here a
     * per-record implementation needs 251 of each and blows both governor limits outright.
     */
    @isTest
    static void bulk251DistinctAssetsDisposeAtConstantCost() {
        Property__c prop = [SELECT Id FROM Property__c LIMIT 1];
        List<Property_Asset__c> assets =
            TestDataFactory.createPropertyAssets(BULK_N, prop.Id, true);
        List<Disposition__c> dispositions = new List<Disposition__c>();
        for (Property_Asset__c a : assets) {
            Disposition__c d = TestDataFactory.createDisposition(
                a.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
            d.Disposition_Stage__c = STAGE_CLOSING;
            dispositions.add(d);
        }
        insert dispositions; // built in the loop, inserted once — never DML in a loop

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        routeStageChange(dispositions, STAGE_CLOSING, STAGE_SALE_CLOSES);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 DISTINCT assets — never one per record');
        Assert.areEqual(1, dmlUsed,
            'EXACTLY ONE Database.update for 251 DISTINCT assets — never one per record');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Property_Asset__c
             WHERE Id IN :assets AND Status__c = :STATUS_DISPOSED],
            'Every one of the 251 assets must be Disposed');
        Assert.areEqual(STATUS_ACTIVE, assetStatus(assetId()),
            'and the @testSetup asset, which no disposition sold, is still Active — the falsifier '
            + 'for a blanket update');
    }

    /**
     * 🔴 THE END-TO-END PATH AT 251, WHICH IS WHAT PROVES THE CHUNKING CLAIM. 251 rows in one
     * `update` forces a SECOND trigger batch (chunks are 200), so completing this test with every
     * asset disposed is the falsifier for "the hook only fires on the first chunk".
     *
     * ⚠ IT ALSO PROVES THE WIRING, WHICH NO OTHER TEST HERE DOES. Every test above calls the
     * service directly; only this one goes through `DispositionTrigger` ->
     * `DispositionTriggerHandler.route`. A build that wrote the service perfectly and forgot to
     * call it from the handler passes everything else in this file.
     *
     * ⚠ THE FIXTURE HAS TO SATISFY TWO VALIDATION RULES TO REACH `Sale Closes` BY REAL DML:
     *   `Wire_Complete_Before_Sale_Closes`      needs `Wire_Verification_Completed__c = true`;
     *   `All_NDAs_Signed_Before_Progression`    needs every non-Declined NDA Signed.
     * Neither is this feature's rule and neither is being tested here — they are the cost of using
     * real DML rather than a synthetic context, and paying it is what makes this the wiring test.
     *
     * ⚠ THE BUDGET ASSERTION IS A CEILING, NOT A NUMBER. `DispositionStageEntryService`,
     * `DispositionApprovalAdvanceService`, `NDA_Signed_Rollup` and the Property Asset trigger all
     * run inside this same transaction. An exact count would go red the day any of them changed,
     * for reasons having nothing to do with this service. What a ceiling still cannot accommodate
     * is per-record work, which is the only defect it exists to catch.
     */
    @isTest
    static void bulk251ThroughTheRealTriggerDisposesBothChunks() {
        Property__c prop = [SELECT Id FROM Property__c LIMIT 1];
        List<Property_Asset__c> assets =
            TestDataFactory.createPropertyAssets(BULK_N, prop.Id, true);
        List<Disposition__c> dispositions = new List<Disposition__c>();
        for (Property_Asset__c a : assets) {
            Disposition__c d = TestDataFactory.createDisposition(
                a.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
            d.Disposition_Stage__c = STAGE_CLOSING;
            d.Wire_Verification_Completed__c = true;
            dispositions.add(d);
        }
        insert dispositions;
        TestDataFactory.signBuyerNdasOn(dispositions);

        List<Disposition__c> updates = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            updates.add(new Disposition__c(
                Id = d.Id, Disposition_Stage__c = STAGE_SALE_CLOSES));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        update updates; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Property_Asset__c
             WHERE Id IN :assets AND Status__c = :STATUS_DISPOSED],
            'Every one of the 251 assets must be Disposed. A count near 200 means the SECOND '
            + 'trigger chunk never reached the service; a count of 0 means the handler does not '
            + 'call it at all.');
        Assert.isTrue(queriesUsed <= 20,
            'CONSTANT, not per-record. 251 rows used ' + queriesUsed + ' queries; a per-record '
            + 'read would have needed 251 and blown the 100-query limit.');
        Assert.isTrue(dmlUsed <= 20,
            'CONSTANT, not per-record. 251 rows used ' + dmlUsed + ' DML statements; a per-record '
            + 'update would have needed 251 and blown the 150-statement limit.');
    }
}
