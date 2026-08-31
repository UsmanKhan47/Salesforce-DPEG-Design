/**
 * Tests for `StageDelayService` — the thresholds, the stall bands and the suppression rule.
 *
 * ── WHY ALMOST NOTHING HERE TOUCHES THE DATABASE ────────────────────────────
 * The class under test is PURE: `evaluate` and `shouldFire` take a clock as an argument and hold no
 * SOQL and no DML. That is the property that makes every band reachable without a frozen-clock hack
 * and every suppression case reachable without running a batch — so these tests exercise it
 * directly, at the cost of one governor unit total. `chunkPurityIsMeasuredNotAsserted` pins the
 * purity itself, because it is the property the batch's whole governor budget rests on.
 *
 * ── 🔴 THE THRESHOLDS ARE INJECTED, NEVER READ FROM THE ORG ─────────────────
 * **A test cannot insert a `__mdt` row via DML**, and `Stage_Threshold_Def__mdt`'s rows are
 * script-loaded rather than deployed (`scripts/load-stage-threshold-defs.apex`, post-deploy step
 * P3) — so an org running this suite may legitimately have NONE, and a test that read the org's
 * live rows would be green here and red there, or worse, green for the wrong reason. Every test
 * below installs its own rows through `overrideThresholdsForTest` and clears them afterwards. Same
 * seam, same reason, as `CallForOffersServiceTest`.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not bite on THIS class — it holds
 * no DML and no locator, so there is nothing a 251-row fixture would exercise that a 3-row one does
 * not. The mandate is met in full by `StageDelayAlertBatchTest`, which is the class that actually
 * runs a chunk. `.claude/rules/content-publication-rule.md` does not apply: nothing in this feature
 * creates a `ContentVersion`, a `ContentNote` or a `ContentDocument`.
 */
@isTest
private class StageDelayServiceTest {

    private static final Date TODAY = Date.newInstance(2026, 8, 31);

    /** One active threshold row. `label` is only ever a human aid; nothing in Apex reads it. */
    private static Stage_Threshold_Def__mdt row(String stageValue, Integer days, Boolean active) {
        return new Stage_Threshold_Def__mdt(
            DeveloperName = 'Stage_' + stageValue.replaceAll('[^A-Za-z0-9]', '_'),
            Stage_Value__c = stageValue,
            Threshold_Days__c = days,
            Is_Active__c = active
        );
    }

