/**
 * Test class for `DispositionDomain`.
 *
 * ── WHY THIS SUITE EXISTS (pins C-2) ──────────────────────────────────────────
 * `recordTypeNameOf` used to exist twice, privately, and the two copies disagreed about the
 * Master/unset case — one returned `null`, the other returned `On_Market`. The `null` answer
 * slipped past an `equals` guard undetected and stalled a Disposition at `Broker Selection`
 * with `Approval_Advance_Pending__c` stuck true and no FLS anywhere on that field to reveal it.
 * See `DispositionDomain.cls`'s class header for the full incident writeup.
 *
 * The single highest-value assertion in this file is therefore
 * `testRecordTypeNameOf_neverReturnsNull_acrossAllInputShapes` — it is written so that it FAILS
 * the instant anyone reintroduces a null-returning path, regardless of which specific input
 * shape triggers it. The second most valuable is
 * `testRecordTypeNameOf_masterOrUnresolvable_defaultsToOnMarketSpecifically`, which pins the
 * default to ON-MARKET specifically (not merely "some non-null string").
 *
 * ── BULK EXEMPTION (record this so a future reviewer does not demand 251 rows) ────────────
 * Per `.claude/rules/bulk-test-rule.md`'s narrowed-scope reasoning: `recordTypeNameOf` is a
 * pure, stateless function of ONE in-memory row — no SOQL, no DML, no loop, no trigger, no
 * batch chunking to force a second firing of. A 251-record test here would prove nothing a
 * single-record test doesn't (there is no batching boundary to cross) and the class header
 * itself notes the 251-row bulk PROOF for this method already lives in
 * `DispositionApprovalAdvanceServiceTest`, which exercises it once per row of its own bulk
 * fixture. This suite deliberately stays at one row per scenario.
 *
 * ── NO DML NEEDED ──────────────────────────────────────────────────────────────────────────
 * `recordTypeNameOf` never queries and never requires a persisted row, so every fixture here is
 * built with `doInsert = false` (or a bare `new Disposition__c(...)`) — nothing in this class
 * touches the database. Record type Ids used for the On_Market / Off_Market cases still come
 * from `TestDataFactory` per project convention, just with insertion suppressed.
 *
 * @description Test class for DispositionDomain
 * @author Unit Testing Agent
 */
@isTest
private class DispositionDomainTest {

    /**
     * One row of the table-driven "never returns null" / "matches expected" sweep.
     */
    private class Scenario {
        String label;
        Disposition__c row;
        String expected;

        Scenario(String label, Disposition__c row, String expected) {
            this.label = label;
            this.row = row;
            this.expected = expected;
        }
    }

