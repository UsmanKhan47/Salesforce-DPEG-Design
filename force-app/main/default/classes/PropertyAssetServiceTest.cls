/**
 * Tests for PropertyAssetService — auto-creation of `Property_Asset__c` on Closed Won
 * (Tranche 5 Item A · D27.3 / D28).
 *
 * ── EVERY ASSERTION IS A READ-BACK, NOT AN IN-MEMORY CHECK ──
 * The service returns nothing and its insert is `AccessLevel.SYSTEM_MODE`, so the ONLY
 * evidence that a value landed is re-querying the row. "The insert succeeded" is not the
 * gate — the standing lesson from post-deploy gate A2 and `TestDataFactoryTest`. Every test
 * below therefore selects the asset back and asserts field VALUES, never a bare count where
 * a value is what matters.
 *
 * ── THE 251 BULK TEST IS MANDATORY HERE AND HAS NO EXEMPTION ──
 * `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton carve-out does NOT apply:
 * this is TRIGGER-DRIVEN (`OpportunityReviewTrigger` -> `OpportunityReviewTriggerHandler`),
 * so a real 251-record close runs it in TWO chunks (200 + 51) and is the only thing that
 * proves the second chunk behaves like the first. The higher-value half of that test is the
 * BUDGET assertion, not the row count: it makes a future change that adds one query per
 * record fail here instead of in production, where the same change would roll back a deal
 * close.
 *
 * ── WHAT THESE TESTS CANNOT PROVE, STATED SO IT IS NOT ASSUMED ──
 * Both selector reads are `WITH SYSTEM_MODE` inside `private without sharing` inner classes,
 * and the DML is `AccessLevel.SYSTEM_MODE`. Running as an administrator, an assertion that
 * "it worked" passes whether or not any of those three decisions is present, so none of them
 * is falsifiable from Apex. They rest on measured repo state (recorded in the service and
 * selector headers: `Property__c` and `Property_Asset__c` are both `sharingModel = Private`;
 * `DPEG_Transaction_Team` holds no `Property_Asset__c` permission of any kind; the
 * `Transaction_Complete_Close` flow carries no `<runInMode>` and therefore runs as that
 * persona) and are proved by post-deploy gates A-G2 and A-G4, run as a real Transactions
 * persona rather than as an admin.
 *
 * ── COVERAGE: 99%, WITH ONE DELIBERATELY UNREACHABLE LINE ──
 * `PropertyAssetService`'s `if (toInsert.isEmpty()) { return; }` — the branch taken when EVERY
 * property in the chunk failed to come back from the seed read — is not reachable from a test
 * and is not seamed open to make a number look better. `Property_Asset__c.Property__c` and
 * `Opportunity.Property__c` are both `deleteConstraint = SetNull`, so deleting a Property
 * NULLS the Opportunity's lookup, which routes the deal down the no-Property path instead.
 * The only real producer is a row disappearing between the idempotency read and the seed read
 * inside one transaction. The guard is kept because without it an empty list would still be
 * handed to `Database.insert`, consuming a DML statement and breaking the budget contract this
 * class asserts. Documented rather than contrived — the standing position for a genuinely
 * uncoverable defensive branch.
 *
 * No @TestSetup: the stage gates require per-test fixtures, and every count query is scoped
 * to the properties the test itself created so the shared `TestDataFactory` scaffold rows
 * cannot leak into an assertion.
 */
@isTest
private class PropertyAssetServiceTest {

    /** .claude/rules/bulk-test-rule.md — 251 forces a SECOND trigger chunk. */
    private static final Integer BULK_N = 251;

    private static final String CLOSED_WON = 'Closed Won';

