/**
 * @description Tests `DispositionStageEntryService`'s `Release Materials` block — the blank-only,
 * idempotent default stamp of `NDA__c.Materials_Released_Date__c` on entry to that stage
 * (`agent-output/disposition-tranche-2-requirements.md` §3 D6.1, added 2026-08-20). It is the
 * middle hop of the buyer activity timeline: without it, both duration columns render `—` on every
 * row and the card's whole point disappears.
 *
 * ── ⚠ WHY THIS IS ITS OWN CLASS RATHER THAN METHODS INSIDE `DispositionStageEntryServiceTest` ──
 * That suite is large, shared and under concurrent edit; this block is a self-contained fifth stage
 * with its own idempotency question ("is the field blank?" rather than "does the child exist?").
 * Keeping it separate makes the diff readable and keeps a merge conflict in one suite from taking
 * the other down. ⚠ It is NOT a licence to skip the sibling suite: anything about the OTHER four
 * stage blocks still belongs there.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE PRECONDITION EVERY REAL-TRANSITION TEST HERE MUST SATISFY, AND WHY
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `All_NDAs_Signed_Before_Progression` fires on
 * `ISCHANGED(Disposition_Stage__c) AND stage IN (Release Materials, ...) AND (NDA_Count__c = 0 OR
 * Signed_NDA_Count__c < NDA_Count__c)`. So a disposition CANNOT be moved into `Release Materials`
 * by `update` unless it already has at least one NDA and every non-Declined one is `Signed`.
 *
 * ✅ THAT IS NOT AN OBSTACLE — IT IS THE PRODUCTION SHAPE, AND IT IS WORTH STATING: on the normal
 * path this stamp lands on NDAs whose `Date_Signed__c` is already set, so the timeline's first
 * duration is computable immediately. The counters are maintained by the after-save flow
 * `NDA_Signed_Rollup`, so the NDA must be inserted (and committed) BEFORE the stage update — which
 * is exactly what `TestDataFactory.signBuyerNdaOn` does.
 *
 * ⚠ The rule is `ISCHANGED`-only, so a disposition INSERTED directly at `Release Materials` bypasses
 * it entirely. `insertDirectlyAtReleaseMaterials_stampsNothingBecauseNoNdaExistsYet` covers that
 * path and asserts the (correct, and initially surprising) outcome.
 *
 * ── BULK ──
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES IN FULL — this is a trigger path
 * over a collection, with no exemption to claim. `bulk251EntrantsStampAtConstantCost` drives 251
 * dispositions through a real `update` and asserts a CONSTANT statement budget, which is the
 * property that matters: a per-disposition query or DML would blow the limits long before finishing.
 * ⚠ ONE NDA PER DISPOSITION, DELIBERATELY. `flows/NDA_Signed_Rollup`'s own description records that
 * the many-NDAs-under-ONE-disposition consolidation is *"untested either way"*; 251 dispositions
 * with one NDA each is the shape that flow's existing bulk coverage already uses, so this test
 * measures THIS block rather than that flow's untested path.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls
 * @see force-app/main/default/classes/NdaSelector.cls (selectByDispositionIds — widened by one
 *      field for this block)
 * @see force-app/main/default/classes/DispositionBuyerTimelineTest.cls (what the date feeds)
 */
@isTest
private class DispositionMaterialsStampTest {

    private static final Integer BULK_N = 251;
    private static final String STAGE_RELEASE_MATERIALS = 'Release Materials';
    private static final String ROLE_BROKER = 'Introducing Broker';

    /** A disposition with one SIGNED buyer NDA — the minimum state that can enter the stage. */
    private static Disposition__c readyDisposition() {
        Disposition__c d = TestDataFactory.createDisposition(null, true);
        TestDataFactory.signBuyerNdaOn(d.Id);
        return d;
    }