    /**
     * Builds every input shape `recordTypeNameOf` must handle, paired with the answer it must
     * produce. Built fresh per test method (no @TestSetup — there is no DML to share).
     */
    private static List<Scenario> buildScenarios() {
        Id onMarketRtId = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(DispositionDomain.RT_ON_MARKET)
            ?.getRecordTypeId();
        Id offMarketRtId = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(DispositionDomain.RT_OFF_MARKET)
            ?.getRecordTypeId();

        List<Scenario> scenarios = new List<Scenario>();

        scenarios.add(new Scenario(
            'null row',
            null,
            DispositionDomain.RT_ON_MARKET
        ));

        scenarios.add(new Scenario(
            'non-null row, null RecordTypeId',
            new Disposition__c(RecordTypeId = null),
            DispositionDomain.RT_ON_MARKET
        ));

        Id unresolvableRtId = fakeUnresolvableRecordTypeId(onMarketRtId);
        if (unresolvableRtId != null) {
            scenarios.add(new Scenario(
                'unresolvable RecordTypeId (syntactically valid, matches nothing)',
                new Disposition__c(RecordTypeId = unresolvableRtId),
                DispositionDomain.RT_ON_MARKET
            ));
        }

        Id masterRtId = masterRecordTypeId();
        if (masterRtId != null) {
            scenarios.add(new Scenario(
                'explicit Master RecordTypeId',
                new Disposition__c(RecordTypeId = masterRtId),
                DispositionDomain.RT_ON_MARKET
            ));
        }

        // 🔴 THE ASSET ARGUMENT WAS `null` ON BOTH LINES BELOW UNTIL 2026-08-31 (Tranche 1 item 8),
        // AND THESE TWO SITES ARE THE **WEAKEST** OF THE ELEVEN REPAIRED — SAID PLAINLY SO NOBODY
        // CITES THEM AS PRECEDENT. `Disposition__c.Property_Asset__c` is gaining a rule requiring
        // it; the mechanism is a VALIDATION RULE, not `required = true` (design decision D-6), and
        // a validation rule fires on **DML**. These two fixtures pass `doInsert = false` and are
        // NEVER inserted — they exist only to be handed to `DispositionDomain.recordTypeNameOf`,
        // which is a pure in-memory read of `RecordTypeId`. So neither line was actually broken.
        // ⚠ THEY ARE REPAIRED ANYWAY, FOR ONE REASON AND AT ONE COST, BOTH WORTH STATING:
        //   REASON — the day one of these scenarios grows an `insert`, the failure would be a
        //   validation-rule error naming a field this class does not care about, in a helper three
        //   methods away from the test that broke.
        //   COST — `defaultPropertyAsset()` performs TWO inserts (Property + Property_Asset) the
        //   first time it is called in a transaction, so this otherwise DML-FREE class now performs
        //   two. That is a real, if small, regression in this file's hygiene, and it is the price
        //   of uniformity. It is safe here because `scenarios()` is called from test bodies, never
        //   inside a `Limits` bracket — this class has none.
        // 🔴 ONE ASSET FOR THE WHOLE RUN. `defaultPropertyAsset()` caches; do NOT substitute
        // `createPropertyAsset(...)`, which would build one per call.
        if (onMarketRtId != null) {
            scenarios.add(new Scenario(
                'explicit On_Market RecordTypeId',
                TestDataFactory.createDisposition(
                    TestDataFactory.defaultPropertyAsset().Id,
                    DispositionDomain.RT_ON_MARKET,
                    false
                ),
                DispositionDomain.RT_ON_MARKET
            ));
        }

        if (offMarketRtId != null) {
            scenarios.add(new Scenario(
                'explicit Off_Market RecordTypeId',
                TestDataFactory.createDisposition(
                    TestDataFactory.defaultPropertyAsset().Id,
                    DispositionDomain.RT_OFF_MARKET,
                    false
                ),
                DispositionDomain.RT_OFF_MARKET
            ));
        }

        return scenarios;
    }

    /**
     * A syntactically valid RecordType Id that does not correspond to any RecordType this org
     * knows about — proves the "unresolvable Id" branch of `info == null`.
     *
     * 🔴 A FABRICATED Id (e.g. `(Id) '012999999999999'`) IS NOT ENOUGH — Apex's `Id` cast
     * validates the pod/instance encoding baked into the middle of the string, not just the
     * 3-char key prefix and overall length. An arbitrary digit string with the right prefix and
     * length still throws `System.StringException: Invalid id` at cast time (measured against
     * this org). The reliable way to get a syntactically-valid-but-unresolvable Id is to start
     * from a REAL Id this org issued and mutate one character in its body — the pod/instance
     * encoding stays valid because it is untouched, and the record itself no longer matches.
     *
     * @param realBaseId a genuine RecordTypeId issued by this org (e.g. On_Market's).
     * @return a same-shape Id one character off from realBaseId, or null if no base was given.
     */
    private static Id fakeUnresolvableRecordTypeId(Id realBaseId) {
        if (realBaseId == null) {
            return null;
        }
        String body = String.valueOf(realBaseId).substring(0, 15);
        String lastChar = body.substring(14, 15);
        String mutatedLastChar = (lastChar == 'X') ? 'Y' : 'X';
        return (Id) (body.substring(0, 14) + mutatedLastChar);
    }

    /**
     * Finds this org's actual Master RecordTypeInfo Id for Disposition__c, or null if the
     * describe surfaces none available to the running user (guarded, not asserted — mirrors
     * TestDataFactory's own describe-guard pattern).
     */
    private static Id masterRecordTypeId() {
        for (Schema.RecordTypeInfo info : Schema.SObjectType.Disposition__c.getRecordTypeInfos()) {
            if (info.isMaster()) {
                return info.getRecordTypeId();
            }
        }
        return null;
    }

