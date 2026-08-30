/**
 * Tests for PropertySelector — now THREE methods, not one (added 2026-08-11 for the SharePoint
 * deal-folder feature): `selectAssetSeedByIds` (Tranche 5A, `PropertyAssetService`),
 * `selectFolderStateByIds` and `queryFolderSweep` (the SharePoint feature, `DealFolderService` /
 * `DealFolderSweepBatch`).
 *
 * For `selectAssetSeedByIds`: three properties are worth pinning and each has its own test: the
 * FIELD SET (an asset cannot be built without both values), the NULL/EMPTY contract (the caller
 * must be able to short-circuit without a wasted query), and the NOT-FOUND contract (an Id that
 * resolves to nothing is absent from the result rather than a null row — that absence is what
 * makes the service skip instead of building a nameless asset that would fail the whole deal
 * close).
 *
 * For `selectFolderStateByIds` / `queryFolderSweep`: the FIELD SET (all four SharePoint fields plus
 * `Name`, the folder-name source), the NULL/EMPTY short-circuit for the by-Ids method, and the
 * NOT-FOUND contract mirroring the asset-seed method's. `queryFolderSweep`'s own WHERE-clause
 * discrimination (Pending/Failed included, Created/Skipped excluded) is proven end-to-end through
 * `DealFolderSweepBatchTest` instead of re-asserted here at the raw-locator level, since a
 * `Database.QueryLocator` exposes no row-count API a selector test could assert against directly.
 *
 * ⚠ AMENDED 2026-08-30 (WS3). A FOURTH METHOD, `selectByNormalizedAddresses`, was added for
 * `LeadConvertService`'s Property-reuse lookup, and it is the FIRST here that DOES carry a
 * `System.runAs` sharing/mode test. The paragraph below is unchanged and still correct for the
 * three methods it was written about — it is NOT a blanket rule, and the distinction is what
 * matters: those three are read-for-display or write-back paths where an under-read produces a
 * SILENCE, so a `runAs` test can only assert "rows came back" and would pass either way. The
 * fourth is an EXISTENCE GUARD, where an under-read makes the caller create a DUPLICATE — a
 * different, readable outcome. The argument for that test, and the two mutations it is built to
 * catch, are at `selectByNormalizedAddresses_escapesSharingForAPrincipalWhoCannotSeeTheRow`.
 * 🔴 AND IT WAS MUTATION-TESTED, NOT ASSERTED. On 2026-08-30, flipping `ReuseLookupReads` from
 * `without sharing` to `with sharing` and re-running this class produced EXACTLY ONE red — that
 * method — with all 13 others still green. So the claim below ("a runAs test would falsify
 * nothing") is measurably FALSE for this fourth method, and the inner class is proven load-bearing
 * rather than argued to be.
 * ⚠ Only that method's claim was re-litigated; the three below were not re-tested and this
 * amendment must not be read as saying they should be.
 *
 * ⚠ NO `System.runAs` MODE/SHARING TEST FOR ANY OF THE ORIGINAL THREE METHODS, AND THAT IS NOT AN
 * OMISSION.
 * Every one of them is `WITH SYSTEM_MODE` inside a `private without sharing` inner class
 * specifically so that the running principal's FLS and sharing cannot change the answer — a
 * bare-user `runAs` asserting "it still returns rows" would pass whether or not the inner class
 * existed, and would therefore falsify nothing (the same reasoning already recorded here for
 * `selectAssetSeedByIds`, and in `DealFolderServiceTest`'s header for the SharePoint pair). What the
 * decision actually rests on is measured org/repo state — `Property__c` is `sharingModel =
 * Private`; its one sharing rule is an owner rule scoped to the `Acquisition` queue, which does not
 * reach a `LeadConvertService`-owned Property; `viewAllRecords` comes from four permission sets
 * none of which `DPEG_Transaction_Team` holds — recorded in the selector's own header for both
 * inner classes. The real proof is a post-deploy gate run AS a genuinely under-provisioned persona
 * (e.g. `DPEG_Transaction_Team`), never an Apex `runAs` block, which cannot falsify a
 * `SYSTEM_MODE`/`without sharing` read at all.
 *
 * No @TestSetup: each method builds exactly the rows it needs and asserts against them.
 */
