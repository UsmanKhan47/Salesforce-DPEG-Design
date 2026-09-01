/**
 * @description Tests `BovAutoSelectionService` — the automatic "highest-scoring, non-preferred,
 * unlocked BOV submission becomes the Selected one" appointment. Added 2026-08-24
 * (`agent-output/bov-autoselect-preferred-brokers.md`).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 READ THIS FIRST: WHY THE OBVIOUS VERSION OF EVERY TEST BELOW WOULD BE VACUOUS
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BOV_Score__c` is a FORMULA returning **null** when its value basis is blank or `<= 0`, and the
 * default factory fixture has no basis — so a test written on one exercises the
 * NO-SCOREABLE-CANDIDATE branch and NOTHING ELSE, while passing and looking complete. That is the
 * single most likely way this feature ships untested.
 *
 * ⚠ THE BASIS MOVED ON 2026-08-25 AND THE SENTENCE ABOVE ONLY SURVIVED BECAUSE THE FACTORY WAS
 * CHANGED TO KEEP IT TRUE. Read this before trusting any fixture in this file:
 *   BEFORE — basis = `Disposition__r.Asking_Price__c`, never set by `createDispositions`.
 *   ALMOST — basis = `Disposition__r.Property_Asset__r.Target_Sale_Price__c`, and
 *            `TestDataFactory.createPropertyAssets` shipped a non-null default (1200000 + i*1000).
 *            Every fixture here would have become SCOREABLE, and every test whose SUBJECT is the
 *            null-score branch — `everyScoreNull_appointsNobodyAndWritesNothing`, the two
 *            `unpricedDispositionAt` tests — would have gone on passing while proving the
 *            OPPOSITE. Same defect, opposite direction, invisible from inside the test either way.
 *   NOW    — that default was REMOVED from `createPropertyAssets`. Unpriced is the default again.
 *
 * THE COUNTERMEASURE IS NOW THREE-PART AND ALL THREE ARE MANDATORY:
 *   1. Every test that needs a real ranking builds its parent with
 *      `TestDataFactory.createPricedDisposition(assetId(), ASKING_PRICE, false)` — which pins the
 *      ASSET's `Target_Sale_Price__c` to `ASKING_PRICE`. ⚠ PIN IT WELL ABOVE THE BOV AMOUNTS: a
 *      basis at or under them saturates the formula's `MIN(ratio, 1.10)` cap and every score TIES,
 *      non-null and useless, which is why `ASKING_PRICE` is 1,500,000 and not the old default.
 *   2. 🔴 Every test whose subject is the NULL-score branch goes through
 *      `unpricedDispositionAt(...)`, which calls `TestDataFactory.unpriceAsset(...)` explicitly
 *      rather than relying on the factory default staying blank. The factory default has now been
 *      the wrong way round once; the explicit call is what makes these tests independent of it.
 *   3. `assertScoresAreRanked(...)` is called INSIDE the ranking tests, BEFORE the assertions that
 *      matter. It re-reads `BOV_Score__c` from the database and fails if any score is null OR if
 *      they are all equal. 🔴 IT IS NOT DEFENSIVE CLUTTER — it is the only thing standing between
 *      this class and a suite that is green because nothing was scoreable, and the only thing that
 *      would catch an all-saturated tie.
 *
 * HOW THE SCORES ARE MADE TO DIFFER, CONCRETELY. `TestDataFactory.createBovSubmissions` holds
 * `Commission_Rate__c` (2.5) and `Days_To_Market__c` (30) constant, so with a fixed
 * `ASKING_PRICE` the formula reduces to a strictly increasing function of `BOV_Amount__c`
 * (`50 * MIN(amount / askingPrice, 1.10) / 1.10`, plus two constants). Every test below therefore
 * sets `BOV_Amount__c` explicitly, with gaps far larger than the field's `scale = 2` rounding, and
 * the row with the LARGEST amount is the expected winner. A deliberate TIE is created by giving
 * two rows the IDENTICAL amount.
 *
 * ── 251-RECORD BULK MANDATE APPLIES — NO EXEMPTION (`.claude/rules/bulk-test-rule.md`) ─────────
 * This is a trigger path and it loops over a collection. ⚠ 251 submissions on ONE disposition span
 * TWO chunks (200 + 51), so the service runs TWICE and the appointment legitimately FLIPS before
 * settling. The bulk tests therefore assert THE END STATE (exactly one Selected, and it is the
 * global highest scorer across all 251) plus a CONSTANT PER-CHUNK COST — never "it flipped once".
 *
 * ── 🔴 THE NON-OWNER TEST IS THE ONLY ONE THAT CAN FAIL ON THE SHARING ESCAPE ─────────────────
 * Every other test here runs as the admin test user, who OWNS every fixture row, and an owner of an
 * OWD-Private record always holds record-level edit — so the `with sharing` question is never
 * asked. `nonOwnerSaver_swapsAnUnownedSiblingAcrossTheSharingBoundary` is the falsifier for
 * `BovAutoSelectionService.SelectionWrites`. Do not delete it, and do not "simplify" its persona.
 *
 * @see force-app/main/default/classes/BovAutoSelectionService.cls
 * @see force-app/main/default/classes/BovSubmissionSelectionGuardTest.cls
 *      (`autoSelectionSwap_isNotRefusedByTheGuard` — the other half of this feature's proof)
 */
@isTest
private class BovAutoSelectionServiceTest {

    private static final Integer BULK_N = 251;

    /**
     * Chosen so every amount used below lands BELOW the formula's `MIN(..., 1.10)` cap — a test
     * whose two candidates both saturate the cap would tie at 50 points on the Value term and the
     * "highest scorer wins" assertion would be decided by the tie-break instead, silently.
     */
    private static final Decimal ASKING_PRICE = 1500000;