    // ═════════════════════════════════════════════════════════════════════════════════════
    // FIXTURE HELPERS
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Inserts `count` properties and `count` Opportunities, one Opportunity per property,
     * already prepared to cross the THREE Closed Won validation gates
     * (`NDA_Signed_Before_Deal_Progression`, `Contract_Signed_Before_Closed_Won` and, since
     * 2026-09-02, `Transaction_Closed_Before_Closed_Won`).
     * The deals are left at 'New'; the caller decides when and how they close.
     *
     * 🔴 THE THIRD GATE IS SATISFIED BY WRITING THE PARENT FLAGS, NOT BY CREATING A
     * `Transaction__c`, AND THAT IS DELIBERATE. `TestDataFactory.markTransactionClosed` is one
     * field pair in one bulk DML; creating a real Transaction per deal would fan out 82 checklist
     * Tasks each through `flows/Transaction_Task_Fanout`, which at this class's BULK_N of 251 is
     * roughly 20,600 Task rows and simply will not run. The full argument lives at that helper's
     * declaration — read it before "improving" this.
     *
     * @param count       How many pairs.
     * @param assetType   `Property__c.Asset_Type__c` for every property (restricted picklist).
     * @param properties  Out-parameter: the inserted properties, index-aligned to the result.
     * @return The inserted, gate-ready Opportunities.
     */
    private static List<Opportunity> dealsReadyToClose(
        Integer count, String assetType, List<Property__c> properties
    ) {
        properties.addAll(TestDataFactory.createProperties(count, false));
        for (Property__c p : properties) {
            p.Asset_Type__c = assetType;
        }
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
     * Moves already-prepared deals to Closed Won in one bulk DML.
     *
     * ⚠ It stays ONE statement on purpose — several callers wrap it in `Test.startTest()` and
     * assert service-level budgets around it. The Closed Won gates are satisfied UPSTREAM, in
     * `dealsReadyToClose` (or inline, for the one caller that builds its own deal); do not move
     * gate preparation in here.
     */
    private static void close(List<Opportunity> opps) {
        for (Opportunity o : opps) {
            o.StageName = CLOSED_WON;
        }
        update opps;
    }

    /** Re-queries every asset hanging off the given properties. */
    private static List<Property_Asset__c> assetsFor(List<Property__c> properties) {
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();
        return [
            SELECT Id, Name, Property__c, Status__c, Property_Type__c, Closing_Date__c
            FROM Property_Asset__c
            WHERE Property__c IN :ids
            ORDER BY Name
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE HAPPY PATH — read back, field by field
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * The core assertion of the whole feature: a deal reaching Closed Won produces exactly one
     * asset, parented to the deal's property, named after it, Active, and typed by the map.
     * Read back from the database — the in-memory list the service built is not evidence.
     */
    @isTest
    static void enteringClosedWon_createsTheAssetWithEveryIntendedValue() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);

        // A DISTINCTIVE close date, deliberately NOT the factory default (today + 90) and not
        // today. Either of those would let a hardcoded `Date.today()` — or a field never written
        // at all, if the default happened to match — pass the assertion below by accident.
        Date expectedClose = Date.today().addDays(37);
        opps[0].CloseDate = expectedClose;

        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(), 'Closing the deal creates exactly one Property Asset');
        Assert.areEqual(properties[0].Id, assets[0].Property__c,
            'The asset must be parented to the deal\'s Property — the whole PM tree hangs off it');
        Assert.areEqual(properties[0].Name, assets[0].Name,
            'Name is the property name VERBATIM (no " Asset" suffix): it is what the Sell Meter, '
            + 'BOV outreach and broker-listing surfaces render as the property label');
        Assert.areEqual('Active', assets[0].Status__c,
            'Status must be Active — a blank status hides the asset from Managed_Properties, '
            + 'Properties_in_AUM AND from Property_Asset_PM_All_RW, the only sharing rule on the object');
        Assert.areEqual('Retail', assets[0].Property_Type__c,
            'Retail maps to Retail');
        Assert.areEqual(expectedClose, assets[0].Closing_Date__c,
            'Closing_Date__c carries Opportunity.CloseDate. Both sides are Date, so this is a '
            + 'straight copy with no coercion — unlike Opportunity.Contract_Executed_Date__c, '
            + 'which is a DateTime and needs .date()');
        // ⚠ THIS ASSERTION USES A SAVE SHAPE PRODUCTION DOES NOT PERFORM (CloseDate supplied in the
        // same DML as the stage change). It is kept because it is the only one that pins a
        // DISTINCTIVE value end to end. The production shape — StageName alone — is pinned
        // separately by closingByStageAlone_carriesWhateverCloseDateTheSaveCommitted below.
    }

