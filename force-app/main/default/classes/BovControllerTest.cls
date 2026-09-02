/**
 * @description Test class for BovController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Read-only class (no DML), already at 100% reported coverage; adds an ordering
 * determinism test, an empty-list scenario, a below-threshold
 * matrixGenerated boundary, a delete-based negative scenario, and a 251-record
 * data-volume read test per .claude/rules/bulk-test-rule.md.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 `BOV_Score__c` IS NOW A FORMULA — RETRACTED 2026-08-22 (conversion completed)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * This paragraph used to describe a FUTURE conversion and named a specific coverage gap at
 * `BovController.cls:87` (`r.bovScore = s.BOV_Score__c != null ? s.BOV_Score__c.intValue() :
 * null;`). Both are stale now that the conversion has happened
 * (manifest/bov-score-formula-conversion/) and are quoted rather than deleted so a reader who
 * remembers the old shape isn't left guessing what changed:
 *   1. `BovRow.bovScore` was `Integer` and is now `Decimal` — the formula is Number(5,2) and
 *      carries up to 2 decimal places (e.g. 68.81); `.intValue()` would have silently truncated
 *      every score.
 *   2. The ternary is GONE. `BovController.cls` now reads `r.bovScore = s.BOV_Score__c;` —
 *      unconditional, no null-guard, no truncation, no branch. The "unreachable `.intValue()`
 *      leg" coverage gap this header used to name is therefore not just covered, it no longer
 *      EXISTS as a branch to cover.
 * Two tests below (`testGetSubmissions_mapsEveryRowFieldToTheRightRecord` and
 * `testGetSubmissions_tiedScores_orderIsDeterministicOldestFirst`) still assert `bovScore` is
 * null — that is NOT the same stale claim. It is still true today because the fixtures sit under a
 * plain `TestDataFactory` Property Asset, which carries NO `Target_Sale_Price__c`, so the formula's
 * guard clause returns null for every fixture in this file regardless of the conversion being
 * complete.
 * ⚠ AMENDED 2026-08-25 — THE FIELD THAT MAKES THAT TRUE CHANGED, AND SO DID WHERE IT LIVES. The
 * basis was `Disposition__c.Asking_Price__c`, which the factory never set; it is now
 * `Property_Asset__c.Target_Sale_Price__c`, TWO hops out, which the factory DID set until the
 * default was removed in that same change (read its comment in `TestDataFactory`). The assertions
 * below are unchanged; the reason they hold is not.
 * What is genuinely owed and NOT yet added here: a test that gives its own fixture's ASSET a real
 * `Target_Sale_Price__c` and asserts a non-null, non-truncated score (e.g. against the
 * hand-verified BOV-0015 / BOV-0017 values in
 * `manifest/bov-score-formula-conversion/step3-package.xml`) — see
 * `BovSubmissionSelectorTest`'s header for the same deferred-coverage list, item 3.
 * 🔴 Do NOT close the null-fixture gap by adding a @TestVisible seam or by making `bovScore`
 * writable — the whole point of the conversion is that the score is derived and nothing can
 * write it. Price the fixture's ASSET instead (`TestDataFactory.createPricedDisposition`).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * DISPOSITION FOUNDATIONS: OutreachSummary.ndaStatus
 * ─────────────────────────────────────────────────────────────────────────────────────
 * The BOV Outreach tile used to render a hard-coded "Signed" NDA pill, misreporting a
 * COMPLIANCE state on every disposition. It now carries the real Status__c of the
 * disposition's most recent NDA__c, or null when there is none.
 *
 * ⚠ THE FAIL-SOFT CATCH IN BovController.readNdaStatusFailSoft IS NOT COVERED HERE, AND
 * THAT IS A KNOWN, ACCEPTED GAP — not an oversight. It only fires when the running user
 * can read Disposition__c but NOT NDA__c, and there is no way to construct that principal
 * in Apex in this org: a bare Standard User throws on the Disposition read FIRST (which is
 * what readPathsThrowAuraHandledException exercises), and every permission set that grants
 * Disposition__c now also grants NDA__c (Gate 1 Q7), so no assignable persona sits in the
 * gap. Design §5.6 says the same thing in general terms — "an FLS test that runs as an
 * admin cannot fail" — and names persona acceptance testing (§8 gate B5) as the only real
 * proof. A @TestVisible seam was deliberately NOT added: it would put test-only branching
 * into a live read path to cover three lines of defence-in-depth.
 *
 * ⚠ THERE ARE NOW **TWO** SUCH CATCHES AND THE SAME ARGUMENT COVERS BOTH (2026-09-01, Tranche 4
 * item 2). `BovController.countComparableResponsesFailSoft` — which is what `matrixGenerated` now
 * derives from — carries an identically-shaped fail-soft catch, and it is uncovered for the same
 * structural reason: reaching it needs a principal who can read `Disposition__c` but NOT
 * `BOV_Submission__c`, and no assignable persona in this org sits in that gap (both disposition
 * permission sets grant the two together). `readPathsThrowAuraHandledException`'s bare Standard
 * User cannot reach it either — `DispositionSelector.selectOutreachById` throws FIRST, one line
 * earlier in the same method, so the outer catch fires and the new read is never attempted.
 * 🔴 THAT ORDERING IS ALSO WHY THAT TEST STAYED GREEN through this change rather than needing
 * repair, and it is worth knowing: if the comparable-response read is ever moved ABOVE the
 * disposition read, that test's second assertion starts passing for a different reason and this
 * paragraph becomes wrong. The same "no @TestVisible seam in a live read path" decision applies.
 * @author Unit Testing Agent
 */