    private static final String SELECTED = 'Selected';
    private static final String BACKUP = 'Backup';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    /** A PRICED disposition at the given stage — the only fixture on which scores are non-null. */
    private static Disposition__c pricedDispositionAt(String stage) {
        Disposition__c d = TestDataFactory.createPricedDisposition(assetId(), ASKING_PRICE, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    /**
     * A disposition whose ASSET carries NO `Target_Sale_Price__c`, so every child scores null.
     *
     * 🔴 THE `unpriceAsset` CALL IS DELIBERATE AND IS NOT REDUNDANT WITH THE FACTORY DEFAULT.
     * `createPropertyAssets` ships no target sale price today, so a plain `createDisposition` would
     * also score null — but it shipped one until 2026-08-25, when the score's basis moved onto the
     * asset and that default had to be removed to stop it inverting this very fixture. The explicit
     * call is what makes this method independent of that decision being re-made: if a target sale
     * price ever comes back to the factory, these tests keep testing what they say.
     * ⚠ It updates the SHARED @testSetup asset, so every disposition in this transaction is
     * unpriced afterwards. No test here mixes priced and unpriced fixtures; if one ever needs to,
     * it must build a SECOND asset rather than re-price this one mid-test.
     */
    private static Disposition__c unpricedDispositionAt(String stage) {
        TestDataFactory.unpriceAsset(assetId());
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    /**
     * An UNSAVED submission at `Backup` with an explicit amount. Uses the SINGULAR factory method
     * on purpose: it reuses the shared per-transaction broker Contact, so building a dozen of these
     * costs ONE Contact insert rather than a dozen.
     */
    private static BOV_Submission__c bov(Id dispositionId, Decimal amount) {
        BOV_Submission__c s = TestDataFactory.createBovSubmission(dispositionId, false);
        s.BOV_Amount__c = amount;
        return s;
    }

    /** As `bov`, flagged as a preferred broker AND carrying a BOV amount. */
    private static BOV_Submission__c preferredBov(Id dispositionId, Decimal amount) {
        BOV_Submission__c s = bov(dispositionId, amount);
        s.Is_Preferred_Broker__c = true;
        return s;
    }

    /**
     * 🔴 THE REALISTIC PREFERRED BROKER: FLAGGED, WITH **NO BOV AMOUNT AT ALL** — so `BOV_Score__c`
     * is null and it is completely unscoreable.
     *
     * ⚠ THIS IS THE NORMAL SHAPE OF A PREFERRED BROKER, NOT AN EDGE CASE, AND USING
     * `preferredBov(...)` INSTEAD WOULD MAKE EVERY PREFERRED TEST WEAKER. `BOV_Amount_Required_On_Submission`
     * is `AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))` — the exemption exists precisely
     * so a preferred broker can be recorded without a quote. A preferred row that HAPPENS to carry a
     * winning amount would be appointed by the SCORED path too, so a test built on one cannot tell
     * "the flag won" from "the score won".
     *
     * ⚠ It clears `BOV_Amount__c` that `TestDataFactory` sets by default; `Broker__c` is left in
     * place because `Broker_Required_On_Submission` is `ISBLANK(Broker__c)` and was NOT given a
     * preferred exemption — so a broker Contact is still mandatory on every row, which is also what
     * keeps `Broker_Firm__c` (and therefore the parent's `Selected_Broker__c` stamp) non-blank.
     */
    private static BOV_Submission__c unquotedPreferredBov(Id dispositionId) {
        BOV_Submission__c s = bov(dispositionId, null);
        s.Is_Preferred_Broker__c = true;
        s.Cap_Rate__c = null;
        s.Commission_Rate__c = null;
        s.Days_To_Market__c = null;
        s.Hist_Success_Rate__c = null;
        return s;
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 `WITH SYSTEM_MODE` IS MANDATORY HERE AND IT IS NOT BOILERPLATE. MEASURED 2026-08-24.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * This started as a PLAIN `[SELECT ...]` — on the standing assumption, stated all over this
     * repo, that "Apex SOQL without `WITH USER_MODE` runs in system mode for CRUD/FLS". **THAT
     * ASSUMPTION IS FALSE FOR A FIELD WITH NO `FieldPermissions` ROW ANYWHERE**, and this class was
     * where it was measured: all 19 methods failed with
     * `System.QueryException: No such column 'Approval_Pending__c' on entity 'BOV_Submission__c'`
     * while `BovSubmissionSelectorTest`'s four `selectSelectionContextByDispositionIds` tests —
     * reading the SAME field through the selector's `WITH SYSTEM_MODE` query — all PASSED.
     *
     * WHY: `Approval_Pending__c` is deliberately granted to NOBODY (both disposition permission-set
     * files carry an explicit "do not complete the set" instruction; an approval process is its only
     * writer). Confirmed in `usman-dpeg` 2026-08-24, three independent ways:
     *   - `SELECT ... FROM FieldPermissions` returns ZERO rows for it, for every persona;
     *   - it is ABSENT from `EntityParticle` for `BOV_Submission__c` while `Approval_Status__c` is
     *     present;
     *   - in anonymous Apex, `Schema.SObjectType.BOV_Submission__c.fields.getMap()
     *     .containsKey('approval_pending__c')` returns **false**.
     * With no grant at all the field is not merely FLS-denied, it is ABSENT FROM THE RUNNING USER'S
     * SCHEMA — so the query cannot even be resolved, and only an EXPLICIT `WITH SYSTEM_MODE` /
     * `AccessLevel.SYSTEM_MODE` puts it back. "System mode by default" is about ENFORCEMENT on a
     * field the user can see; it does not add back a field they cannot.
     *
     * ⚠ SO A TEST OF THIS FEATURE CANNOT READ THE LOCK FIELDS THE ORDINARY WAY, AND THE FAILURE IS
     * LOUD RATHER THAN SILENT — which is the one mercy. Do not "simplify" this back to a plain
     * query; do not "fix" it by granting FLS on `Approval_Pending__c` either.
     */
    private static Map<Id, BOV_Submission__c> stateOf(Id dispositionId) {
        return new Map<Id, BOV_Submission__c>([
            SELECT Id, Submission_Status__c, Approval_Status__c, Approval_Pending__c,
                   Is_Preferred_Broker__c, Is_System_Selected__c, Is_Manually_Appointed__c,
                   BOV_Score__c, BOV_Amount__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * The Id holding the PREFERRED slot, or null when nothing does.
     *
     * 🔴 ADDED 2026-08-24 WITH THE TWO-SLOT MODEL, AND IT IS WHY `assertExactlyOneSelected` COULD
     * NOT SIMPLY BE RELAXED TO "ONE OR TWO". A disposition may now legitimately hold two Selected
     * rows, so an assertion that counts them proves almost nothing — the question that matters is
     * WHICH ROW IS IN WHICH SLOT. Every preferred test below asserts both slots by identity.
     * Fails loudly rather than returning an arbitrary row if the invariant is broken.
     */
    private static Id preferredSlotOn(Id dispositionId) {
        List<Id> held = new List<Id>();
        for (BOV_Submission__c s : stateOf(dispositionId).values()) {
            if (SELECTED.equals(s.Submission_Status__c) && s.Is_Preferred_Broker__c == true) {
                held.add(s.Id);
            }
        }
        Assert.isTrue(held.size() <= 1,
            '🔴 TWO SELECTED PREFERRED ROWS on one disposition (' + held + '). That is the half of '
            + 'the narrowed exclusivity invariant this slot exists to hold, so a failure here is a '
            + 'guard defect, not an assertion problem.');
        return held.isEmpty() ? null : held[0];
    }

    /**
     * The Id holding the APPOINTED (non-preferred) slot, or null when nothing does. See
     * `preferredSlotOn` for why the two are read separately.
     */
    private static Id appointedSlotOn(Id dispositionId) {
        List<Id> held = new List<Id>();
        for (BOV_Submission__c s : stateOf(dispositionId).values()) {
            if (SELECTED.equals(s.Submission_Status__c) && s.Is_Preferred_Broker__c != true) {
                held.add(s.Id);
            }
        }
        Assert.isTrue(held.size() <= 1,
            '🔴 TWO SELECTED NON-PREFERRED ROWS on one disposition (' + held + '). The other half of '
            + 'the narrowed exclusivity invariant.');
        return held.isEmpty() ? null : held[0];
    }

    /**
     * Asserts BOTH slots by identity in one call. Pass null for a slot that must be EMPTY.
     *
     * ⚠ IT ALSO ASSERTS `Is_System_Selected__c`, WHICH IS THE POINT OF THE FIELD. The scored
     * winner must carry it and the preferred row must not — that is what
     * `DispositionApprovalService` and the comparison matrix use to tell two Selected rows apart,
     * and a test that only checked `Submission_Status__c` would pass against a version that never
     * wrote the flag at all.
     */
    private static void assertSlots(Id dispositionId, Id expectedPreferred, Id expectedAppointed,
                                    String why) {
        Assert.areEqual(expectedPreferred, preferredSlotOn(dispositionId),
            why + ' — PREFERRED SLOT');
        Assert.areEqual(expectedAppointed, appointedSlotOn(dispositionId),
            why + ' — APPOINTED (scored / manual) SLOT');
        Map<Id, BOV_Submission__c> rows = stateOf(dispositionId);
        for (BOV_Submission__c s : rows.values()) {
            Boolean shouldCarryFlag = s.Id == expectedAppointed
                && s.Is_Preferred_Broker__c != true
                && s.BOV_Score__c != null;
            if (shouldCarryFlag) {
                Assert.isTrue(s.Is_System_Selected__c,
                    why + ' — the SCORED winner must carry Is_System_Selected__c. Without it the '
                    + 'approval router cannot tell it from a preferred row, and every row selected '
                    + 'before the field existed stays unrepaired.');
            } else {
                Assert.isFalse(s.Is_System_Selected__c,
                    why + ' — only the scored winner may carry Is_System_Selected__c; ' + s.Id
                    + ' must not. A preferred row carrying it, or a demoted row keeping it, is the '
                    + 'two-rows-claiming-one-slot state the guard exists to make unreachable.');
            }
        }
    }

    private static List<Id> selectedIdsOn(Id dispositionId) {
        List<Id> ids = new List<Id>();
        for (BOV_Submission__c s : stateOf(dispositionId).values()) {
            if (SELECTED.equals(s.Submission_Status__c)) {
                ids.add(s.Id);
            }
        }
        return ids;
    }

    private static void assertExactlyOneSelected(Id dispositionId, Id expectedWinnerId, String why) {
        List<Id> selected = selectedIdsOn(dispositionId);
        Assert.areEqual(1, selected.size(),
            why + ' — expected EXACTLY ONE Selected submission, found ' + selected.size()
            + '. Zero means auto-selection did not run or found no candidate; two or more means the '
            + 'demotion and the promotion were not applied in the same statement.');
        Assert.areEqual(expectedWinnerId, selected[0], why);
    }

    /**
     * 🔴 THE ANTI-VACUITY GUARD. See the class header. Fails when any score is null (the fixture
     * forgot its asking price, and every ranking assertion after this line would be meaningless) or
     * when every score is identical (nothing is being RANKED, only tie-broken).
     *
     * ⚠ Call it AFTER the rows are inserted and BEFORE the behavioural assertions, so a broken
     * fixture reports itself rather than showing up as a confusing "expected X, was Y".
     */
    private static void assertScoresAreRanked(Id dispositionId) {
        Set<Decimal> distinct = new Set<Decimal>();
        for (BOV_Submission__c s : stateOf(dispositionId).values()) {
            Assert.isNotNull(s.BOV_Score__c,
                '🔴 FIXTURE PRECONDITION FAILED: BOV_Score__c is NULL on ' + s.Id + '. The parent '
                + 'Disposition\'s ASSET has no Target_Sale_Price__c (use '
                + 'TestDataFactory.createPricedDisposition) '
                + 'or the row has no BOV_Amount__c. Every ranking assertion in this test would pass '
                + 'VACUOUSLY, by exercising the no-scoreable-candidate branch instead.');
            distinct.add(s.BOV_Score__c);
        }
        Assert.isTrue(distinct.size() > 1,
            '🔴 FIXTURE PRECONDITION FAILED: every submission scored the SAME value ' + distinct
            + '. Nothing is being ranked, so "the highest scorer wins" cannot fail here. Give the '
            + 'rows different BOV_Amount__c values.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // AUTO-SELECTION ON INSERT AND UPDATE
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** The first scoreable submission to arrive is appointed with no incumbent to demote. */
    @isTest
    static void firstScoreableSubmission_isSelectedOnInsert() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');

        Test.startTest();
        BOV_Submission__c only = bov(d.Id, 1000000);
        insert only;
        Test.stopTest();

        assertExactlyOneSelected(d.Id, only.Id,
            'A lone scoreable submission must be appointed automatically on insert — this is the '
            + 'behaviour that replaced the Select Broker button');
    }

    /**
     * 🔴 THE CENTRAL TEST. A higher-scoring submission arriving must demote the committed incumbent
     * and promote itself IN ONE STATEMENT. If `BovAutoSelectionService` is ever moved to a before
     * context or split into two DML, `BovSubmissionSelectionGuardService` refuses this insert and
     * this test fails with the guard's own DUPLICATE_SELECTED message — which is the correct alarm.
     */
    @isTest
    static void aHigherScorerArriving_demotesTheIncumbentAndPromotesItself() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = bov(d.Id, 1000000);
        insert incumbent; // auto-selected: the only candidate

        Test.startTest();
        BOV_Submission__c challenger = bov(d.Id, 1400000);
        insert challenger;
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, challenger.Id,
            'The higher-scoring challenger must take the appointment');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(incumbent.Id).Submission_Status__c,
            'and the incumbent must be demoted IN THE SAME STATEMENT — see the class header of '
            + 'BovAutoSelectionService for why any other shape is refused by the guard');
        Assert.areEqual(new List<String>(),
            BovAutoSelectionService.lastRunSelectionFailures,
            'No write may have been refused. This list carries the platform StatusCode.');
    }

    /** A LOWER-scoring arrival must not disturb the incumbent. */
    @isTest
    static void aLowerScorerArriving_changesNothing() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = bov(d.Id, 1400000);
        insert incumbent;

        Test.startTest();
        BOV_Submission__c weaker = bov(d.Id, 900000);
        insert weaker;
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, incumbent.Id,
            'A weaker response must never displace the appointed broker');
    }

    /** Editing a losing submission's amount above the incumbent's re-ranks on UPDATE, not insert. */
    @isTest
    static void raisingALosersAmount_reRanksOnUpdate() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = bov(d.Id, 1400000);
        BOV_Submission__c loser = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ incumbent, loser };
        Assert.areEqual(new List<Id>{ incumbent.Id }, selectedIdsOn(d.Id),
            'precondition: the stronger row holds the appointment before the edit');

        Test.startTest();
        update new BOV_Submission__c(Id = loser.Id, BOV_Amount__c = 1450000);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, loser.Id,
            'Raising a response above the incumbent must move the appointment on the UPDATE path. '
            + 'Still pointing at the old incumbent means the after-update hook is missing or its '
            + 'BOV_Amount__c change key was dropped.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // A NULL SCORE IS NOT A RANK
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE F-6 RULE. An UNPRICED disposition scores every child null, and nothing is appointed.
     * ⚠ This is the ONE test in the class that deliberately uses an ordinary factory disposition,
     * and it must NOT call `assertScoresAreRanked` — null scores are the subject here, not a bug.
     */
    @isTest
    static void everyScoreNull_appointsNobodyAndWritesNothing() {
        Disposition__c d = unpricedDispositionAt('BOV Outreach');
        // 🔴 BUILT OUTSIDE THE MEASUREMENT WINDOW, AND THAT IS NOT TIDINESS. MEASURED 2026-08-24:
        // with these three `bov(...)` calls inline in the `insert` below, this assertion read 2
        // instead of 1 and looked exactly like an auto-selection defect. The culprit was the
        // FIXTURE — `TestDataFactory.createBovSubmission` lazily inserts the shared broker Contact
        // on its FIRST call in a transaction, and method ARGUMENTS are evaluated AFTER
        // `Limits.getDmlStatements()` has already been read. A governor assertion that brackets its
        // own arguments measures the helper, not the code under test.
        List<BOV_Submission__c> rows = new List<BOV_Submission__c>{
            bov(d.Id, 900000), bov(d.Id, 1200000), bov(d.Id, 1400000)
        };

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        insert rows;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        for (BOV_Submission__c s : stateOf(d.Id).values()) {
            Assert.isNull(s.BOV_Score__c,
                'precondition: a disposition whose ASSET has no Target_Sale_Price__c must score '
                + 'every child NULL — if this row has a score, unpricedDispositionAt stopped '
                + 'calling TestDataFactory.unpriceAsset and every assertion below is a lie');
        }
        Assert.areEqual(0, selectedIdsOn(d.Id).size(),
            '🔴 NOTHING may be appointed when no candidate is scoreable. Selecting the oldest row '
            + 'here would be "auto-select whichever BOV arrived first", appointing a broker for a '
            + 'sale nobody has priced.');
        // ── 🔴 RE-DERIVED 2026-08-31 (Tranche 1 item 7). WAS `areEqual(1, dmlUsed, …)`. ───────────
        // The claim is unchanged and must not be weakened: THIS SERVICE must write NOTHING when no
        // candidate is scoreable. What joined the count is `DispositionCounterRollupService`'s
        // `Responses_Received__c` parent write in `afterInsert` — which is CORRECT here and must
        // NOT be guarded by anything score-related: three unscoreable responses are still three
        // responses received, and the counter says nothing about who is appointed.
        //   1  this test's own `insert rows`
        //   1  the counter's parent Database.update (ONE per chunk)
        //   0  BovAutoSelectionService — the subject, and still zero
        // 🔴 A THIRD STATEMENT MEANS THE NULL-SCORE GUARD WAS REMOVED. Same failure, new baseline.
        Assert.areEqual(2, dmlUsed,
            'and the auto-selection service must cost ZERO extra DML — the two statements are this '
            + 'test\'s own insert and the Responses_Received__c recompute. A THIRD write means the '
            + 'null-score guard was removed. DML used: ' + dmlUsed);
    }

    /**
     * 🔴 THE PRIMARY PRODUCTION PATH: responses arrive first, the TARGET SALE PRICE is set LATER on
     * the PROPERTY ASSET, and the appointment must happen on THAT save with the user issuing no
     * child DML at all. Without `PropertyAssetTriggerHandler.afterUpdate` ->
     * `reselectForRepricedDispositions` this fails, and in production it would fail SILENTLY —
     * green deploy, green tests, no error.
     *
     * ⚠ THE TRIGGERING SAVE IS ON `Property_Asset__c`, NOT `Disposition__c`, SINCE 2026-08-25.
     * This test used to `update new Disposition__c(Id = d.Id, Asking_Price__c = ASKING_PRICE)`.
     * `Asking_Price__c` is retired from the disposition flow and still COMPILES, so the old line
     * would still have run — and would have asserted nothing, because no disposition field feeds
     * `BOV_Score__c` any more. This is the falsifier for the hook having moved objects.
     */
    @isTest
    static void pricingTheAssetAfterTheResponsesArrived_appointsTheWinner() {
        Disposition__c d = unpricedDispositionAt('BOV Outreach');
        BOV_Submission__c weak = bov(d.Id, 900000);
        BOV_Submission__c strong = bov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ weak, strong };
        Assert.areEqual(0, selectedIdsOn(d.Id).size(),
            'precondition: nothing is appointed while the asset carries no target sale price');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        update new Property_Asset__c(Id = assetId(), Target_Sale_Price__c = ASKING_PRICE);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, strong.Id,
            '🔴 Pricing the ASSET must re-rank every child of every disposition under it and '
            + 'appoint the winner. Zero Selected rows means the asset-side hook is missing or is '
            + 'still watching Disposition__c.Asking_Price__c — and on a live sale there may be no '
            + 'further reason to edit a BOV again, so the feature would simply never fire.');
        Assert.areEqual(2, dmlUsed,
            'ONE for this test\'s own ASSET update, plus ONE for the service\'s single bulk child '
            + 'write. The USER issues zero child DML — that is the whole point of the parent hook.');
    }