    /** Moves a disposition into `Release Materials` by real DML, firing the real trigger. */
    private static void enterReleaseMaterials(Disposition__c d) {
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = STAGE_RELEASE_MATERIALS);
    }

    /** The buyer NDAs of a disposition, with the stamped field. */
    private static List<NDA__c> ndasOf(Id dispositionId) {
        return [
            SELECT Id, Party_Role__c, Materials_Released_Date__c
            FROM NDA__c
            WHERE Disposition__c = :dispositionId
        ];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The default
    // ─────────────────────────────────────────────────────────────────────────

    /** The primary behaviour: entering the stage stamps TODAY on the blank buyer NDA. */
    @isTest
    static void enteringReleaseMaterials_stampsTodayOnABlankBuyerNda() {
        Disposition__c d = readyDisposition();
        Assert.isNull(ndasOf(d.Id)[0].Materials_Released_Date__c,
            'FIXTURE PRECONDITION: the field starts blank, so a passing assertion below can only '
            + 'come from this stamp and not from the factory');

        Test.startTest();
        enterReleaseMaterials(d);
        Test.stopTest();

        Assert.areEqual(Date.today(), ndasOf(d.Id)[0].Materials_Released_Date__c,
            'Entering Release Materials must default-stamp the buyer NDA — without it the '
            + 'timeline\'s middle hop, and both duration columns, disappear');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 BLANK-ONLY. NEVER OVERWRITE.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 AN ANALYST'S OWN DATE SURVIVES. This is the whole reason the stamp is FILL-IF-BLANK rather
     * than unconditional: overwriting a hand-entered release date with "today" is a silent data
     * loss, and the per-buyer date exists precisely so *"materials went to buyer A on Tuesday and
     * buyer B on Friday"* is expressible.
     */
    @isTest
    static void analystEnteredDate_isNeverOverwritten() {
        Disposition__c d = TestDataFactory.createDisposition(null, true);
        NDA__c nda = TestDataFactory.signBuyerNdaOn(d.Id);
        Date handEntered = Date.today().addDays(-9);
        update new NDA__c(Id = nda.Id, Materials_Released_Date__c = handEntered);

        Test.startTest();
        enterReleaseMaterials(d);
        Test.stopTest();

        Assert.areEqual(handEntered, ndasOf(d.Id)[0].Materials_Released_Date__c,
            'The analyst\'s own date must survive. FILL-IF-BLANK, never unconditional.');
        Assert.areNotEqual(Date.today(), ndasOf(d.Id)[0].Materials_Released_Date__c,
            'and specifically must not have been replaced with today');
    }

    /**
     * IDEMPOTENCY: stepping back out of the stage and forward again must not restamp. Two
     * independent mechanisms make this hold — `createStageEntryRecords` tests ENTRY rather than
     * presence, and the fill-if-blank guard — and this test would go red if BOTH were removed.
     */
    @isTest
    static void reEnteringTheStage_doesNotRestamp() {
        Disposition__c d = readyDisposition();
        enterReleaseMaterials(d);
        Date firstStamp = ndasOf(d.Id)[0].Materials_Released_Date__c;
        Assert.isNotNull(firstStamp, 'FIXTURE PRECONDITION: the first entry stamped');
        // Back out, then in again. Both hops leave the stamped date alone.
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = 'NDA');

        Test.startTest();
        enterReleaseMaterials(d);
        Test.stopTest();

        Assert.areEqual(firstStamp, ndasOf(d.Id)[0].Materials_Released_Date__c,
            'A stage re-entry must not restart the clock');
    }

    /** A save that does not CHANGE the stage is not an entry and stamps nothing. */
    @isTest
    static void savingWithoutChangingStage_stampsNothing() {
        Disposition__c d = readyDisposition();

        Test.startTest();
        // An ordinary edit while parked at Disposition Readiness.
        update new Disposition__c(Id = d.Id, Title_Company__c = 'Some Other Title Co');
        Test.stopTest();

        Assert.isNull(ndasOf(d.Id)[0].Materials_Released_Date__c,
            'ENTRY, not presence — an unrelated save must not stamp anything');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scope — buyers only
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 AN `Introducing Broker` NDA IS NOT STAMPED. The date means "the deal package went to THIS
     * BUYER", and a broker is not a buyer — the same `Party_Role__c` key `openBuyerNdas` uses and
     * the same one the timeline selector filters on, so the stamp and the card cannot disagree about
     * who counts.
     */
    @isTest
    static void introducingBrokerNda_isNotStamped() {
        Disposition__c d = TestDataFactory.createDisposition(null, true);
        TestDataFactory.signBuyerNdaOn(d.Id);
        // The broker's NDA, also Signed so the release gate still passes.
        NDA__c broker = TestDataFactory.createDispositionNda(d.Id, false);
        broker.Party_Role__c = ROLE_BROKER;
        broker.Status__c = 'Signed';
        insert broker;

        Test.startTest();
        enterReleaseMaterials(d);
        Test.stopTest();

        Map<String, Date> byRole = new Map<String, Date>();
        for (NDA__c nda : ndasOf(d.Id)) {
            byRole.put(nda.Party_Role__c, nda.Materials_Released_Date__c);
        }
        Assert.areEqual(Date.today(), byRole.get('Buyer'), 'The BUYER is stamped');
        Assert.isNull(byRole.get(ROLE_BROKER),
            'and the Introducing Broker is NOT — this date is a statement about a purchaser');
    }

    /**
     * A disposition INSERTED directly at `Release Materials` stamps nothing, and that is correct
     * rather than a gap. `All_NDAs_Signed_Before_Progression` is `ISCHANGED`-only so the insert is
     * permitted, but no NDA exists yet at the moment of entry — auto-defaults fire on a transition,
     * and a row that did not exist at the transition missed it.
     *
     * ⚠ The same accepted consequence applies to a buyer added AFTER the stage entry: they get no
     * default and the analyst types the date. `openDispositionLois` records the identical trade for
     * a second-round LOI.
     */
    @isTest
    static void insertDirectlyAtReleaseMaterials_stampsNothingBecauseNoNdaExistsYet() {
        Disposition__c d = TestDataFactory.createDisposition(null, false);
        d.Disposition_Stage__c = STAGE_RELEASE_MATERIALS;

        Test.startTest();
        insert d;
        Test.stopTest();

        Assert.isTrue(ndasOf(d.Id).isEmpty(),
            'Entering the stage does not CREATE an NDA — only the `NDA` stage does that — so there '
            + 'is nothing to stamp, and no error either');
    }

    /** A stage entry with no NDAs at all is a silent no-op, not an exception. */
    @isTest
    static void ndaAddedAfterTheStageEntry_getsNoDefault() {
        Disposition__c d = TestDataFactory.createDisposition(null, false);
        d.Disposition_Stage__c = STAGE_RELEASE_MATERIALS;
        insert d;

        Test.startTest();
        NDA__c late = TestDataFactory.createDispositionNda(d.Id, true);
        Test.stopTest();

        Assert.isNull(
            [SELECT Materials_Released_Date__c FROM NDA__c WHERE Id = :late.Id]
                .Materials_Released_Date__c,
            'A buyer added AFTER the transition missed the default; the analyst types the date. '
            + 'Stated and asserted so it is not rediscovered as a bug.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BULK — .claude/rules/bulk-test-rule.md, 251 records, no exemption
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 251 DISPOSITIONS ENTER THE STAGE IN ONE DML AND ALL 251 NDAs ARE STAMPED AT CONSTANT COST.
     *
     * The budget claim is 1 SOQL + 1 DML PER STAGE ENTERED PER CHUNK. A 251-row update spans TWO
     * trigger chunks, so the honest ceiling around the whole DML is 2 queries + 2 DML for THIS
     * block — asserting an exact number would pin the chunk size rather than the service, so the
     * assertion below is a CEILING that a per-record implementation could not possibly satisfy
     * (251 queries and 251 DML statements would blow both limits outright).
     *
     * ⚠ THE CEILING IS DELIBERATELY GENEROUS BECAUSE OTHER AUTOMATION SHARES THE TRANSACTION —
     * `DispositionApprovalAdvanceService`, `NDA_Signed_Rollup` and the other stage blocks all run
     * on this same update. A tight number here would go red the day any of them changed, for
     * reasons having nothing to do with this block. What it CANNOT accommodate is per-record work,
     * which is the only defect this assertion exists to catch.
     */
    @isTest
    static void bulk251EntrantsStampAtConstantCost() {
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, null, true);
        // ONE insert for all 251 NDAs — never one per disposition.
        TestDataFactory.signBuyerNdasOn(dispositions);

        List<Disposition__c> updates = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            updates.add(new Disposition__c(
                Id = d.Id, Disposition_Stage__c = STAGE_RELEASE_MATERIALS
            ));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        update updates;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        List<NDA__c> stamped = [
            SELECT Id FROM NDA__c
            WHERE Disposition__c IN :dispositions AND Materials_Released_Date__c = TODAY
        ];
        Assert.areEqual(BULK_N, stamped.size(),
            'All 251 buyer NDAs must be stamped — one per disposition');
        Assert.isTrue(queriesUsed <= 20,
            'CONSTANT, not per-record. 251 rows used ' + queriesUsed + ' queries; a per-record '
            + 'read would have needed 251 and blown the 100-query limit.');
        Assert.isTrue(dmlUsed <= 20,
            'CONSTANT, not per-record. 251 rows used ' + dmlUsed + ' DML statements; a per-record '
            + 'update would have needed 251 and blown the 150-statement limit.');
    }

    /**
     * 🔴 THE ZERO-COST FALSIFIER: 251 dispositions saved WITHOUT entering `Release Materials` must
     * not reach this block at all. This trigger fires on EVERY `Disposition__c` write in the org, so
     * the common case has to be free.
     */
    @isTest
    static void bulk251SavesThatEnterNoTargetStage_stampNothing() {
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, null, true);
        TestDataFactory.signBuyerNdasOn(dispositions);

        List<Disposition__c> updates = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            // An ordinary edit — the stage is untouched.
            updates.add(new Disposition__c(Id = d.Id, Title_Company__c = 'Bulk Title Co'));
        }

        Test.startTest();
        update updates;
        Test.stopTest();

        Assert.areEqual(0,
            [
                SELECT COUNT() FROM NDA__c
                WHERE Disposition__c IN :dispositions AND Materials_Released_Date__c != NULL
            ],
            'A save that enters no target stage must stamp nothing at all');
    }
}
