/**
 * Test class for `PropertyPackageController` — the reads behind `c/packageSiblings` (a card on the
 * Lead and Opportunity record pages) and `c/recentPackages` (a Lead Funnel homepage widget, added
 * 2026-08-17, design §8).
 *
 * ⚠ TWO METHODS, TWO SECTIONS, AND THEY SHARE ONLY THE FIXTURE HELPERS. `getSiblingRecords` is a
 * per-record read whose interesting behaviour is the server-side object DISPATCH; `getRecentPackages`
 * is a no-argument org-wide read whose interesting behaviour is ORDER + LIMIT + member counting. The
 * `getRecentPackages` methods live in their own section at the foot of this class, and several of them
 * depend on `Test.setCreatedDate` (rows inserted in one transaction can tie on `CreatedDate`, and
 * `ORDER BY` over ties is unspecified — so an order assertion without it passes by luck).
 *
 * ⚠ THE TWO FAILURE-PATH TESTS ARE NOT DUPLICATES: each asserts its own method's OWN user-safe
 * message and asserts the other's is absent. The messages are deliberately different constants,
 * because one is shown on a record page and the other on a homepage.
 *
 * ═══ WHAT IS ACTUALLY UNDER TEST: THE SERVER DISPATCH ═══
 * The feature's whole design claim is that ONE LWC bundle can sit on the Lead record page AND the
 * Opportunity record page because the SERVER decides which object it was handed. So the two most
 * important tests here are a matched PAIR — the same package read from a Lead anchor and from an
 * Opportunity anchor — asserting that each returns the OTHER members. A dispatch that silently
 * worked for one object and returned nothing for the other would look perfectly healthy from either
 * page alone, which is exactly why the pair discriminates in both directions.
 *
 * ⚠ ONE METHOD RUNS A REAL `Database.convertLead`
 * (`getSiblingRecords_fromAConvertedDeal_doesNotListTheDealsOwnFormerLeadAsASibling`), and it is the
 * only one that can: the current-record exclusion here compares Ids, and a converted deal's own
 * former Lead has a DIFFERENT Id while being the SAME asset. Independently-inserted fixtures make
 * that exclusion look correct at every member count. Its selector-layer twin is
 * `PropertyPackageSelectorTest.aConvertedMemberIsCountedOnceNotTwice`.
 *
 * ═══ ⚠ NO 251-RECORD BULK TEST — ARGUED, NOT SKIPPED ═══
 * `.claude/rules/bulk-test-rule.md`'s mandate exists to force a second trigger batch chunk and to
 * expose per-record queries. Neither is reachable here:
 *   • THE METHOD IS SINGLE-RECORD BY CONSTRUCTION — it takes ONE `recordId`, because it is a
 *     `cacheable=true` read for ONE record page a human has open. There is no collection parameter.
 *   • A PACKAGE CANNOT HAVE 251 MEMBERS. `ExtractAddressQueueable.MAX_PROPERTIES` is 10, so one
 *     email routes at most 10 properties -> at most 10 Leads plus at most 10 converted
 *     Opportunities. 251 members is a state production cannot produce.
 * The genuine risk is a read whose cost grows per member, and
 * `getSiblingRecords_costsExactlyTwoQueriesAtVolume` asserts that directly, at a member count above
 * the production ceiling. `PropertyPackageSelectorTest` carries the same argument for the query
 * itself.
 *
 * ⚠ The AuraHandledException boundary is covered with the repo-standard BARE-USER technique: a user
 * on `Minimum Access - Salesforce` has no FLS on `Property_Package__c`, so `WITH USER_MODE` throws
 * `System.QueryException` ("No such column ..." — how the platform reports an FLS denial) and the
 * catch runs. 🔴 That test stops proving anything the moment anyone "simplifies" either selector to
 * SYSTEM_MODE, because SYSTEM_MODE is precisely what suppresses the throw. Both selectors are
 * USER_MODE deliberately (they back a user-requested record-page read) and must stay so.
 */
@isTest
private class PropertyPackageControllerTest {

    /** Above the production ceiling of 10 (MAX_PROPERTIES). See the class header. */
    private static final Integer VOLUME_MEMBERS = 25;

    private static Property_Package__c insertPackage(String name) {
        Property_Package__c pkg = new Property_Package__c(Name = name, Property_Count__c = 3);
        insert pkg;
        return pkg;
    }

    private static List<Lead> insertMemberLeads(Integer count, Id packageId) {
        List<Lead> leads = TestDataFactory.createLeads(count, false);
        for (Lead l : leads) {
            l.Property_Package__c = packageId;
        }
        insert leads;
        return leads;
    }

