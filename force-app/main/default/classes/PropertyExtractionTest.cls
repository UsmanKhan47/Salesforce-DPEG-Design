/**
 * Test class for PropertyExtraction — specifically `hasNoExtractedValues()`, added 2026-08-12
 * as the Apex half of the Defect-2 fix in
 * agent-output/design-requirements-pipeline-defects.md.
 *
 * PropertyExtraction is a pure DTO (no SOQL, no DML, no callouts, no platform dependency
 * beyond Date/Decimal — see the class header), so every test here is a plain in-memory
 * assertion with no fixture, no mock and no Test.startTest()/stopTest() boundary. `compareTo`
 * (the lock-ordering total order) is exercised end to end elsewhere in
 * ExtractAddressQueueableTest and is deliberately out of scope for this class, which covers
 * only the method that changed.
 *
 * 🔴 THE TWO-WAY REQUIREMENT, AND WHY BOTH DIRECTIONS ARE PINNED SEPARATELY. An all-empty
 * object must read true (the "Team lunch Friday + Q3 expense reports" shape
 * `ExtractAddressQueueable.firstProperty`/`isFootnotable` now skip). An object naming exactly
 * ONE fact — deliberately a NUMERIC member (`unitCount`), per the method's own Javadoc — must
 * read false. The false case is the one that actually matters in production: it is what stops
 * a genuine "128-unit multifamily, 6.2 cap, $14M" property (named by its facts, with no
 * `propertyName` and no `propertyAddress`) from being treated as if the email said nothing at
 * all, which would strip its whole deal block (FIX 2's `applyPropertyBlock` stamp) and
 * mislabel a real OUTCOME_NO_ADDRESS Lead as OUTCOME_NO_PROPERTY. A predicate that only ever
 * returns true has never been falsified; this class exists so it can be.
 *
 * NO ContentVersion, no ContentNote, no ContentDocument anywhere in this class
 * (`.claude/rules/content-publication-rule.md` is not engaged).
 *
 * BULK: `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply. This is a pure
 * function over an in-memory DTO with no SOQL, no DML and no trigger/batch/queueable context —
 * there is no batch-chunking behaviour to expose at any volume, and a 251-object loop here
 * would prove nothing a single call does not already prove. `.claude/rules/bulk-test-rule.md`'s
 * own per-transaction-singleton exemption reasoning applies a fortiori: this method is not even
 * async, let alone bulk-shaped.
 *
 * @see PropertyExtraction.cls (the class under test)
 * @see ExtractAddressQueueableTest.cls (integration coverage of firstProperty/isFootnotable,
 *      the two callers this predicate was added for)
 */
@isTest
private class PropertyExtractionTest {

    // ── hasNoExtractedValues() — the two-way contract ────────────────────────

    @isTest
    static void hasNoExtractedValues_everyMemberNullOrBlank_returnsTrue() {
        // The measured artefact: a model response containing ONE property object where every
        // extracted field is null or blank — the "Team lunch Friday + Q3 expense reports" shape.
        PropertyExtraction empty = new PropertyExtraction();

        Assert.isTrue(empty.hasNoExtractedValues(),
            'A freshly constructed instance carries no extracted values at all and must read '
            + 'TRUE — this is the population firstProperty()/isFootnotable() must now skip');
    }

    @isTest
    static void hasNoExtractedValues_exactlyOneNumericMemberSet_returnsFalse() {
        // 🔴 THE LOAD-BEARING DIRECTION. Deliberately NUMERIC (unitCount), per the method's own
        // Javadoc: this is the shape that protects the OUTCOME_NO_ADDRESS population — an email
        // that describes a property only by its FACTS ("128-unit multifamily") carries no name
        // and no address, and must NOT be treated as "states nothing at all". A predicate that
        // tested only name/address would wrongly return true here and strip the Lead's deal
        // block along with mislabelling it OUTCOME_NO_PROPERTY.
        PropertyExtraction factsOnly = new PropertyExtraction();
        factsOnly.unitCount = 128;

        Assert.isFalse(factsOnly.hasNoExtractedValues(),
            'A property stating even ONE numeric fact — with no name and no address — SAYS '
            + 'SOMETHING and must never be treated as structurally empty');
    }

    @isTest
    static void hasNoExtractedValues_exactlyOneStringMemberSet_returnsFalse() {
        // The mirror case on the string side — a name-only property, the shape
        // execute_addresslessNamedProperty_stampsTheBlockButClaimsNothing already covers
        // end to end in ExtractAddressQueueableTest. Pinned here directly on the DTO too.
        PropertyExtraction nameOnly = new PropertyExtraction();
        nameOnly.propertyName = 'Eden Prairie Apartments';

        Assert.isFalse(nameOnly.hasNoExtractedValues(),
            'A property naming itself, with nothing else extracted, still says something');
    }