@isTest
private class PropertySelectorTest {

    /** Matches the repo-standard bulk count (.claude/rules/bulk-test-rule.md). */
    private static final Integer BULK_N = 251;

    /**
     * THE FIELD SET IS THE CONTRACT. `Name` becomes `Property_Asset__c.Name`, which is a
     * MANDATORY Text field — losing it turns a deal close into a REQUIRED_FIELD_MISSING
     * rollback. `Asset_Type__c` feeds the `Property_Type__c` allow-list map. Narrowing this
     * SELECT breaks the caller, so both are asserted by value rather than by non-null.
     */
    @isTest
    static void selectAssetSeedByIds_returnsNameAndAssetType() {
        Property__c prop = TestDataFactory.createProperty(true);

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectAssetSeedByIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The one requested property should be returned');
        Assert.areEqual(prop.Id, result[0].Id, 'Id must be selected — it becomes the asset lookup');
        Assert.areEqual('Test Property 0', result[0].Name,
            'Name must be selected — it becomes the mandatory Property_Asset__c.Name');
        Assert.areEqual('Retail', result[0].Asset_Type__c,
            'Asset_Type__c must be selected — it is the only input to the Property_Type__c map');
    }

    /**
     * A property Id that no longer resolves is simply ABSENT, not a null row. That absence is
     * what `PropertyAssetService` counts as `runSkippedUnreadableProperty` and skips, instead
     * of building an asset with no Name and failing the entire deal close for every other deal
     * in the same chunk.
     */
    @isTest
    static void selectAssetSeedByIds_missingId_isAbsentNotNull() {
        Property__c live = TestDataFactory.createProperty(true);
        Property__c doomed = TestDataFactory.createProperty(true);
        Id ghostId = doomed.Id;
        delete doomed;

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectAssetSeedByIds(new Set<Id>{ live.Id, ghostId });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the surviving property comes back; a deleted Id yields no row at all');
        Assert.areEqual(live.Id, result[0].Id, 'The surviving row is the one that is returned');
    }