    /**
     * 🔴 THE SAVE SHAPE PRODUCTION ACTUALLY PERFORMS — added 2026-08-10 (review W3).
     *
     * Both other `Closing_Date__c` assertions in this class supply `CloseDate` IN the closing save
     * (`enteringClosedWon_createsTheAssetWithEveryIntendedValue` and the tie-break in
     * `twoDealsOnOneProperty_inOneChunk_createOneAsset`). Every production route does the opposite:
     * `StageAdvanceService` writes `StageName` only, and the `Transaction_Complete_Close` flow
     * writes `StageName` + `Deal_Category__c` + `Deal_Status__c`. Neither supplies a `CloseDate`.
     *
     * That difference is not cosmetic, because of the org-side behaviour measured on this org
     * 2026-08-10 and recorded on the tie-break test below: a save entering `Closed Won` WITHOUT
     * supplying `CloseDate` in that same save has `CloseDate` REWRITTEN TO TODAY by the time
     * `Trigger.new` is built, while a save that DOES supply one keeps the supplied value. So the two
     * existing assertions both exercise the branch production never takes, and the branch that
     * actually determines what `Closing_Date__c` ends up holding had nothing pinning it.
     *
     * ── WHAT THIS TEST DELIBERATELY DOES **NOT** ASSERT ─────────────────────────────────────
     * It does not assert `Date.today()`, and must never be "tightened" to. Hardcoding the rewrite
     * would make a repo test an assertion about ORG-SIDE AUTOMATION THAT SOURCE CONTROL CANNOT SEE
     * (no flow and no workflow in this repo references `CloseDate`) — it would red the day an admin
     * changed something invisible to this branch, and it would tell a future reader the rewrite is
     * a guarantee rather than an observation. Comparing against the value READ BACK from the
     * database instead holds under BOTH readings: rewrite or no rewrite, the asset must carry
     * whatever `CloseDate` the save committed.
     *
     * What it therefore falsifies: the day someone drops the `closingDateByProperty` carry-over in
     * `PropertyAssetService.createAssets`, or repoints it at anything other than the Opportunity's
     * committed `CloseDate`, this reds — on the only route the application actually uses.
     */
    @isTest
    static void closingByStageAlone_carriesWhateverCloseDateTheSaveCommitted() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        // STAGE ONLY. A fresh SObject carrying just Id + StageName — not the `close()` helper and
        // not the in-memory `opps` list, either of which would ship a full field set and could
        // re-supply a CloseDate the production callers never send.
        update new Opportunity(Id = opps[0].Id, StageName = CLOSED_WON);
        Test.stopTest();

        Opportunity saved = [SELECT CloseDate FROM Opportunity WHERE Id = :opps[0].Id];
        List<Property_Asset__c> assets = assetsFor(properties);