    /**
     * An ordinary Property Asset save that does not touch the target sale price must cost nothing.
     *
     * 🔴 THIS CONTRACT MATTERS MORE ON `Property_Asset__c` THAN IT EVER DID ON `Disposition__c`.
     * The asset is a Property Management object saved constantly by a team with no disposition
     * involvement; a query on every asset save would land in every PM bulk test in the repo. The
     * `repricedAssetIds.isEmpty()` early return in the service is what this asserts.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 IT CALLS THE SERVICE DIRECTLY INSTEAD OF SAVING AN ASSET, AND BOTH HALVES OF THAT ARE
     *    DELIBERATE. REWRITTEN 2026-08-25 AFTER IT FAILED IN DEPLOY (expected 0, actual 1).
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * REASON 1 — A TRIGGER-LEVEL QUERY COUNT IS THE WRONG INSTRUMENT FOR A ONE-HOOK CONTRACT.
     * `Limits.getQueries()` around an `update` measures EVERY consumer on
     * `PropertyAssetTriggerHandler`, not this one. `OnboardingAutoCreateService.ensureOnClosing`
     * runs first and is at zero cost only because the factory asset has no `Closing_Date__c` — so
     * the old assertion silently depended on an unrelated fixture detail, and the day a third
     * consumer joins that trigger (or the factory starts stamping a closing date) it fails while
     * naming THIS hook. The claim is "the reprice hook does not query when the price is unchanged";
     * the measurement must therefore bracket the reprice hook and nothing else.
     *
     * REASON 2 — THE ACTUAL CAUSE OF THE DEPLOY FAILURE, RECORDED SO IT IS NOT RE-DIAGNOSED WRONG.
     * It was NOT `ensureOnClosing` (measured: it early-returns at zero cost here). The one query
     * was `assetId()` — `[SELECT Id FROM Property_Asset__c LIMIT 1]` — sitting in the ARGUMENT LIST
     * of the `update` and therefore evaluated AFTER `queriesBefore` had already been read. ⚠ THIS
     * IS THE SECOND TIME THIS CLASS HAS BEEN BITTEN BY IT: the identical trap is written up at
     * `everyScoreNull_appointsNobodyAndWritesNothing` ("a governor assertion that brackets its own
     * arguments measures the helper, not the code under test"). Every value the measured statement
     * needs is now hoisted ABOVE `Test.startTest()`.
     *
     * REASON 3 — WHY THE FALSIFIER CALL IS NOT PADDING. A method that had been deleted, stubbed, or
     * short-circuited at its first line would also report zero queries, so a lone `areEqual(0, ...)`
     * cannot tell "the equality check worked" from "nothing ran". The second call, with the price
     * genuinely changed, is what makes the zero mean something: it must cost AT LEAST the
     * disposition lookup. Delete it and this test stops being able to fail for the right reason.
     */
    @isTest
    static void anAssetSaveThatDoesNotChangeThePrice_costsNothing() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c only = bov(d.Id, 1000000);
        insert only;

        // 🔴 EVERYTHING THE MEASURED CALLS NEED IS BUILT HERE, ABOVE THE WINDOW. See REASON 2.
        Id aId = assetId();
        List<Property_Asset__c> unchanged = new List<Property_Asset__c>{
            new Property_Asset__c(Id = aId, Target_Sale_Price__c = ASKING_PRICE)
        };
        Map<Id, Property_Asset__c> samePrice = new Map<Id, Property_Asset__c>{
            aId => new Property_Asset__c(Id = aId, Target_Sale_Price__c = ASKING_PRICE)
        };
        // The falsifier's inputs — a REAL change, same asset. Also hoisted.
        List<Property_Asset__c> repriced = new List<Property_Asset__c>{
            new Property_Asset__c(Id = aId, Target_Sale_Price__c = ASKING_PRICE + 250000)
        };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        BovAutoSelectionService.reselectForRepricedDispositions(unchanged, samePrice);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