    /**
     * NULL/EMPTY SHORT-CIRCUIT. The wrapper returns an empty list WITHOUT issuing SOQL, which
     * is what lets the caller's "a chunk that closes no deal costs zero queries" budget hold.
     * The query count is asserted, not just the return value — returning empty after paying
     * for a query would satisfy a naive assertion while breaking the budget.
     */
    @isTest
    static void selectAssetSeedByIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> fromNull = PropertySelector.selectAssetSeedByIds(null);
        List<Property__c> fromEmpty = PropertySelector.selectAssetSeedByIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, spent, 'Neither short-circuit may issue SOQL');
    }

    /**
     * Bulk read per .claude/rules/bulk-test-rule.md: 251 properties in ONE call, one query.
     * A read has no trigger chunking, so what this actually pins is that the caller never
     * degrades into a per-record query — the same property the service's own budget test
     * asserts from the other side.
     */
    @isTest
    static void selectAssetSeedByIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> result = PropertySelector.selectAssetSeedByIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 properties should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // selectFolderStateByIds — added 2026-08-11 for the SharePoint deal-folder feature
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** THE FIELD SET IS THE CONTRACT: `Name` is the folder-name source, the three SharePoint
     *  fields are the idempotency guard and the stamp-without-a-second-read optimisation. */
    @isTest
    static void selectFolderStateByIds_returnsNameAndAllFourSharePointFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        update new Property__c(
            Id = prop.Id,
            SharePoint_Folder_ID__c = 'item-77',
            SharePoint_Folder_URL__c = 'https://contoso.sharepoint.com/x/item-77',
            SharePoint_Folder_Status__c = 'Created'
        );

        Test.startTest();
        List<Property__c> result = PropertySelector.selectFolderStateByIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), '');
        Assert.areEqual('Test Property 0', result[0].Name,
            'Name must be selected — it is the source DealFolderService.sanitizeFolderName sanitizes');
        Assert.areEqual('item-77', result[0].SharePoint_Folder_ID__c,
            'The idempotency guard field must be selected');
        Assert.areEqual('https://contoso.sharepoint.com/x/item-77', result[0].SharePoint_Folder_URL__c, '');
        Assert.areEqual('Created', result[0].SharePoint_Folder_Status__c, '');
    }

    @isTest
    static void selectFolderStateByIds_missingId_isAbsentNotNull() {
        Property__c live = TestDataFactory.createProperty(true);
        Property__c doomed = TestDataFactory.createProperty(true);
        Id ghostId = doomed.Id;
        delete doomed;

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectFolderStateByIds(new Set<Id>{ live.Id, ghostId });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the surviving property comes back');
        Assert.areEqual(live.Id, result[0].Id, '');
    }

    @isTest
    static void selectFolderStateByIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> fromNull = PropertySelector.selectFolderStateByIds(null);
        List<Property__c> fromEmpty = PropertySelector.selectFolderStateByIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), '');
        Assert.areEqual(0, spent,
            'Neither short-circuit may issue SOQL — this is what keeps a chunk that closes no deal '
            + 'at ZERO queries on the DealFolderService side');
    }

    /** Bulk read per .claude/rules/bulk-test-rule.md: 251 properties in ONE call, one query — the
     *  same property `DealFolderService.claimFolders` relies on for its constant-per-chunk budget. */
    @isTest
    static void selectFolderStateByIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> result = PropertySelector.selectFolderStateByIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 properties should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // queryFolderSweep — added 2026-08-11 for DealFolderSweepBatch
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void queryFolderSweep_returnsANonNullLocator() {
        Test.startTest();
        Database.QueryLocator locator = PropertySelector.queryFolderSweep();
        Test.stopTest();

        Assert.isNotNull(locator, 'The batch\'s start() depends on this never being null');
    }

    /**
     * The WHERE-clause discrimination itself (Pending/Failed included, Created/Skipped excluded)
     * is proven end-to-end through `DealFolderSweepBatchTest`
     * (`sweepBatch_createdAndSkippedRows_areNeverTouchedByTheBatch`), which can observe the effect
     * — which rows the batch actually touches — since a `Database.QueryLocator` exposes no
     * row-count or content API a selector-level test could assert against directly without driving
     * it through real batch execution. Deliberately not re-proven here at the raw-locator level.
     */

    // ═════════════════════════════════════════════════════════════════════════════════════
    // selectByNormalizedAddresses — added 2026-08-30 (WS3) for LeadConvertService's reuse lookup
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Two wordings of one building, differing in case, punctuation AND spacing, plus the key
     *  both must produce. The literal key is hardcoded so a change to the normalization's SHAPE
     *  is visible here rather than silently re-keying every Property in the org. */
    private static final String WORDING_A = '1400 Royal Lane, Dallas TX 75229';
    private static final String WORDING_B = '1400  ROYAL LANE., dallas,  tx  75229';
    private static final String KEY_AB = '1400 royal lane dallas tx 75229';

    /** A Property carrying a WS3 key. Built here rather than in `TestDataFactory` because the key
     *  is the subject of every test below and each one needs to choose it. */
    private static Property__c keyedProperty(String name, String address, String key) {
        return new Property__c(
            Name = name,
            Address__c = address,
            Normalized_Address__c = key,
            Asset_Type__c = 'Retail'
        );
    }

    /**
     * 🔴 `AccessLevel.SYSTEM_MODE` IS MANDATORY ON EVERY INSERT THAT TOUCHES
     * `Normalized_Address__c`, AND THIS WAS MEASURED, NOT ASSUMED. On 2026-08-30 a plain
     * `insert prop;` of these same fixtures failed all five tests below with
     *     System.DmlException: Operation failed due to fields being inaccessible on
     *     Sobject Property__c
     * running as a System Administrator. A Metadata-API-deployed field arrives with no
     * `FieldPermissions` row for ANY profile, and "Apex DML is system mode by default" does not
     * put back a field that is absent from the running user's schema — only an EXPLICIT access
     * level does. It is the same fact that forces `WITH SYSTEM_MODE` on the reads in this class,
     * and the same one that made `LeadConvertService.createProperties` state its access level.
     *
     * ⚠ Do not "fix" a future failure here by granting FLS in a permission set and reverting this
     * to a plain insert: the grant is a display concern, and a test that depends on it is a test
     * that breaks the day someone tightens a permission set.
     */
    private static void insertKeyed(List<Property__c> properties) {
        Database.insert(properties, true, AccessLevel.SYSTEM_MODE);
    }

    /** Single-record convenience over `insertKeyed`. */
    private static Property__c insertKeyed(Property__c property) {
        insertKeyed(new List<Property__c>{ property });
        return property;
    }

    /**
     * THE FIELD SET IS THE CONTRACT, and it is TWO fields for a reason the caller depends on.
     * `Id` is the value `LeadConvertService` links to; `Normalized_Address__c` is what lets it
     * re-key an unordered result list back onto the (up to 251) buildings it asked about. Dropping
     * the second field does not fail loudly — the caller simply cannot tell which row answered
     * which question.
     *
     * The lookup is asserted through the SECOND broker's wording, not the first, so the test
     * exercises what the feature is for: two spellings of one building meeting on one key.
     */
    @isTest
    static void selectByNormalizedAddresses_returnsIdAndKey() {
        Property__c prop = keyedProperty('Orion ParkView', WORDING_A, KEY_AB);
        insertKeyed(prop);
        Assert.areEqual(KEY_AB, PropertyMatchingService.normalizeAddress(WORDING_B),
            'PRECONDITION: the second wording really does normalize onto the same key, or this '
            + 'test is about string equality rather than about the feature');

        Test.startTest();
        List<Property__c> result = PropertySelector.selectByNormalizedAddresses(
            new Set<String>{ PropertyMatchingService.normalizeAddress(WORDING_B) });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The building is found through the other broker\'s wording');
        Assert.areEqual(prop.Id, result[0].Id,
            'Id must be selected — it becomes Opportunity.Property__c on the reusing deal');
        Assert.areEqual(KEY_AB, result[0].Normalized_Address__c,
            'and Normalized_Address__c must be selected — without it the caller cannot map an '
            + 'unordered result set back onto the keys it asked about');
    }

    /**
     * 🔴 THE BLANK-KEY STRIP, WHICH GUARDS THE WORST OUTCOME THIS METHOD CAN PRODUCE.
     * `PropertyMatchingService.normalizeAddress` returns `''` for a blank address. A `''` that
     * reached the WHERE clause would match every Property whose key is empty, collapsing every
     * addressless building in the org into one answer — and it is one careless caller away.
     *
     * The query count is asserted, not merely the empty result: returning empty AFTER paying for a
     * query would satisfy a naive assertion while breaking the caller's per-invocation budget (the
     * `LeadConvertService` header's third SOQL is "skipped entirely when no Lead carries an
     * address", and this short-circuit is what makes that true).
     */
    @isTest
    static void selectByNormalizedAddresses_nullEmptyOrAllBlank_returnsEmptyAndCostsNoQuery() {
        // A Property that DOES carry an empty-string key — the row a leaked '' would find. It can
        // only be built by hand; the service never writes one (buildProperty nulls a blank key).
        insertKeyed(keyedProperty('Nameless building', null, ''));

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> fromNull = PropertySelector.selectByNormalizedAddresses(null);
        List<Property__c> fromEmpty = PropertySelector.selectByNormalizedAddresses(new Set<String>());
        List<Property__c> fromBlanks =
            PropertySelector.selectByNormalizedAddresses(new Set<String>{ '', '   ', null });
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, fromBlanks.size(),
            '🔴 and an all-blank input finds NOTHING — not the empty-keyed Property inserted above. '
            + 'A blank is the ABSENCE of a key, not a key that happens to be short');
        Assert.areEqual(0, spent,
            'None of the three short-circuits may issue SOQL — the caller\'s budget says the reuse '
            + 'read is skipped entirely for a chunk in which no Lead carries an address');
    }

    /**
     * Bulk read per `.claude/rules/bulk-test-rule.md`: 251 keys in ONE call, ONE query. A read has
     * no trigger chunking, so what this pins is that `LeadConvertService` can hand the whole
     * converted chunk over in a single call — which is the entire reason the WS3 contract change
     * is "+1 SOQL" rather than "+1 SOQL per Lead".
     */
    @isTest
    static void selectByNormalizedAddresses_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = new List<Property__c>();
        Set<String> keys = new Set<String>();
        for (Integer i = 0; i < BULK_N; i++) {
            String wording = i + ' Bulk Reuse Street, Houston TX';
            String key = PropertyMatchingService.normalizeAddress(wording);
            properties.add(keyedProperty('Bulk Property ' + i, wording, key));
            keys.add(key);
        }
        insertKeyed(properties);
        Assert.areEqual(BULK_N, keys.size(), 'Fixture sanity: 251 DISTINCT keys');

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> result = PropertySelector.selectByNormalizedAddresses(keys);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 buildings should be returned');
        Assert.areEqual(1, spent, 'A 251-key read costs exactly one query, not 251');
    }

    /**
     * DUPLICATE KEYS ARE LEGAL AND THE ORDER IS THE CONTRACT. `Normalized_Address__c` is
     * deliberately `unique = false` — the org may already hold two Property rows for one building
     * (that is the bug WS3 fixes, and a unique index would refuse the backfill that finds them) —
     * so this method CAN return several rows for one key.
     *
     * `LeadConvertService` keeps the FIRST row per key, so "first" must mean the OLDEST row, every
     * run. Otherwise reuse oscillates between two duplicates transaction by transaction, and the
     * building's deals scatter across both of them instead of converging on one.
     *
     * ⚠ `Test.setCreatedDate` is what makes this non-vacuous: two rows inserted in one transaction
     * share a CreatedDate to the second, so without it the `ORDER BY` would be decided by the Id
     * tiebreak alone and the age half of the contract would never be exercised.
     */
    @isTest
    static void selectByNormalizedAddresses_duplicateKey_returnsOldestFirst() {
        Property__c newer = keyedProperty('Newer duplicate', WORDING_B, KEY_AB);
        Property__c older = keyedProperty('Older duplicate', WORDING_A, KEY_AB);
        insertKeyed(new List<Property__c>{ newer, older });
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-90));

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectByNormalizedAddresses(new Set<String>{ KEY_AB });
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            'Both rows come back — the key is not unique, by design, so this method must not '
            + 'silently pick one for the caller');
        Assert.areEqual(older.Id, result[0].Id,
            'and the OLDEST is FIRST. The caller keeps result[0] per key, so this ordering is what '
            + 'makes reuse converge on the original Property instead of alternating between two '
            + 'duplicates run to run');
    }

    /**
     * 🔴 THE MODE AND THE SHARING, MEASURED RATHER THAN ARGUED — AND THIS METHOD IS THE FIRST IN
     * THIS CLASS FOR WHICH SUCH A TEST IS NOT VACUOUS. Read this together with the amended
     * paragraph in the class header.
     *
     * Why it falsifies here when the header says it would not for the other three: those three
     * are read-for-display or write-back paths where an under-read produces a SILENCE, and the
     * argument for `without sharing` is about what fails to happen. This one is an EXISTENCE
     * GUARD. Under `with sharing` a converter who cannot see the earlier Property gets ZERO ROWS,
     * `LeadConvertService` reads that as "this building is new", and it creates the duplicate the
     * whole workstream exists to prevent — so the two implementations differ in a value this test
     * can read, not merely in a risk profile.
     *
     * Both halves are pinned by one fixture, and each is separately falsifiable:
     *   • SHARING — ✅ MEASURED 2026-08-30, not reasoned about. Flipping `ReuseLookupReads` to
     *     `with sharing` and re-running this class gave EXACTLY ONE failure — this method —
     *     `Assertion Failed: The reuse lookup finds the building ANYWAY`, with the other 13 tests
     *     still green. The persona (Minimum Access, no permission sets, does not own the row,
     *     `Property__c` OWD Private) gets zero rows.
     *   • MODE — flip `WITH SYSTEM_MODE` to `WITH USER_MODE` and the same persona, who holds no
     *     `Property__c` CRUD at all, gets a `QueryException` instead of a result.
     *
     * The `UserRecordAccess` assertion is the CONTROL. Without it, a persona who happened to have
     * access would make the whole test pass while proving nothing — the exact shape of vacuum the
     * class header is right to be suspicious of.
     */
    @isTest
    static void selectByNormalizedAddresses_escapesSharingForAPrincipalWhoCannotSeeTheRow() {
        Property__c prop = keyedProperty('Invisible ParkView', WORDING_A, KEY_AB);
        insertKeyed(prop);
        User outsider = minimumAccessUser('wsx');

        // CONTROL: the persona genuinely cannot see this row. `RecordId` must be SELECTed as well
        // as filtered on, or UserRecordAccess returns rows that cannot be matched back.
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :outsider.Id AND RecordId = :prop.Id
        ];
        Assert.areEqual(1, access.size(), 'Control: access is measurable for this persona/row pair');
        Assert.isFalse(access[0].HasReadAccess,
            'CONTROL, and the test is vacuous without it: the persona must genuinely have NO read '
            + 'access to this Property. Property__c OWD is Private, the persona owns nothing and '
            + 'holds none of the four permission sets granting viewAllRecords');

        List<Property__c> result;
        Test.startTest();
        System.runAs(outsider) {
            result = PropertySelector.selectByNormalizedAddresses(new Set<String>{ KEY_AB });
        }
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'The reuse lookup finds the building ANYWAY. A zero here means the read stopped '
            + 'escaping sharing — and the visible consequence is not an error, it is a DUPLICATE '
            + 'Property, i.e. the pre-WS3 behaviour restored silently for exactly the competing-'
            + 'broker population the feature was built for');
        Assert.areEqual(prop.Id, result[0].Id, 'and it is the right building');
    }

    /**
     * A persona with the Minimum Access profile and NO permission set of any kind — the shape
     * `.claude/agent-memory` and this repo's denial tests both settle on, because `Standard User`
     * grants enough on standard objects to mask a denial. Nothing is granted here deliberately:
     * the point of the persona is that it can see nothing.
     *
     * ⚠ MIXED_DML: `User` is a setup object and this class does non-setup DML in the same
     * transaction, so the insert runs inside `System.runAs(currentUser)` — the same workaround
     * `TestDataFactory`'s own User builders and `LeadConvertServiceTest.lookupOnlyUser` use.
     *
     * @param aliasSeed 1-4 lowercase characters; the Alias field caps at 8 with the uniquifier.
     * @return The inserted User.
     */
    private static User minimumAccessUser(String aliasSeed) {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        String unique = aliasSeed + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User persona = new User(
            FirstName = 'Sharing',
            LastName = 'Outsider',
            Alias = aliasSeed,
            Email = 'sharing.outsider@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert persona;
        }
        return persona;
    }
}