        Assert.areEqual(1, assets.size(),
            'A stage-only close is still a close — the asset must be created on the route '
            + 'StageAdvanceService and Transaction_Complete_Close actually take');
        Assert.isNotNull(saved.CloseDate,
            'GUARD, so the comparison below cannot pass vacuously: CloseDate is a required standard '
            + 'field, so Trigger.new always carries one and null == null can never be the reason '
            + 'this test is green');
        Assert.areEqual(saved.CloseDate, assets[0].Closing_Date__c,
            'On the route production actually takes, the asset must carry whatever CloseDate the '
            + 'save committed — this reds if the carry-over is ever dropped, under either reading '
            + 'of the org-side rewrite documented in the service header');
        // ⚠ NETTED, NOT RELAXED (2026-08-22). `runDmlCount` is a Limits delta measured AROUND
        // `Database.insert`, and that insert now fires `PropertyAssetTrigger` ->
        // `OnboardingAutoCreateService` synchronously, whose own DML lands inside the same
        // window. Subtracting the downstream's separately-measured cost keeps this assertion
        // saying exactly what it always said — "this service performs ONE bulk insert" — while
        // the line below pins the new cost on its own terms. Do NOT collapse them into a bare
        // `areEqual(2, ...)`: that would pass if either half doubled and the other halved.
        Assert.areEqual(1,
            PropertyAssetService.runDmlCount - OnboardingAutoCreateService.runDmlCount,
            'and the stage-only shape costs the same single bulk insert as any other close');
        Assert.areEqual(1, OnboardingAutoCreateService.runDmlCount,
            'the onboarding auto-create it now cascades into costs exactly ONE bulk insert too');
    }

    /** The remaining four mapped values, so the allow-list is pinned entry by entry. */
    @isTest
    static void everyMappedAssetTypeLandsOnItsCounterpart() {
        Map<String, String> expected = new Map<String, String>{
            'Industrial'  => 'Industrial',
            'Office'      => 'Office',
            'Multifamily' => 'Multifamily',
            'Mixed-Use'   => 'Mixed-Use'
        };

        Test.startTest();
        for (String assetType : expected.keySet()) {
            List<Property__c> properties = new List<Property__c>();
            close(dealsReadyToClose(1, assetType, properties));

            List<Property_Asset__c> assets = assetsFor(properties);
            Assert.areEqual(1, assets.size(), assetType + ' should produce one asset');
            Assert.areEqual(expected.get(assetType), assets[0].Property_Type__c,
                assetType + ' must map to ' + expected.get(assetType));
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 Property_Type__c — THE UNRESTRICTED-PICKLIST HAZARD
    //
    // `Property__c.Asset_Type__c` is RESTRICTED with 10 values;
    // `Property_Asset__c.Property_Type__c` is NOT restricted and has 5. Five source values
    // have no counterpart, and an off-list write to an unrestricted picklist SUCCEEDS
    // SILENTLY — no error, no DML failure, nothing to notice. These tests are the only
    // detection there is.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE SKIP PIN THE BRIEF REQUIRES. `Land` exists on the source and NOT on the target.
     * The asset is still created (a land acquisition is a real acquisition) but its type is
     * left BLANK. If anyone replaces the map with a blind copy, `Property_Type__c` reads
     * 'Land' here — a value no user can pick and every property-type report buckets on its
     * own — and this test goes red.
     */
    @isTest
    static void unmappedAssetType_leavesThePropertyTypeBlank_andStillCreatesTheAsset() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Land', properties);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(),
            'A Land acquisition still becomes an asset — the PM tree needs a root either way');
        Assert.isNull(assets[0].Property_Type__c,
            'Land has no clean counterpart, so the type is LEFT BLANK. A blind copy would store '
            + '"Land" silently, because Property_Type__c is not a restricted picklist');
        Assert.areEqual('Active', assets[0].Status__c, 'Every other value still lands');
        Assert.areEqual(1, PropertyAssetService.runSkippedUnmappedType,
            'The refusal is counted so it is not invisible');
    }

    /** The other four deliberate refusals, including the two "nearly right" traps. */
    @isTest
    static void theFourRemainingUnmappedTypesAreAlsoLeftBlank() {
        // C-Store is NOT folded into Retail and Medical Office is NOT folded into Office:
        // the source picklist carries them as separate values, so collapsing them would
        // destroy a distinction the schema deliberately makes.
        List<String> unmapped = new List<String>{ 'C-Store', 'Storage', 'Hospitality', 'Medical Office' };

        Test.startTest();
        for (String assetType : unmapped) {
            List<Property__c> properties = new List<Property__c>();
            close(dealsReadyToClose(1, assetType, properties));

            List<Property_Asset__c> assets = assetsFor(properties);
            Assert.areEqual(1, assets.size(), assetType + ' should still produce an asset');
            Assert.isNull(assets[0].Property_Type__c,
                assetType + ' has no clean counterpart and must be left blank, never approximated');
        }
        Test.stopTest();
    }

    /** A property with no Asset_Type__c at all yields a blank type and is not counted a refusal. */
    @isTest
    static void nullAssetType_leavesTheTypeBlankAndIsNotCountedAsARefusal() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, null, properties);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(), 'A typeless property still becomes an asset');
        Assert.isNull(assets[0].Property_Type__c, 'Nothing to map, nothing written');
        Assert.areEqual(0, PropertyAssetService.runSkippedUnmappedType,
            'A blank source is absence of data, not a refused value — do not conflate them');
    }

    /**
     * 🔴 THE DESCRIBE GUARD'S ONLY FALSIFIER. Every target in the real map IS a live picklist
     * value, so `activeTypeMap()` never fires in production and a test cannot otherwise tell
     * "the guard works" from "there is no guard". Injecting a map whose target is NOT on the
     * picklist forces the guard to choose, and because the field is UNRESTRICTED an absent
     * guard would STORE the bogus string rather than throw. Same problem and same remedy as
     * the `LeadConvertService` describe-guard tests.
     */
    @isTest
    static void aTargetThatIsNotALivePicklistValueIsDropped_notStored() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);

        PropertyAssetService.typeMapOverride =
            new Map<String, String>{ 'Retail' => 'Not A Real Property Type' };

        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(), 'The asset is still created');
        Assert.isNull(assets[0].Property_Type__c,
            'A map target that is not an ACTIVE picklist value must be dropped. Without the '
            + 'describe guard the unrestricted field would have stored "Not A Real Property Type"');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // IDEMPOTENCY (D27.3: "never a second asset for one property")
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Re-saving an already-closed deal is a no-op: stage ENTRY, not stage IS. */
    @isTest
    static void reSavingAClosedDealCreatesNoSecondAsset() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);
        close(opps);
        Assert.areEqual(1, assetsFor(properties).size(), 'Precondition: the first close built one asset');

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        opps[0].Description = 'a later, unrelated edit';
        update opps; // still Closed Won — did NOT just enter it
        Test.stopTest();

        Assert.areEqual(1, assetsFor(properties).size(),
            'A deal already at Closed Won must not open a second asset');
        Assert.areEqual(1, PropertyAssetService.runInvocations,
            'The service still ran — it is the GUARD that declines, not the routing');
        Assert.areEqual(0, PropertyAssetService.runQueryCount,
            'A save that enters no stage costs ZERO queries; the guard returns before any read');
        Assert.areEqual(0, PropertyAssetService.runDmlCount, 'and zero DML');
    }

    /**
     * A property that already carries an asset — a seeded one, a Yardi-mirrored one, or one
     * from an earlier acquisition — is left alone. This is the branch that costs ONE query
     * and NO DML, and it is the branch a sharing-scoped idempotency read would silently skip
     * (see `PropertyAssetSelector.AssetCreationReads`).
     */
    @isTest
    static void aPropertyThatAlreadyHasAnAssetGetsNoSecondOne() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);
        Property_Asset__c preexisting = TestDataFactory.createPropertyAsset(properties[0].Id, true);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(), 'The property still has exactly one asset');
        Assert.areEqual(preexisting.Id, assets[0].Id, 'and it is the pre-existing one, untouched');
        Assert.areEqual(1, PropertyAssetService.runQueryCount,
            'The guard short-circuits after the idempotency read — the seed read is never paid for');
        Assert.areEqual(0, PropertyAssetService.runDmlCount, 'and nothing is written');
    }

    /**
     * TWO deals closing against ONE property in the SAME chunk produce ONE asset. The
     * de-duplication is structural (`Set<Id>` of property Ids), not incidental, and this is the
     * case a per-record implementation would get wrong without any single-record test noticing.
     *
     * It also pins the `Closing_Date__c` TIE-BREAK: earliest `CloseDate` wins.
     *
     * 🔴 THE ORDER OF THE TWO SAVES BELOW IS LOAD-BEARING, AND IT IS NOT STYLE. The repoint is
     * committed FIRST and the two `CloseDate`s are set only afterwards, so that they travel in
     * the SAME DML that moves the stage to Closed Won. MEASURED on this org 2026-08-10: when a
     * save moves an Opportunity into `Closed Won` WITHOUT supplying `CloseDate` in that same
     * save, `Trigger.new` arrives with `CloseDate` rewritten to **TODAY** — a previously
     * committed future date is not what the trigger sees. When the same save DOES supply a
     * `CloseDate`, the supplied value survives untouched. Nothing in this repo does that
     * (no flow and no workflow references `CloseDate`), so it is org-side automation or
     * platform behaviour that source control cannot see — the standing "the repo is not the
     * org" lesson. Setting the dates in a prior save therefore makes both deals arrive carrying
     * the SAME date, which makes the tie-break unobservable and the assertion vacuous.
     */
    @isTest
    static void twoDealsOnOneProperty_inOneChunk_createOneAsset() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(2, 'Retail', properties);
        // Save 1: point the second deal at the FIRST property. No CloseDate change here.
        opps[1].Property__c = properties[0].Id;
        update opps;

        // Save 2 (below, via close()): the dates ride along WITH the stage change. The EARLIER
        // one goes on the FIRST deal ON PURPOSE. `Trigger.new` follows the order of the list
        // passed to DML, so an undocumented last-wins `put` would keep the SECOND deal's LATER
        // date — which is what makes this assertion discriminate between the two rules rather
        // than pass under either. (Putting the earlier date second would have made last-wins and
        // earliest-wins agree, and the test vacuous.)
        Date earlier = Date.today().addDays(10);
        opps[0].CloseDate = earlier;
        opps[1].CloseDate = Date.today().addDays(60);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Property_Asset__c WHERE Property__c = :properties[0].Id],
            'Two deals on one property still yield exactly ONE asset');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Property_Asset__c WHERE Property__c = :properties[1].Id],
            'The orphaned second property is not touched — nothing closed against it');
        // Netted against the downstream onboarding auto-create — see the note on
        // closingByStageAlone_carriesWhateverCloseDateTheSaveCommitted.
        Assert.areEqual(1,
            PropertyAssetService.runDmlCount - OnboardingAutoCreateService.runDmlCount,
            'One bulk insert, not two');
        // Pins the tie-break the Closing_Date__c carry-over introduces. A tie-break exists
        // whether or not it is documented — a bare `put` in the collect loop is last-wins on
        // Trigger.new order, which is not a guarantee. EARLIEST is the deterministic rule: the
        // property was ACQUIRED on the first close.
        Assert.areEqual(earlier,
            [SELECT Closing_Date__c FROM Property_Asset__c
             WHERE Property__c = :properties[0].Id].Closing_Date__c,
            'When two deals close against one property, the EARLIEST CloseDate wins');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SKIP PATHS AND ENTRY DETECTION
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 A DEAL WITH NO `Property__c` IS SKIPPED, NOT THROWN ON. Manually created deals never
     * get a Property (only `LeadConvertService` creates one, at conversion). Throwing would
     * make such a deal impossible to close at all — an existing, legitimate workflow broken by
     * a feature meant to add one. The residual is real and is documented in the service header:
     * the deal closes with no asset and nothing at runtime says so.
     */
    @isTest
    static void aDealWithNoPropertyIsSkipped_notThrownOn() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(1, true);
        TestDataFactory.signPrimaryNda(opps);
        TestDataFactory.signContract(opps);
        // The third Closed Won gate (2026-09-02). This deal is built inline rather than through
        // dealsReadyToClose, so it needs the preparation of its own.
        TestDataFactory.markTransactionClosed(opps);
        Assert.isNull(opps[0].Property__c, 'Precondition: a manually built deal has no Property');

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps); // must NOT throw
        Test.stopTest();

        Assert.areEqual(CLOSED_WON,
            [SELECT StageName FROM Opportunity WHERE Id = :opps[0].Id].StageName,
            'The deal closes normally — a missing Property must never block a close');
        Assert.areEqual(1, PropertyAssetService.runSkippedNoProperty, 'The skip is counted');
        Assert.areEqual(0, PropertyAssetService.runQueryCount,
            'With nothing to build the guard returns before any read');
        Assert.areEqual(0, PropertyAssetService.runDmlCount, 'and writes nothing');
    }

    /** An unrelated stage move costs nothing at all. */
    @isTest
    static void aStageMoveThatIsNotClosedWonCostsNothing() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(1, 'Retail', properties);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        opps[0].StageName = 'Under Review';
        update opps;
        Test.stopTest();

        Assert.areEqual(0, assetsFor(properties).size(), 'No asset before Closed Won');
        Assert.areEqual(1, PropertyAssetService.runInvocations, 'The handler still routed to us');
        Assert.areEqual(0, PropertyAssetService.runQueryCount, 'but the guard cost nothing');
        Assert.areEqual(0, PropertyAssetService.runDmlCount, 'and wrote nothing');
    }

    /**
     * THE INSERT PATH (`oldMap == null`). A record created directly at Closed Won — a data
     * load, a migration, a fixture — counts as ENTERING the stage, the same reading
     * `ContractExecutionService.openTransactionsOnAboutToClose` uses. Note the FIVE Closed Won
     * validation rules (four until 2026-09-02, when `Transaction_Closed_Before_Closed_Won` made
     * it five) are all `ISCHANGED`-gated and so do not fire on insert, which is exactly why this
     * path exists in the wild and must be covered.
     *
     * ⚠ THE INSERT HOLE IS A DECISION, NOT AN OVERSIGHT, AND THIS TEST IS THE ONE THAT DEPENDS ON
     * IT. `Transaction_Closed_Before_Closed_Won` was scoped `ISCHANGED(StageName)` like its four
     * siblings rather than being widened to cover insert. Closing the hole is not merely a
     * formula edit: a Transaction cannot reference an Opportunity that does not exist yet, so the
     * two flags CANNOT be true in the same DML that inserts a deal at Closed Won — an
     * insert-scoped rule would make that state unreachable by any route, blocking every data load
     * and migration, with no workaround. The residual is that the API and Data Loader can still
     * create a closed deal with no transaction; the gate governs the TRANSITION, which is what
     * every human route uses.
     */
    @isTest
    static void aDealInsertedDirectlyAtClosedWonAlsoGetsItsAsset() {
        List<Property__c> properties = TestDataFactory.createProperties(1, true);
        List<Opportunity> opps = TestDataFactory.createOpportunities(1, false);
        opps[0].Property__c = properties[0].Id;
        opps[0].StageName = CLOSED_WON;

        Test.startTest();
        insert opps;
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(1, assets.size(),
            'Inserting at Closed Won IS entering Closed Won — a data load must not skip the asset');
        Assert.areEqual('Active', assets[0].Status__c, 'with the same values as the update path');
        Assert.areEqual('Retail', assets[0].Property_Type__c, 'and the same mapped type');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 records, TWO trigger chunks, and a CONSTANT budget
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `.claude/rules/bulk-test-rule.md` in full: 251 deals closing in ONE transaction forces a
     * second 200-record trigger chunk, which is the only way to prove chunk 2 behaves like
     * chunk 1.
     *
     * 🔴 THE BUDGET ASSERTION IS THE HIGHER-VALUE HALF. The row count would still pass if
     * someone rewrote the service to query per record — right up until a real 200-deal batch
     * blew the SOQL limit and rolled back every close in it. `runQueryCount` and `runDmlCount`
     * are MEASURED `Limits` deltas taken inside the service, not a hand tally, so a query added
     * inside either selector is caught here too.
     *
     * The arithmetic, stated so a future reader does not have to re-derive it:
     *   251 records -> 2 chunks (200 + 51) -> runInvocations = 2
     *   2 SOQL per invocation (idempotency read + seed read)  -> runQueryCount = 4
     *   1 DML  per invocation (one bulk insert)               -> runDmlCount   = 2
     * Both totals are independent of the record count; only the invocation count scales, and
     * it scales with CHUNKS, not deals.
     *
     * Do not shrink the record count and do not relax the budget to make this pass.
     */
    @isTest
    static void bulk251EnteringClosedWon_createsEveryAssetOnAConstantBudget() {
        List<Property__c> properties = new List<Property__c>();
        List<Opportunity> opps = dealsReadyToClose(BULK_N, 'Retail', properties);

        PropertyAssetService.resetRunCounters();
        // The asset insert now cascades into OnboardingAutoCreateService, whose counters the
        // budget assertions below net out. Reset both at the same point or the subtraction lies.
        OnboardingAutoCreateService.resetRunCounters();
        Test.startTest();
        close(opps);
        Test.stopTest();

        List<Property_Asset__c> assets = assetsFor(properties);
        Assert.areEqual(BULK_N, assets.size(), 'All 251 closes must produce an asset each');

        // READ-BACK across the whole set: one asset per property, every value landed.
        Set<Id> parented = new Set<Id>();
        for (Property_Asset__c a : assets) {
            parented.add(a.Property__c);
            Assert.areEqual('Active', a.Status__c, 'Every asset is Active');
            Assert.areEqual('Retail', a.Property_Type__c, 'Every asset carries the mapped type');
            Assert.isNotNull(a.Name, 'Every asset carries the mandatory Name');
        }
        Assert.areEqual(BULK_N, parented.size(),
            'Each of the 251 properties has its OWN asset — no duplicates, no orphans');

        Assert.areEqual(2, PropertyAssetService.runInvocations,
            '251 records is two trigger chunks (200 + 51)');
        // ⚠ NETTED AGAINST THE DOWNSTREAM CASCADE (2026-08-22), NOT RELAXED. These are Limits
        // deltas measured around `Database.insert`, which now fires `PropertyAssetTrigger` ->
        // `OnboardingAutoCreateService` inside the same window. Subtracting that service's own
        // separately-measured counters keeps these two assertions saying precisely what they
        // always said about THIS service, and the four lines after them pin the new cost.
        Assert.areEqual(4,
            PropertyAssetService.runQueryCount - OnboardingAutoCreateService.runQueryCount,
            'CONSTANT 2 SOQL per invocation regardless of chunk size — 2 chunks = 4 queries. '
            + 'If this reds because the number grew with the record count, a query moved into a loop');
        Assert.areEqual(2,
            PropertyAssetService.runDmlCount - OnboardingAutoCreateService.runDmlCount,
            'CONSTANT 1 bulk DML per invocation — 2 chunks = 2 statements');

        // 🔴 THE NEW BUDGET, PINNED ON ITS OWN TERMS. 251 closes now also open 251 onboardings,
        // and this is the assertion that fails HERE rather than in production if someone adds a
        // query per asset. The arithmetic:
        //   2 chunks x 1 idempotency read                         -> 2
        //   + GroupNotifier's ONE-TIME cost, cached statically for the rest of the transaction:
        //     notification type + group, and group MEMBERS only if the group exists in the
        //     target org (GroupMemberSelector short-circuits an empty Id set) -> 2 or 3
        //                                                            = 4 or 5, and INDEPENDENT
        //   of the 251 either way. The ceiling is what discriminates; the exact one-time term is
        //   org state, and `OnboardingAutoCreateServiceTest` pins the per-chunk cost exactly by
        //   warming the notifier caches first. Do NOT "tighten" this to an areEqual here.
        Assert.areEqual(2, OnboardingAutoCreateService.runInvocations,
            'The asset trigger fires once per asset-insert chunk, mirroring the deal chunks');
        Assert.areEqual(BULK_N, OnboardingAutoCreateService.runCreated,
            'Every one of the 251 closing assets opens exactly one Onboarding');
        Assert.isTrue(OnboardingAutoCreateService.runQueryCount <= 5,
            'The onboarding auto-create must stay CONSTANT in asset count: at most 2 idempotency '
            + 'reads plus the notifier\'s one-time lookups. Found '
            + OnboardingAutoCreateService.runQueryCount
            + ' — anything near 251 means a query moved into a per-record loop');
        Assert.areEqual(2, OnboardingAutoCreateService.runDmlCount,
            'ONE bulk Onboarding insert per chunk — 2 chunks = 2 statements');
        Assert.areEqual(0, OnboardingAutoCreateService.runFailed,
            'and nothing was refused — a non-zero here is a real defect, not test noise');
    }
}
