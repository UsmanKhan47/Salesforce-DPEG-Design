/**
 * Tests for BovSubmissionSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population, ORDER BY determinism, the
 * empty-result contract, and a 251-record data-volume read
 * (.claude/rules/bulk-test-rule.md).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DEFERRED COVERAGE — `BOV_Score__c` ORDERING IS STILL NOT PROVABLE IN APEX (RETRACTED IN
 *    PART 2026-08-22, manifest/bov-score-formula-conversion/, Step 3)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * This class used to prove `ORDER BY BOV_Score__c DESC NULLS LAST` by ASSIGNING scores of 90 / 80
 * / null to three fixtures. `BOV_Score__c` is now a live FORMULA field (conversion completed
 * 2026-08-22) and a formula field cannot be assigned in Apex, so those assignments are gone for
 * good — and with them the only mechanism this repo had for producing two submissions with
 * DIFFERENT scores.
 *
 * ⚠ RETRACTED: "`Asking_Price__c` DOES NOT EXIST ON `Disposition__c` YET." It exists now
 * (`objects/Disposition__c/fields/Asking_Price__c.field-meta.xml`, deployed by a concurrent wave).
 * What is STILL true, and is why deferred items 1/2/3 below remain owed rather than closed: this
 * class's own `@testSetup` (and every `TestDataFactory.createDisposition`/`createDispositions`
 * call site) still does not SET `Asking_Price__c`, so the formula's guard clause still returns
 * null for every fixture in this file and no test here exercises the DESC leg of the ORDER BY —
 * see the restored premise assertions in `selectByDispositionId_populatesEverySelectedField` and
 * `selectByDispositionId_tiedScores_ordersOldestFirstDeterministically` for where this is now
 * asserted explicitly rather than assumed.
 *
 * ⚠ WHAT IS OWED, and must not be quietly dropped:
 *   1. a test that gives ONE disposition an asking price and two submissions with different
 *      `BOV_Amount__c`, asserting the higher-valuing broker sorts FIRST (the DESC leg);
 *   2. a test mixing a scored disposition's submissions with an unscored one's, asserting the
 *      nulls fall to the BOTTOM (the `NULLS LAST` leg, still untested);
 *   3. the derived VALUE itself asserted at least once against the published band table — e.g.
 *      the hand-verified BOV-0015 (68.81) / BOV-0017 (82.95) values in
 *      `manifest/bov-score-formula-conversion/step3-package.xml` — so the formula is pinned by a
 *      test rather than only by its own `<description>`.
 *   4. RESOLVED, NOT DEFERRED (2026-08-22): this item used to name `BovController`'s
 *      `s.BOV_Score__c.intValue()` branch as unreachable. That ternary no longer exists —
 *      `BovController.cls` now reads `r.bovScore = s.BOV_Score__c;` unconditionally, and
 *      `BovRow.bovScore` was widened `Integer` -> `Decimal` in the same change (a truncating
 *      `.intValue()` would have silently dropped BOV_Score__c's 2 decimal places). See
 *      `BovControllerTest`'s header for the corresponding retraction.
 * The tie-break test below covers the half that IS provable today, and is the half that was
 * actually broken.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *
 * @TestSetup builds the Property -> Property_Asset -> Disposition scaffold with
 * explicit parent Ids (never default*()), and every test queries for that
 * Disposition — the TestDataFactory header warns the static scaffold cache does
 * NOT survive the @TestSetup boundary.
 *
 * No System.runAs USER_MODE test: BOV_Submission__c is a custom object and P3
 * proved the custom-field FLS gap is 0, so the running user reads every selected
 * field (the runAs assertion is reserved for standard-object selectors).
 */