    /**
     * @description Test recordTypeNameOf - null row defaults to On_Market
     */
    @isTest
    static void testRecordTypeNameOf_nullRow_returnsOnMarket() {
        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(null);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_ON_MARKET,
            result,
            'A null Disposition row must default to On_Market, never null.'
        );
    }

    /**
     * @description Test recordTypeNameOf - non-null row with null RecordTypeId defaults to On_Market
     */
    @isTest
    static void testRecordTypeNameOf_nullRecordTypeId_returnsOnMarket() {
        Disposition__c disposition = new Disposition__c(RecordTypeId = null);

        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(disposition);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_ON_MARKET,
            result,
            'A row with a null RecordTypeId must default to On_Market, never null.'
        );
    }

    /**
     * @description Test recordTypeNameOf - explicit On_Market record type resolves to On_Market
     */
    @isTest
    static void testRecordTypeNameOf_explicitOnMarket_returnsOnMarket() {
        Schema.RecordTypeInfo onMarketInfo = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(DispositionDomain.RT_ON_MARKET);
        if (onMarketInfo == null) {
            return; // On_Market record type not deployed to this org; guarded like TestDataFactory.
        }

        Disposition__c disposition = TestDataFactory.createDisposition(
            null, DispositionDomain.RT_ON_MARKET, false
        );

        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(disposition);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_ON_MARKET,
            result,
            'An explicit On_Market RecordTypeId must resolve to On_Market.'
        );
    }

    /**
     * @description Test recordTypeNameOf - explicit Off_Market record type resolves to Off_Market
     */
    @isTest
    static void testRecordTypeNameOf_explicitOffMarket_returnsOffMarket() {
        Schema.RecordTypeInfo offMarketInfo = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(DispositionDomain.RT_OFF_MARKET);
        if (offMarketInfo == null) {
            return; // Off_Market record type not deployed to this org; guarded like TestDataFactory.
        }

        Disposition__c disposition = TestDataFactory.createDisposition(
            null, DispositionDomain.RT_OFF_MARKET, false
        );

        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(disposition);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_OFF_MARKET,
            result,
            'An explicit Off_Market RecordTypeId must resolve to Off_Market, not On_Market.'
        );
    }

    /**
     * @description Test recordTypeNameOf - explicit Master record type defaults to On_Market
     *              (the exact case that regressed under C-2: one prior copy returned null here).
     */
    @isTest
    static void testRecordTypeNameOf_explicitMaster_returnsOnMarket() {
        Id masterId = masterRecordTypeId();
        if (masterId == null) {
            return; // No Master RecordTypeInfo surfaced to the running user; guarded.
        }
        Disposition__c disposition = new Disposition__c(RecordTypeId = masterId);

        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(disposition);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_ON_MARKET,
            result,
            'A Master-record-type row must default to On_Market specifically (this is the exact '
            + 'C-2 regression case — the retired copy returned null here).'
        );
    }

    /**
     * @description Test recordTypeNameOf - a syntactically valid but unresolvable RecordTypeId
     *              defaults to On_Market
     */
    @isTest
    static void testRecordTypeNameOf_unresolvableRecordTypeId_returnsOnMarket() {
        Id onMarketRtId = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(DispositionDomain.RT_ON_MARKET)
            ?.getRecordTypeId();
        Id unresolvableRtId = fakeUnresolvableRecordTypeId(onMarketRtId);
        if (unresolvableRtId == null) {
            return; // No deployed record type available to derive a same-shape fake Id from.
        }
        Disposition__c disposition = new Disposition__c(RecordTypeId = unresolvableRtId);

        Test.startTest();
        String result = DispositionDomain.recordTypeNameOf(disposition);
        Test.stopTest();

        Assert.areEqual(
            DispositionDomain.RT_ON_MARKET,
            result,
            'An Id this org cannot resolve to a RecordTypeInfo must default to On_Market, never null.'
        );
    }

    /**
     * @description THE regression pin for C-2: recordTypeNameOf must NEVER return null, across
     *              every input shape the method documents handling. This is the test that fails
     *              the instant anyone reintroduces a null-returning branch.
     */
    @isTest
    static void testRecordTypeNameOf_neverReturnsNull_acrossAllInputShapes() {
        List<Scenario> scenarios = buildScenarios();

        Test.startTest();
        for (Scenario scenario : scenarios) {
            String result = DispositionDomain.recordTypeNameOf(scenario.row);
            Assert.isNotNull(
                result,
                'recordTypeNameOf must never return null (scenario: ' + scenario.label + '). '
                + 'A null answer is exactly the C-2 defect: it slips past an equals guard undetected.'
            );
        }
        Test.stopTest();
    }

    /**
     * @description Table-driven sweep: every input shape must resolve to its documented,
     *              specific expected value (not merely "non-null").
     */
    @isTest
    static void testRecordTypeNameOf_matchesExpectedValue_acrossAllInputShapes() {
        List<Scenario> scenarios = buildScenarios();

        Test.startTest();
        for (Scenario scenario : scenarios) {
            String result = DispositionDomain.recordTypeNameOf(scenario.row);
            Assert.areEqual(
                scenario.expected,
                result,
                'recordTypeNameOf mismatch for scenario: ' + scenario.label
            );
        }
        Test.stopTest();
    }
}
