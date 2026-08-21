/**
 * Tests for BovSubmissionSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population, ORDER BY determinism, the
 * empty-result contract, and a 251-record data-volume read
 * (.claude/rules/bulk-test-rule.md).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DEFERRED COVERAGE — `BOV_Score__c` ORDERING IS NOT PROVABLE IN APEX RIGHT NOW (2026-08-21)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * This class used to prove `ORDER BY BOV_Score__c DESC NULLS LAST` by ASSIGNING scores of 90 / 80
 * / null to three fixtures. `BOV_Score__c` is being recreated as a FORMULA, and a formula field
 * cannot be assigned in Apex, so those assignments are gone — and with them the only mechanism
 * this repo had for producing two submissions with DIFFERENT scores.
 *
 * There is no substitute available yet, and that is worth stating plainly rather than papering
 * over: the formula's value dimension is gated on `Disposition__r.Asking_Price__c`, which returns
 * null for the whole score when the parent has no asking price. `Asking_Price__c` DOES NOT EXIST
 * ON `Disposition__c` YET (it ships in the same sequenced wave as the formula). Until it does,
 * every submission in every test — and every submission in the org — scores null, so no fixture
 * can make the DESC leg of that ORDER BY do anything observable.
 *
 * ⚠ WHAT IS OWED WHEN `Asking_Price__c` AND THE FORMULA LAND, and must not be quietly dropped:
 *   1. a test that gives ONE disposition an asking price and two submissions with different
 *      `BOV_Amount__c`, asserting the higher-valuing broker sorts FIRST (the DESC leg);
 *   2. a test mixing a scored disposition's submissions with an unscored one's, asserting the
 *      nulls fall to the BOTTOM (the `NULLS LAST` leg, which is currently dead syntax because
 *      everything is null);
 *   3. the derived VALUE itself asserted at least once against the published band table, so the
 *      formula is pinned by a test rather than only by its own `<description>`;
 *   4. `BovController`'s `s.BOV_Score__c.intValue()` branch (BovController.cls:87), whose non-null
 *      leg becomes UNREACHABLE from any test in the meantime — see `BovControllerTest`'s header.
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
        // 🔴 THE VALUE CHANGED, THE CLAIM DID NOT. This line used to read
        // `Assert.areEqual(80, s.BOV_Score__c, ...)`, where the 80 came from a hard-coded
        // TestDataFactory assignment that has been removed (a formula field cannot be assigned in
        // Apex). Asserting NULL is NOT a weaker test of the same claim, because the claim this line
        // makes is "BOV_Score__c is in the SELECT list" — and what falsifies THAT is the read
        // itself: touching a field omitted from a SOQL SELECT throws
        // `System.SObjectException: SObject row was retrieved via SOQL without querying the
        // requested field`, whatever value is asserted afterwards. Drop the field from the query
        // and this line still fails.
        Assert.isNull(s.BOV_Score__c,
            'BOV_Score__c should be selected — and null, because nothing writes it and the '
            + 'formula that will replace it returns null with no asking price on the parent');
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
        // The premise: with nothing writing a score, the primary key decides nothing at all.
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
}