@isTest
private class BovControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'BOV Outreach';
        d.Package_Sent__c = Date.today().addDays(-15);
        d.Submission_Deadline__c = Date.today().addDays(1);
        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 RE-EXAMINED 2026-08-31 (Tranche 1 item 7) — `Responses_Received__c` NOW HAS A WRITER,
        //    AND THIS HAND-SET VALUE SURVIVES. THE ANSWER IS "STILL VALID", AND THE REASON IS
        //    NARROW ENOUGH THAT A FUTURE EDIT COULD DESTROY IT WITHOUT NOTICING.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // `DispositionCounterRollupService` recomputes this field from the live `BOV_Submission__c`
        // count, but ONLY from `BovSubmissionTrigger` — i.e. only when a SUBMISSION is saved. This
        // line is part of a `Disposition__c` insert with zero submissions in existence, so nothing
        // fires and the 4 stands.
        //
        // ⚠ RE-EXAMINED AGAIN 2026-09-01 (Tranche 4 item 2) AND THE ANSWER FLIPPED FROM "STILL
        //   VALID" TO "NO LONGER RELIED ON". The paragraph below is QUOTED rather than deleted,
        //   because its warning is what told the editor how to fix the tests:
        //
        //     RETRACTED: "The two tests that ASSERT on it were checked one by one and neither is
        //     vacuous: `testGetOutreachSummary_positiveScenario` — creates NO submissions, so 4
        //     stands. `testGetOutreachSummary_belowThreshold_...` — writes 2 by a Disposition
        //     update, also with no submissions. 2 stands."
        //
        //   `matrixGenerated` no longer derives from this field at all — it counts the NON-PREFERRED
        //   submissions the comparison matrix renders (`BovController.OutreachSummary.matrixGenerated`
        //   argues why). A fixture with zero submissions and a hand-typed 4 therefore asserted a
        //   generated matrix on a sale where no broker had responded, which could only ever pass
        //   vacuously. BOTH tests were repointed to insert real rows, exactly as the surviving
        //   sentence below instructs, so the counter is now written by
        //   `DispositionCounterRollupService` and this hand-set 4 is overwritten in every
        //   outreach-summary test. It still stands for any FUTURE test that inserts no submissions.
        //
        // 🔴 THE TRAP FOR THE NEXT EDITOR — STILL LIVE AND NOW ALSO THE PRESCRIBED FIX: adding ONE
        // `TestDataFactory.createBovSubmission(...)` to a test that asserts this literal would
        // silently move `responsesReceived` to the real row count and the assertion would fail with
        // a number nobody wrote. If a fixture needs both submissions AND a specific summary count,
        // the honest fix is to insert exactly that many submissions — not to re-set the field
        // afterwards, which the next child save undoes. See `respondersOn(...)` below.
        // ⚠ `Brokers_Contacted__c` is NOT trigger-owned and stays hand-set: it counts brokers
        // ASKED, which no child row records.
        d.Responses_Received__c = 4;
        d.Brokers_Contacted__c = 6;
        d.Selected_Broker__c = 'CBRE - Mark Chen';
        insert d;
    }

    /**
     * ── RENAMED FROM `..._ordersByScoreDescending` (re-authored 2026-08-21) ──────────────────
     * The old name and its `rows[0].brokerFirm == 'CBRE'` assertion were carried entirely by two
     * hard-coded `BOV_Score__c` assignments (91 and 84). `BOV_Score__c` is being recreated as a
     * FORMULA and cannot be assigned in Apex, so the fixture could no longer produce two different
     * scores and the ordering claim became unprovable — see this class's header for what is owed.
     * ⚠ That header line used to end "once `Disposition__c.Asking_Price__c` and the formula ship".
     * The formula shipped; `Asking_Price__c` was then retired (2026-08-25) and the basis moved to
     * `Property_Asset__c.Target_Sale_Price__c`. What is owed is unchanged — the field to set is.
     *
     * 🔴 WHAT SURVIVED IS THE PART THAT WAS NEVER ABOUT THE SCORE: that `getSubmissions` maps every
     * BovRow member off the right record. Those assertions are now keyed BY RECORD ID instead of by
     * list position, which makes them STRICTER, not looser — the old positional form would have
     * passed if the mapping were correct and the order wrong, or if two rows' fields were swapped
     * consistently. Ordering is proved separately, by the test below.
     */
    @isTest
    static void testGetSubmissions_mapsEveryRowFieldToTheRightRecord() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        // 🔴 Broker_Firm__c IS PINNED VIA Broker__c, NOT A HAND-TYPED LITERAL, AS OF 2026-08-20
        // (Tranche 2, requirements §3 D1). BovSubmissionBrokerStampService overwrites any
        // hand-typed Broker_Firm__c the instant Broker__c is set (which is now every save) — see
        // that service's header ("the stamp wins") and TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c winner = TestDataFactory.createBovSubmission(d.Id, false);
        winner.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE', true).Id;
        winner.BOV_Amount__c = 28500000;
        winner.Commission_Rate__c = 3.0;
        winner.Days_To_Market__c = 45;
        winner.Hist_Success_Rate__c = 82;
        winner.Submission_Status__c = 'Selected';
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(d.Id, false);
        backup.Broker__c = TestDataFactory.createBrokerContactWithFirm('JLL', true).Id;
        backup.BOV_Amount__c = 27900000;
        backup.Commission_Rate__c = 2.5;
        backup.Days_To_Market__c = 52;
        backup.Hist_Success_Rate__c = 78;
        backup.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ winner, backup };

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two submissions should be returned');
        // Keyed by String, not Id: BovRow.id is declared `String` (BovController.cls:18) because it
        // crosses the @AuraEnabled boundary. Using a Map<Id,...> here would not compile.
        Map<String, BovController.BovRow> byId = new Map<String, BovController.BovRow>();
        for (BovController.BovRow r : rows) {
            byId.put(r.id, r);
        }
        BovController.BovRow winnerRow = byId.get(String.valueOf(winner.Id));
        BovController.BovRow backupRow = byId.get(String.valueOf(backup.Id));
        Assert.isNotNull(winnerRow, 'The Selected submission must be returned');
        Assert.isNotNull(backupRow, 'The Backup submission must be returned');
        Assert.areEqual('CBRE', winnerRow.brokerFirm,
            'The stamped firm must map onto ITS OWN row, not merely appear somewhere in the list');
        Assert.areEqual('JLL', backupRow.brokerFirm, 'and likewise for the other row');
        Assert.areEqual(28500000, winnerRow.bovAmount, 'BOV_Amount__c maps through');
        Assert.areEqual(45, winnerRow.daysToMarket, 'Days_To_Market__c maps through as an Integer');
        Assert.areEqual(true, winnerRow.isSelected, 'Selected status should map to isSelected = true');
        Assert.areEqual(false, backupRow.isSelected, 'Backup status should map to isSelected = false');
        // 🔴 `BovRow.isPreferred` (added 2026-08-24). Asserted as a hard `false`, NOT merely
        // "not true": `c/bovComparisonMatrix` renders twice off this ONE payload and filters on
        // `=== true` / `!== true`, so a value arriving as `undefined` would land the row in the
        // ranked instance by luck rather than by contract. Both directions are pinned — the TRUE
        // case is `getSubmissions_mapsThePreferredBrokerFlag` below.
        Assert.areEqual(false, winnerRow.isPreferred,
            'An ordinary response must map isPreferred = false, not null');
        Assert.areEqual(false, backupRow.isPreferred, 'and likewise for the other row');
        // 🔴 RETRACTED 2026-08-22 (conversion completed). This used to pin a now-deleted ternary's
        // null leg and name a coverage gap on its `.intValue()` leg — both gone, see this class's
        // header. Null is still the only reachable answer HERE because this fixture's Disposition
        // (@testSetup) sits under an asset with no Target_Sale_Price__c — which is a property of
        // the FIXTURE, not of the production code path. ⚠ The basis moved from the Disposition's
        // own (now retired) Asking_Price__c to the asset on 2026-08-25; this stayed null only
        // because TestDataFactory.createPropertyAssets lost its Target_Sale_Price__c default in
        // the same change.
        Assert.isNull(winnerRow.bovScore,
            'bovScore passes through as null while nothing can write or derive a score');
        Assert.isNull(backupRow.bovScore, 'and likewise for the other row');
        // 🔴 `BovRow.name` (added 2026-08-21) — the Select/Replace Broker picker's ONLY
        // disambiguator when two options share a firm AND a contact name, which six broker
        // Contacts in this org genuinely do. Compared against a fresh read because `Name` is an
        // AUTO-NUMBER (measured: type string, autoNumber true) — the sequence value belongs to the
        // org, not to this fixture. What the assertion pins is the MAPPING: point `r.name` at the
        // wrong record, or drop `Name` from the selector's SELECT list, and it fails (the latter as
        // an SObjectException the controller masks into READ_FAILURE_MESSAGE, so the whole test
        // fails rather than this line).
        Map<Id, BOV_Submission__c> named = new Map<Id, BOV_Submission__c>([
            SELECT Id, Name FROM BOV_Submission__c WHERE Disposition__c = :d.Id
        ]);
        Assert.areEqual(named.get(winner.Id).Name, winnerRow.name,
            'The submission auto-number must map onto ITS OWN row');
        Assert.areEqual(named.get(backup.Id).Name, backupRow.name, 'and likewise for the other');
        Assert.areNotEqual(winnerRow.name, backupRow.name,
            'PREMISE — two submissions really do carry different auto-numbers, which is the whole '
            + 'reason the picker can lean on this field to separate duplicate brokers');
    }

    /**
     * ── REPLACES `testGetSubmissions_nullScore_sortsLast` (re-authored 2026-08-21) ───────────
     * The old test set one score to 70 and one to null and asserted NULLS LAST pushed the unscored
     * row to the end. Both assignments are gone with the formula conversion, and — more to the
     * point — the situation it modelled has INVERTED: it is no longer one null among scored rows,
     * it is ALL rows null, on every disposition in the org, until an asking price exists.
     *
     * 🔴 THAT MAKES THIS THE HIGHER-VALUE TEST OF THE TWO, because with every score tied at null
     * `ORDER BY BOV_Score__c DESC NULLS LAST` had no effective key left and the matrix reordered
     * between page loads. It pins the fix — `, CreatedDate ASC, Id ASC` — at the CONTROLLER
     * boundary, which is where the LWC actually consumes the order, rather than only in the
     * selector's own test. CreatedDates are set in the reverse of insert order so that insert
     * order cannot masquerade as a passing sort.
     */
    @isTest
    static void testGetSubmissions_tiedScores_orderIsDeterministicOldestFirst() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(3, d.Id, true);
        Test.setCreatedDate(subs[0].Id, System.now().addMinutes(-10));
        Test.setCreatedDate(subs[1].Id, System.now().addMinutes(-20));
        Test.setCreatedDate(subs[2].Id, System.now().addMinutes(-30));

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Three submissions should be returned');
        Assert.isNull(rows[0].bovScore, 'PREMISE — every score ties at null, so DESC decides nothing');
        Assert.areEqual(String.valueOf(subs[2].Id), rows[0].id,
            'The oldest submission must reach the LWC first — with every score tied, CreatedDate '
            + 'ASC is the only key left and without it the matrix reshuffles between page loads');
        Assert.areEqual(String.valueOf(subs[1].Id), rows[1].id, 'then the next-oldest');
        Assert.areEqual(String.valueOf(subs[0].Id), rows[2].id, 'then the newest');
    }

    /**
     * The TRUE half of `BovRow.isPreferred` (added 2026-08-24).
     *
     * 🔴 ONE WIRE FEEDS BOTH MATRIX INSTANCES, WHICH IS WHY THIS FLAG IS ON THE ROW RATHER THAN IN
     * A SECOND APEX METHOD. `c/bovComparisonMatrix` renders twice on the Disposition page — a
     * `preferredOnly` card above the ranked one — and splits THIS payload client-side. Zero extra
     * SOQL, zero extra cache entries, and the two instances cannot disagree about the same broker's
     * numbers.
     *
     * ⚠ IT ALSO PROVES `Is_Preferred_Broker__c` IS ACTUALLY IN THE `WITH USER_MODE` SELECT. If the
     * field is dropped from `selectByDispositionId`, this fails; if the FLS grant is missing in the
     * org, `getSubmissions` throws `No such column` and is masked as the generic read-failure
     * message — so the whole matrix disappears for that persona and this test goes red rather than
     * the defect reaching UAT.
     */
    @isTest
    static void getSubmissions_mapsThePreferredBrokerFlag() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c ordinary = TestDataFactory.createBovSubmission(d.Id, false);
        BOV_Submission__c preferred = TestDataFactory.createBovSubmission(d.Id, false);
        preferred.Is_Preferred_Broker__c = true;
        insert new List<BOV_Submission__c>{ ordinary, preferred };

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        Map<String, BovController.BovRow> byId = new Map<String, BovController.BovRow>();
        for (BovController.BovRow r : rows) {
            byId.put(r.id, r);
        }
        Assert.areEqual(true, byId.get(String.valueOf(preferred.Id)).isPreferred,
            '🔴 A preferred-broker row must arrive flagged, or it renders in the RANKED matrix and '
            + 'becomes auto-selectable — the exact defect the flag exists to prevent');
        Assert.areEqual(false, byId.get(String.valueOf(ordinary.Id)).isPreferred,
            'and an ordinary row must not, or it vanishes out of the ranked matrix entirely');
    }

    @isTest
    static void testGetSubmissions_noSubmissions_returnsEmptyList() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No BOV_Submission__c records exist yet, so the list should be empty');
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251
     * BOV_Submission__c children under one Disposition, inserted via a single
     * bulk DML statement, to prove the row-transform loop in getSubmissions
     * scales without a CPU-time or heap-size breach.
     */
    @isTest
    static void testGetSubmissions_251Submissions_allRowsTransformCleanly() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        TestDataFactory.createBovSubmissions(251, d.Id, true);

        Test.startTest();
        List<BovController.BovRow> rows = BovController.getSubmissions(d.Id);
        Test.stopTest();

        System.assertEquals(251, rows.size(), 'All 251 submissions should be returned and transformed');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 matrixGenerated — THE POPULATION MOVED ON 2026-09-01 (Tranche 4 item 2, decision D-4)
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // `matrixGenerated` used to read `Responses_Received__c >= 3`. It now counts the population
    // `c/bovComparisonMatrix` actually renders — every submission EXCEPT the preferred broker.
    //
    // 🔴 THAT INVALIDATED THE OLD FIXTURE SHAPE, NOT JUST THE OLD ASSERTIONS, AND THE @TestSetup
    // BLOCK PREDICTED IT IN TERMS: "If a fixture needs both submissions AND a specific summary
    // count, the honest fix is to insert exactly that many submissions — not to re-set the field
    // afterwards, which the next child save undoes." Both tests below used to assert a badge state
    // on a disposition carrying ZERO submissions and a hand-typed counter. Under the new
    // derivation that fixture says "no brokers have responded" while claiming a generated matrix —
    // it could only ever have passed vacuously. Every test in this block now inserts REAL rows, so
    // `Responses_Received__c` is written by `DispositionCounterRollupService` and the two numbers
    // are produced by the same data rather than agreeing by hand.
    //
    // ⚠ THE FIXTURES ARE UNPRICED ON PURPOSE (`TestDataFactory.createPropertyAssets` deliberately
    // leaves `Target_Sale_Price__c` null), so every `BOV_Score__c` is null,
    // `BovAutoSelectionService` appoints nobody, and `Selected_Broker__c` on the parent is left
    // exactly as @TestSetup wrote it. That is what keeps the `'CBRE - Mark Chen'` assertion below
    // meaningful rather than accidentally true.

    /**
     * @param comparable how many ordinary (non-preferred) responses to create.
     * @param preferred  how many preferred responses to create — these count toward
     *                   `Responses_Received__c` and NOT toward `matrixGenerated`.
     */
    private static void respondersOn(Id dispositionId, Integer comparable, Integer preferred) {
        List<BOV_Submission__c> rows =
            TestDataFactory.createBovSubmissions(comparable + preferred, dispositionId, false);
        for (Integer i = comparable; i < rows.size(); i++) {
            rows[i].Is_Preferred_Broker__c = true;
        }
        insert rows;
    }

    @isTest
    static void testGetOutreachSummary_positiveScenario() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        respondersOn(d.Id, 4, 0);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(4, s.responsesReceived,
            'Responses received should pass through — and it is now the rollup\'s number, not the '
            + '@TestSetup literal, because four real submissions exist');
        System.assertEquals(true, s.matrixGenerated, '4 comparable responses meets the >= 3 threshold for matrix generation');
        System.assertEquals('CBRE - Mark Chen', s.selectedBroker, 'Selected broker should pass through');
    }

    @isTest
    static void testGetOutreachSummary_belowThreshold_matrixNotGenerated() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        respondersOn(d.Id, 2, 0);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(2, s.responsesReceived,
            'PREMISE — the rollup must have written 2, or the badge assertion below proves nothing');
        System.assertEquals(false, s.matrixGenerated, 'Below the 3-response threshold, the matrix should not be flagged generated');
    }

    /**
     * 🔴 THE BOUNDARY ITSELF, AT EXACTLY 3. Neither pre-existing test sat on it — one used 4 and
     * the other 2 — so an off-by-one in the threshold (`> 3` instead of `>= 3`) would have passed
     * both. This is the test that stops that.
     */
    @isTest
    static void testGetOutreachSummary_exactlyThreeComparable_matrixIsGenerated() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        respondersOn(d.Id, 3, 0);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(3, s.responsesReceived, 'PREMISE — exactly three responses');
        Assert.isTrue(s.matrixGenerated,
            'THE BOUNDARY: three is the threshold, so three comparable responses must generate the '
            + 'matrix. A `> 3` implementation passes every other test in this class and fails here.');
    }

    /**
     * 🔴 THE WHOLE POINT OF TRANCHE 4 ITEM 2, AND THE ONLY TEST THAT CAN FAIL IF THE DERIVATION IS
     * REVERTED TO `Responses_Received__c >= 3`.
     *
     * Three child rows, one of them the PREFERRED broker. `Responses_Received__c` is 3 — correctly,
     * it counts every broker who came back (T1 decision D-9) — and the comparison matrix renders
     * TWO rows, because `c/bovComparisonMatrix._visible` excludes the preferred one. The badge must
     * follow the MATRIX.
     *
     * ⚠ BOTH NUMBERS ARE ASSERTED, DELIBERATELY. Asserting only `matrixGenerated == false` would
     * also pass if someone "fixed" the disagreement by making `countByDispositionIds` skip
     * preferred rows — which would silently redefine `Responses_Received__c`, break the "n of m"
     * tile beside this badge, and contradict `countByDispositionIds_countsEveryStatus_notJustSelected`.
     * Pinning `responsesReceived == 3` in the same test makes the two facts disagree ON PURPOSE and
     * makes that repair fail here.
     */
    @isTest
    static void testGetOutreachSummary_thirdResponseIsPreferred_matrixNotGenerated() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        respondersOn(d.Id, 2, 1);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(3, s.responsesReceived,
            '🔴 THE COUNTER MUST STILL SAY 3. It answers "how many brokers came back", the preferred '
            + 'broker is one of them, and that is Tranche 1 decision D-9. If this drops to 2, the '
            + 'fix was applied to the wrong end and the "n of m" tile is now wrong.');
        Assert.isFalse(s.matrixGenerated,
            '🔴 ...AND THE BADGE MUST STILL SAY NO. Only two of those three rows are comparable — '
            + 'the matrix excludes the preferred broker — so "Matrix Generated ✓" would be sitting '
            + 'above a two-row table with nothing on screen explaining why.');
    }

    /**
     * The other side of the same line: three COMPARABLE rows plus a preferred one is four children,
     * and the badge appears.
     *
     * ⚠ WITHOUT THIS, THE TEST ABOVE IS HALF AN ARGUMENT. An implementation that simply returned
     * `false` whenever any preferred row existed would satisfy it and be wrong — a preferred broker
     * does not disable the matrix, it is merely not IN it.
     */
    @isTest
    static void testGetOutreachSummary_preferredPlusThreeComparable_matrixIsGenerated() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        respondersOn(d.Id, 3, 1);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        System.assertEquals(4, s.responsesReceived, 'PREMISE — four brokers came back');
        Assert.isTrue(s.matrixGenerated,
            'A preferred broker does not SUPPRESS the badge, it is simply not counted toward it: '
            + 'three comparable responses still generate the matrix');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ndaStatus — the real NDA pill (replaces the hard-coded 'Signed')
    // ═══════════════════════════════════════════════════════════════════════════

    /** A disposition-parented NDA: NDA__c is dual-parented and both lookups are optional. */
    private static NDA__c dispositionNda(Id dispositionId, String status) {
        NDA__c nda = TestDataFactory.createNda(null, false);
        nda.Disposition__c = dispositionId;
        nda.Status__c = status;
        insert nda;
        return nda;
    }

    /**
     * 🔴 THE DEFECT THIS CLOSES. The pill previously read "Signed" on every disposition
     * whether or not an NDA existed. The @TestSetup disposition has NO NDA, so the honest
     * answer is null — and asserting NULL here is what makes the old hard-coded value
     * impossible to reintroduce on the server side.
     */
    @isTest
    static void testGetOutreachSummary_noNda_ndaStatusIsNull() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.isNull(s.ndaStatus,
            'With no NDA on the disposition the status must be null, not a hard-coded "Signed"');
    }

    @isTest
    static void testGetOutreachSummary_withNda_returnsItsRealStatus() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        dispositionNda(d.Id, 'Pending');

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.areEqual('Pending', s.ndaStatus,
            'The pill must show the NDA\'s REAL status, including an unflattering one');
    }

    /** Many NDAs, one pill: the most recently created row wins (mirrors the selector contract). */
    @isTest
    static void testGetOutreachSummary_multipleNdas_showsTheLatest() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        NDA__c older = dispositionNda(d.Id, 'Pending');
        dispositionNda(d.Id, 'Signed');
        // In-transaction CreatedDate ties would make ORDER BY CreatedDate DESC arbitrary.
        Test.setCreatedDate(older.Id, System.now().addMinutes(-5));

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.areEqual('Signed', s.ndaStatus, 'The latest NDA defines the pill');
    }

    /**
     * An NDA hanging off an OPPORTUNITY must never leak into a disposition's pill —
     * NDA__c is dual-parented, so this is a live confusion risk rather than a hypothetical.
     */
    @isTest
    static void testGetOutreachSummary_opportunityNdaDoesNotLeakIn() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createNda(opp.Id, true);

        Test.startTest();
        BovController.OutreachSummary s = BovController.getOutreachSummary(d.Id);
        Test.stopTest();

        Assert.isNull(s.ndaStatus,
            'An Opportunity-parented NDA is not this disposition\'s NDA and must not populate the pill');
    }

    /**
     * P6 controller error boundary: a Disposition Id that no longer exists makes the
     * selector's single-row SOQL throw System.QueryException, which getOutreachSummary
     * now catches and re-surfaces as a user-safe AuraHandledException at the LWC boundary
     * (ARCHITECTURE.md §5). Intent preserved from the original raw-QueryException test:
     * a missing Disposition surfaces an error — but now the raw "no rows" detail is
     * masked and only the user-safe message reaches the caller.
     */
    @isTest
    static void testGetOutreachSummary_invalidId_throwsUserSafeAuraException() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        Boolean threw = false;
        try {
            BovController.getOutreachSummary(deletedId);
            System.assert(false, 'Expected an AuraHandledException for a Disposition Id that no longer exists');
        } catch (AuraHandledException e) {
            threw = true;
            System.assertEquals(false, e.getMessage().toLowerCase().contains('no rows'),
                'The raw QueryException detail must be masked at the boundary: ' + e.getMessage());
            System.assertEquals(true, e.getMessage().toLowerCase().contains('could not be loaded'),
                'The user should get the fixed user-safe read-failure message: ' + e.getMessage());
        }
        System.assert(threw, 'A deleted Disposition Id should surface a user-safe AuraHandledException');
        Test.stopTest();
    }

    // A bare user with no DPEG access: both reads query custom objects (BOV_Submission__c /
    // Disposition__c) WITH USER_MODE and throw for the unprivileged user, exercising both
    // read-failure catches which map to a user-safe AuraHandledException at the LWC boundary
    // (P6). getSubmissions has no prior negative-path coverage (an empty list returns early),
    // so this restricted-user path is the only way to reach its catch.
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    @isTest
    static void readPathsThrowAuraHandledException() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                BovController.getSubmissions(d.Id);
                Assert.fail('expected AuraHandledException from getSubmissions under a restricted user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getSubmissions read failure maps to AuraHandledException');
            }
            try {
                BovController.getOutreachSummary(d.Id);
                Assert.fail('expected AuraHandledException from getOutreachSummary under a restricted user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getOutreachSummary read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // replaceSelectedBroker — thin wrapper over BovSubmissionService (DEV-6)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void replaceSelectedBroker_positiveScenario_returnsTheWarningMessage() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        String msg = BovController.replaceSelectedBroker(
            d.Id, challenger.Id, 'Company Decision', 'Owner asked for a change.');
        Test.stopTest();

        System.assertEquals('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :challenger.Id].Submission_Status__c);
        System.assertEquals('Backup',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id].Submission_Status__c);
        System.assert(msg.contains('must be approved'), 'The warning must survive the controller boundary: ' + msg);
        // The two new parameters are PASSED THROUGH, not swallowed — proved on the row the service
        // writes rather than by mocking, because "the controller is thin" is only meaningful if the
        // values actually arrive at the far end.
        BOV_Broker_Change__c row = [
            SELECT Reason__c, Notes__c FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id LIMIT 1
        ];
        Assert.areEqual('Company Decision', row.Reason__c,
            'The reason must reach the history row through the controller');
        Assert.areEqual('Owner asked for a change.', row.Notes__c,
            'And so must the notes');
    }

    /**
     * A blank reason is a SERVICE rule, and the controller must surface it through the SECOND
     * catch — verbatim — rather than adding a rule of its own or masking it as a system failure.
     * This is the same three-catch-order proof as the two tests below, on the newest refusal path.
     */
    @isTest
    static void replaceSelectedBroker_blankReason_surfacesTheRefusalVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        Boolean refused = false;
        try {
            BovController.replaceSelectedBroker(d.Id, challenger.Id, null, 'notes');
            Assert.fail('A blank reason must be refused');
        } catch (AuraHandledException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('reason'),
                'The service\'s authored refusal must surface verbatim, not the generic '
                + 'REPLACE_FAILURE_MESSAGE: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The controller must surface the BovSubmissionException verbatim');
        Assert.areEqual(0,
            [SELECT COUNT() FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id],
            'And nothing may be recorded');
    }

    /**
     * 🔴 THE THREE-CATCH ORDER, PROVED THE SAME WAY DispositionControllerTest proves
     * findOrCreate's two-catch order: a user-actionable refusal must surface VERBATIM, not be
     * masked behind the generic REPLACE_FAILURE_MESSAGE.
     */
    @isTest
    static void replaceSelectedBroker_challengerNotOnDisposition_surfacesTheRefusalVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c other = TestDataFactory.createDisposition(asset.Id, false);
        other.Disposition_Stage__c = 'BOV Outreach';
        insert other;
        BOV_Submission__c foreign = TestDataFactory.createBovSubmission(other.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            BovController.replaceSelectedBroker(d.Id, foreign.Id, 'Other', null);
            Assert.fail('A cross-disposition submission must be refused');
        } catch (AuraHandledException e) {
            refused = true;
            System.assert(e.getMessage().contains('does not belong to this disposition'),
                'The refusal must surface verbatim, not the generic message: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(refused, 'The controller must surface the BovSubmissionException verbatim');
    }

    /**
     * The permission-denial leg of the three-catch order — verbatim, ordered FIRST, mirroring
     * DispositionApprovalController's own argument for why a denial must never fall through to
     * the generic clause.
     */
    @isTest
    static void replaceSelectedBroker_bareUser_isDeniedVerbatim() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        User u = bareUser();

        DispositionActionPermissionService.clearCache();
        System.runAs(u) {
            Test.startTest();
            Boolean denied = false;
            try {
                BovController.replaceSelectedBroker(d.Id, challenger.Id, 'Other', null);
                Assert.fail('A bare user with no disposition-driver grant must be denied');
            } catch (AuraHandledException e) {
                denied = true;
                System.assert(e.getMessage().contains('permission'),
                    'The denial must surface the shared permission wording verbatim: ' + e.getMessage());
            }
            Test.stopTest();
            System.assert(denied);
        }
        DispositionActionPermissionService.clearCache();
        System.assertEquals('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id].Submission_Status__c,
            'A denied call must write nothing');
    }
}