    /** The shipped-shape configuration: a flat 14 across the stages these tests use. */
    private static void installFlat14() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, true),
            row('Underwriting', 14, true),
            row('LOI', 14, true)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THRESHOLD RESOLUTION — the three degenerate inputs get three answers
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void noRowsAtAllFallsBackToAFlatFourteenForEveryOpenStage() {
        // 🔴 THE MOST VALUABLE TEST IN THIS CLASS. CMDT records are not deployable in this repo, so
        // "the loader was never run" is the state the org is in the moment this feature deploys.
        // Without the fallback the job would classify every deal as not-delayed and log a healthy
        // all-zeros summary — a dead feature that looks shipped. If someone deletes
        // DEFAULT_THRESHOLD_DAYS on the grounds that the loader exists, this goes red.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>());

        Assert.areEqual(14, StageDelayService.thresholdFor('New'),
            'With no rows at all every OPEN stage falls back to the shipped 14 days');
        Assert.areEqual(14, StageDelayService.thresholdFor('Under Review'), 'Under Review too');
        Assert.areEqual(14, StageDelayService.thresholdFor('Development Review'), 'Land-only stage');
        Assert.areEqual(14, StageDelayService.thresholdFor('Construction Review'), 'Retail-only stage');
        Assert.areEqual(14, StageDelayService.thresholdFor('Underwriting'), 'Underwriting too');
        Assert.areEqual(14, StageDelayService.thresholdFor('LOI'), 'LOI too');
        Assert.areEqual(14, StageDelayService.thresholdFor('Under Contract (PSA)'),
            'including the one whose name carries parentheses');
        Assert.areEqual(14, StageDelayService.thresholdFor('About to Close'), 'About to Close too');

        // 🔴 AND THE CLOSED STAGES GET NOTHING, EVEN IN THE FALLBACK. Belt to the selector's braces:
        // if `IsClosed = FALSE` were ever dropped from the locator, a Dead/Pass deal reaching this
        // service would still not be chased.
        Assert.isNull(StageDelayService.thresholdFor('Closed Won'),
            'Closed Won is never chased — it is not in the fallback list');
        Assert.isNull(StageDelayService.thresholdFor('Dead/Pass'),
            'and neither is Dead/Pass');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void rowsThatExistButAreAllInactiveSwitchTheFeatureOffRatherThanFallingBack() {
        // 🔴 THE DISTINCTION FROM THE TEST ABOVE IS THE ENTIRE REASON resolveThresholds COUNTS ROWS
        // AND ACTIVE ROWS SEPARATELY. An admin unchecking every Is_Active__c is DELIBERATELY
        // switching the reminder off; falling back to 14 here would make that intent unexpressible.
        // Collapsing the two cases into one `isEmpty()` test reds this method and nothing else.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, false),
            row('Underwriting', 21, false)
        });

        Assert.isNull(StageDelayService.thresholdFor('New'),
            'Rows exist but none is active, so the configuration is honoured as EMPTY');
        Assert.isNull(StageDelayService.thresholdFor('Underwriting'), 'for every stage');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void aStageWithNoRowIsNotTrackedWhileItsSiblingsStillAre() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, true),
            row('Underwriting', 30, true),
            row('LOI', 7, false)
        });

        Assert.areEqual(14, StageDelayService.thresholdFor('New'), 'Active rows govern');
        Assert.areEqual(30, StageDelayService.thresholdFor('Underwriting'),
            'and a per-stage value is honoured — the flat 14 is a shipped CONFIGURATION, not a rule');
        Assert.isNull(StageDelayService.thresholdFor('LOI'),
            'An inactive row is the same as no row: that one stage is switched off');
        Assert.isNull(StageDelayService.thresholdFor('About to Close'),
            'and a stage with no row at all is simply not tracked — once ANY row exists the '
            + 'fallback list is not consulted');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void theStageKeyIsMatchedCaseInsensitivelyAndIgnoresSurroundingSpace() {
        // 🔴 THE TRAP THIS PINS: Apex `==` on String is case-INSENSITIVE but `Map<String,..>.get()`
        // is case-SENSITIVE. An admin typing `under review` into Stage_Value__c would get a silent
        // miss and a stage that never alerts, with nothing anywhere reporting it.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('under review', 14, true),
            row('  Underwriting  ', 21, true)
        });

        Assert.areEqual(14, StageDelayService.thresholdFor('Under Review'),
            'A lower-cased Stage_Value__c still matches the real StageName API value');
        Assert.areEqual(21, StageDelayService.thresholdFor('UNDERWRITING'),
            'and the lookup side is case-folded too, so neither end has to be exact');
        Assert.areEqual(21, StageDelayService.thresholdFor('Underwriting'),
            'and stray whitespace around a hand-typed Stage_Value__c is trimmed');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void incompleteRowsAreSkippedRatherThanCrashingTheJob() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, true),
            new Stage_Threshold_Def__mdt(
                DeveloperName = 'Stage_Blank', Stage_Value__c = null,
                Threshold_Days__c = 14, Is_Active__c = true
            ),
            new Stage_Threshold_Def__mdt(
                DeveloperName = 'Stage_NoDays', Stage_Value__c = 'LOI',
                Threshold_Days__c = null, Is_Active__c = true
            ),
            null
        });

        Assert.areEqual(14, StageDelayService.thresholdFor('New'),
            'A good row survives its broken neighbours');
        Assert.isNull(StageDelayService.thresholdFor('LOI'),
            'A row with no Threshold_Days__c is an incomplete record, not an instruction: it is '
            + 'SKIPPED, so LOI is untracked rather than tracked at zero days');

        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE LOCATOR CEILING
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void theCeilingIsTheSmallestActiveThresholdBecauseItIsTheWidestNet() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 30, true),
            row('Underwriting', 7, true),
            row('LOI', 60, true),
            row('About to Close', 3, false)
        });

        Assert.areEqual(TODAY.addDays(-7), StageDelayService.locatorCeiling(TODAY),
            'The SMALLEST ACTIVE threshold sets the ceiling — a larger one would exclude rows the '
            + 'in-memory check still needs to see. The inactive 3-day row must NOT narrow it');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void theCeilingFallsBackToTheShippedThresholdWhenNothingIsConfigured() {
        // Two very different configurations, ONE ceiling, and deliberately so: an empty
        // configuration is enforced IN MEMORY (thresholdFor returns null for every stage, so
        // nothing fires). Letting the ceiling also carry that meaning would put one rule in two
        // places, and the header says so. The cost is a bounded read that produces no work.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>());
        Assert.areEqual(TODAY.addDays(-14), StageDelayService.locatorCeiling(TODAY),
            'No rows at all: the ceiling matches the fallback threshold');

        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, false)
        });
        Assert.areEqual(TODAY.addDays(-14), StageDelayService.locatorCeiling(TODAY),
            'and an all-inactive configuration reads the same, because the ceiling is a CHEAPNESS '
            + 'bound and never a correctness bound');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void theCeilingReadsTheClockWhenItIsNotGivenOne() {
        installFlat14();
        Assert.areEqual(Date.today().addDays(-14), StageDelayService.locatorCeiling(null),
            'A null asOf is treated as today rather than throwing inside a batch start()');
        StageDelayService.clearThresholdOverrideForTest();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // evaluate — the four bands, and the boundary
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aDealWithNoEntryDateIsUnmeasurableRatherThanBrandNew() {
        // 🔴 The un-backfilled legacy population (post-deploy step P4). Collapsing "no entry date"
        // into "entered today" would make the whole back catalogue look brand new; collapsing it the
        // other way would alert on all of it at once on day one. Neither is right, so it is its own
        // band and it never fires.
        installFlat14();

        StageDelayService.StageDelay d = StageDelayService.evaluate('New', null, TODAY);

        Assert.areEqual('NO_ENTRY_DATE', d.status, 'There is no anchor, so nothing can be measured');
        Assert.isFalse(d.isDelayed, 'and an unmeasurable deal is never delayed');
        Assert.isNull(d.daysInStage, 'with no day count at all — not zero');
        Assert.isFalse(
            StageDelayService.shouldFire(d.isDelayed, 'New', null, null, null),
            'so it can never fire, whatever its marker says');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void anUntrackedStageIsCountedButNeverChased() {
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 14, true)
        });

        StageDelayService.StageDelay d =
            StageDelayService.evaluate('About to Close', TODAY.addDays(-900), TODAY);

        Assert.areEqual('NOT_TRACKED', d.status, 'No active row for this stage');
        Assert.isFalse(d.isDelayed, 'so it is not chased no matter how long it has sat there');
        Assert.areEqual(900, d.daysInStage,
            'but the day count is still derived, so a badge could show it without a second rule');
        Assert.isNull(d.thresholdDays, 'and there is no threshold to report');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void theBoundaryIsAtOrPastTheThresholdNotStrictlyPast() {
        // The single most likely off-by-one in the feature. A deal that entered exactly 14 days ago
        // has BEEN in the stage for 14 days; `> threshold` would make the shipped "14 days" mean 15.
        installFlat14();

        StageDelayService.StageDelay onDay13 =
            StageDelayService.evaluate('Underwriting', TODAY.addDays(-13), TODAY);
        StageDelayService.StageDelay onDay14 =
            StageDelayService.evaluate('Underwriting', TODAY.addDays(-14), TODAY);
        StageDelayService.StageDelay onDay15 =
            StageDelayService.evaluate('Underwriting', TODAY.addDays(-15), TODAY);

        Assert.areEqual('ON_TRACK', onDay13.status, 'Day 13 of a 14-day threshold is still healthy');
        Assert.isFalse(onDay13.isDelayed, 'and does not fire');
        Assert.areEqual('DELAYED', onDay14.status, 'Day 14 IS the threshold and it is inclusive');
        Assert.isTrue(onDay14.isDelayed, 'so day 14 fires');
        Assert.areEqual('DELAYED', onDay15.status, 'and everything past it stays delayed');
        Assert.areEqual(14, onDay14.thresholdDays,
            'The state reports the threshold it was measured against, so a consumer never has to '
            + 'look it up a second time and cannot look it up differently');
    }

    @isTest
    static void theRenderedStringsAreLocaleIndependentAndSharedWithEveryConsumer() {
        // The batch puts `label` in the notification title and `detail` in its body. Pinning them
        // here is what stops a future badge and the bell describing the same stall two ways — and
        // the date format is hand-rolled precisely so this assertion is not silently
        // locale-dependent (green here, red on a box with another default).
        installFlat14();

        StageDelayService.StageDelay d =
            StageDelayService.evaluate('Underwriting', Date.newInstance(2026, 8, 11), TODAY);

        Assert.areEqual('20 days in Underwriting', d.label, 'The badge line');
        Assert.areEqual(
            'This deal has been in Underwriting since Aug 11, 2026 — 20 days, past the 14-day threshold.',
            d.detail,
            'and the sentence, with a fixed Mmm D, YYYY date that does not move with the locale');

        StageDelayService.StageDelay oneDay =
            StageDelayService.evaluate('New', TODAY.addDays(-1), TODAY);
        Assert.areEqual('1 day in New', oneDay.label, 'and the singular is not "1 days"');
    }

    @isTest
    static void aNullClockIsTreatedAsTodayRatherThanThrowingInsideAChunk() {
        installFlat14();
        StageDelayService.StageDelay d =
            StageDelayService.evaluate('New', Date.today().addDays(-20));
        Assert.isTrue(d.isDelayed,
            'The convenience overload reads the clock — the one deliberately impure entry point');
        Assert.areEqual(20, d.daysInStage, 'counted from today');

        StageDelayService.StageDelay guarded =
            StageDelayService.evaluate('New', Date.today().addDays(-20), null);
        Assert.areEqual(20, guarded.daysInStage,
            'and a null asOf is guarded rather than raising a NullPointerException in a batch');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴 shouldFire — ONCE PER STAGE OCCUPANCY, AND THE TWO RE-ARM LEGS
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void anUndelayedDealNeverFiresHoweverBlankItsMarkerIs() {
        Assert.isFalse(
            StageDelayService.shouldFire(false, 'New', TODAY.addDays(-1), null, null),
            'Not delayed is the first gate and nothing downstream can open it');
        Assert.isFalse(
            StageDelayService.shouldFire(null, 'New', TODAY.addDays(-1), null, null),
            'and a null isDelayed is treated as false rather than as unknown');
    }

    @isTest
    static void aDelayedDealWithNoMarkerFiresOnceAndThenIsSilent() {
        Date entry = TODAY.addDays(-20);

        Assert.isTrue(StageDelayService.shouldFire(true, 'New', entry, null, null),
            'No marker at all: the first reminder is owed');
        Assert.isFalse(StageDelayService.shouldFire(true, 'New', entry, 'New', TODAY),
            'Once marked for THIS occupancy it is silent — the user decision is one reminder per '
            + 'stage occupancy, not an escalating ladder');
        Assert.isFalse(
            StageDelayService.shouldFire(true, 'New', entry, 'New', TODAY.addDays(60)),
            'and it stays silent indefinitely, which is what stops a year-old stuck deal being '
            + 'reported 365 times');
    }

    @isTest
    static void movingToADifferentStageReArmsTheReminder() {
        // LEG A. Without it a deal that moved on and stalled again would be PERMANENTLY SILENT —
        // on exactly the deals someone cared enough to progress.
        Date newEntry = TODAY.addDays(-20);

        Assert.isTrue(
            StageDelayService.shouldFire(true, 'Underwriting', newEntry, 'New', TODAY.addDays(-40)),
            'The marker is about a stage the deal has left, so it does not suppress the new one');
    }

    @isTest
    static void leavingAndReEnteringTheSameStageReArmsTheReminder() {
        // 🔴 LEG B, AND IT IS THE ONE LEG A CANNOT COVER — the stage name is UNCHANGED, so leg A is
        // blind to it. This is why the marker snapshots BOTH the stage and the date. A deal that
        // goes New -> Underwriting -> New has entered New again and its clock restarts
        // (OpportunityStageEntryService overwrites Stage_Entry_Date__c unconditionally on a
        // transition, precisely so this is true).
        Date firstOccupancySent = TODAY.addDays(-40);
        Date reEnteredOn = TODAY.addDays(-20);

        Assert.isTrue(
            StageDelayService.shouldFire(true, 'New', reEnteredOn, 'New', firstOccupancySent),
            'The anchor moved forward past the marker: this is a NEW occupancy of the same stage');
        Assert.isFalse(
            StageDelayService.shouldFire(true, 'New', reEnteredOn, 'New', TODAY.addDays(-6)),
            'but a marker written INSIDE the current occupancy still suppresses');
    }

    @isTest
    static void aSameDayReEntryStillReArms_whichIsWhyLegBUsesLessThanOrEqual() {
        // 🔴 THE ONE-CHARACTER DEVIATION FROM THE DESIGN DOCUMENT'S LITERAL `<`, PINNED SO NOBODY
        // "CORRECTS" IT BACK. A deal reminded on day 14 that bounces out of and back into the SAME
        // stage on that SAME day ends with markerSentDate == liveStageEntryDate. With `<` neither
        // leg fires and that occupancy is silent FOREVER. With `<=` it re-arms — and it cannot
        // double-fire, which the next assertion is the control for.
        Date sameDay = TODAY;

        Assert.isTrue(
            StageDelayService.shouldFire(true, 'New', sameDay, 'New', sameDay),
            'markerSentDate == entryDate is a same-day re-entry and MUST re-arm');

        // THE CONTROL. Firing requires daysInStage >= threshold >= 1, so a marker written inside an
        // occupancy always carries a date STRICTLY LATER than that occupancy's entry date. `<=`
        // therefore cannot produce a second reminder within one occupancy at any shipped threshold.
        Assert.isFalse(
            StageDelayService.shouldFire(true, 'New', TODAY.addDays(-14), 'New', TODAY),
            'A real in-occupancy marker (entry + 14) is still strictly later than the entry date, '
            + 'so `<=` does not reintroduce the daily-spam failure');
    }

    @isTest
    static void halfAMarkerIsTreatedAsNoMarkerAndReArms() {
        Date entry = TODAY.addDays(-20);

        Assert.isTrue(StageDelayService.shouldFire(true, 'New', entry, 'New', null),
            'A stage with no date is not an instruction');
        Assert.isTrue(StageDelayService.shouldFire(true, 'New', entry, null, TODAY),
            'and neither is a date with no stage');
        Assert.isTrue(StageDelayService.shouldFire(true, 'New', entry, '   ', TODAY),
            'nor a blank one. An extra reminder is recoverable; a permanently silent deal is not');
    }

    @isTest
    static void aNullEntryDateCannotSuppressLegBIntoFiringSpuriously() {
        // Defensive but reachable: the locator excludes null entry dates, and evaluate() would have
        // returned isDelayed = false anyway — but shouldFire is PUBLIC and takes isDelayed as an
        // argument, so a future caller could hand it this shape.
        Assert.isFalse(
            StageDelayService.shouldFire(true, 'New', null, 'New', TODAY),
            'With no anchor there is nothing for leg B to compare against, so the marker stands');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PURITY — the property the batch's whole governor budget rests on
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void chunkPurityIsMeasuredNotAsserted() {
        // 🔴 `StageDelayAlertBatch` claims "0 SOQL of its own per chunk, constant in chunk size".
        // That claim is only true because THIS class never queries — including
        // `Stage_Threshold_Def__mdt.getAll()`, which is a metadata accessor and not SOQL. Measured
        // over 300 evaluations so that a per-record query would be unmissable rather than lost in
        // the noise. ⚠ Measured INSIDE the test transaction and BEFORE any stopTest, because
        // Test.stopTest() restores the pre-test counters and makes the obvious reading vacuous.
        StageDelayService.clearThresholdOverrideForTest();
        installFlat14();

        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        for (Integer i = 0; i < 300; i++) {
            StageDelayService.StageDelay d =
                StageDelayService.evaluate('Underwriting', TODAY.addDays(-i), TODAY);
            StageDelayService.shouldFire(d.isDelayed, 'Underwriting', TODAY.addDays(-i), 'New', TODAY);
            StageDelayService.thresholdFor('LOI');
        }

        Assert.areEqual(queriesBefore, Limits.getQueries(),
            '300 evaluations must consume ZERO queries — a CMDT getAll() is not SOQL, and if that '
            + 'ever changes the batch header\'s governor claim is false');
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(),
            'and zero DML: the marker write belongs to the batch, which owns the transaction');

        StageDelayService.clearThresholdOverrideForTest();
    }

    @isTest
    static void theThresholdsResolveOncePerTransactionRatherThanPerCall() {
        // The cache is a CORRECTNESS property, not a speed trick: without it an admin saving a row
        // mid-chunk could measure deal 3 against 14 days and deal 190 against 21, and the marker
        // written for each would be measured against a different configuration.
        installFlat14();
        Assert.areEqual(14, StageDelayService.thresholdFor('New'), 'PRECONDITION');

        // Injecting a different set WITHOUT clearing proves the read goes through the cache: the
        // override seam itself re-resolves, so the new value must be visible immediately after it
        // and the old one must not survive.
        StageDelayService.overrideThresholdsForTest(new List<Stage_Threshold_Def__mdt>{
            row('New', 21, true)
        });
        Assert.areEqual(21, StageDelayService.thresholdFor('New'),
            'A deliberate re-injection is honoured');

        StageDelayService.clearThresholdOverrideForTest();
    }
}