    @isTest
    static void hasNoExtractedValues_everyMemberSet_returnsFalse() {
        // Sanity check at the opposite extreme — not required by the design brief, but cheap
        // and it confirms the predicate is not vacuously true for a fully-populated instance.
        PropertyExtraction full = new PropertyExtraction();
        full.propertyName = 'Full House';
        full.propertyAddress = '100 Main St';
        full.assetType = 'Multifamily';
        full.dealType = 'Commercial';
        full.saleProcess = 'Call for Offers';
        full.zoning = 'MU-2';
        full.sellerEntity = 'Full House LLC';
        full.dealRoomLink = 'https://example.invalid/deal-room';
        full.guidancePrice = 14000000;
        full.guidancePriceLow = 13000000;
        full.guidancePriceHigh = 15000000;
        full.capRate = 6.2;
        full.noi = 868000;
        full.occupancyPct = 95;
        full.adr = 150;
        full.buildingSf = 120000;
        full.lotSizeAcres = 3.5;
        full.unitCount = 128;
        full.yearBuilt = 2001;
        full.yearRenovated = 2019;
        full.waltYears = 4.5;
        full.offerDueDate = Date.today().addDays(30);

        Assert.isFalse(full.hasNoExtractedValues(), 'A fully populated property obviously says something');
    }

    // ── The routing-key exclusion ─────────────────────────────────────────────

    @isTest
    static void hasNoExtractedValues_normalizedAddressAndClusterKeyAreExcluded_stillReturnsTrue() {
        // 🔴 PINS THE METHOD'S OWN JAVADOC: normalizedAddress/clusterKey are ROUTING KEYS the
        // queueable derives, never values the email stated, so they must NOT count toward "this
        // email said something". Without this exclusion the predicate's answer would depend on
        // WHEN it is called (before or after ExtractAddressQueueable populates the sort keys),
        // which would make it unreliable for its one caller — buildWorkList runs before the
        // keys exist, and firstProperty runs on the same pre-sort list, but a future caller that
        // reordered those steps must not silently change the answer.
        PropertyExtraction routingKeysOnly = new PropertyExtraction();
        routingKeysOnly.normalizedAddress = '100 main st';
        routingKeysOnly.clusterKey = '100 main';

        Assert.isTrue(routingKeysOnly.hasNoExtractedValues(),
            'normalizedAddress and clusterKey are derived by the queueable, not stated by the '
            + 'email, and must never count as "this property says something"');
    }

    // ── Member-count rot guard (code review S2) ───────────────────────────────

    @isTest
    static void hasNoExtractedValues_javadocRotGuard_publicMemberCountIs24() {
        // 🔴 PINS THE PREDICATE'S OWN JAVADOC WARNING: "a new member added above without a line
        // here silently narrows the predicate". This test does not exercise
        // hasNoExtractedValues() at all — it independently counts every PUBLIC member
        // PropertyExtraction actually declares, via JSON.serialize, so a 23rd extracted member
        // added to the class without a matching line in hasNoExtractedValues() fails HERE, with
        // an explicit count mismatch, rather than silently narrowing the predicate and being
        // noticed only if someone happens to exercise the new member through
        // hasNoExtractedValues_everyMemberSet_returnsFalse (which would still pass, vacuously,
        // for a predicate that simply never looks at the new field).
        //
        // VERIFIED against the class directly (not assumed): 24 top-level `public` members are
        // declared on PropertyExtraction — propertyName, propertyAddress, assetType, dealType,
        // saleProcess, guidancePrice, guidancePriceLow, guidancePriceHigh, capRate, noi,
        // occupancyPct, adr, buildingSf, lotSizeAcres, unitCount, yearBuilt, yearRenovated,
        // waltYears, zoning, sellerEntity, dealRoomLink, offerDueDate (22 EXTRACTED members —
        // exactly the set hasNoExtractedValues() tests, by design, see the routing-key exclusion
        // test above) plus normalizedAddress and clusterKey (the 2 ROUTING keys
        // hasNoExtractedValues() deliberately excludes). 22 + 2 = 24. `hasNoExtractedValues()`
        // and `compareTo()` are the only other `public` members on the class; both are methods,
        // not fields, and JSON.serialize does not emit them.
        PropertyExtraction full = new PropertyExtraction();
        full.propertyName = 'Full House';
        full.propertyAddress = '100 Main St';
        full.assetType = 'Multifamily';
        full.dealType = 'Commercial';
        full.saleProcess = 'Call for Offers';
        full.zoning = 'MU-2';
        full.sellerEntity = 'Full House LLC';
        full.dealRoomLink = 'https://example.invalid/deal-room';
        full.guidancePrice = 14000000;
        full.guidancePriceLow = 13000000;
        full.guidancePriceHigh = 15000000;
        full.capRate = 6.2;
        full.noi = 868000;
        full.occupancyPct = 95;
        full.adr = 150;
        full.buildingSf = 120000;
        full.lotSizeAcres = 3.5;
        full.unitCount = 128;
        full.yearBuilt = 2001;
        full.yearRenovated = 2019;
        full.waltYears = 4.5;
        full.offerDueDate = Date.today().addDays(30);
        full.normalizedAddress = '100 main st';
        full.clusterKey = '100 main';

        Map<String, Object> serialized =
            (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(full));

        Assert.areEqual(24, serialized.keySet().size(),
            'PropertyExtraction must declare exactly 24 public members (22 extracted + '
            + 'normalizedAddress + clusterKey). If this count changed, a member was added or '
            + 'removed — go verify hasNoExtractedValues() still tests every EXTRACTED member '
            + '(never the two routing keys) before updating this count. Actual keys: '
            + serialized.keySet());
    }
}