    private static List<Opportunity> insertMemberOpportunities(Integer count, Id packageId) {
        List<Opportunity> opps = TestDataFactory.createOpportunities(count, null, false);
        for (Opportunity o : opps) {
            o.Property_Package__c = packageId;
        }
        insert opps;
        return opps;
    }

    /**
     * A user with a real licence and NO permission sets, so `WITH USER_MODE` denies
     * `Property_Package__c`. Inserted inside a `System.runAs` wrapper because `User` is a SETUP
     * object and this class also inserts business records — the canonical MIXED_DML workaround.
     */
    private static User insertBareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User bare = new User(
            FirstName = 'Bare',
            LastName = 'PackageReader',
            Alias = 'barepkg',
            Email = 'bare.package@example.invalid',
            Username = 'bare.package.' + unique + '@example.invalid',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bare;
        }
        return bare;
    }

    /**
     * Index the rows by Id for order-independent assertions.
     *
     * ⚠ Keyed by STRING, not by Id, because `SiblingRow.id` is a `String` — the DTO is serialized to
     * the client, where an Id has no meaning. Keying a `Map<Id, ...>` off it would rely on Apex's
     * implicit String-to-Id conversion, which is validated at RUNTIME; a String map cannot fail that
     * way. Callers therefore pass `String.valueOf(someId)`.
     */
    private static Map<String, PropertyPackageController.SiblingRow> byId(
            List<PropertyPackageController.SiblingRow> rows) {
        Map<String, PropertyPackageController.SiblingRow> result =
            new Map<String, PropertyPackageController.SiblingRow>();
        for (PropertyPackageController.SiblingRow row : rows) {
            result.put(row.id, row);
        }
        return result;
    }

    // ── THE MATCHED PAIR: the same package, read from both object types ──────

    @isTest
    static void getSiblingRecords_fromALeadAnchor_returnsTheOtherMembersAndExcludesItself() {
        Property_Package__c pkg = insertPackage('FW: three-asset portfolio');
        List<Lead> leads = insertMemberLeads(2, pkg.Id);
        List<Opportunity> opps = insertMemberOpportunities(1, pkg.Id);
        Lead anchor = leads[0];

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(pkg.Id), result.packageId, 'The package header must come back');
        Assert.areEqual('FW: three-asset portfolio', result.packageName,
            'with its Name — the card\'s heading, and the only human-recognisable identifier a '
            + 'package has');
        Assert.areEqual('/lightning/r/Property_Package__c/' + pkg.Id + '/view', result.packageUrl,
            'and a server-built URL. The CLIENT must never compose one — that needs the object API '
            + 'name, the single thing this design keeps away from the component');

        Assert.areEqual(2, result.siblings.size(),
            'The OTHER Lead and the Opportunity — two siblings from a three-member package');
        Map<String, PropertyPackageController.SiblingRow> rows = byId(result.siblings);
        Assert.isFalse(rows.containsKey(String.valueOf(anchor.Id)),
            '🔴 THE ANCHOR MUST BE EXCLUDED. A card that lists the record you are already looking at '
            + 'as one of its "related" records reads as a bug on every single package');
        Assert.isTrue(rows.containsKey(String.valueOf(leads[1].Id)), 'the sibling Lead is present');
        Assert.isTrue(rows.containsKey(String.valueOf(opps[0].Id)),
            'AND SO IS THE OPPORTUNITY. A Lead\'s siblings are not only Leads — once one member of a '
            + 'package converts, the card must still show it, or the grouping appears to shrink as '
            + 'the deals progress');

        PropertyPackageController.SiblingRow leadRow = rows.get(String.valueOf(leads[1].Id));
        Assert.areEqual('/lightning/r/Lead/' + leads[1].Id + '/view', leadRow.recordUrl,
            'each row carries its own server-built URL');
        Assert.isNotNull(leadRow.name, 'and a label');
        Assert.areEqual('New', leadRow.status, 'and its state — Lead.Status for a Lead row');
        Assert.isNotNull(leadRow.objectLabel,
            'and the object LABEL, supplied by the server so the client never derives an object name');

        PropertyPackageController.SiblingRow oppRow = rows.get(String.valueOf(opps[0].Id));
        Assert.areEqual('/lightning/r/Opportunity/' + opps[0].Id + '/view', oppRow.recordUrl, '');
        Assert.areEqual('New', oppRow.status,
            'an Opportunity row carries StageName in the SAME field — one column, whichever object '
            + 'the row is');
        Assert.areNotEqual(leadRow.objectLabel, oppRow.objectLabel,
            'and the two labels DIFFER, which is what lets a human tell a Lead row from a deal row '
            + 'without the client knowing either object name');
    }

    @isTest
    static void getSiblingRecords_fromAnOpportunityAnchor_returnsTheOtherMembersAndExcludesItself() {
        // 🔴 THE OTHER HALF OF THE PAIR. This is the test that fails if the dispatch only ever
        // learned about Lead — a defect invisible from the Lead record page, which is where anyone
        // would smoke-test first.
        Property_Package__c pkg = insertPackage('FW: converted portfolio');
        List<Lead> leads = insertMemberLeads(2, pkg.Id);
        List<Opportunity> opps = insertMemberOpportunities(2, pkg.Id);
        Opportunity anchor = opps[0];

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(pkg.Id), result.packageId,
            'An Opportunity anchor resolves the SAME package. The client sent only an Id — it does '
            + 'not know, and must not need to know, which object it is on');
        Assert.areEqual(3, result.siblings.size(), 'Two Leads plus the other Opportunity');
        Map<String, PropertyPackageController.SiblingRow> rows = byId(result.siblings);
        Assert.isFalse(rows.containsKey(String.valueOf(anchor.Id)), 'The anchoring deal is excluded');
        Assert.isTrue(rows.containsKey(String.valueOf(opps[1].Id)), 'its sibling deal is present');
        Assert.isTrue(rows.containsKey(String.valueOf(leads[0].Id)) && rows.containsKey(String.valueOf(leads[1].Id)),
            'and so are the Leads that have not converted yet');
    }

    /** See PropertyPackageSelectorTest.convertedStatus — this org's Lead Status picklist is custom. */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    @isTest
    static void getSiblingRecords_fromAConvertedDeal_doesNotListTheDealsOwnFormerLeadAsASibling() {
        // 🔴 THE SECOND HALF OF REVIEW C3, AND THE HALF THE SELECTOR TEST CANNOT SEE. Its twin,
        // PropertyPackageSelectorTest.aConvertedMemberIsCountedOnceNotTwice, pins the member COUNT at
        // the query. This pins what a human actually looks at, and it fails for a reason no Id
        // comparison can fix:
        //
        // `buildSiblings` excludes the current record by comparing Ids — `l.Id != recordId`. When the
        // card is on an Opportunity, that deal's OWN former Lead has a DIFFERENT Id, even though the
        // two rows are one asset. So before the selector's `IsConverted = false` filter, opening a
        // converted deal showed the deal ITSELF in its own "related properties" list, as a Lead whose
        // link redirects to a Contact. The current-record exclusion cannot be strengthened to catch
        // it (there is no Id to compare against); the husk has to leave the query, which is why the
        // fix is one WHERE clause in the selector and NOT a second condition here.
        //
        // ⚠ THIS FIXTURE MUST CONVERT FOR REAL. Inserting a Lead and an Opportunity separately gives
        // them no relationship at all, so the exclusion would look correct at any member count.
        Property_Package__c pkg = insertPackage('FW: two assets, one worked');
        List<Lead> members = insertMemberLeads(2, pkg.Id);
        Lead becomesTheDeal = members[0];
        Lead staysOpen = members[1];

        // The conversion is FIXTURE, so it sits outside the test block — the same shape
        // LeadConvertServiceTest.convertLeadOfType uses. What is under test is the READ that follows.
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(becomesTheDeal.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        Assert.isTrue(res.isSuccess(), 'Precondition: the conversion must succeed');
        Id anchorOppId = res.getOpportunityId();

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(anchorOppId);
        Test.stopTest();

        Assert.areEqual(String.valueOf(pkg.Id), result.packageId,
            'The converted deal still resolves its package — the grouping survives conversion, which '
            + 'is the entire point of carrying Property_Package__c forward');
        Map<String, PropertyPackageController.SiblingRow> rows = byId(result.siblings);
        Assert.isFalse(rows.containsKey(String.valueOf(becomesTheDeal.Id)),
            '🔴 THE ANCHOR DEAL\'S OWN FORMER LEAD MUST NOT BE LISTED. It is not a related property, '
            + 'it IS this property — and its row would carry a URL that silently navigates the user '
            + 'to a Contact');
        Assert.isFalse(rows.containsKey(String.valueOf(anchorOppId)),
            'and neither is the deal itself, by the ordinary Id exclusion');
        Assert.areEqual(1, result.siblings.size(),
            'exactly ONE sibling: the other asset off the same email. Two would mean this deal is '
            + 'showing up as its own sibling');
        Assert.areEqual(String.valueOf(staysOpen.Id), result.siblings[0].id,
            'and it is the member that has not been worked yet — the row a human would actually click');
    }

    // ── "nothing to show" is an ANSWER, never an error ──────────────────────

    @isTest
    static void getSiblingRecords_recordWithNoPackage_returnsAnEmptyResultNotAnError() {
        // THE OVERWHELMINGLY COMMON CASE — most emails name one property, so most Leads have no
        // package. It must be cheap and boring: the client renders NOTHING (not an empty card) when
        // packageId is null, so an exception here would put a red banner on nearly every Lead.
        Lead solo = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(solo.Id);
        Test.stopTest();

        Assert.isNull(result.packageId, 'No package means a null Id — the client\'s "render nothing" signal');
        Assert.isNotNull(result.siblings,
            'and siblings is ALWAYS a list, never null. The DTO initialises it so the component needs '
            + 'no defensive check of its own');
        Assert.areEqual(0, result.siblings.size(), 'and it is empty');
    }

    @isTest
    static void getSiblingRecords_packageWhoseOnlyMemberIsTheAnchor_returnsZeroSiblings() {
        // The memberless / single-member package is a real accepted residual (design R6): a
        // multi-property email whose other properties failed to route after the package was created.
        // The package Id is still returned — it is TRUE that this record came off a multi-property
        // email, and the link is how a human reaches the routing audit that explains the rest.
        Property_Package__c pkg = insertPackage('FW: only one routed');
        Lead only = insertMemberLeads(1, pkg.Id)[0];

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(only.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(pkg.Id), result.packageId,
            'The package is still reported — a one-member package records that a multi-property '
            + 'email arrived and mostly failed, which is information, not noise');
        Assert.areEqual(0, result.siblings.size(),
            'with no siblings, because the anchor is excluded from its own list');
    }

    @isTest
    static void getSiblingRecords_nullRecordId_returnsAnEmptyResultWithoutQuerying() {
        Test.startTest();
        Integer q0 = Limits.getQueries();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(null);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.isNull(result.packageId, 'A null Id yields the empty result');
        Assert.areEqual(0, result.siblings.size(), '');
        Assert.areEqual(0, queryDelta,
            'and costs NO query. A record page can render before recordId is injected, so this path '
            + 'is genuinely reached');
    }

    @isTest
    static void deletingAPackage_setNullsEveryMemberLookup_whichIsWhyTheControllerCanNeverObserveAStaleId() {
        // 🔴 THIS TEST DOES NOT EXERCISE `getSiblingRecords` AT ALL — it exists to explain, with a
        // measurement rather than a claim, why the controller's defensive `pkg == null` branch
        // (reached when `resolvePackageId` returns a non-null Id but
        // `PropertyPackageSelector.selectWithMembersById` finds no row for it) is UNREACHABLE via
        // integration testing and therefore cannot be covered the way every other branch in this
        // class is.
        //
        // The three `Property_Package__c` lookups (Lead, Opportunity, Property__c) are all
        // `deleteConstraint SetNull` (§1 rule 3: "deleting a package must never cascade into deal
        // records"). SetNull is not merely a delete-time permission check — the platform NULLS OUT
        // every child's lookup field AS PART OF THE SAME DELETE, synchronously, in the same
        // transaction, which this test measures directly. So a Lead can never be read back still
        // carrying a package Id that no longer resolves to a row: the instant the package is gone,
        // so is the pointer. Building a fixture that fakes the opposite state would mean inserting a
        // Lead with `Property_Package__c` set to an already-nonexistent Id, which the platform
        // refuses at DML with `INVALID_CROSS_REFERENCE_KEY` before the fixture can even exist.
        //
        // The null-guard in `getSiblingRecords` is retained anyway, deliberately, as defense in
        // depth against exactly the class of bug `PropertyPackageSelectorTest
        // .selectWithMembersById_unknownIdReturnsNullRatherThanThrowing` pins at the selector layer
        // — a future caller of that selector, or a future relationship shape without SetNull, must
        // still not NPE. This test is the record of why code review should not ask for that one line
        // to be "covered" the ordinary way.
        Property_Package__c pkg = insertPackage('FW: about to vanish from under a Lead');
        Lead member = insertMemberLeads(1, pkg.Id)[0];
        Assert.areEqual(pkg.Id,
            [SELECT Property_Package__c FROM Lead WHERE Id = :member.Id].Property_Package__c,
            'Precondition: the Lead really does carry the package before the delete');

        Test.startTest();
        delete pkg;
        Test.stopTest();

        Assert.isNull(
            [SELECT Property_Package__c FROM Lead WHERE Id = :member.Id].Property_Package__c,
            'SetNull fires IN THE SAME TRANSACTION as the delete: the moment the package is gone, '
            + 'every member\'s lookup is nulled with it — there is no window in which a Lead can be '
            + 'read back still pointing at a package that no longer exists');
    }

    @isTest
    static void getSiblingRecords_unsupportedObjectType_returnsAnEmptyResultRatherThanThrowing() {
        // The dispatch is an ALLOW-LIST. An admin can place this component on any record page in App
        // Builder, and a placement on a third object is a configuration mistake that should render
        // nothing — not an error banner on someone's record.
        Contact c = TestDataFactory.createContact(null, true);

        Test.startTest();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(c.Id);
        Test.stopTest();

        Assert.isNull(result.packageId,
            'An Id of an object this card does not serve resolves to no package, silently. Adding a '
            + 'third object is a `when` branch plus that object\'s own selector method — never a '
            + 'new bundle');
        Assert.areEqual(0, result.siblings.size(), '');
    }

    // ── governor headroom ───────────────────────────────────────────────────

    @isTest
    static void getSiblingRecords_costsExactlyTwoQueriesAtVolume() {
        // 🔴 THE REPLACEMENT FOR THE 251-RECORD MANDATE, and a sharper instrument. TWO queries: the
        // ANCHOR read (which package is this record in?) and the PACKAGE read (which returns BOTH
        // member collections through relationship subqueries). It is 2 at 25 members exactly as it
        // is at 2 — a per-member read would report 26.
        Property_Package__c pkg = insertPackage('FW: volume');
        List<Lead> leads = insertMemberLeads(VOLUME_MEMBERS, pkg.Id);

        Test.startTest();
        Integer q0 = Limits.getQueries();
        PropertyPackageController.PackageSiblings result =
            PropertyPackageController.getSiblingRecords(leads[0].Id);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(2, queryDelta,
            'EXACTLY TWO queries at ' + VOLUME_MEMBERS + ' members: one anchor read plus one '
            + 'package-with-subqueries read. Three would mean the Leads and Opportunities are being '
            + 'fetched separately; ' + (VOLUME_MEMBERS + 1) + ' would mean per-member reads');
        Assert.areEqual(VOLUME_MEMBERS - 1, result.siblings.size(),
            'and every member but the anchor came back — otherwise the count above is cheap for the '
            + 'wrong reason');
    }

    // ── the AuraHandledException boundary ───────────────────────────────────

    @isTest
    static void aDeniedReadSurfacesAsAnAuraHandledExceptionWithNoPlatformText() {
        Property_Package__c pkg = insertPackage('FW: denied');
        Lead anchor = insertMemberLeads(1, pkg.Id)[0];
        User bare = insertBareUser();

        Test.startTest();
        System.runAs(bare) {
            try {
                PropertyPackageController.getSiblingRecords(anchor.Id);
                Assert.fail('A user with no FLS on Lead.Property_Package__c must be refused. If this '
                    + 'line is reached, either the anchor read stopped being USER_MODE or the bare '
                    + 'user acquired a grant — and this test now proves nothing');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('related properties could not be loaded'),
                    'ARCHITECTURE.md §5: the boundary must return a FIXED, user-safe message and '
                    + 'never leak platform text such as "No such column". Got: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('No such column'),
                    'and specifically not the FLS-denial wording, which tells a user nothing and '
                    + 'tells an attacker something');
            }
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // getRecentPackages — the c/recentPackages homepage widget (2026-08-17, design §8)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Index the rows by package Id. Keyed by STRING for the same reason `byId` above is — the DTO is
     * serialized to the client, where an Id has no meaning, so `RecentPackageRow.id` is a `String`.
     */
    private static Map<String, PropertyPackageController.RecentPackageRow> recentById(
            List<PropertyPackageController.RecentPackageRow> rows) {
        Map<String, PropertyPackageController.RecentPackageRow> result =
            new Map<String, PropertyPackageController.RecentPackageRow>();
        for (PropertyPackageController.RecentPackageRow row : rows) {
            result.put(row.id, row);
        }
        return result;
    }

    /**
     * Insert `count` packages with DISTINCT `CreatedDate`s, oldest first.
     *
     * 🔴 `Test.setCreatedDate` IS REQUIRED FOR ANY ORDER- OR LIMIT-SENSITIVE ASSERTION HERE: rows
     * inserted in one transaction can tie on `CreatedDate`, and `ORDER BY ... DESC` over ties returns
     * an UNSPECIFIED order — so "the newest five came back" would pass or fail by luck and would keep
     * passing with the `ORDER BY` deleted. Same helper, same reason, as
     * `PropertyPackageSelectorTest.insertPackagesWithDistinctCreatedDates`.
     *
     * @return The packages oldest-first, so the expected result of a newest-first read is REVERSED.
     */
    private static List<Property_Package__c> insertPackagesOldestFirst(Integer count) {
        List<Property_Package__c> packages = new List<Property_Package__c>();
        for (Integer i = 0; i < count; i++) {
            packages.add(new Property_Package__c(
                Name = 'FW: package ' + i,
                Property_Count__c = 2
            ));
        }
        insert packages;
        for (Integer i = 0; i < count; i++) {
            Test.setCreatedDate(packages[i].Id, Datetime.now().addDays(i - count));
        }
        return packages;
    }

    @isTest
    static void getRecentPackages_mapsEveryFieldTheWidgetRenders() {
        // FIELD-BY-FIELD, because every one of these drives a visible cell and a silently-unmapped
        // field renders as an empty cell or an em dash — which on this widget reads as a FACT ("the
        // broker did not say"), not as a bug.
        Property_Package__c pkg = new Property_Package__c(
            Name = 'FW: fully populated portfolio',
            Property_Count__c = 4,
            Broker_Name__c = 'Dana Reyes',
            Broker_Email__c = 'dana@brokerage.example.com',
            Received_DateTime__c = Datetime.newInstanceGmt(2026, 8, 14, 17, 30, 0)
        );
        insert pkg;
        insertMemberLeads(2, pkg.Id);
        insertMemberOpportunities(1, pkg.Id);

        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One package in the org, one row');
        PropertyPackageController.RecentPackageRow row = rows[0];

        Assert.areEqual(String.valueOf(pkg.Id), row.id, 'the Id, as the datatable key-field');
        Assert.areEqual('FW: fully populated portfolio', row.name,
            'the Name — the row label and its link text');
        Assert.areEqual('/lightning/r/Property_Package__c/' + pkg.Id + '/view', row.recordUrl,
            '🔴 A SERVER-BUILT URL, reusing the same private recordUrl() helper as the sibling card. '
            + 'The client must not compose one: that would put the object API name in a second place, '
            + 'and the server already owns that string');
        // ⚠ `.intValue()` is type-explicit and scale-independent, not a fix for a measured failure —
        // see the fuller note in `PropertyPackageSelectorTest.selectRecent_selectsEveryFieldTheWidget
        // Displays`. The Integer-vs-Decimal `equals` trap is real for a scale-BEARING field; on a
        // scale-0 Number like this one the bare form is green in this org.
        Assert.areEqual(4, row.propertyCount.intValue(),
            'Property_Count__c — properties named in the EMAIL, which is why it may legitimately '
            + 'disagree with the two member counts below (design residual R9)');
        Assert.areEqual('Dana Reyes', row.brokerName, 'the Broker cell');
        Assert.areEqual('dana@brokerage.example.com', row.brokerEmail,
            'and its supporting text in the same cell');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 14, 17, 30, 0), row.receivedDateTime,
            'Received_DateTime__c — what the Received column DISPLAYS');
        Assert.isNotNull(row.createdDate,
            'AND CreatedDate, which is a different field doing a different job: it is the SORT key, '
            + 'and the client uses it for a relative-age fallback when receivedDateTime is null. '
            + 'Dropping it from the DTO would silently blank the Received cell of every package whose '
            + 'header parse failed');
        Assert.areEqual(2, row.leadCount,
            'leadCount is .size() on the Leads__r subquery — no second query, no aggregate subquery');
        Assert.areEqual(1, row.opportunityCount, 'and opportunityCount likewise');
    }

    @isTest
    static void getRecentPackages_returnsNewestFirst() {
        // The widget's whole reason for existing is that `recentLeads`' priority-partitioned feed can
        // push a package's Leads past its cutoff. An unordered read here reproduces that defect in a
        // new place: five arbitrary packages instead of the five most recent.
        List<Property_Package__c> oldestFirst = insertPackagesOldestFirst(3);

        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'all three fit inside RECENT_LIMIT');
        Assert.areEqual(String.valueOf(oldestFirst[2].Id), rows[0].id,
            '🔴 NEWEST FIRST, and the ORDER SURVIVES THE DTO MAPPING. The selector orders the rows; '
            + 'this asserts the controller\'s loop does not reverse or re-sort them');
        Assert.areEqual(String.valueOf(oldestFirst[0].Id), rows[2].id, 'and the oldest is last');
    }

    @isTest
    static void getRecentPackages_respectsRECENT_LIMITAndKeepsTheNEWEST() {
        // 🔴 TWO CLAIMS, AND THE SECOND IS THE LOAD-BEARING ONE. "Five of seven" is satisfied by ANY
        // five — including the five OLDEST, which is what a LIMIT with no (or an ascending) ORDER BY
        // returns. A homepage widget showing the five oldest packages in the org would look entirely
        // healthy and be exactly backwards.
        //
        // ⚠ The count is asserted against the CONSTANT, not against a literal 5. Changing
        // RECENT_LIMIT is a legitimate product decision and must not red this test; changing whether
        // the limit is APPLIED must.
        Integer total = PropertyPackageController.RECENT_LIMIT + 2;
        List<Property_Package__c> oldestFirst = insertPackagesOldestFirst(total);

        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        Assert.areEqual(PropertyPackageController.RECENT_LIMIT, rows.size(),
            'Truncated to RECENT_LIMIT of ' + total + ' — SERVER-SIDE, and that is the feature\'s '
            + 'ONLY cutoff. c/recentPackages performs no client-side .slice() precisely because a '
            + 'second truncation layer on top of a server cutoff is what hid packages in the Lead feed');

        Map<String, PropertyPackageController.RecentPackageRow> byPackage = recentById(rows);
        Assert.isFalse(byPackage.containsKey(String.valueOf(oldestFirst[0].Id)),
            '🔴 THE OLDEST PACKAGE IS DROPPED. This is the half that reds if the ORDER BY goes missing '
            + 'or turns ascending');
        Assert.isFalse(byPackage.containsKey(String.valueOf(oldestFirst[1].Id)),
            'and so is the second oldest');
        Assert.isTrue(byPackage.containsKey(String.valueOf(oldestFirst[total - 1].Id)),
            'while the newest is kept');
    }

    @isTest
    static void getRecentPackages_anOrgWithNoPackagesReturnsAnEmptyListNotAnError() {
        // The permanent state until the first multi-property email arrives, so it must be cheap and
        // boring: the widget renders its "none yet" message for it. An exception here would put a red
        // banner on the Lead Funnel homepage of every org from day one until a broker happened to send
        // two properties in one email.
        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        Assert.isNotNull(rows, 'a list, never null — the client iterates it without a guard');
        Assert.areEqual(0, rows.size(), 'and it is empty');
    }

    @isTest
    static void getRecentPackages_aMemberlessPackageReportsZeroCountsRatherThanFailing() {
        // Design residual R6: a multi-property email whose properties all failed to route after the
        // package row was created. It is a real, accepted state, and the row must still render — the
        // package link is how a human reaches the routing audit that explains where they went.
        //
        // What this pins is the DTO's null-guard on both subqueries. The platform returns an EMPTY
        // child collection rather than null, so this passes either way today; it exists so that if that
        // ever changes, the failure is a red test rather than an NPE that blanks all five rows of the
        // homepage widget over one memberless package.
        insertPackage('FW: nothing routed');

        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'the package itself still renders');
        Assert.areEqual(0, rows[0].leadCount, 'with zero Leads');
        Assert.areEqual(0, rows[0].opportunityCount, 'and zero Opportunities');
        Assert.areEqual(3, rows[0].propertyCount.intValue(),
            'while Property_Count__c still reports what the EMAIL said (insertPackage seeds 3). The '
            + 'two numbers disagreeing is '
            + 'CORRECT here and must not be "fixed" (design residual R9) — one is a fact about the '
            + 'email, the other about what exists in the database now');
    }

    @isTest
    static void getRecentPackages_doesNotDoubleCountAConvertedMember() {
        // The controller-layer twin of
        // `PropertyPackageSelectorTest.selectRecent_aConvertedMemberIsCountedOnceNotTwice`. That one
        // pins the QUERY's `IsConverted = false` filter; this one pins what the WIDGET is handed, which
        // is the number a human actually reads.
        //
        // ⚠ IT NEEDS A REAL CONVERSION. The bug requires a Lead and an Opportunity that are the SAME
        // ASSET, both pointing at the package — `LeadConvertService.applyDealFields` copies the package
        // forward and nothing nulls the husk Lead's copy. Inserting the two independently cannot
        // produce that state, so such a fixture would show correct counts at any member count.
        Property_Package__c pkg = insertPackage('FW: two assets, one worked');
        List<Lead> members = insertMemberLeads(2, pkg.Id);

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(members[0].Id);
        lc.setConvertedStatus(convertedStatus());
        Assert.isTrue(Database.convertLead(lc).isSuccess(),
            'Precondition: the conversion must succeed');

        Test.startTest();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Test.stopTest();

        PropertyPackageController.RecentPackageRow row = rows[0];
        Assert.areEqual(1, row.leadCount,
            '🔴 ONE open Lead, not two. The converted member\'s husk Lead still carries the package, so '
            + 'an unfiltered count would report 2 Leads AND 1 Opportunity for TWO assets — and unlike '
            + 'the sibling card, which shows rows a human can compare, this widget shows only the '
            + 'numbers, with nothing to cross-check them against');
        Assert.areEqual(1, row.opportunityCount, 'and the worked asset appears once, as a deal');
        Assert.areEqual(2, row.leadCount + row.opportunityCount,
            'TWO members for two assets. A conversion MOVES an asset between the two counts; it does '
            + 'not add one');
    }

    @isTest
    static void getRecentPackages_costsExactlyOneQueryAtVolume() {
        // The replacement for the 251-record mandate (see the class header), and a sharper instrument.
        // This is a HOMEPAGE read that runs beside four other widgets, so the risk is not volume — the
        // limit is 5 — it is a per-package or per-member query creeping in. ONE, at RECENT_LIMIT
        // packages each carrying members.
        List<Property_Package__c> packages = insertPackagesOldestFirst(
            PropertyPackageController.RECENT_LIMIT);
        for (Property_Package__c pkg : packages) {
            insertMemberLeads(2, pkg.Id);
        }

        Test.startTest();
        Integer q0 = Limits.getQueries();
        List<PropertyPackageController.RecentPackageRow> rows =
            PropertyPackageController.getRecentPackages();
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(1, queryDelta,
            'EXACTLY ONE query for ' + PropertyPackageController.RECENT_LIMIT
            + ' packages and their members. Two would mean the members are fetched separately; six '
            + 'would mean one read per package on a homepage that already runs four other widgets');
        Assert.areEqual(PropertyPackageController.RECENT_LIMIT, rows.size(), '');
        for (PropertyPackageController.RecentPackageRow row : rows) {
            Assert.areEqual(2, row.leadCount,
                'and every row got its real counts — otherwise the query count above is cheap for the '
                + 'wrong reason');
        }
    }

    @isTest
    static void getRecentPackages_aDeniedReadSurfacesAsAnAuraHandledExceptionWithItsOWNMessage() {
        // The same BARE-USER technique as the sibling method above: a user on `Minimum Access -
        // Salesforce` has no FLS on Property_Package__c, so `WITH USER_MODE` throws
        // `System.QueryException` ("No such column ..." — how the platform reports an FLS denial) and
        // the catch runs.
        //
        // 🔴 THIS TEST STOPS PROVING ANYTHING IF ANYONE "SIMPLIFIES" selectRecent TO SYSTEM_MODE —
        // SYSTEM_MODE is precisely what suppresses the throw. It is USER_MODE deliberately: this backs
        // a read a human requested by opening their own homepage.
        insertPackage('FW: denied');
        User bare = insertBareUser();

        Test.startTest();
        System.runAs(bare) {
            try {
                PropertyPackageController.getRecentPackages();
                Assert.fail('A user with no FLS on Property_Package__c must be refused. If this line '
                    + 'is reached, either selectRecent stopped being USER_MODE or the bare user '
                    + 'acquired a grant — and this test now proves nothing');
            } catch (AuraHandledException e) {
                // ⚠ "Property packages" — the card's SETTLED title, re-worded THREE times on
                // 2026-08-17 (`Recent packages` -> `Recent portfolios`, RETRACTED -> `Portfolio
                // deals`, ALSO RETRACTED -> `Property packages`) in lockstep with
                // `c/recentPackages`' client-side `GENERIC_ERROR`. The API names all still say
                // Package through every rename — only the strings a user READS changed.
                //
                // 🔴 `Portfolio deals` WAS RETRACTED FOR A MEASURED REASON, NOT A STYLISTIC ONE: on
                // the day it shipped it collided with a live `Opportunity` STAGE of exactly that
                // name, from a manual, dormant feature answering a DIFFERENT question ("which
                // seller's deal bundle is this part of?") than this card ("which inbound broker
                // emails arrived?"). That feature has since been retired outright (Portfolio Deal
                // rename, phases A1-A3), so the collision is gone and the note above is history.
                // What this assertion still guards is the SETTLED wording: it may move only in
                // lockstep with `c/recentPackages`' client-side `GENERIC_ERROR`, and only as part of
                // the program that owns the vocabulary — never by a local edit reviving an old
                // label.
                Assert.isTrue(e.getMessage().contains('Property packages could not be loaded'),
                    '🔴 ITS OWN MESSAGE, NOT THE SIBLING CARD\'S. The two failures are shown in '
                    + 'different places to a user doing different things, so "the related properties '
                    + 'could not be loaded" would be actively misleading on a homepage where the user '
                    + 'is not looking at any property. Got: ' + e.getMessage());
                Assert.isFalse(e.getMessage().contains('related properties'),
                    'and specifically NOT the record-page wording — a shared constant would let a '
                    + 'future re-wording of one message silently re-word the other');
                Assert.isFalse(e.getMessage().contains('No such column'),
                    'and never the platform\'s FLS-denial text, which tells a user nothing and tells '
                    + 'an attacker something (ARCHITECTURE.md §5)');
            }
        }
        Test.stopTest();
    }
}