        // THE FALSIFIER — same method, same asset, price genuinely moved. See REASON 3.
        Integer queriesBeforeReprice = Limits.getQueries();
        BovAutoSelectionService.reselectForRepricedDispositions(repriced, samePrice);
        Integer queriesUsedOnReprice = Limits.getQueries() - queriesBeforeReprice;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'The ZERO-QUERY fast path on the reprice hook: a chunk in which no asset changed '
            + 'Target_Sale_Price__c must return BEFORE the disposition lookup, let alone the '
            + 'selection query. Queries used: ' + queriesUsed);
        Assert.areEqual(0, dmlUsed,
            'and ZERO DML — an unchanged price must not write any submission');
        Assert.isTrue(queriesUsedOnReprice >= 1,
            'FALSIFIER: with the price actually changed the SAME method must issue at least the '
            + 'disposition lookup. Zero here means the assertions above are passing because the '
            + 'method does nothing at all, not because the equality check works. '
            + 'Queries used: ' + queriesUsedOnReprice);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE LOCK — ALL THREE LEGS, PLUS RECALL
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Builds the standard locked-scenario fixture: a WEAK incumbent holding the appointment, ready
     * for the caller to apply a lock leg and then introduce a STRONGER challenger.
     *
     * @param d the priced disposition.
     * @return the incumbent, already Selected by auto-selection.
     */
    private static BOV_Submission__c weakIncumbentOn(Disposition__c d) {
        BOV_Submission__c incumbent = bov(d.Id, 900000);
        insert incumbent;
        Assert.areEqual(new List<Id>{ incumbent.Id }, selectedIdsOn(d.Id),
            'precondition: the weak incumbent must hold the appointment before the lock is applied');
        return incumbent;
    }

    /**
     * Applies a lock leg. `Approval_Pending__c` and `Approval_Status__c` have NO editable FLS for
     * ANY persona (an approval process is their only writer), so this uses SYSTEM_MODE exactly as
     * `Set_Broker_Approval_Pending` / `Set_Broker_Approval_Approved` do in production.
     */
    private static void applyLock(BOV_Submission__c row) {
        Database.update(row, AccessLevel.SYSTEM_MODE);
    }

    /** Inserts a strictly stronger challenger and returns it. */
    private static BOV_Submission__c strongChallengerOn(Disposition__c d) {
        BOV_Submission__c challenger = bov(d.Id, 1400000);
        insert challenger;
        return challenger;
    }

    /** LOCK LEG 1 — an approval is in flight. */
    @isTest
    static void approvalPending_freezesTheAppointment() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = weakIncumbentOn(d);
        applyLock(new BOV_Submission__c(Id = incumbent.Id, Approval_Pending__c = true));

        Test.startTest();
        BOV_Submission__c challenger = strongChallengerOn(d);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, incumbent.Id,
            '🔴 A submission with an approval IN FLIGHT must freeze auto-selection. This is not '
            + 'only a business rule: Broker_Finalize_Approval is recordEditability = AdminOnly, and '
            + 'SYSTEM_MODE does NOT lift an approval lock — demoting it would throw ENTITY_IS_LOCKED '
            + 'inside an allOrNone = true update and roll back the UNRELATED insert above.');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(challenger.Id).Submission_Status__c,
            'and the stronger challenger must sit at Backup, waiting for a human');
    }

    /** LOCK LEG 2 — the principals approved. */
    @isTest
    static void approvedDecision_freezesTheAppointment() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = weakIncumbentOn(d);
        applyLock(new BOV_Submission__c(Id = incumbent.Id, Approval_Status__c = 'Approved'));

        Test.startTest();
        strongChallengerOn(d);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, incumbent.Id,
            'An APPROVED broker must never be swapped out automatically. Approval_Pending__c goes '
            + 'back to FALSE on approval, so this leg is the only thing holding the lock afterwards.');
    }

    /**
     * 🔴 LOCK LEG 2, REJECTION HALF — THE SETTLED USER DECISION (2026-08-24): a rejection keeps
     * auto-selection LOCKED. This is the test that would change if that decision is ever reversed,
     * and it is the ONLY thing pinning it.
     */
    @isTest
    static void rejectedDecision_staysLockedAndDoesNotResume() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = weakIncumbentOn(d);
        applyLock(new BOV_Submission__c(
            Id = incumbent.Id, Approval_Status__c = 'Rejected', Approval_Pending__c = false));

        Test.startTest();
        BOV_Submission__c challenger = strongChallengerOn(d);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, incumbent.Id,
            '🔴 REJECTION KEEPS IT LOCKED. If auto-selection resumed it would answer a question the '
            + 'principals just answered by hand — silently swapping in a different broker with no '
            + 'actor. The remedy after a rejection is Replace Broker, deliberately.');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(challenger.Id).Submission_Status__c,
            'and the challenger stays a Backup until a human uses Replace Broker');
    }

    /** LOCK LEG 3 — set directly. The integration with Replace Broker is the next test. */
    @isTest
    static void manuallyAppointed_freezesTheAppointment() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = weakIncumbentOn(d);
        applyLock(new BOV_Submission__c(Id = incumbent.Id, Is_Manually_Appointed__c = true));

        Test.startTest();
        strongChallengerOn(d);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, incumbent.Id,
            'A human deliberate pick must survive every later BOV save');
    }

    /**
     * 🔴 THE LOCK LEG THAT EXISTS BECAUSE OF THIS EXACT SEQUENCE, END TO END.
     * `replaceSelectedBroker` CLEARS `Approval_Status__c` on both rows so the replacement needs a
     * fresh approval — which zeroes the other two lock legs. Without
     * `Is_Manually_Appointed__c = true` on the challenger, auto-selection would UNLOCK and undo the
     * human's pick on the very next BOV save. This test fails RED if that one field assignment is
     * removed from `BovSubmissionService.replaceSelectedBroker`.
     */
    @isTest
    static void replaceBrokerAfterARejection_isNotUndoneByTheNextSave() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c topScorer = bov(d.Id, 1400000);
        BOV_Submission__c humansPick = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ topScorer, humansPick };
        Assert.areEqual(new List<Id>{ topScorer.Id }, selectedIdsOn(d.Id),
            'precondition: the algorithm appoints the top scorer first');
        // The principals reject it, then a human overrides with the weaker broker.
        applyLock(new BOV_Submission__c(Id = topScorer.Id, Approval_Status__c = 'Rejected'));

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(
            d.Id, humansPick.Id, 'Performance Issue', 'Principals rejected the top scorer.');
        // A perfectly ordinary later edit on the losing row — the trigger fires, and must do nothing.
        update new BOV_Submission__c(Id = topScorer.Id, BOV_Amount__c = 1490000);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.isTrue(after.get(humansPick.Id).Is_Manually_Appointed__c,
            '🔴 replaceSelectedBroker must stamp Is_Manually_Appointed__c on the challenger. '
            + 'Without it every assertion below is unreachable.');
        assertExactlyOneSelected(d.Id, humansPick.Id,
            '🔴 THE HUMAN\'S DELIBERATE PICK MUST SURVIVE. replaceSelectedBroker clears '
            + 'Approval_Status__c on BOTH rows, so Is_Manually_Appointed__c is the ONLY remaining '
            + 'lock leg — and the row that just got a bigger BOV amount is the higher scorer.');
    }

    /**
     * 🔴 RECALL UNLOCKS. `Broker_Finalize_Approval`'s recallActions fire
     * `Clear_Broker_Approval_Pending` (true -> false) and NO status update, so a recall is the ONE
     * event that releases the lock with no other field moving. If `Approval_Pending__c` is dropped
     * from the change keys this test fails — and a recalled disposition would silently stop
     * recomputing forever.
     */
    @isTest
    static void recall_unlocksAndRecomputes() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = weakIncumbentOn(d);
        applyLock(new BOV_Submission__c(Id = incumbent.Id, Approval_Pending__c = true));
        BOV_Submission__c challenger = strongChallengerOn(d);
        Assert.areEqual(new List<Id>{ incumbent.Id }, selectedIdsOn(d.Id),
            'precondition: the pending approval blocked the stronger challenger');

        Test.startTest();
        // The recall: Approval_Pending__c back to false, Approval_Status__c still null.
        applyLock(new BOV_Submission__c(Id = incumbent.Id, Approval_Pending__c = false));
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        Assert.isNull(stateOf(d.Id).get(incumbent.Id).Approval_Status__c,
            'precondition: a recall fires no status update, so no decision was recorded');
        assertExactlyOneSelected(d.Id, challenger.Id,
            'A recall means "I did not mean to send that yet" — nothing was decided, the state is '
            + 'identical to pre-submission, and recomputation must resume immediately.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 PREFERRED BROKERS WIN OUTRIGHT (user decision 2026-08-24), AND TIES
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ⚠ THE TWO TESTS THAT USED TO HEAD THIS SECTION ASSERTED THE EXACT OPPOSITE — that a preferred
    // broker "must never be appointed" and that a disposition of only preferred rows "keeps NO
    // appointed broker". Both are REPLACED, not merely renamed, because their bodies asserted the
    // inverted outcome. Recorded here so a reader who finds the old names in git history knows the
    // requirement changed rather than the code regressing.

    /**
     * 🔴 THE CENTRAL TEST OF THE NEW DECISION. Adding a preferred broker to a disposition that
     * already has an auto-appointed scored winner DEMOTES that winner and takes the slot.
     *
     * ⚠ THE PREFERRED ROW HERE HAS **NO BOV AMOUNT AT ALL**, so its `BOV_Score__c` is NULL — and it
     * must win anyway. That is the whole point of the decision and the reason "a null score is not
     * a rank" had to be scoped to the SCORED path: a preferred broker is exempt from
     * `BOV_Amount_Required_On_Submission`, so an unquoted preferred row is the NORMAL case, not an
     * edge case. If this test is ever "fixed" by giving the row an amount it stops proving anything.
     */
    @isTest
    static void addingAPreferredBroker_leavesTheScoredWinnerSelected() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c scoredWinner = bov(d.Id, 1400000);
        insert scoredWinner;
        assertSlots(d.Id, null, scoredWinner.Id,
            'precondition: scoring appointed the strongest response, and the PREFERRED slot is '
            + 'empty because no preferred row exists yet');

        Test.startTest();
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        insert preferred;
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        Assert.isNull(after.get(preferred.Id).BOV_Score__c,
            'precondition: the preferred row is UNSCOREABLE — it has no BOV amount, which is the '
            + 'normal shape of a preferred broker and the case this decision had to accommodate. '
            + 'A preferred row that HAPPENED to score would be appointed by the scored path too, '
            + 'so a test built on one could not tell the flag from the score.');
        Assert.isNotNull(after.get(scoredWinner.Id).BOV_Score__c,
            'precondition: the row beside it IS scoreable, so the two really are in different slots');
        assertSlots(d.Id, preferred.Id, scoredWinner.Id,
            '🔴 THE CENTRAL ASSERTION OF THE TWO-SLOT MODEL. Adding a preferred broker fills the '
            + 'PREFERRED slot and LEAVES THE SCORED WINNER SELECTED. A null appointed slot here '
            + 'means the retracted V2 rule is back — the preferred row EVICTING the scored winner '
            + '— which is the one line planFor was rewritten to delete.');
        Assert.areEqual(SELECTED, after.get(scoredWinner.Id).Submission_Status__c,
            'stated again directly on the row, because this is the exact value the deleted '
            + 'demotion write used to change to Backup');
    }

    /**
     * 🔴 SCORING CAN NEVER DISPLACE A PREFERRED BROKER. The specific regression this guards against
     * is a later, HIGHER-SCORING ordinary response arriving — the exact event that moves the
     * appointment on every non-preferred disposition.
     */
    @isTest
    static void aBetterScoredResponseArriving_cannotDisplaceAPreferredBroker() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        insert preferred;
        Assert.areEqual(new List<Id>{ preferred.Id }, selectedIdsOn(d.Id), 'precondition');

        Test.startTest();
        BOV_Submission__c strongest = bov(d.Id, 1450000); // the strongest possible scored response
        insert strongest;
        Test.stopTest();

        assertSlots(d.Id, preferred.Id, strongest.Id,
            '🔴 An unquoted preferred broker must KEEP the preferred slot against the '
            + 'highest-scoring response on the sale, and that response must take the SCORED slot '
            + 'beside it. A preferred slot pointing at the scored row means the two passes in '
            + 'planFor have been collapsed back into one winner.');
    }

    /** The asset-reprice path must not displace a preferred broker either. */
    @isTest
    static void pricingTheAsset_cannotDisplaceAPreferredBroker() {
        Disposition__c d = unpricedDispositionAt('BOV Outreach');
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        BOV_Submission__c strong = bov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ preferred, strong };
        assertSlots(d.Id, preferred.Id, null,
            'precondition: the preferred row holds its slot even while the asset carries no target '
            + 'sale price (score is irrelevant on that path), and the SCORED slot is EMPTY because '
            + 'nothing is scoreable yet — which is what makes the reprice below observable');

        Test.startTest();
        update new Property_Asset__c(Id = assetId(), Target_Sale_Price__c = ASKING_PRICE);
        Test.stopTest();

        assertSlots(d.Id, preferred.Id, strong.Id,
            'Pricing the asset materialises every scored response. None of them may touch the '
            + 'PREFERRED slot — and the asset hook must still fill the SCORED slot, which is the '
            + 'whole reason that hook exists (a sale priced after its BOV responses arrived gets '
            + 'no scored appointment at all without it).');
    }

    /**
     * 🔴 MULTIPLE PREFERRED ROWS: THE NEWEST WINS. This INVERTS the `CreatedDate ASC` tie-break
     * every other ranked query in this module uses, so it needs its own falsifier — see
     * `BovAutoSelectionService.isNewer` for the argument (under oldest-wins a second
     * "Add Preferred Broker" click would be a silent no-op with no remedy).
     *
     * ⚠ `Test.setCreatedDate` IS USED RATHER THAN RELYING ON INSERT ORDER. Two rows inserted in one
     * test share a `CreatedDate`, so insert order alone could make this pass on the Id tie-break
     * while the CreatedDate comparison was broken. Backdating the first row makes the two keys
     * disagree deliberately: `older` is older by ten minutes but may hold either Id.
     */
    @isTest
    static void twoPreferredBrokers_theNewestOneIsAppointedAndTheOlderIsRetired() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c older = unquotedPreferredBov(d.Id);
        insert older;
        Test.setCreatedDate(older.Id, System.now().addMinutes(-10));

        Test.startTest();
        BOV_Submission__c newer = unquotedPreferredBov(d.Id);
        insert newer;
        Test.stopTest();

        assertSlots(d.Id, newer.Id, null,
            '🔴 The MOST RECENTLY ADDED preferred broker must hold the preferred slot. Pointing at '
            + 'the older row means isNewer() has been "harmonised" to the CreatedDate ASC tie-break '
            + 'the rest of the module uses — which would make a second Add Preferred Broker click a '
            + 'SILENT NO-OP with no remedy.');
        // ⚠ AMENDED 2026-08-24: this used to assert the older row dropped to `Backup` and STAYED on
        // the preferred list. It no longer exists at all — `BovPreferredBrokerService` retires it,
        // which is the user's "the outgoing row is removed from the list" decision. The state
        // assertion is kept rather than deleted because "it is gone" and "it is Backup" are one
        // `continue` apart in the retirement loop and only one of them is correct.
        Assert.isNull(stateOf(d.Id).get(older.Id),
            '🔴 The superseded preferred broker must be REMOVED FROM THE LIST, not merely demoted. '
            + 'Finding it at Backup means BovPreferredBrokerService did not run — check the call '
            + 'ORDER in BovSubmissionTriggerHandler.afterInsert, which puts it before reselect.');
        Assert.areEqual(1, [
            SELECT COUNT() FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id
        ], '🔴 AND THE HISTORY ROW IS THE OTHER HALF OF THAT DECISION. A delete with no history row '
            + 'destroys the only record the broker was ever appointed — BOV_Submission__c has '
            + 'enableHistory false and the row itself is gone.');
    }

    /**
     * REQUIREMENT 5, HALF ONE: UNFLAGGING. `Is_Preferred_Broker__c` is one of `reselect`'s change
     * keys, so scoring resumes on the ordinary update hook — no delete context involved.
     *
     * 🔴 THE PREFERRED ROW HERE CARRIES A BOV AMOUNT, AND THAT IS NOT AN ARBITRARY FIXTURE CHOICE —
     * IT IS THE ONLY SHAPE THAT CAN BE UNFLAGGED AT ALL. `BOV_Amount_Required_On_Submission` is
     * `AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))`, so clearing the flag on an
     * UNQUOTED preferred row makes the rule's first clause true while the second still is, and the
     * platform REFUSES THE SAVE. `unflaggingAnUnquotedPreferredBroker_isRefusedByTheValidationRule`
     * immediately below pins that, because it is a real limitation with a real remedy (delete the
     * row instead) and it must not be discovered in UAT.
     */
    @isTest
    static void unflaggingTheLastPreferredBroker_resumesScoring() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c preferred = preferredBov(d.Id, 950000); // quoted, so it CAN be unflagged
        BOV_Submission__c strong = bov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ preferred, strong };
        assertSlots(d.Id, preferred.Id, strong.Id,
            'precondition: the preferred row holds the PREFERRED slot despite scoring below '
            + '`strong`, which holds the SCORED slot beside it — the coexistence that makes the '
            + 're-rank below observable');

        Test.startTest();
        update new BOV_Submission__c(Id = preferred.Id, Is_Preferred_Broker__c = false);
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, strong.Id,
            '🔴 Removing the last preferred broker must hand the sale back to SCORING and re-rank '
            + 'from the top. Still pointing at the ex-preferred row means the flag change was not '
            + 'one of the change keys, or the preferred branch is not reading the CURRENT value.');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(preferred.Id).Submission_Status__c,
            'and the now-ordinary, lower-scoring row is demoted');
    }

    /**
     * 🔴 A REAL LIMITATION, MEASURED 2026-08-24 WHILE BUILDING REQUIREMENT 5 — NOT A TEST OF THE
     * PLATFORM FOR ITS OWN SAKE.
     *
     * "Unflag the preferred broker and scoring resumes" DOES NOT WORK on the most common shape of
     * preferred row: an UNQUOTED one. `BOV_Amount_Required_On_Submission` exempts a row only while
     * `Is_Preferred_Broker__c` is true, so the very save that clears the flag is the save that
     * makes the amount mandatory, and the platform refuses it. The user never sees auto-selection
     * resume because the update never commits.
     *
     * ⇒ **THE REMEDY FOR AN UNQUOTED PREFERRED BROKER IS DELETE, NOT UNFLAG**, which is exactly why
     * the `after delete` trigger context was added in the same change
     * (`deletingThePreferredBroker_resumesScoring`). Without that context this feature would have
     * had NO working withdrawal path at all for its normal case.
     *
     * ⚠ This is pinned rather than worked around because the fix is a DECLARATIVE one nobody has
     * asked for (relaxing the validation rule, or exempting on `ISCHANGED`), and quietly making the
     * Apex tolerate it would hide the fact that the button does nothing.
     */
    @isTest
    static void unflaggingAnUnquotedPreferredBroker_isRefusedByTheValidationRule() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        BOV_Submission__c strong = bov(d.Id, 1400000);
        insert new List<BOV_Submission__c>{ preferred, strong };
        assertSlots(d.Id, preferred.Id, strong.Id, 'precondition');

        Test.startTest();
        Boolean refused = false;
        try {
            update new BOV_Submission__c(Id = preferred.Id, Is_Preferred_Broker__c = false);
        } catch (DmlException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('BOV Amount'),
                'The refusal must be BOV_Amount_Required_On_Submission, not something else: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused,
            '⚠ IF THIS NOW SUCCEEDS, THE VALIDATION RULE HAS BEEN RELAXED and the limitation this '
            + 'test documents is gone — which would be good news. Re-point this test at the new '
            + 'behaviour and update the "delete, not unflag" note on '
            + 'BovAutoSelectionService.reselectForDeleted; do not simply delete it.');
        assertSlots(d.Id, preferred.Id, strong.Id,
            'and because the save was refused, NOTHING changed — the preferred broker still holds '
            + 'its slot and the scored winner still holds its own. The user clicked, saw an error '
            + 'about a field they were told was optional, and the sale is unchanged.');
    }

    /**
     * REQUIREMENT 5, HALF TWO: DELETION. 🔴 THIS IS THE HALF THAT NEEDED A WHOLE NEW TRIGGER
     * CONTEXT — `BovSubmissionTrigger` had NO delete context at all, so before this change deleting
     * the appointed broker left the sale with NO Selected submission and nothing to notice it.
     */
    @isTest
    static void deletingThePreferredBroker_resumesScoring() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        BOV_Submission__c strong = bov(d.Id, 1400000);
        BOV_Submission__c weak = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ preferred, strong, weak };
        assertSlots(d.Id, preferred.Id, strong.Id,
            'precondition: BOTH slots are filled, which is what makes "deleting the preferred row '
            + 'empties ONLY the preferred slot" a falsifiable claim');

        Test.startTest();
        delete preferred;
        Test.stopTest();

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, strong.Id,
            '🔴 Deleting the appointed broker must re-rank the sale. ZERO Selected rows here means '
            + 'the `after delete` context is missing and the sale silently lost its broker — which '
            + 'is exactly the state that existed before 2026-08-24.');
    }

    /** Deleting an ORDINARY, losing row must not disturb the appointment. */
    @isTest
    static void deletingALosingResponse_leavesTheAppointmentAlone() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c strong = bov(d.Id, 1400000);
        BOV_Submission__c weak = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ strong, weak };
        Assert.areEqual(new List<Id>{ strong.Id }, selectedIdsOn(d.Id), 'precondition');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        delete weak;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // ── 🔴 RE-DERIVED 2026-08-31 (Tranche 1 item 7). THIS WAS `areEqual(1, dmlUsed, …)`. ──────
        // The claim being asserted has NOT changed and must not be weakened: THIS SERVICE still
        // writes nothing when the answer did not move. What changed is that `afterDelete` gained a
        // SECOND job — `DispositionCounterRollupService`, maintaining
        // `Disposition__c.Responses_Received__c` — and that one has no idempotency short-circuit
        // and must not have one: a deleted submission is one fewer response, unconditionally.
        //   1  this test's own `delete weak`
        //   1  the counter's parent `Database.update` (ONE per chunk; this is one chunk)
        //   0  BovAutoSelectionService — the subject of this test, and still zero
        // 🔴 IF THIS READS 3, THE IDEMPOTENCY SHORT-CIRCUIT THIS TEST EXISTS FOR IS GONE. The
        // assertion still fails for exactly the reason it always did; only the baseline moved.
        Assert.areEqual(2, dmlUsed,
            'ONE for this delete itself and ONE for the Responses_Received__c recompute — the '
            + 'answer did not change, so BovAutoSelectionService\'s idempotency short-circuit must '
            + 'still write NOTHING. A third statement means that short-circuit is gone. '
            + 'DML used: ' + dmlUsed);
        assertExactlyOneSelected(d.Id, strong.Id, 'and the appointment is untouched');
    }


    /**
     * TIES. Two identical amounts produce two identical scores, so the appointment is decided
     * entirely by `CreatedDate ASC, Id ASC`.
     *
     * ⚠ THE ASSERTION IS DELIBERATELY "THE WINNER IS THE ROW THE SELECTOR RANKS FIRST" RATHER THAN
     * A HARD-CODED ROW. Both rows are created in the SAME transaction, so `CreatedDate` ties too
     * and `Id ASC` decides — and Salesforce does not promise that Ids issued in sequence sort in
     * insertion order. Pinning a specific row would make this test flaky for a reason that has
     * nothing to do with the code. What the feature actually CONTRACTS is that the green Selected
     * pill lands on the TOP ROW OF THE MATRIX, and the matrix and the algorithm read the same
     * ORDER BY — which is exactly what this asserts.
     */
    @isTest
    static void tiedScores_theAppointmentGoesToTheRowRankedFirst() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');

        Test.startTest();
        insert new List<BOV_Submission__c>{ bov(d.Id, 1200000), bov(d.Id, 1200000) };
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = stateOf(d.Id);
        List<Decimal> scores = new List<Decimal>();
        for (BOV_Submission__c s : after.values()) {
            Assert.isNotNull(s.BOV_Score__c, 'precondition: both rows must be scoreable');
            scores.add(s.BOV_Score__c);
        }
        Assert.areEqual(scores[0], scores[1],
            'precondition: this test is about a TIE — if the scores differ the tie-break is not '
            + 'what decided the outcome and the assertion below proves nothing');

        List<BOV_Submission__c> ranked =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(new Set<Id>{ d.Id });
        assertExactlyOneSelected(d.Id, ranked[0].Id,
            'On a tie the appointment must go to the row the SELECTOR ranks first (oldest, then '
            + 'lowest Id) — the same order c/bovComparisonMatrix displays. Any other answer puts '
            + 'the green Selected pill on a row that is not the top row of the table.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // IDEMPOTENCY
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Re-running when the answer is already correct must write NOTHING — otherwise every BOV save
     * in the org would issue a pointless DML and re-fire the whole trigger stack.
     */
    @isTest
    static void reRunningWhenAlreadyCorrect_writesNothing() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c winner = bov(d.Id, 1400000);
        BOV_Submission__c loser = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ winner, loser };
        Assert.areEqual(new List<Id>{ winner.Id }, selectedIdsOn(d.Id), 'precondition');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        // A qualifying change (Days_To_Market__c is a scoring input) that does NOT alter the order.
        update new BOV_Submission__c(Id = loser.Id, Days_To_Market__c = 31);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed,
            'Only this test\'s own update. A second DML means the idempotency short-circuit is '
            + 'gone and every save re-writes the same answer.');
        assertExactlyOneSelected(d.Id, winner.Id, 'and the answer is unchanged');
    }

    /**
     * The re-entrancy stop. The service\'s own `Database.update` re-fires `afterUpdate`, which
     * routes straight back here because `Submission_Status__c` just changed. It TERMINATES without
     * the flag (the second pass computes zero writes) — the flag is about COST.
     */
    @isTest
    static void theSwapDoesNotReEnterItself() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = bov(d.Id, 900000);
        insert incumbent;
        // Built OUTSIDE the window — see everyScoreNull_appointsNobodyAndWritesNothing for the
        // measured incident. (It happens to be free here because the line above already warmed the
        // factory's shared broker Contact, but relying on call ORDER for a governor assertion is
        // exactly the fragility that bit once.)
        BOV_Submission__c challenger = bov(d.Id, 1400000);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert challenger;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // ── 🔴 RE-DERIVED 2026-08-31 (Tranche 1 item 7). THIS WAS `areEqual(2, dmlUsed, …)` with
        // the message "ONE for this test's own insert, ONE for the service's swap." Both of those
        // are still true and still counted; a THIRD joined them:
        //   1  this test's own `insert challenger`
        //   1  BovAutoSelectionService's swap — the subject of this test
        //   1  DispositionCounterRollupService's parent write (Responses_Received__c), ONE per
        //      chunk, in afterInsert. It runs AFTER the swap and the swap's own re-fired
        //      afterUpdate costs it NOTHING (the lookup did not move -> zero-query fast path).
        // 🔴 A FOURTH STILL MEANS THE SERVICE'S OWN WRITE RE-ENTERED ITSELF — the shape this repo
        // has a measured incident for (trigger-cascade-on-bulk-insert). The failure mode this
        // assertion guards is unchanged; only the baseline moved.
        Assert.areEqual(3, dmlUsed,
            'ONE for this test\'s own insert, ONE for the service\'s swap, ONE for the '
            + 'Responses_Received__c recompute. A FOURTH would mean the service\'s own write '
            + 're-entered it and wrote again — the shape this repo has a measured incident for '
            + '(trigger-cascade-on-bulk-insert). DML used: ' + dmlUsed);
        // ── 🔴 THE QUERY ASSERTION IS THE ONLY THING THAT CAN FALSIFY `suppressReentry` ────────
        // MEASURED 2026-08-24: deleting the flag's early return leaves EVERY OTHER TEST IN THIS
        // TRANCHE GREEN. The recursion terminates on its own (the second pass finds the winner
        // already Selected and alone and computes zero writes), so the DML count above does not
        // move and no end state changes. The ONLY observable is the wasted query. Without this
        // line the flag would be unfalsifiable code that a future "simplification" could delete
        // with a fully green suite — and this repo has a measured incident
        // (trigger-cascade-on-bulk-insert) where exactly that shape cost 23 SOQL at production
        // scale.
        // THE THREE, DERIVED:
        //   1. BovSubmissionBrokerStampService's Contact read (Broker__c goes null -> set on
        //      insert, which is always "changed"), in beforeInsert;
        //   2. BovAutoSelectionService's own selection read, in afterInsert;
        //   3. BovSubmissionSelectionGuardService's sibling read in the beforeUpdate of the
        //      service's OWN swap — the challenger is becoming Selected there, so the guard's
        //      zero-query fast path does not apply.
        // A FOURTH would be the re-entrant selection read the flag exists to prevent.
        //   ⚠ RE-DERIVED 2026-08-31 (Tranche 1 item 7). THE THREE ABOVE ARE UNCHANGED AND ARE
        //   STILL THE POINT. A FOURTH JOINED THEM, AND IT IS NOT THE RE-ENTRANT ONE:
        //   4. BovSubmissionSelector.countByDispositionIds — the Responses_Received__c aggregate,
        //      ONE per chunk, in afterInsert. The counter's own parent `Database.update` on
        //      Disposition__c adds ZERO queries.
        //      ⚠ CORRECTED 2026-08-31 (Tranche 1 code review, W-1). RETRACTED: "DispositionTrigger
        //      Handler's TWO consumers are change-keyed on Disposition_Stage__c and
        //      Approval_Advance_Pending__c, neither of which this shell touches (VERIFIED against
        //      those methods, not assumed)." Two things were wrong with it, and the CONCLUSION —
        //      zero queries — survives both.
        //        (a) There are FOUR consumers, not two. `DispositionTrigger` is `(before insert,
        //            before update, after insert, after update)` and the shell `Database.update`
        //            fires the before contexts too: `DispositionStageEntryService.stampListing
        //            Dates` (pure in-memory, zero SOQL on every path) and `DispositionBrokerStamp
        //            Service.stampSelectedBrokerLabel` (change-keyed on `Broker__c`, returns
        //            before its one Contact query). Both are free for this shell, which is why
        //            the 4 below does not move. The full four-way audit is in
        //            `DispositionCounterRollupService.applyCounts`'s javadoc.
        //        (b) "VERIFIED" overclaimed. Nothing in this tranche has been compiled, deployed
        //            or run — every governor figure here is DERIVED FROM SOURCE. The deploy will
        //            settle them.
        //   🔴 SO A **FIFTH** IS NOW THE RE-ENTRANT SELECTION READ. That is the whole reason this
        //   assertion exists and the reason it must stay EXACT rather than becoming `<=`: it is the
        //   ONLY observable that can falsify `suppressReentry` — measured 2026-08-24, deleting the
        //   flag's early return leaves every other test in this tranche green.
        Assert.areEqual(4, queriesUsed,
            '🔴 A FIFTH QUERY MEANS `suppressReentry` IS GONE: the service\'s own Database.update '
            + 're-fired afterUpdate, which routed straight back into reselect because '
            + 'Submission_Status__c had just changed. The fourth is the Responses_Received__c '
            + 'aggregate (2026-08-31) and is expected. Queries used: ' + queriesUsed);
        Assert.isFalse(BovAutoSelectionService.suppressReentry,
            '🔴 The re-entrancy flag must be RESET after every run. Left true it would silently '
            + 'disable auto-selection for the rest of the transaction — which is exactly why it is '
            + 'reset in a finally block.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE SHARING ESCAPE — THE ONLY TEST HERE THAT CAN FAIL ON IT
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ⚠ EVERY TEST ABOVE THIS LINE WOULD PASS AGAINST A `with sharing` VERSION OF THE WRITE. They
    // run as the admin test user, who OWNS every fixture row, and an owner of an OWD-Private record
    // always holds record-level edit — so the question that fails in production is never asked.
    // Here the SIBLING BEING DEMOTED stays owned by the admin and the RUNNING USER is a
    // Minimum-Access principal carrying DPEG_Disposition_Edit: viewAllRecords, NO modifyAllRecords.
    //
    // ⚠ THE TRIGGERING SAVE IS AN UPDATE ON A ROW THE PERSONA OWNS, NOT AN INSERT. That is
    // deliberate scaffolding: an insert would additionally require cross-reference access to the
    // broker Contact and would fail for a reason unrelated to the subject. The SUBJECT is the
    // DEMOTION of the row the persona does not own.

    private static void assertReadableButNotEditable(Id submissionId) {
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :submissionId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the saver must be able to READ the sibling — that is what '
            + 'DPEG_Disposition_Edit.viewAllRecords grants, and it is why the selection read '
            + 'succeeds and then hides the write failure.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the saver must NOT be able to EDIT the sibling. That is the '
            + 'whole point. If this is true the persona gained record-level edit from somewhere '
            + '(modifyAllRecords, a role, a widened sharing rule) and every assertion after it is '
            + 'vacuous. Investigate the org; do NOT delete this assertion.');
    }

    /**
     * Fails RED if `BovAutoSelectionService.SelectionWrites` is removed and the `Database.update`
     * is inlined into the `with sharing` outer class. `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS
     * and NEVER sharing (ARCHITECTURE.md §2) — four sites in this module were fixed for exactly
     * this on 2026-08-21 after a measured production incident.
     */
    @isTest
    static void nonOwnerSaver_swapsAnUnownedSiblingAcrossTheSharingBoundary() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = bov(d.Id, 1400000);
        BOV_Submission__c challenger = bov(d.Id, 900000);
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        Assert.areEqual(new List<Id>{ incumbent.Id }, selectedIdsOn(d.Id),
            'precondition: the ADMIN-owned row holds the appointment');

        User saver = TestDataFactory.createNonOwnerDispositionApprover('bas1');
        // Only the CHALLENGER changes hands. The incumbent — the row that must be demoted — stays
        // with the admin, and that is the subject of this test.
        update new BOV_Submission__c(Id = challenger.Id, OwnerId = saver.Id);

        System.runAs(saver) {
            assertReadableButNotEditable(incumbent.Id);
            Test.startTest();
            // SYSTEM_MODE for FLS only — the persona may not hold edit FLS on every scoring input.
            // ⚠ IT DOES NOT WEAKEN THE TEST: SYSTEM_MODE never lifts sharing, so the DEMOTION of
            // the admin-owned incumbent is still refused unless SelectionWrites escapes it.
            Database.update(
                new BOV_Submission__c(Id = challenger.Id, BOV_Amount__c = 1450000),
                AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        assertScoresAreRanked(d.Id);
        Assert.areEqual(new List<String>(),
            BovAutoSelectionService.lastRunSelectionFailures,
            '🔴 THE SWAP WAS REFUSED. This list carries the platform StatusCode — read it in the '
            + 'message above. INSUFFICIENT_ACCESS_OR_READONLY means the `without sharing` escape '
            + '(SelectionWrites) has been removed or bypassed.');
        assertExactlyOneSelected(d.Id, challenger.Id,
            'A user who can SEE but not EDIT the incumbent must still be able to trigger the swap. '
            + 'Still pointing at the incumbent means the demotion was refused at RECORD level, '
            + 'which SYSTEM_MODE cannot fix.');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(incumbent.Id).Submission_Status__c,
            'and the unowned incumbent is the row that actually had to be written');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 251-RECORD BULK — .claude/rules/bulk-test-rule.md
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @param d      the priced parent.
     * @param ascending when true the LAST row built is the highest scorer.
     * @return the 251 unsaved submissions.
     */
    private static List<BOV_Submission__c> bulkRowsOn(Disposition__c d, Boolean ascending) {
        List<BOV_Submission__c> rows = new List<BOV_Submission__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            // Singular factory call on purpose: it reuses the shared broker Contact, so 251 rows
            // cost ONE Contact insert instead of 251 and the 150-DML-statement limit is untouched.
            rows.add(bov(d.Id, 1000000 + (ascending ? i : BULK_N - i) * 1000));
        }
        return rows;
    }

    private static BOV_Submission__c highestScorerOn(Id dispositionId) {
        BOV_Submission__c best;
        for (BOV_Submission__c s : stateOf(dispositionId).values()) {
            if (best == null || s.BOV_Score__c > best.BOV_Score__c) {
                best = s;
            }
        }
        return best;
    }

    /**
     * 🔴 251 ROWS ON ONE DISPOSITION SPAN TWO CHUNKS (200 + 51), so auto-selection runs TWICE and
     * the appointment legitimately flips: chunk 1 appoints the best of the first 200, chunk 2 sees
     * all 251 and corrects it. THE ASSERTION IS THE END STATE, NOT THE NUMBER OF FLIPS.
     *
     * ⚠ THE DML ASSERTION IS THE HIGH-VALUE HALF. A per-RECORD write would still leave exactly one
     * Selected row and pass the end-state assertion, while burning 251 DML statements — it would
     * blow the 150-statement limit somewhere between here and production scale and nothing above
     * would notice.
     */
    @isTest
    static void bulk251Insert_appointsTheGlobalWinnerAtConstantCost() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        List<BOV_Submission__c> rows = bulkRowsOn(d, true);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert rows; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // ── 🔴 RE-DERIVED 2026-08-31 (Tranche 1 item 7). WAS `areEqual(3, dmlUsed)` / `<= 8`. ─────
        // The CLAIM is unchanged and is the only thing that matters: cost is CONSTANT PER CHUNK,
        // never per record. Two new terms joined it, both per chunk:
        //   DML   1 own insert + 2 selection writes (1/chunk) + 2 counter writes (1/chunk) = 5
        //   SOQL  as before, plus ONE Responses_Received__c aggregate per chunk = +2
        // 🔴 THE DML ASSERTION STAYS EXACT. A per-record counter write would read ~251 here and is
        // precisely the defect this line catches; loosening it to `<=` would forfeit that.
        Assert.areEqual(5, dmlUsed,
            'ONE for this line\'s own insert, plus ONE selection write PER CHUNK and ONE '
            + 'Responses_Received__c write PER CHUNK — 251 rows is TWO chunks, so exactly '
            + '1 + 2 + 2 = 5. A per-record write would read close to 251 and would exhaust the '
            + '150-statement limit long before reaching 251. DML used: ' + dmlUsed);
        Assert.isTrue(queriesUsed <= 12,
            'PER-CHUNK CONSTANT BUDGET: one selection query, one broker-stamp Contact query, one '
            + 'exclusivity-guard query on the service\'s own write, and (since 2026-08-31) one '
            + 'Responses_Received__c aggregate — FOUR per chunk, two chunks, plus headroom. '
            + '⚠ THE BOUND MOVED FROM 8 TO 12 BECAUSE THE BUDGET GREW, NOT TO MAKE A FAILURE PASS: '
            + '8 was 3/chunk + headroom and the fourth query consumed all of it. A per-record query '
            + 'would still read close to 251. Queries used: ' + queriesUsed);

        assertScoresAreRanked(d.Id);
        assertExactlyOneSelected(d.Id, highestScorerOn(d.Id).Id,
            'The GLOBAL highest scorer across all 251 must hold the appointment. A winner drawn '
            + 'from the first 200 means the SECOND chunk was dropped; two Selected rows mean the '
            + 'chunks fought.');
    }

    /**
     * The 251-record UPDATE twin. Reversing every amount makes a DIFFERENT row the winner, so a
     * no-op implementation cannot pass.
     */
    @isTest
    static void bulk251Update_reRanksToTheNewGlobalWinner() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        List<BOV_Submission__c> rows = bulkRowsOn(d, true);
        insert rows;
        Id originalWinner = highestScorerOn(d.Id).Id;
        Assert.areEqual(new List<Id>{ originalWinner }, selectedIdsOn(d.Id), 'precondition');

        // Reverse the ranking: row i now carries what row (N-1-i) carried.
        List<BOV_Submission__c> reversals = new List<BOV_Submission__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            reversals.add(new BOV_Submission__c(
                Id = rows[i].Id,
                BOV_Amount__c = 1000000 + (BULK_N - 1 - i) * 1000
            ));
        }

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        update reversals; // 251 rows -> TWO trigger chunks
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // ── 🔴 TWO, NOT THREE, AND THE DERIVATION IS THE POINT (measured 2026-08-24) ───────────
        // The insert twin above costs 3 (one per chunk plus the caller's own). This one costs 2,
        // and BOTH orderings of the tie below produce 2 — so it is exact, not lucky:
        //   During chunk 1 the platform has applied the new amounts to rows 0-199 ONLY; rows
        //   200-250 still hold their OLD values. rows[0]'s NEW amount and rows[250]'s OLD amount
        //   are both 1,250,000 — a genuine TIE at the top.
        //     - if chunk 1 breaks that tie to rows[0]: it writes ONCE (demote rows[250], promote
        //       rows[0]); chunk 2 then finds rows[0] still the global winner and already Selected
        //       and alone, so the IDEMPOTENCY short-circuit writes NOTHING.  1 + 1 = 2.
        //     - if chunk 1 breaks it to rows[250] (already Selected and alone): chunk 1 writes
        //       NOTHING; chunk 2, now seeing every new amount, writes ONCE.  1 + 1 = 2.
        // ⚠ A NAIVE "one write per chunk" EXPECTATION OF 3 IS WRONG AND WAS MEASURED WRONG. The
        // real contract is AT MOST one write per chunk, and the short-circuit is why it can be
        // fewer. A per-RECORD write would read close to 251 and blow the 150-statement limit.
        Assert.areEqual(2, dmlUsed,
            'ONE for this line\'s own update, plus AT MOST ONE selection write per chunk — and '
            + 'exactly one of the two chunks short-circuits on this fixture, either way. Constant '
            + 'in the number of submissions; a per-record write would read close to 251.');
        assertScoresAreRanked(d.Id);
        Id newWinner = highestScorerOn(d.Id).Id;
        Assert.areNotEqual(originalWinner, newWinner,
            'precondition: the reversal really did move the top score to a different row — if it '
            + 'did not, the assertion below would pass against a no-op');
        assertExactlyOneSelected(d.Id, newWinner,
            'The appointment must follow the new global winner across BOTH chunks');
    }

    /**
     * 251 submissions spread over 251 SEPARATE dispositions — the shape a data load actually takes,
     * and the one where a per-disposition query would blow the 100-SOQL limit at row 101.
     */
    @isTest
    static void bulk251AcrossManyDispositions_appointsOnePerSaleAtConstantCost() {
        List<Disposition__c> dispositions = TestDataFactory.createPricedDispositions(
            BULK_N, assetId(), ASKING_PRICE, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'BOV Outreach';
        }
        insert dispositions;

        List<BOV_Submission__c> rows = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            rows.add(bov(d.Id, 1200000));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert rows;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        // ⚠ BOUND RAISED FROM 8 TO 12 ON 2026-08-31 (Tranche 1 item 7), FOR A BUDGET THAT GREW
        // RATHER THAN A FAILURE THAT NEEDED HIDING. `DispositionCounterRollupService` adds ONE
        // aggregate PER CHUNK (two chunks = +2), and it is keyed on the whole `Set<Id>` of parents
        // exactly as the selection read is — which is the property this test measures. 🔴 THE
        // CLAIM IS UNCHANGED AND IS THE ONLY THING THAT MATTERS: 251 SEPARATE DISPOSITIONS MUST NOT
        // COST 251 QUERIES. Both new queries are per-chunk, so this bound is still a constant and
        // still fails at row 101 if either read is ever moved inside a per-disposition loop.
        Assert.isTrue(queriesUsed <= 12,
            '🔴 ONE selection query and ONE Responses_Received__c aggregate PER CHUNK, each keyed '
            + 'on the whole Set<Id> of parents, never one per disposition. 251 dispositions would '
            + 'be 251+ queries and would fail at row 101. Queries used: ' + queriesUsed);
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM BOV_Submission__c
             WHERE Disposition__c IN :dispositions AND Submission_Status__c = :SELECTED],
            'Every one of the 251 sales must have appointed its lone candidate. A total below 251 '
            + 'means the second trigger chunk was dropped.');
    }

    /**
     * 🔴 THE NON-OWNER TWIN FOR THE PREFERRED PATH — REPOINTED 2026-08-24, AND THE REASON IT HAD TO
     *    BE IS ITSELF A FINDING WORTH KEEPING.
     *
     * ⚠ WHAT THIS TEST USED TO DO NO LONGER CROSSES THE SHARING BOUNDARY AT ALL. It flagged a
     * saver-owned row as preferred and asserted that the ADMIN-owned scored winner was demoted.
     * Under the two-slot model there IS no such demotion — the preferred row is promoted BESIDE the
     * scored winner and the only row written is the saver's own. Left as it was, the test would
     * have gone GREEN AND VACUOUS: deleting `SelectionWrites`' `without sharing` escape would not
     * have reddened it, because nothing unowned is written on that path any more.
     *
     * 🔴 SO IT NOW DRIVES THE ONE PREFERRED-SLOT BRANCH THAT STILL WRITES AN UNOWNED ROW: THE
     * PREFERRED **DEMOTION**. Reaching it needs a superseded preferred row that is still Selected,
     * which `BovPreferredBrokerService` normally makes unreachable by deleting it — so the fixture
     * uses the UNDELETE GAP, exactly as
     * `DispositionApprovalServiceTest.submitAtBovOutreach_twoSelectedSubmissions...` does, and for
     * the same reason: a restored row arrives with no SELECTION automation having seen it. That is
     * a real production path, not a contrivance.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ RETRACTED IN PLACE 2026-08-31 (Tranche 1 code review, W-3 — this file was missed by the
     *   D-5 sweep of the same day, which stopped one file short).
     * ══════════════════════════════════════════════════════════════════════════════════════════
     *     RETRACTED: "the platform has no `before undelete` context and this trigger declares no
     *     `after undelete` one".
     *
     * THE SECOND CLAUSE IS FALSE. `BovSubmissionTrigger` gained `after undelete` on 2026-08-31
     * (design decision D-5), to route `DispositionCounterRollupService` and nothing else.
     *
     * THE FIRST CLAUSE IS TRUE AND IS THE ONE THIS FIXTURE ACTUALLY DEPENDS ON, which is why the
     * fixture is unchanged and still works. TWO SEPARATE REASONS, and they are not the same one:
     *   - `BovSubmissionSelectionGuardService` runs in `before insert` / `before update`, and the
     *     platform still has no `before undelete` context AT ALL, so it cannot run on a restore
     *     however the trigger is wired.
     *   - `BovPreferredBrokerService.retireReplacedPreferred` and `BovAutoSelectionService.reselect`
     *     are AFTER-context (routed from `afterInsert` / `afterUpdate`), so for them the protection
     *     is not the platform — it is that `BovSubmissionTriggerHandler.afterUndelete` routes the
     *     counter and NOTHING ELSE. That is a standing rule recorded at that method, argued at
     *     `BovAutoSelectionService.reselectForDeleted`, and it is deliberately revocable by a
     *     single line of code. ⚠ Do not conflate the two: the first is a platform fact, the second
     *     is a decision, and only the second can be undone by accident.
     * 🔴 IF THIS FIXTURE EVER STARTS PRODUCING ONE ROW, THE CAUSE IS SOMETHING NEW BEING ROUTED
     * INTO `afterUndelete` — not a bug in the service under test. Read that standing rule first.
     *
     * ⚠ NOT A DUPLICATE of `nonOwnerSaver_swapsAnUnownedSiblingAcrossTheSharingBoundary`, which
     * covers the SCORED demotion. Two branches, two falsifiers.
     */
    @isTest
    static void nonOwnerSaver_preferredDemotionCrossesTheSharingBoundary() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');

        // ── The undelete gap, step by step. Reordering these breaks the fixture. ──
        BOV_Submission__c stale = unquotedPreferredBov(d.Id);
        insert stale;                       // promoted into the preferred slot
        Test.setCreatedDate(stale.Id, System.now().addMinutes(-10));
        delete stale;                       // SOQL stops seeing it, so the retirement service does too
        BOV_Submission__c current = unquotedPreferredBov(d.Id);
        insert current;                     // retirement finds ONE preferred row: nothing to retire
        // ⚠ CORRECTED 2026-08-31 (W-3). This line read "no undelete context anywhere on this
        // trigger". `BovSubmissionTrigger` HAS declared `after undelete` since 2026-08-31 (D-5) —
        // it routes the response counter ONLY. What the fixture depends on is untouched: no
        // BEFORE undelete context exists on the platform, and neither the retirement service nor
        // auto-selection is routed into the new after context.
        undelete stale;                     // no SELECTION automation sees a restore

        Assert.areEqual(2, [
            SELECT COUNT() FROM BOV_Submission__c
            WHERE Disposition__c = :d.Id AND Submission_Status__c = 'Selected'
              AND Is_Preferred_Broker__c = TRUE
        ], 'PREMISE — two Selected preferred rows must really exist, or the demotion branch below '
            + 'is never entered and this test passes vacuously. A 1 here means something was '
            + 'routed into BovSubmissionTrigger.afterUndelete that RE-DECIDES which row is '
            + 'Selected — the counter that lives there today cannot, it never reads '
            + 'Submission_Status__c. Read the standing rule at '
            + 'BovSubmissionTriggerHandler.afterUndelete before touching this test.');

        User saver = TestDataFactory.createNonOwnerDispositionApprover('bas2');
        // Only the CURRENT row changes hands. The row that must be DEMOTED stays with the admin.
        update new BOV_Submission__c(Id = current.Id, OwnerId = saver.Id);

        System.runAs(saver) {
            assertReadableButNotEditable(stale.Id);
            Test.startTest();
            // Any change key on a row the saver owns re-ranks the sale. `Days_To_Market__c` is a
            // scoring input and therefore a key; it touches neither slot directly, so the demotion
            // below is unambiguously auto-selection's own work.
            Database.update(
                new BOV_Submission__c(Id = current.Id, Days_To_Market__c = 45),
                AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            BovAutoSelectionService.lastRunSelectionFailures,
            '🔴 THE DEMOTION WAS REFUSED — read the StatusCode above. '
            + 'INSUFFICIENT_ACCESS_OR_READONLY means the `without sharing` escape on '
            + 'SelectionWrites has been removed or bypassed.');
        assertSlots(d.Id, current.Id, null,
            'The NEWEST preferred row keeps the slot and the superseded one is demoted — even '
            + 'though the row that had to be written belongs to somebody else');
        Assert.areEqual(BACKUP, stateOf(d.Id).get(stale.Id).Submission_Status__c,
            'and the unowned superseded row is the one that actually had to be written');
    }

    /**
     * 251 PREFERRED ROWS ON ONE DISPOSITION — `.claude/rules/bulk-test-rule.md`, applied to the
     * branch the scored bulk tests never touch.
     *
     * 🔴 IT IS ALSO THE ONLY BULK PROOF THAT `isNewer` IS A **TOTAL** ORDER. All 251 rows are
     * created in the same transaction and every one is unscoreable, so `CreatedDate` ties across
     * the whole set and the `Id` tie-break decides ALONE. If that leg were non-deterministic the
     * two chunks could disagree and leave two Selected rows — which the end-state assertion catches.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 AMENDED 2026-08-24 — AND WHAT CHANGED IS WORTH READING BEFORE ANYONE "FIXES" THE NUMBERS.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 251 preferred rows on ONE disposition is now **250 SUCCESSIVE REPLACEMENTS**, because
     * `BovPreferredBrokerService` retires the outgoing preferred broker every time a new one
     * arrives. So this insert now ends with exactly ONE surviving submission and 250
     * `BOV_Broker_Change__c` history rows — and it costs more DML than it used to, which is a real
     * consequence of the user's decision rather than a regression:
     *
     *   per chunk: 1 retirement history INSERT + 1 retirement DELETE + 1 selection UPDATE
     *              (the delete's own `after delete` re-rank is normally free, because the survivor
     *              is already correct by then)
     *   plus 1 for the caller's own insert. TWO chunks -> the assertion below.
     *
     * ⚠ THE PROPERTY THAT MATTERS IS UNCHANGED AND IS WHAT THE ASSERTION DEFENDS: the cost is
     * CONSTANT PER CHUNK, not per record. A per-record retirement would issue ~500 statements and
     * blow the 150-statement limit long before the end state was reached.
     */
    @isTest
    static void bulk251PreferredOnOneDisposition_retiresAllButTheNewest() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        List<BOV_Submission__c> rows = new List<BOV_Submission__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            rows.add(unquotedPreferredBov(d.Id));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert rows; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 RE-DERIVED 2026-08-31 (Tranche 1 item 7). WAS `<= 9` DML / `<= 12` SOQL.
        // ══════════════════════════════════════════════════════════════════════════════════════
        // This test's path fires `DispositionCounterRollupService` TWICE PER CHUNK, which is more
        // than anywhere else in the suite and is worth spelling out:
        //   - once in `afterInsert` (the arriving preferred rows), and
        //   - once in `afterDelete`, because the retirement DELETES the outgoing preferred row —
        //     and a deleted submission is genuinely one fewer response, so the counter MUST run
        //     there. The `afterUpdate` on the selection write costs nothing (the lookup did not
        //     move -> zero-query fast path).
        //   ⇒ +2 SOQL and +2 DML per chunk; TWO chunks ⇒ +4 each.
        //
        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 ARITHMETIC CORRECTED 2026-08-31 (Tranche 1 code review, W-8). READ THIS BEFORE
        //    QUOTING ANY NUMBER BELOW.
        // ══════════════════════════════════════════════════════════════════════════════════════
        //     RETRACTED: "DERIVED: DML 9 + 4 = 13. SOQL 12 + 4 = 16. The bounds below carry ONE
        //     statement of headroom over each, matching this file's existing 'plus headroom'
        //     convention."
        //
        // WHAT WAS WRONG: 9 was the previous BOUND, not the previous derived VALUE. Adding a new
        // term to a bound and calling the result "DERIVED" launders the old bound's slack into the
        // new one and then re-spends it — which repeals the very convention the sentence told the
        // next reader to follow. The direction is safe (`isTrue(x <= N)` cannot go red because N is
        // too large) and that is exactly why it would never have been caught by a test run.
        //
        // THE HONEST DML DERIVATION, FROM THIS METHOD'S OWN HEADER TERMS ("per chunk: 1 retirement
        // history INSERT + 1 retirement DELETE + 1 selection UPDATE ... plus 1 for the caller's own
        // insert"):
        //     old   1 + 3×2 = 7      (NOT 9 — 9 was the bound, carrying 2 of slack)
        //     new   7 + 4    = 11
        //   ⇒ the bound of 14 below carries THREE statements of headroom, not one.
        // ⚠ THIS FILE CONTAINS TWO DERIVATIONS THAT DISAGREE BY ONE TERM PER CHUNK, AND THAT IS
        // WHY THE BOUND IS NOT BEING TIGHTENED TO 12. The header calls the delete-cascade re-rank
        // "normally free"; the old assertion MESSAGE counted it, giving "at most FOUR per chunk"
        // and 1 + 4×2 = 9. Under that second reading the new figure is 13 and 14 carries one. The
        // two readings have never been reconciled against a run, so 14 stands as the safe upper
        // bound of both and the slack is DECLARED here rather than hidden.
        //
        // 🔴 AND THE SOQL SIDE CANNOT BE DERIVED AT ALL. The old bound of 12 is not term-derived
        // anywhere in this file or in `BovPreferredBrokerServiceTest`; it arrived as a bare number
        // ("widened by the retirement read and the delete-cascade re-rank and by nothing else")
        // with no per-chunk breakdown behind it. 12 + 4 = 16 and the 17 below therefore inherit an
        // unverified base: they are a bound, not a derivation, and this comment must not pretend
        // otherwise. ⚠ WHOEVER FIRST RUNS THIS TEST SHOULD RECORD THE ACTUAL `queriesUsed` HERE
        // and replace the whole SOQL bound with a term list, the way the DML side has one.
        //
        // ⚠ STANDING CONSTRAINT FOR EVERY FIGURE IN THIS BLOCK: DERIVED FROM SOURCE, NEVER
        // MEASURED. Nothing in this tranche has been compiled, deployed or run.
        // ⚠ THE PROPERTY UNDER TEST IS UNCHANGED AND IS WHY THE BOUNDS MAY MOVE AT ALL: the cost
        // must be CONSTANT PER CHUNK. Every added term is per-chunk. A per-record retirement or a
        // per-record counter write would read close to 500 and blow the 150-statement limit — 14
        // and 17 catch that exactly as 9 and 12 did.
        // 🔴 DO NOT RAISE THESE AGAIN WITHOUT DERIVING THE NEW TERM THE SAME WAY. A bound bumped to
        // make a red test green is how a per-record regression ships.
        Assert.isTrue(dmlUsed <= 14,
            '🔴 CONSTANT PER CHUNK, NOT PER RECORD. ONE for this insert plus at most SIX per chunk '
            + '(retirement history insert, retirement delete, the delete-cascade re-rank, the '
            + 'selection write, and the Responses_Received__c recompute in BOTH afterInsert and '
            + 'afterDelete). A per-record retirement would read close to 500 and exhaust the '
            + '150-statement limit. DML used: ' + dmlUsed);
        Assert.isTrue(queriesUsed <= 17,
            'PER-CHUNK CONSTANT BUDGET, widened by the retirement read, the delete-cascade re-rank '
            + 'and (since 2026-08-31) the two Responses_Received__c aggregates — and by nothing '
            + 'else. Queries used: ' + queriesUsed);
        List<BOV_Submission__c> survivors = [
            SELECT Id, Submission_Status__c FROM BOV_Submission__c
            WHERE Disposition__c = :d.Id WITH SYSTEM_MODE
        ];
        Assert.areEqual(1, survivors.size(),
            '🔴 EXACTLY ONE of the 251 preferred rows may SURVIVE. Every other one was replaced by '
            + 'the next, and "replaced" now means removed from the list. More than one means the '
            + 'retirement did not run across both chunks.');
        Assert.areEqual(SELECTED, survivors[0].Submission_Status__c,
            'and the survivor holds the preferred slot — two chunks disagreeing on the winner would '
            + 'show up here as a Backup survivor, i.e. isNewer() is not a total order over rows '
            + 'that share a CreatedDate.');
        Assert.areEqual(BULK_N - 1, [
            SELECT COUNT() FROM BOV_Broker_Change__c WHERE Disposition__c = :d.Id
        ], '🔴 ONE HISTORY ROW PER RETIREMENT, ACROSS BOTH CHUNKS. A count of 249 or 199 means one '
            + 'chunk logged nothing while still deleting — the exact failure mode this feature is '
            + 'built to make impossible.');
    }

    /**
     * 251 rows where a preferred row and a scored winner land in DIFFERENT chunks — the ordering
     * hazard a single-chunk test cannot reach.
     *
     * The preferred row is built LAST, so it lands in chunk 2 (rows 200-250) while chunk 1 has
     * already appointed a scored winner. The end state must still be the preferred row.
     */
    @isTest
    static void bulk251PreferredArrivingInTheSecondChunk_stillWins() {
        Disposition__c d = pricedDispositionAt('BOV Outreach');
        List<BOV_Submission__c> rows = new List<BOV_Submission__c>();
        for (Integer i = 0; i < BULK_N - 1; i++) {
            rows.add(bov(d.Id, 1000000 + i * 1000));
        }
        BOV_Submission__c preferred = unquotedPreferredBov(d.Id);
        rows.add(preferred); // index 250 -> chunk 2

        Test.startTest();
        insert rows;
        Test.stopTest();

        Assert.areEqual(preferred.Id, preferredSlotOn(d.Id),
            '🔴 An unquoted preferred row arriving in the SECOND chunk must take the PREFERRED slot '
            + 'on a sale chunk 1 had already given a scored winner. An empty slot means the '
            + 'preferred branch does not survive re-evaluation across chunks.');
        Id appointed = appointedSlotOn(d.Id);
        Assert.isNotNull(appointed,
            '🔴 AND THE SCORED SLOT MUST STILL BE FILLED. This is the two-slot half of the test: '
            + 'under the retracted "preferred pre-empts" rule the preferred row arriving in chunk 2 '
            + 'DEMOTED the scored winner, so a null here means that rule is back.');
        Assert.areNotEqual(preferred.Id, appointed,
            'and the two slots must be held by DIFFERENT rows');
        Assert.isTrue(stateOf(d.Id).get(appointed).Is_System_Selected__c,
            'the scored occupant carries Is_System_Selected__c, which is what tells the approval '
            + 'router which of the two Selected rows is the model pick');
    }
}