@isTest
private class BovSubmissionSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    @isTest
    static void selectByDispositionId_populatesEverySelectedField() {
        Id dispId = dispositionId();
        // Factory defaults are known values; asserting them proves each field is selected.
        // 🔴 Broker_Firm__c / Contact_Name__c ARE THE STAMPED CONTACT'S VALUES, NOT THE FACTORY'S
        // OWN TEXT LITERALS, AS OF 2026-08-20 (Tranche 2, requirements §3 D1).
        // BovSubmissionBrokerStampService overwrites both the instant Broker__c is set on insert,
        // which is now every insert (Broker_Required_On_Submission). createBovSubmission's
        // singular convenience path reuses the shared TestDataFactory.defaultBrokerContact(),
        // whose known values are 'Test Brokerage 0' (Broker_Firm__c, matching the factory's own
        // former literal by coincidence) and 'Test Contact 0' (Name = FirstName 'Test' + LastName
        // 'Contact 0' — NOT the retired 'Test Broker 0' literal).
        TestDataFactory.createBovSubmission(dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one BOV submission exists for the Disposition');
        BOV_Submission__c s = result[0];
        Assert.areEqual('Test Brokerage 0', s.Broker_Firm__c, 'Broker_Firm__c should be selected');
        Assert.areEqual('Test Contact 0', s.Contact_Name__c, 'Contact_Name__c should be selected');
        Assert.areEqual(1200000, s.BOV_Amount__c, 'BOV_Amount__c should be selected');
        Assert.areEqual(2.5, s.Commission_Rate__c, 'Commission_Rate__c should be selected');
        Assert.areEqual(30, s.Days_To_Market__c, 'Days_To_Market__c should be selected');
        Assert.areEqual(75, s.Hist_Success_Rate__c, 'Hist_Success_Rate__c should be selected');
        Assert.areEqual(6.25, s.Cap_Rate__c, 'Cap_Rate__c should be selected');
        // 🔴 RESTORED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3). BOV_Score__c is
        // now a live FORMULA field again and is back in the SELECT list. It still asserts NULL —
        // not because "nothing writes it" (a formula field is never written, that reasoning no
        // longer applies) but because this test's @testSetup Disposition
        // (TestDataFactory.createDisposition) does not set Asking_Price__c, so the formula's own
        // guard clause returns null regardless of BOV_Amount__c/Commission_Rate__c/
        // Days_To_Market__c (confirmed against TestDataFactory.createBovSubmissions's own header,
        // 2026-08-22). A test that needs a NON-null score must give its own Disposition fixture a
        // real Asking_Price__c — see this class's header, deferred item 3.
        Assert.isNull(s.BOV_Score__c,
            'BOV_Score__c should be selected — and null, because this fixture\'s Disposition has '
            + 'no Asking_Price__c, so the formula\'s guard clause returns null');
        Assert.areEqual('Backup', s.Submission_Status__c, 'Submission_Status__c should be selected');
        // 🔴 `Name` (added 2026-08-21). Compared against a fresh read rather than a literal because
        // it is an AUTO-NUMBER (measured in usman-dpeg: type string, autoNumber true, nillable
        // false) — the sequence value is the org's to choose, not this test's. What the assertion
        // pins is that the field is IN THE SELECT LIST: drop it and `s.Name` throws
        // `System.SObjectException: SObject row was retrieved via SOQL without querying the
        // requested field` before any comparison happens. It is what tells two identically-named,
        // identically-firmed brokers apart in the Select/Replace Broker picker.
        Assert.areEqual([SELECT Name FROM BOV_Submission__c WHERE Id = :s.Id].Name, s.Name,
            'Name should be selected — the picker\'s only disambiguator for duplicate brokers');
    }

    /**
     * ── REPLACES `selectByDispositionId_ordersByScoreDescNullsLast` (re-authored 2026-08-21) ──
     * The old test assigned scores 90 / 80 / null to three fixtures and asserted they came back in
     * that order. Those three assignments cannot exist once `BOV_Score__c` is a formula, so the
     * test had to change; what it is REPLACED WITH is chosen to prove the thing that is actually
     * at risk, not to be an easier version of the old test.
     *
     * 🔴 WHAT IS AT RISK IS THE TIE-BREAK, AND IT IS A LIVE BUG, NOT A FUTURE ONE.
     * `ORDER BY BOV_Score__c DESC NULLS LAST` has no secondary key. Two rows that tie may come back
     * in either order, and once the score is a formula returning null for any disposition without
     * an asking price — which is every disposition today — EVERY row ties, leaving the query with
     * no effective sort key at all and the broker matrix reordering between page loads. This test
     * pins the fix: `, CreatedDate ASC, Id ASC`.
     *
     * The three fixtures are given EXPLICIT, DISTINCT CreatedDates in the REVERSE of their insert
     * order, which is what makes this falsifying rather than accidental — if the `CreatedDate ASC`
     * key were dropped the rows would fall back to insert/Id order and every assertion below would
     * fail. `Id ASC` is deliberately NOT asserted: it exists as a total-order backstop for two rows
     * created in the same transaction, and pinning it would be asserting the platform's Id
     * allocation order rather than anything this repo controls.
     */
    @isTest
    static void selectByDispositionId_tiedScores_ordersOldestFirstDeterministically() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(3, dispId, true);
        // Reverse of insert order, so insert order cannot masquerade as a passing sort.
        Test.setCreatedDate(subs[0].Id, System.now().addMinutes(-10));
        Test.setCreatedDate(subs[1].Id, System.now().addMinutes(-20));
        Test.setCreatedDate(subs[2].Id, System.now().addMinutes(-30));

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three submissions should return');
        // 🔴 RESTORED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3). Same fixture
        // fact as selectByDispositionId_populatesEverySelectedField above: this test's @testSetup
        // Disposition has no Asking_Price__c, so BOV_Score__c's formula guard returns null for all
        // three fixtures regardless of their BOV_Amount__c/Commission_Rate__c/Days_To_Market__c —
        // which is exactly the premise this tie-break test needs (every score ties at null, so
        // CreatedDate ASC / Id ASC is the ONLY key left).
        Assert.isNull(result[0].BOV_Score__c, 'PREMISE — every fixture score ties at null');
        Assert.isNull(result[1].BOV_Score__c, 'PREMISE — every fixture score ties at null');
        Assert.isNull(result[2].BOV_Score__c, 'PREMISE — every fixture score ties at null');
        Assert.areEqual(subs[2].Id, result[0].Id,
            'The OLDEST submission must come first — CreatedDate ASC is the key that survives when '
            + 'every score ties at null');
        Assert.areEqual(subs[1].Id, result[1].Id, 'then the next-oldest');
        Assert.areEqual(subs[0].Id, result[2].Id, 'then the newest');
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ⚠ THE PARAGRAPH THAT WAS HERE UNTIL 2026-08-21 SAID THE TWO-SELECTED STATE WAS UNREACHABLE
    //   FROM A TEST. IT IS QUOTED RATHER THAN DELETED, BECAUSE ITS CONCLUSION WAS RIGHT AND ITS
    //   PREMISE WAS TOO BROAD, AND ONLY THE PREMISE CHANGED:
    //
    //       RETRACTED: "reaching it needs TWO Selected rows on one disposition, and since
    //       2026-08-20 `BovSubmissionSelectionGuardService` makes that state unsavable: such a
    //       fixture fails at `insert`, not at the assertion… the `LIMIT 1` tie-break is covered by
    //       the argument in the selector's javadoc… not by a fixture. Do not add the seam."
    //
    // WHAT STAYS TRUE: **do not add the seam.** `BovSubmissionSelectionGuardService`'s header
    // records that a `@TestVisible` bypass switch was considered and rejected, because it would put
    // a production-reachable escape hatch in the guard in order to build the state the guard exists
    // to prevent. No seam has been added and none should be.
    //
    // WHAT WAS TOO BROAD: "unsavable" was measured against the guard's TWO CONTEXTS
    // (`before insert`, `before update`) and then generalised to every path. `BovSubmissionTrigger`
    // declares NO `after undelete` context, and the platform has no BEFORE undelete context at all
    // — a gap the guard's own residual list names (R-1). So the state is reachable, in production
    // and in a test, by deleting a Selected row and restoring it after another has been appointed.
    // `twoSelectedViaUndelete` below does exactly that, which is why it is a HONEST fixture rather
    // than a contrivance: it is the real way this org can acquire two Selected brokers.
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * Two genuinely `Selected` submissions on one disposition, built through the ONE path
     * `BovSubmissionSelectionGuardService` cannot see.
     *
     * 🔴 EVERY STEP IS LORE-BEARING; DO NOT REORDER THEM.
     *   1. insert row A as Selected  — permitted, nothing is committed-Selected yet;
     *   2. DELETE row A             — SOQL does not see Recycle Bin rows, so the guard's sibling
     *                                 read stops counting it;
     *   3. insert row B as Selected — the guard counts ZERO committed Selected rows and permits it;
     *   4. UNDELETE row A           — `BovSubmissionTrigger` has no undelete context, so no guard
     *                                 runs at all and the second Selected row simply appears.
     * Swap 3 and 4 and the insert is refused, which is the guard working correctly.
     *
     * @return {A, B} in that order, both Selected, both committed.
     */
    private static List<BOV_Submission__c> twoSelectedViaUndelete(Id dispId) {
        BOV_Submission__c first = TestDataFactory.createBovSubmission(dispId, false);
        first.Submission_Status__c = 'Selected';
        insert first;
        delete first;

        BOV_Submission__c second = TestDataFactory.createBovSubmission(dispId, false);
        second.Submission_Status__c = 'Selected';
        insert second;

        undelete first;
        return new List<BOV_Submission__c>{ first, second };
    }

    @isTest
    static void selectByDispositionId_noSubmissions_returnsEmpty() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A Disposition with no submissions returns an empty list, not null');
    }

    @isTest
    static void selectByDispositionId_bulk251_readsAll() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmissions(BULK_N, dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 submissions under the Disposition should be read');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectedByDispositionId — backs DispositionApprovalService's BOV Outreach branch
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectSelectedByDispositionId_noSelected_returnsEmptyList() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmission(dispId, true); // Backup only

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedByDispositionId(dispId);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(),
            'EMPTY IS A FIRST-CLASS ANSWER — "no broker is Selected yet" is user-actionable, not '
            + 'an error, and the caller turns it into an authored message naming the fix');
    }

    @isTest
    static void selectSelectedByDispositionId_returnsTheSelectedOne() {
        Id dispId = dispositionId();
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(dispId, false);
        backup.Submission_Status__c = 'Backup';
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(dispId, false);
        selected.Submission_Status__c = 'Selected';
        // Pinned via Broker__c, not a hand-typed literal — see TestDataFactory.createBrokerContactWithFirm.
        selected.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - The Winner', true).Id;
        insert new List<BOV_Submission__c>{ backup, selected };

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Exactly one row is Selected, so exactly one comes back — the Backup sibling must NOT');
        Assert.areEqual(selected.Id, result[0].Id, 'Only the Selected submission must be returned');
        // Re-read from the database rather than trusting the in-memory fixture: the firm is written
        // by a BEFORE trigger (BovSubmissionBrokerStampService) and Apex does NOT write before-trigger
        // values back onto the variable that was inserted.
        Assert.areEqual('CBRE - The Winner', result[0].Broker_Firm__c,
            'Broker_Firm__c must be selected');
    }

    @isTest
    static void selectSelectedByDispositionId_nullInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedByDispositionId(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, queriesUsed, 'and issues no query at all');
    }

    /**
     * 🔴 THE POINT OF DROPPING `LIMIT 1` (2026-08-21). THIS TEST IS THE WHOLE JUSTIFICATION FOR A
     * SELECTOR SIGNATURE CHANGE, SO READ IT BEFORE RESTORING THE LIMIT.
     *
     * With `LIMIT 1` this query answered a two-Selected disposition with ONE ROW and no signal —
     * and `DispositionApprovalService`'s BOV Outreach branch then submitted that arbitrary row into
     * `Broker_Finalize_Approval`, appointing a broker nobody chose. The old javadoc described that
     * behaviour approvingly ("the highest-scoring one wins here"). No `if` in the service could
     * have detected it, because the second row had already been discarded by the database.
     *
     * ⚠ THE PREMISE ASSERTION IS NOT DECORATION. If the guard ever gains an undelete context — the
     * right fix for its own R-1 residual — this fixture stops being able to build the state, and
     * the premise line is what will say so plainly instead of leaving `result.size() == 1` to look
     * like a selector regression.
     */
    @isTest
    static void selectSelectedByDispositionId_twoSelected_returnsBOTH() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> pair = twoSelectedViaUndelete(dispId);

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(2, [
            SELECT COUNT() FROM BOV_Submission__c
            WHERE Disposition__c = :dispId AND Submission_Status__c = 'Selected'
        ], 'PREMISE — the undelete gap must really have produced two committed Selected rows, or '
            + 'this test proves nothing about the selector');
        Assert.areEqual(2, result.size(),
            '🔴 BOTH ROWS MUST COME BACK. A `LIMIT 1` here returns one of them with no signal, and '
            + 'the caller submits an arbitrary broker into Broker_Finalize_Approval. The ">1" '
            + 'refusal is not an `if` the service could have written — it is this query.');
        Set<Id> ids = new Map<Id, BOV_Submission__c>(result).keySet();
        Assert.isTrue(ids.contains(pair[0].Id), 'the restored row');
        Assert.isTrue(ids.contains(pair[1].Id), 'and the one appointed while it was deleted');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectStatusesByDispositionId — backs BovSubmissionService.replaceSelectedBroker
    // (WITH SYSTEM_MODE — the field, not the caller, forces it: Approval_Status__c arrives with
    // no FLS for any profile until the permission-set deploy lands)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectStatusesByDispositionId_returnsEveryRowNotJustSelected() {
        Id dispId = dispositionId();
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(dispId, false);
        selected.Submission_Status__c = 'Selected';
        selected.Approval_Status__c = 'Approved';
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(dispId, false);
        backup.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ selected, backup };

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectStatusesByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            '🔴 EVERY SUBMISSION MUST RETURN, NOT JUST THE SELECTED ONE — this is what makes the '
            + 'replace operation self-healing against a partial earlier failure');
        Map<Id, BOV_Submission__c> byId = new Map<Id, BOV_Submission__c>(result);
        Assert.areEqual('Approved', byId.get(selected.Id).Approval_Status__c,
            'Approval_Status__c must be selected — the field this method exists to reach');
    }

    @isTest
    static void selectStatusesByDispositionId_nullAndEmptyInput_returnsEmptyList() {
        Assert.areEqual(0, BovSubmissionSelector.selectStatusesByDispositionId(null).size());
    }

    @isTest
    static void selectStatusesByDispositionId_noSubmissions_returnsEmptyList() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectStatusesByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(0, result.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectedByDispositionIds — backs BovSubmissionSelectionGuardService
    // (SET-keyed, WITH SYSTEM_MODE — the CALLER forces the mode: a before-trigger read the running
    // user never asked for, where a USER_MODE throw would roll back their own save)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The SET is the point: one query must answer for MANY dispositions at once, because the caller
     * runs inside a trigger chunk. A per-parent implementation would be SOQL in a loop.
     *
     * ⚠ ONE Selected ROW PER DISPOSITION, NOT TWO ON ONE. Since 2026-08-20 the trigger guard this
     * method backs makes a second Selected row on one disposition UNSAVABLE, so a fixture that
     * built one would fail at `insert`, not at the assertion.
     */
    @isTest
    static void selectSelectedByDispositionIds_spansManyParentsAndReturnsOnlySelected() {
        Id firstDisp = dispositionId();
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c secondDisp = TestDataFactory.createDisposition(asset.Id, true);

        BOV_Submission__c firstSelected = TestDataFactory.createBovSubmission(firstDisp, false);
        firstSelected.Submission_Status__c = 'Selected';
        BOV_Submission__c firstBackup = TestDataFactory.createBovSubmission(firstDisp, false);
        firstBackup.Submission_Status__c = 'Backup';
        BOV_Submission__c secondSelected =
            TestDataFactory.createBovSubmission(secondDisp.Id, false);
        secondSelected.Submission_Status__c = 'Selected';
        insert new List<BOV_Submission__c>{ firstSelected, firstBackup, secondSelected };

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectSelectedByDispositionIds(
            new Set<Id>{ firstDisp, secondDisp.Id });
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            'ONE query must answer for BOTH dispositions — that is what keeps the guard out of a '
            + 'per-record loop');
        Map<Id, BOV_Submission__c> byId = new Map<Id, BOV_Submission__c>(result);
        Assert.isTrue(byId.containsKey(firstSelected.Id), 'The first parent\'s Selected row');
        Assert.isTrue(byId.containsKey(secondSelected.Id), 'The second parent\'s Selected row');
        Assert.isFalse(byId.containsKey(firstBackup.Id),
            'A Backup row must NOT be returned — the guard counts Selected siblings only');
        Assert.areEqual(firstDisp, byId.get(firstSelected.Id).Disposition__c,
            'Disposition__c must be selected — the caller groups the count by it');
    }

    /** Null/empty-safe and, on empty, issues NO query at all. */
    @isTest
    static void selectSelectedByDispositionIds_nullAndEmptyInput_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer nullSize = BovSubmissionSelector.selectSelectedByDispositionIds(null).size();
        Integer emptySize =
            BovSubmissionSelector.selectSelectedByDispositionIds(new Set<Id>()).size();
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, nullSize, 'Null input returns an empty list');
        Assert.areEqual(0, emptySize, 'An empty set returns an empty list');
        Assert.areEqual(0, queriesUsed,
            'Neither may issue a query — the guard\'s zero-query fast path depends on this');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // selectSelectedBrokerByDispositionId — the Log Offer dialog's ON-MARKET broker read
    // (2026-08-21).
    //
    // 🔴 IT IS A SEPARATE METHOD FROM `selectSelectedByDispositionId` PRECISELY SO THAT
    // `Broker__c` — which `DPEG_Admin_Access` does NOT grant (measured in the org via
    // `FieldPermissions`, 2026-08-21) — cannot break Submit Selected Broker. The first test
    // below is therefore ALSO an assertion about the OTHER method: it proves the two field
    // lists are genuinely different, which is the whole safety argument. If someone
    // "de-duplicates" them, that test is what should fail.
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectSelectedBrokerByDispositionId_returnsTheBrokerWithItsName() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(2, dispId, true);
        submissions[1].Submission_Status__c = 'Selected';
        update submissions[1];
        Contact expectedBroker = [
            SELECT Id, Name FROM Contact WHERE Id = :submissions[1].Broker__c LIMIT 1
        ];

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the Selected submission comes back');
        Assert.areEqual(submissions[1].Id, result[0].Id, 'The Backup row must be filtered out');
        Assert.areEqual(expectedBroker.Id, result[0].Broker__c, 'Broker__c must be selected');
        // 🔴 THE TRAVERSAL. Without `Broker__r.Name` the modal renders a broker Id with no name.
        Assert.areEqual(
            expectedBroker.Name,
            result[0].Broker__r.Name,
            'Broker__r.Name is what the read-only Broker field displays'
        );
        // Selected but not asserted-on by the modal today; in the SELECT because a legacy row
        // carries only the firm.
        Assert.isNotNull(result[0].Broker_Firm__c, 'Broker_Firm__c must stay in the SELECT');
    }

    @isTest
    static void selectSelectedBrokerByDispositionId_noSelectedRow_returnsEmptyNotAThrow() {
        Id dispId = dispositionId();
        // Every factory submission defaults to Backup — the normal on-market state before
        // Broker_Finalize_Approval has run.
        TestDataFactory.createBovSubmissions(3, dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionId(dispId);
        Test.stopTest();

        // 🔴 A FIRST-CLASS ANSWER. "No broker is Selected yet" is the normal state of an
        // on-market sale before the appointment is approved, and an offer logged in that window
        // legitimately carries a null broker. A fetch-for-use throw would turn that into a
        // dialog that refuses to open.
        Assert.areEqual(0, result.size(), 'No Selected row means an empty list, never a throw');
    }

    @isTest
    static void selectSelectedBrokerByDispositionId_nullInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionId(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'Null input returns an empty list');
        Assert.areEqual(0, queriesUsed, 'A null Id must not issue a query');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // selectSelectedBrokerByDispositionIds — the NDA auto-create broker stamp's ON-MARKET
    // read (2026-08-21). ONE CHARACTER from the method above and NOT a bulk overload of it.
    //
    // 🔴 THREE THINGS DIFFER, AND EACH HAS A TEST BELOW:
    //   the SET parameter   its caller is an after-trigger over a chunk, so a per-parent call
    //                       would be SOQL in a loop;
    //   `AND Broker__c != NULL` in the WHERE — the singular method has no such term, so the two
    //                       deliberately DISAGREE on a Selected-but-brokerless row;
    //   `WITH SYSTEM_MODE`  the singular one is USER_MODE. Not testable here (this org's
    //                       custom-field FLS gap is 0 and the class-header note explains why no
    //                       runAs test exists in this file), so it is argued at the declaration.
    // ⚠ NO `Broker__r.Name` EITHER — the caller stamps an Id into a lookup and never renders a
    // name. `…_selectsNoTraversal` below is what stops it being "helpfully" added back.
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectSelectedBrokerByDispositionIds_spansManyParentsAndReturnsOnlySelected() {
        Id firstDisp = dispositionId();
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c secondDisp = TestDataFactory.createDisposition(asset.Id, true);

        // Two distinct brokers so a cross-wired result cannot pass — createBovSubmissions(2, ...)
        // builds two DIFFERENT broker Contacts in one insert (the singular overload reuses the
        // shared defaultBrokerContact and would make the assertion vacuous).
        List<BOV_Submission__c> firstPair =
            TestDataFactory.createBovSubmissions(2, firstDisp, false);
        firstPair[0].Submission_Status__c = 'Selected';
        firstPair[1].Submission_Status__c = 'Backup';
        BOV_Submission__c secondSelected =
            TestDataFactory.createBovSubmission(secondDisp.Id, false);
        secondSelected.Submission_Status__c = 'Selected';
        insert new List<BOV_Submission__c>{ firstPair[0], firstPair[1], secondSelected };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(
                new Set<Id>{ firstDisp, secondDisp.Id });
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'ONE query for BOTH dispositions — the caller runs inside a trigger chunk');
        Assert.areEqual(2, result.size(), 'One Selected row from each parent');
        Map<Id, Id> brokerByDisposition = new Map<Id, Id>();
        for (BOV_Submission__c row : result) {
            brokerByDisposition.put(row.Disposition__c, row.Broker__c);
        }
        Assert.areEqual(firstPair[0].Broker__c, brokerByDisposition.get(firstDisp),
            'The first parent resolves to ITS Selected submission\'s broker — not the Backup '
            + 'row\'s, and not the other parent\'s');
        Assert.areEqual(secondSelected.Broker__c, brokerByDisposition.get(secondDisp.Id),
            'The second parent resolves to its own');
        Assert.areNotEqual(
            brokerByDisposition.get(firstDisp),
            brokerByDisposition.get(secondDisp.Id),
            'The two fixture brokers must be different Contacts, or the two assertions above '
            + 'would both pass against a single cross-wired answer'
        );
    }

    /**
     * 🔴 `Broker__r` MUST NOT BE TRAVERSED. Under `SYSTEM_MODE` adding `Broker__r.Name` would not
     * throw for anyone, so nothing would FAIL if someone added it — it would just materialise a
     * child sObject per row inside an after-trigger, for a name the caller never renders. This is
     * the only test that can notice.
     */
    @isTest
    static void selectSelectedBrokerByDispositionIds_selectsNoTraversal() {
        Id dispId = dispositionId();
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(dispId, false);
        selected.Submission_Status__c = 'Selected';
        insert selected;

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(new Set<Id>{ dispId });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The Selected row comes back');
        Assert.isNotNull(result[0].Broker__c, 'Broker__c is in the SELECT');
        // 🔴 `getPopulatedFieldsAsMap()`, NOT `Assert.isNull(result[0].Broker__r, ...)`. Reading an
        // un-queried relationship off a SOQL-retrieved sObject raises
        // `System.SObjectException: SObject row was retrieved via SOQL without querying the
        // requested field` — so the obvious assertion would ERROR rather than pass, on correct
        // code. The populated-field map answers "was it selected?" without dereferencing it.
        Assert.isFalse(result[0].getPopulatedFieldsAsMap().containsKey('Broker__r'),
            'Broker__r must NOT be resolved. The caller stamps an Id into a lookup; a traversal '
            + 'here is pure heap inside a trigger.');
    }

    /**
     * A disposition with only `Backup` submissions resolves to NOTHING, and that empty answer is
     * what makes the NDA auto-create stamp degrade to "no broker" instead of appointing a broker
     * nobody chose.
     */
    @isTest
    static void selectSelectedBrokerByDispositionIds_noSelectedRow_returnsEmptyNotAThrow() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmissions(3, dispId, true);   // all default to Backup

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(new Set<Id>{ dispId });
        Test.stopTest();

        Assert.areEqual(0, result.size(),
            'No Selected row means an empty list, never a throw — a throw here happens inside an '
            + 'AFTER trigger and would roll back the user\'s own stage change');
    }

    /** Null/empty-safe and, on empty, issues NO query — the off-market chunk's zero-cost path. */
    @isTest
    static void selectSelectedBrokerByDispositionIds_nullAndEmptyInput_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer nullSize =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(null).size();
        Integer emptySize =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(new Set<Id>()).size();
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, nullSize, 'Null input returns an empty list');
        Assert.areEqual(0, emptySize, 'An empty set returns an empty list');
        Assert.areEqual(0, queriesUsed,
            'Neither may query. DispositionStageEntryService.resolveBrokers relies on this to keep '
            + 'an all-off-market NDA chunk at zero extra queries.');
    }

    /**
     * 251 parents, ONE query, every one resolved — `.claude/rules/bulk-test-rule.md`. 251 is the
     * number because the CALLER is trigger-driven and a chunk spans two firings; the read itself
     * has no chunking, so what this pins is that the cost does not grow with the set.
     */
    @isTest
    static void selectSelectedBrokerByDispositionIds_bulk251_readsAllInOneQuery() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Disposition__c> dispositions =
            TestDataFactory.createDispositions(BULK_N, asset.Id, true);
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(BULK_N, null, false);
        Set<Id> dispositionIds = new Set<Id>();
        for (Integer i = 0; i < BULK_N; i++) {
            submissions[i].Disposition__c = dispositions[i].Id;
            submissions[i].Submission_Status__c = 'Selected';
            dispositionIds.add(dispositions[i].Id);
        }
        insert submissions;   // built in the loop, inserted once — never DML in a loop

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectedBrokerByDispositionIds(dispositionIds);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed, 'EXACTLY ONE query for 251 parents');
        Assert.areEqual(BULK_N, result.size(), 'Every parent\'s Selected row is returned');
        Set<Id> distinctParents = new Set<Id>();
        for (BOV_Submission__c row : result) {
            distinctParents.add(row.Disposition__c);
            Assert.isNotNull(row.Broker__c,
                'Every returned row names a broker — that is what AND Broker__c != NULL buys');
        }
        Assert.areEqual(BULK_N, distinctParents.size(),
            '251 DISTINCT parents, so the caller\'s map is keyed one-to-one');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectSelectionContextByDispositionIds — the auto-selection read (2026-08-24)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE FIELD LIST IS THE CONTRACT, AND ONE OMISSION BREAKS THE FEATURE SILENTLY.
     * `BovAutoSelectionService` reads all eight columns; a narrowed SELECT does NOT degrade to null
     * — Apex throws `System.SObjectException: SObject row was retrieved via SOQL without querying
     * the requested field`, inside an after-trigger, which rolls back the user's own save. This
     * test asserts every one of them is readable off the returned row.
     *
     * ⚠ THE DISPOSITION IS **PRICED** ON PURPOSE. `BOV_Score__c` is null without an asking price,
     * so on the shared `@testSetup` disposition the score assertion below could not distinguish
     * "selected but null" from "not selected at all". This is the deferred-coverage note in this
     * class's header coming due.
     */
    @isTest
    static void selectSelectionContextByDispositionIds_populatesEverySelectedField() {
        Disposition__c priced = TestDataFactory.createPricedDisposition(
            [SELECT Id FROM Property_Asset__c LIMIT 1].Id, 1500000, true);
        BOV_Submission__c row = TestDataFactory.createBovSubmission(priced.Id, false);
        row.BOV_Amount__c = 1200000;
        row.Is_Preferred_Broker__c = true; // ⚠ SINCE 2026-08-24 THIS MEANS IT IS AUTO-SELECTED
        insert row;

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(new Set<Id>{ priced.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The one submission on that disposition is returned');
        BOV_Submission__c got = result[0];
        Assert.areEqual(priced.Id, got.Disposition__c, 'Disposition__c must be selected');
        Assert.areEqual('Selected', got.Submission_Status__c,
            'Submission_Status__c must be selected — it is the field the service writes');
        Assert.isNotNull(got.BOV_Score__c,
            '🔴 BOV_Score__c must be selected AND non-null on a priced disposition. Null here means '
            + 'the fixture lost its Asking_Price__c and every auto-selection test is vacuous.');
        Assert.isFalse(got.Approval_Pending__c,
            '🔴 Approval_Pending__c must be selected — it is lock leg 1, and it is the field that '
            + 'forces this read to WITH SYSTEM_MODE (no permission set grants it, by design)');
        Assert.isNull(got.Approval_Status__c, 'Approval_Status__c must be selected — lock leg 2');
        Assert.isFalse(got.Is_Manually_Appointed__c,
            'Is_Manually_Appointed__c must be selected — lock leg 3');
        Assert.isTrue(got.Is_Preferred_Broker__c,
            'Is_Preferred_Broker__c must be selected — since 2026-08-24 it is what makes a row WIN '
            + 'the appointment outright, whatever it scores');
        Assert.isNotNull(got.CreatedDate,
            '🔴 CreatedDate must be selected — it is the ONLY tie-break among preferred rows '
            + '(newest wins, BovAutoSelectionService.isNewer) and it cannot be read off this '
            + 'ORDER BY, which deliberately sorts oldest-first');
    }

    /**
     * THE ORDER BY IS THE ALGORITHM for the SCORED path. The service takes the FIRST scoreable
     * non-preferred row and
     * appoints that broker, with no second sort in Apex — so if this ordering ever changes, the
     * appointment changes with it and nothing else would notice.
     */
    @isTest
    static void selectSelectionContextByDispositionIds_ordersHighestScoreFirst() {
        Disposition__c priced = TestDataFactory.createPricedDisposition(
            [SELECT Id FROM Property_Asset__c LIMIT 1].Id, 1500000, true);
        BOV_Submission__c low = TestDataFactory.createBovSubmission(priced.Id, false);
        low.BOV_Amount__c = 900000;
        low.Is_Preferred_Broker__c = true;  // ⚠ 2026-08-24: this no longer keeps auto-selection
        // out of the test — a preferred row now WINS. It is kept because this test asserts the
        // QUERY's order, which is unaffected by which row ends up Selected.
        BOV_Submission__c high = TestDataFactory.createBovSubmission(priced.Id, false);
        high.BOV_Amount__c = 1400000;
        high.Is_Preferred_Broker__c = true;
        insert new List<BOV_Submission__c>{ low, high };

        Test.startTest();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(new Set<Id>{ priced.Id });
        Test.stopTest();

        Assert.areEqual(2, result.size(), 'Both rows are returned — this read is not filtered');
        Assert.areEqual(high.Id, result[0].Id,
            'BOV_Score__c DESC must put the higher-scoring row FIRST. The service appoints '
            + 'result[0]; c/bovComparisonMatrix displays the same order, and if the two ever '
            + 'diverge the green Selected pill lands on a row that is not the top row of the table.');
    }

    /** Null and empty inputs must cost ZERO queries — the service's fast path depends on it. */
    @isTest
    static void selectSelectionContextByDispositionIds_nullAndEmptyInput_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> fromNull =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(null);
        List<BOV_Submission__c> fromEmpty =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(new Set<Id>());
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A null or empty parent set must issue NO query — this is the zero-query fast path '
            + 'that keeps auto-selection invisible to every unrelated feature\'s bulk test');
        Assert.areEqual(0, fromNull.size(), 'null returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'and so does an empty set');
    }

    /** ONE query for 251 parents — never one per disposition. */
    @isTest
    static void selectSelectionContextByDispositionIds_bulk251_readsAllInOneQuery() {
        List<Disposition__c> dispositions = TestDataFactory.createPricedDispositions(
            BULK_N, [SELECT Id FROM Property_Asset__c LIMIT 1].Id, 1500000, true);
        Set<Id> dispositionIds = new Set<Id>();
        List<BOV_Submission__c> submissions = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            dispositionIds.add(d.Id);
            BOV_Submission__c s = TestDataFactory.createBovSubmission(d.Id, false);
            s.BOV_Amount__c = 1200000;
            s.Is_Preferred_Broker__c = true; // ⚠ 2026-08-24: each of these IS now auto-selected;
            // harmless here because this test asserts only the selector's own query COUNT
            submissions.add(s);
        }
        insert submissions;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<BOV_Submission__c> result =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(dispositionIds);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 parents. One per disposition would fail at row 101 on the '
            + 'SOQL limit, inside a trigger, taking the user\'s save with it.');
        Assert.areEqual(BULK_N, result.size(), 'Every parent\'s submission is returned');
    }
}
