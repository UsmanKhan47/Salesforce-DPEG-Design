/**
 * Test class for `PortfolioDealController` — the reads behind `c/portfolioDealSiblings` (a card on
 * the Lead and Opportunity record pages) and `c/recentPortfolioDeals` (a Lead Funnel homepage
 * widget, added 2026-08-17, design §8).
 *
 * Renamed from `PropertyPackageControllerTest` in phase B4 of the Portfolio Deal rename
 * (2026-08-18). ⚠ TWO KINDS OF NAME APPEAR BELOW AND BOTH OF THEM MOVED — in two separate tasks.
 * The OBJECT (`Portfolio_Deal__c`), the controller, and its methods and DTOs were all repointed and
 * renamed. The CLIENT BUNDLE names above were renamed straight afterwards by the LWC half of B4
 * (`packageSiblings` -> `portfolioDealSiblings`, `recentPackages` -> `recentPortfolioDeals`;
 * design §5 B4, B-Q3 now resolved), and every reference here was updated to match.
 * 🔴 A STALE BUNDLE NAME IN A COMMENT CANNOT FAIL — it is not compiled and no test asserts it — so
 * any future bundle rename must sweep this file BY HAND rather than expect a red test to say so.
 *
 * 🔴 THIS CLASS PINS A BREAKING CLIENT CONTRACT AND IS THE PLACE THE BREAK IS VISIBLE. Phase B4
 * renamed `getRecentPackages` -> `getRecentPortfolioDeals`, `PackageSiblings` ->
 * `PortfolioDealSiblings` (including its `packageId` / `packageName` / `packageUrl` properties, all
 * of which are WIRE names the record-page component reads by name) and `RecentPackageRow` ->
 * `RecentPortfolioDealRow` (type name only — its properties were already object-neutral, so the
 * homepage widget's payload is unchanged). Apex and LWC must deploy together.
 *
 * ⚠ TWO METHODS, TWO SECTIONS, AND THEY SHARE ONLY THE FIXTURE HELPERS. `getSiblingRecords` is a
 * per-record read whose interesting behaviour is the server-side object DISPATCH; `getRecentPortfolioDeals`
 * is a no-argument org-wide read whose interesting behaviour is ORDER + LIMIT + member counting. The
 * `getRecentPortfolioDeals` methods live in their own section at the foot of this class, and several of them
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
 * important tests here are a matched PAIR — the same portfolio deal read from a Lead anchor and from an
 * Opportunity anchor — asserting that each returns the OTHER members. A dispatch that silently
 * worked for one object and returned nothing for the other would look perfectly healthy from either
 * page alone, which is exactly why the pair discriminates in both directions.
 *
 * ⚠ ONE METHOD RUNS A REAL `Database.convertLead`
 * (`getSiblingRecords_fromAConvertedDeal_doesNotListTheDealsOwnFormerLeadAsASibling`), and it is the
 * only one that can: the current-record exclusion here compares Ids, and a converted deal's own
 * former Lead has a DIFFERENT Id while being the SAME asset. Independently-inserted fixtures make
 * that exclusion look correct at every member count. Its selector-layer twin is
 * `PortfolioDealSelectorTest.aConvertedMemberIsCountedOnceNotTwice`.
 *
 * ═══ ⚠ NO 251-RECORD BULK TEST — ARGUED, NOT SKIPPED ═══
 * `.claude/rules/bulk-test-rule.md`'s mandate exists to force a second trigger batch chunk and to
 * expose per-record queries. Neither is reachable here:
 *   • THE METHOD IS SINGLE-RECORD BY CONSTRUCTION — it takes ONE `recordId`, because it is a
 *     `cacheable=true` read for ONE record page a human has open. There is no collection parameter.
 *   • A PORTFOLIO DEAL CANNOT HAVE 251 MEMBERS. `ExtractAddressQueueable.MAX_PROPERTIES` is 10, so one
 *     email routes at most 10 properties -> at most 10 Leads plus at most 10 converted
 *     Opportunities. 251 members is a state production cannot produce.
 * The genuine risk is a read whose cost grows per member, and
 * `getSiblingRecords_costsExactlyTwoQueriesAtVolume` asserts that directly, at a member count above
 * the production ceiling. `PortfolioDealSelectorTest` carries the same argument for the query
 * itself.
 *
 * ⚠ The AuraHandledException boundary is covered with the repo-standard BARE-USER technique: a user
 * on `Minimum Access - Salesforce` has no FLS on `Portfolio_Deal__c`, so `WITH USER_MODE` throws
 * `System.QueryException` ("No such column ..." — how the platform reports an FLS denial) and the
 * catch runs. 🔴 That test stops proving anything the moment anyone "simplifies" either selector to
 * SYSTEM_MODE, because SYSTEM_MODE is precisely what suppresses the throw. Both selectors are
 * USER_MODE deliberately (they back a user-requested record-page read) and must stay so.
 */
@isTest
private class PortfolioDealControllerTest {

    /** Above the production ceiling of 10 (MAX_PROPERTIES). See the class header. */
    private static final Integer VOLUME_MEMBERS = 25;

    private static Portfolio_Deal__c insertPortfolioDeal(String name) {
        Portfolio_Deal__c deal = new Portfolio_Deal__c(Name = name, Property_Count__c = 3);
        insert deal;
        return deal;
    }

    private static List<Lead> insertMemberLeads(Integer count, Id portfolioDealId) {
        List<Lead> leads = TestDataFactory.createLeads(count, false);
        for (Lead l : leads) {
            l.Portfolio_Deal__c = portfolioDealId;
        }
        insert leads;
        return leads;
    }

    private static List<Opportunity> insertMemberOpportunities(Integer count, Id portfolioDealId) {
        List<Opportunity> opps = TestDataFactory.createOpportunities(count, null, false);
        for (Opportunity o : opps) {
            o.Portfolio_Deal__c = portfolioDealId;
        }
        insert opps;
        return opps;
    }

    /**
     * A user with a real licence and NO permission sets, so `WITH USER_MODE` denies
     * `Portfolio_Deal__c`. Inserted inside a `System.runAs` wrapper because `User` is a SETUP
     * object and this class also inserts business records — the canonical MIXED_DML workaround.
     */
    private static User insertBareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User bare = new User(
            FirstName = 'Bare',
            LastName = 'PortfolioDealReader',
            Alias = 'baredeal',
            Email = 'bare.portfoliodeal@example.invalid',
            Username = 'bare.portfoliodeal.' + unique + '@example.invalid',
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
    private static Map<String, PortfolioDealController.SiblingRow> byId(
            List<PortfolioDealController.SiblingRow> rows) {
        Map<String, PortfolioDealController.SiblingRow> result =
            new Map<String, PortfolioDealController.SiblingRow>();
        for (PortfolioDealController.SiblingRow row : rows) {
            result.put(row.id, row);
        }
        return result;
    }

    // ── THE MATCHED PAIR: the same portfolio deal, read from both object types ──────

    @isTest
    static void getSiblingRecords_fromALeadAnchor_returnsTheOtherMembersAndExcludesItself() {
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: three-asset portfolio');
        List<Lead> leads = insertMemberLeads(2, deal.Id);
        List<Opportunity> opps = insertMemberOpportunities(1, deal.Id);
        Lead anchor = leads[0];

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(deal.Id), result.portfolioDealId, 'The portfolio deal header must come back');
        Assert.areEqual('FW: three-asset portfolio', result.portfolioDealName,
            'with its Name — the card\'s heading, and the only human-recognisable identifier a '
            + 'portfolio deal has');
        Assert.areEqual('/lightning/r/Portfolio_Deal__c/' + deal.Id + '/view', result.portfolioDealUrl,
            'and a server-built URL. The CLIENT must never compose one — that needs the object API '
            + 'name, the single thing this design keeps away from the component');

        Assert.areEqual(2, result.siblings.size(),
            'The OTHER Lead and the Opportunity — two siblings from a three-member portfolio deal');
        Map<String, PortfolioDealController.SiblingRow> rows = byId(result.siblings);
        Assert.isFalse(rows.containsKey(String.valueOf(anchor.Id)),
            '🔴 THE ANCHOR MUST BE EXCLUDED. A card that lists the record you are already looking at '
            + 'as one of its "related" records reads as a bug on every single portfolio deal');
        Assert.isTrue(rows.containsKey(String.valueOf(leads[1].Id)), 'the sibling Lead is present');
        Assert.isTrue(rows.containsKey(String.valueOf(opps[0].Id)),
            'AND SO IS THE OPPORTUNITY. A Lead\'s siblings are not only Leads — once one member of a '
            + 'portfolio deal converts, the card must still show it, or the grouping appears to shrink as '
            + 'the deals progress');

        PortfolioDealController.SiblingRow leadRow = rows.get(String.valueOf(leads[1].Id));
        Assert.areEqual('/lightning/r/Lead/' + leads[1].Id + '/view', leadRow.recordUrl,
            'each row carries its own server-built URL');
        Assert.isNotNull(leadRow.name, 'and a label');
        Assert.areEqual('New', leadRow.status, 'and its state — Lead.Status for a Lead row');
        Assert.isNotNull(leadRow.objectLabel,
            'and the object LABEL, supplied by the server so the client never derives an object name');

        PortfolioDealController.SiblingRow oppRow = rows.get(String.valueOf(opps[0].Id));
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
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: converted portfolio');
        List<Lead> leads = insertMemberLeads(2, deal.Id);
        List<Opportunity> opps = insertMemberOpportunities(2, deal.Id);
        Opportunity anchor = opps[0];

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(deal.Id), result.portfolioDealId,
            'An Opportunity anchor resolves the SAME portfolio deal. The client sent only an Id — it does '
            + 'not know, and must not need to know, which object it is on');
        Assert.areEqual(3, result.siblings.size(), 'Two Leads plus the other Opportunity');
        Map<String, PortfolioDealController.SiblingRow> rows = byId(result.siblings);
        Assert.isFalse(rows.containsKey(String.valueOf(anchor.Id)), 'The anchoring deal is excluded');
        Assert.isTrue(rows.containsKey(String.valueOf(opps[1].Id)), 'its sibling deal is present');
        Assert.isTrue(rows.containsKey(String.valueOf(leads[0].Id)) && rows.containsKey(String.valueOf(leads[1].Id)),
            'and so are the Leads that have not converted yet');
    }

    /** See PortfolioDealSelectorTest.convertedStatus — this org's Lead Status picklist is custom. */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    @isTest
    static void getSiblingRecords_fromAConvertedDeal_doesNotListTheDealsOwnFormerLeadAsASibling() {
        // 🔴 THE SECOND HALF OF REVIEW C3, AND THE HALF THE SELECTOR TEST CANNOT SEE. Its twin,
        // PortfolioDealSelectorTest.aConvertedMemberIsCountedOnceNotTwice, pins the member COUNT at
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
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: two assets, one worked');
        List<Lead> members = insertMemberLeads(2, deal.Id);
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
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(anchorOppId);
        Test.stopTest();

        Assert.areEqual(String.valueOf(deal.Id), result.portfolioDealId,
            'The converted deal still resolves its portfolio deal — the grouping survives conversion, which '
            + 'is the entire point of carrying Portfolio_Deal__c forward');
        Map<String, PortfolioDealController.SiblingRow> rows = byId(result.siblings);
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

    // ── Property_Address__c carried onto SiblingRow (2026-08-19) ────────────

    @isTest
    static void getSiblingRecords_carriesPropertyAddressForBothMemberTypes() {
        // Added with the address line on `c/portfolioDealSiblings`'s tiles. The DTO reads a
        // DIFFERENTLY-NAMED source on each branch of `buildSiblings` — `l.Property_Address__c` and
        // `o.Property_Address__c` — so wiring only one of them is a real and easy mistake, and its
        // symptom is a tile that shows the address for Leads but not for Opportunities. Nothing
        // fails; the line is just quietly absent for half the rows, which is indistinguishable from
        // the entirely normal "this record has no address" state.
        //
        // 🔴 THE OPPORTUNITY VALUE CANNOT BE ASSIGNED — `Opportunity.Property_Address__c` is a
        // read-only FORMULA over `Property__r.Address__c`, so it is produced the way production
        // produces it (a real Property__c, linked) and only exists once the row is re-queried, which
        // the selector inside this call does. See `SiblingRow.propertyAddress`.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: addresses on both sides');

        List<Lead> leads = TestDataFactory.createLeads(2, false);
        for (Lead l : leads) {
            l.Portfolio_Deal__c = deal.Id;
        }
        leads[1].Property_Address__c = '1002 Multi St, Houston, TX';
        insert leads;

        Property__c prop = TestDataFactory.createProperties(1, false)[0];
        prop.Address__c = '1003 Multi St, Houston, TX';
        insert prop;
        List<Opportunity> opps = TestDataFactory.createOpportunities(1, null, false);
        opps[0].Portfolio_Deal__c = deal.Id;
        opps[0].Property__c = prop.Id;
        insert opps;

        Lead anchor = leads[0];

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(2, result.siblings.size(),
            'Precondition: the other Lead and the Opportunity');
        Map<String, PortfolioDealController.SiblingRow> rows = byId(result.siblings);

        Assert.areEqual('1002 Multi St, Houston, TX',
            rows.get(String.valueOf(leads[1].Id)).propertyAddress,
            'THE LEAD BRANCH of buildSiblings carries Lead.Property_Address__c onto the row — stored '
            + 'Text, written by the Broker Protection LLM extraction step');
        Assert.areEqual('1003 Multi St, Houston, TX',
            rows.get(String.valueOf(opps[0].Id)).propertyAddress,
            '🔴 AND THE OPPORTUNITY BRANCH carries its own, which is the half a Lead-anchored smoke '
            + 'test would never exercise. Same API name, different KIND of field: a formula through '
            + 'Property__c. Wiring one branch and not the other is the likely defect here, and it '
            + 'produces no error anywhere — just a missing line on half the tiles');

        // ⚠ ADDITIVE, so the assertions that mattered before must still hold. The address is an
        // EXTRA member on the row, never a replacement for the name — a change that moved the
        // address into `name` (or appended it) would satisfy every assertion above.
        Assert.isNotNull(rows.get(String.valueOf(leads[1].Id)).name,
            'the row still carries its own name');
        Assert.areNotEqual(rows.get(String.valueOf(leads[1].Id)).propertyAddress,
            rows.get(String.valueOf(leads[1].Id)).name,
            'and the name is NOT the address — they are two separate members feeding two separate '
            + 'lines on the tile, with the name link deliberately unchanged by this addition');
        Assert.areEqual('New', rows.get(String.valueOf(leads[1].Id)).status,
            'and its status is untouched');
    }

    @isTest
    static void getSiblingRecords_aBlankPropertyAddressArrivesAsNullOnBothMemberTypes() {
        // 🔴 BLANK IS THE NORMAL CASE, NOT AN EDGE CASE, and the client renders NO element for it.
        // The two member types are blank for two unrelated reasons, and only one needs setting up:
        //   • LEAD — stored Text, blank when the extraction found no address. ⚠ MUST BE NULLED
        //     EXPLICITLY: `TestDataFactory.createLeads` always populates it, so a fixture that just
        //     calls the factory silently tests the POPULATED path here.
        //   • OPPORTUNITY — a `BlankAsBlank` formula over `Property__r.Address__c`, blank while
        //     `Property__c` is unset. Not linking a Property IS the blank case.
        //
        // ⚠ ANCHORED ON AN OPPORTUNITY DELIBERATELY, so this method and the one above cover BOTH
        // dispatch directions between them — the same reason the exclusion tests are a matched pair.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: no addresses known');

        List<Lead> leads = TestDataFactory.createLeads(1, false);
        leads[0].Portfolio_Deal__c = deal.Id;
        leads[0].Property_Address__c = null;
        insert leads;

        List<Opportunity> opps = insertMemberOpportunities(2, deal.Id);
        Opportunity anchor = opps[0];

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(anchor.Id);
        Test.stopTest();

        Assert.areEqual(2, result.siblings.size(),
            'Precondition: the Lead and the other Opportunity, with the anchor excluded');
        Map<String, PortfolioDealController.SiblingRow> rows = byId(result.siblings);

        Assert.isNull(rows.get(String.valueOf(leads[0].Id)).propertyAddress,
            'A Lead with no extracted address arrives as NULL — not an empty string, and not a '
            + 'placeholder. The client gates on this value, so a non-null blank would render an '
            + 'address line containing nothing on a large share of tiles');
        Assert.isNull(rows.get(String.valueOf(opps[1].Id)).propertyAddress,
            'and an Opportunity with no Property__c likewise, via BlankAsBlank on the formula');

        // 🔴 AND THE ROWS ARE OTHERWISE COMPLETE. A missing address must cost the tile a LINE, never
        // a ROW — the two look identical in a screenshot and entirely different to someone hunting
        // for a sibling record. This is the assertion that fails if a future "skip rows with no
        // address" optimisation is ever mistaken for a tidy-up.
        Assert.isNotNull(rows.get(String.valueOf(leads[0].Id)).name,
            'the addressless Lead is still listed, with its name');
        Assert.isNotNull(rows.get(String.valueOf(leads[0].Id)).recordUrl, 'and its link');
        Assert.isNotNull(rows.get(String.valueOf(leads[0].Id)).objectLabel, 'and its object label');
        Assert.areEqual('New', rows.get(String.valueOf(opps[1].Id)).status,
            'and the addressless Opportunity still reports its stage');
    }

    // ── "nothing to show" is an ANSWER, never an error ──────────────────────

    @isTest
    static void getSiblingRecords_recordWithNoPortfolioDeal_returnsAnEmptyResultNotAnError() {
        // THE OVERWHELMINGLY COMMON CASE — most emails name one property, so most Leads have no
        // portfolio deal. It must be cheap and boring: the client renders NOTHING (not an empty card) when
        // portfolioDealId is null, so an exception here would put a red banner on nearly every Lead.
        Lead solo = TestDataFactory.createLead(true);

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(solo.Id);
        Test.stopTest();

        Assert.isNull(result.portfolioDealId, 'No portfolio deal means a null Id — the client\'s "render nothing" signal');
        Assert.isNotNull(result.siblings,
            'and siblings is ALWAYS a list, never null. The DTO initialises it so the component needs '
            + 'no defensive check of its own');
        Assert.areEqual(0, result.siblings.size(), 'and it is empty');
    }

    @isTest
    static void getSiblingRecords_portfolioDealWhoseOnlyMemberIsTheAnchor_returnsZeroSiblings() {
        // The memberless / single-member portfolio deal is a real accepted residual (design R6): a
        // multi-property email whose other properties failed to route after the portfolio deal was created.
        // The portfolio deal Id is still returned — it is TRUE that this record came off a multi-property
        // email, and the link is how a human reaches the routing audit that explains the rest.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: only one routed');
        Lead only = insertMemberLeads(1, deal.Id)[0];

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(only.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(deal.Id), result.portfolioDealId,
            'The portfolio deal is still reported — a one-member portfolio deal records that a multi-property '
            + 'email arrived and mostly failed, which is information, not noise');
        Assert.areEqual(0, result.siblings.size(),
            'with no siblings, because the anchor is excluded from its own list');
    }

    @isTest
    static void getSiblingRecords_nullRecordId_returnsAnEmptyResultWithoutQuerying() {
        Test.startTest();
        Integer q0 = Limits.getQueries();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(null);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.isNull(result.portfolioDealId, 'A null Id yields the empty result');
        Assert.areEqual(0, result.siblings.size(), '');
        Assert.areEqual(0, queryDelta,
            'and costs NO query. A record page can render before recordId is injected, so this path '
            + 'is genuinely reached');
    }

    @isTest
    static void deletingAPortfolioDeal_setNullsEveryMemberLookup_whichIsWhyTheControllerCanNeverObserveAStaleId() {
        // 🔴 THIS TEST DOES NOT EXERCISE `getSiblingRecords` AT ALL — it exists to explain, with a
        // measurement rather than a claim, why the controller's defensive `deal == null` branch
        // (reached when `resolvePortfolioDealId` returns a non-null Id but
        // `PortfolioDealSelector.selectWithMembersById` finds no row for it) is UNREACHABLE via
        // integration testing and therefore cannot be covered the way every other branch in this
        // class is.
        //
        // The three `Portfolio_Deal__c` lookups (Lead, Opportunity, Property__c) are all
        // `deleteConstraint SetNull` (§1 rule 3: "deleting a portfolio deal must never cascade into deal
        // records"). SetNull is not merely a delete-time permission check — the platform NULLS OUT
        // every child's lookup field AS PART OF THE SAME DELETE, synchronously, in the same
        // transaction, which this test measures directly. So a Lead can never be read back still
        // carrying a portfolio deal Id that no longer resolves to a row: the instant the portfolio deal is gone,
        // so is the pointer. Building a fixture that fakes the opposite state would mean inserting a
        // Lead with `Portfolio_Deal__c` set to an already-nonexistent Id, which the platform
        // refuses at DML with `INVALID_CROSS_REFERENCE_KEY` before the fixture can even exist.
        //
        // The null-guard in `getSiblingRecords` is retained anyway, deliberately, as defense in
        // depth against exactly the class of bug `PortfolioDealSelectorTest
        // .selectWithMembersById_unknownIdReturnsNullRatherThanThrowing` pins at the selector layer
        // — a future caller of that selector, or a future relationship shape without SetNull, must
        // still not NPE. This test is the record of why code review should not ask for that one line
        // to be "covered" the ordinary way.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: about to vanish from under a Lead');
        Lead member = insertMemberLeads(1, deal.Id)[0];
        Assert.areEqual(deal.Id,
            [SELECT Portfolio_Deal__c FROM Lead WHERE Id = :member.Id].Portfolio_Deal__c,
            'Precondition: the Lead really does carry the portfolio deal before the delete');

        Test.startTest();
        delete deal;
        Test.stopTest();

        Assert.isNull(
            [SELECT Portfolio_Deal__c FROM Lead WHERE Id = :member.Id].Portfolio_Deal__c,
            'SetNull fires IN THE SAME TRANSACTION as the delete: the moment the portfolio deal is gone, '
            + 'every member\'s lookup is nulled with it — there is no window in which a Lead can be '
            + 'read back still pointing at a portfolio deal that no longer exists');
    }

    @isTest
    static void getSiblingRecords_unsupportedObjectType_returnsAnEmptyResultRatherThanThrowing() {
        // The dispatch is an ALLOW-LIST. An admin can place this component on any record page in App
        // Builder, and a placement on a third object is a configuration mistake that should render
        // nothing — not an error banner on someone's record.
        Contact c = TestDataFactory.createContact(null, true);

        Test.startTest();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(c.Id);
        Test.stopTest();

        Assert.isNull(result.portfolioDealId,
            'An Id of an object this card does not serve resolves to no portfolio deal, silently. Adding a '
            + 'third object is a `when` branch plus that object\'s own selector method — never a '
            + 'new bundle');
        Assert.areEqual(0, result.siblings.size(), '');
    }

    // ── governor headroom ───────────────────────────────────────────────────

    @isTest
    static void getSiblingRecords_costsExactlyTwoQueriesAtVolume() {
        // 🔴 THE REPLACEMENT FOR THE 251-RECORD MANDATE, and a sharper instrument. TWO queries: the
        // ANCHOR read (which portfolio deal is this record in?) and the PORTFOLIO-DEAL read (which returns BOTH
        // member collections through relationship subqueries). It is 2 at 25 members exactly as it
        // is at 2 — a per-member read would report 26.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: volume');
        List<Lead> leads = insertMemberLeads(VOLUME_MEMBERS, deal.Id);

        Test.startTest();
        Integer q0 = Limits.getQueries();
        PortfolioDealController.PortfolioDealSiblings result =
            PortfolioDealController.getSiblingRecords(leads[0].Id);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(2, queryDelta,
            'EXACTLY TWO queries at ' + VOLUME_MEMBERS + ' members: one anchor read plus one '
            + 'portfolio-deal-with-subqueries read. Three would mean the Leads and Opportunities are being '
            + 'fetched separately; ' + (VOLUME_MEMBERS + 1) + ' would mean per-member reads');
        Assert.areEqual(VOLUME_MEMBERS - 1, result.siblings.size(),
            'and every member but the anchor came back — otherwise the count above is cheap for the '
            + 'wrong reason');
    }

    // ── the AuraHandledException boundary ───────────────────────────────────

    @isTest
    static void aDeniedReadSurfacesAsAnAuraHandledExceptionWithNoPlatformText() {
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: denied');
        Lead anchor = insertMemberLeads(1, deal.Id)[0];
        User bare = insertBareUser();

        Test.startTest();
        System.runAs(bare) {
            try {
                PortfolioDealController.getSiblingRecords(anchor.Id);
                Assert.fail('A user with no FLS on Lead.Portfolio_Deal__c must be refused. If this '
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
    // getRecentPortfolioDeals — the c/recentPortfolioDeals homepage widget (2026-08-17, design §8)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Index the rows by portfolio deal Id. Keyed by STRING for the same reason `byId` above is — the DTO is
     * serialized to the client, where an Id has no meaning, so `RecentPortfolioDealRow.id` is a `String`.
     */
    private static Map<String, PortfolioDealController.RecentPortfolioDealRow> recentById(
            List<PortfolioDealController.RecentPortfolioDealRow> rows) {
        Map<String, PortfolioDealController.RecentPortfolioDealRow> result =
            new Map<String, PortfolioDealController.RecentPortfolioDealRow>();
        for (PortfolioDealController.RecentPortfolioDealRow row : rows) {
            result.put(row.id, row);
        }
        return result;
    }

    /**
     * Insert `count` portfolio deals with DISTINCT `CreatedDate`s, oldest first.
     *
     * 🔴 `Test.setCreatedDate` IS REQUIRED FOR ANY ORDER- OR LIMIT-SENSITIVE ASSERTION HERE: rows
     * inserted in one transaction can tie on `CreatedDate`, and `ORDER BY ... DESC` over ties returns
     * an UNSPECIFIED order — so "the newest five came back" would pass or fail by luck and would keep
     * passing with the `ORDER BY` deleted. Same helper, same reason, as
     * `PortfolioDealSelectorTest.insertPortfolioDealsWithDistinctCreatedDates`.
     *
     * @return The portfolio deals oldest-first, so the expected result of a newest-first read is REVERSED.
     */
    private static List<Portfolio_Deal__c> insertPortfolioDealsOldestFirst(Integer count) {
        List<Portfolio_Deal__c> deals = new List<Portfolio_Deal__c>();
        for (Integer i = 0; i < count; i++) {
            deals.add(new Portfolio_Deal__c(
                Name = 'FW: portfolio deal ' + i,
                Property_Count__c = 2
            ));
        }
        insert deals;
        for (Integer i = 0; i < count; i++) {
            Test.setCreatedDate(deals[i].Id, Datetime.now().addDays(i - count));
        }
        return deals;
    }

    @isTest
    static void getRecentPortfolioDeals_mapsEveryFieldTheWidgetRenders() {
        // FIELD-BY-FIELD, because every one of these drives a visible cell and a silently-unmapped
        // field renders as an empty cell or an em dash — which on this widget reads as a FACT ("the
        // broker did not say"), not as a bug.
        Portfolio_Deal__c deal = new Portfolio_Deal__c(
            Name = 'FW: fully populated portfolio',
            Property_Count__c = 4,
            Broker_Name__c = 'Dana Reyes',
            Broker_Email__c = 'dana@brokerage.example.com',
            Received_DateTime__c = Datetime.newInstanceGmt(2026, 8, 14, 17, 30, 0)
        );
        insert deal;
        insertMemberLeads(2, deal.Id);
        insertMemberOpportunities(1, deal.Id);

        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One portfolio deal in the org, one row');
        PortfolioDealController.RecentPortfolioDealRow row = rows[0];

        Assert.areEqual(String.valueOf(deal.Id), row.id, 'the Id, as the datatable key-field');
        Assert.areEqual('FW: fully populated portfolio', row.name,
            'the Name — the row label and its link text');
        Assert.areEqual('/lightning/r/Portfolio_Deal__c/' + deal.Id + '/view', row.recordUrl,
            '🔴 A SERVER-BUILT URL, reusing the same private recordUrl() helper as the sibling card. '
            + 'The client must not compose one: that would put the object API name in a second place, '
            + 'and the server already owns that string');
        // ⚠ `.intValue()` is type-explicit and scale-independent, not a fix for a measured failure —
        // see the fuller note in `PortfolioDealSelectorTest.selectRecent_selectsEveryFieldTheWidget
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
            + 'Dropping it from the DTO would silently blank the Received cell of every portfolio deal whose '
            + 'header parse failed');
        Assert.areEqual(2, row.leadCount,
            'leadCount is .size() on the Leads__r subquery — no second query, no aggregate subquery');
        Assert.areEqual(1, row.opportunityCount, 'and opportunityCount likewise');
    }

    @isTest
    static void getRecentPortfolioDeals_returnsNewestFirst() {
        // The widget's whole reason for existing is that `recentLeads`' priority-partitioned feed can
        // push a portfolio deal's Leads past its cutoff. An unordered read here reproduces that defect in a
        // new place: five arbitrary portfolio deals instead of the five most recent.
        List<Portfolio_Deal__c> oldestFirst = insertPortfolioDealsOldestFirst(3);

        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'all three fit inside RECENT_LIMIT');
        Assert.areEqual(String.valueOf(oldestFirst[2].Id), rows[0].id,
            '🔴 NEWEST FIRST, and the ORDER SURVIVES THE DTO MAPPING. The selector orders the rows; '
            + 'this asserts the controller\'s loop does not reverse or re-sort them');
        Assert.areEqual(String.valueOf(oldestFirst[0].Id), rows[2].id, 'and the oldest is last');
    }

    @isTest
    static void getRecentPortfolioDeals_respectsRECENT_LIMITAndKeepsTheNEWEST() {
        // 🔴 TWO CLAIMS, AND THE SECOND IS THE LOAD-BEARING ONE. "Five of seven" is satisfied by ANY
        // five — including the five OLDEST, which is what a LIMIT with no (or an ascending) ORDER BY
        // returns. A homepage widget showing the five oldest portfolio deals in the org would look entirely
        // healthy and be exactly backwards.
        //
        // ⚠ The count is asserted against the CONSTANT, not against a literal 5. Changing
        // RECENT_LIMIT is a legitimate product decision and must not red this test; changing whether
        // the limit is APPLIED must.
        Integer total = PortfolioDealController.RECENT_LIMIT + 2;
        List<Portfolio_Deal__c> oldestFirst = insertPortfolioDealsOldestFirst(total);

        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        Assert.areEqual(PortfolioDealController.RECENT_LIMIT, rows.size(),
            'Truncated to RECENT_LIMIT of ' + total + ' — SERVER-SIDE, and that is the feature\'s '
            + 'ONLY cutoff. c/recentPortfolioDeals performs no client-side .slice() precisely because a '
            + 'second truncation layer on top of a server cutoff is what hid portfolio deals in the Lead feed');

        Map<String, PortfolioDealController.RecentPortfolioDealRow> byPortfolioDeal = recentById(rows);
        Assert.isFalse(byPortfolioDeal.containsKey(String.valueOf(oldestFirst[0].Id)),
            '🔴 THE OLDEST PORTFOLIO DEAL IS DROPPED. This is the half that reds if the ORDER BY goes missing '
            + 'or turns ascending');
        Assert.isFalse(byPortfolioDeal.containsKey(String.valueOf(oldestFirst[1].Id)),
            'and so is the second oldest');
        Assert.isTrue(byPortfolioDeal.containsKey(String.valueOf(oldestFirst[total - 1].Id)),
            'while the newest is kept');
    }

    @isTest
    static void getRecentPortfolioDeals_anOrgWithNoPortfolioDealsReturnsAnEmptyListNotAnError() {
        // The permanent state until the first multi-property email arrives, so it must be cheap and
        // boring: the widget renders its "none yet" message for it. An exception here would put a red
        // banner on the Lead Funnel homepage of every org from day one until a broker happened to send
        // two properties in one email.
        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        Assert.isNotNull(rows, 'a list, never null — the client iterates it without a guard');
        Assert.areEqual(0, rows.size(), 'and it is empty');
    }

    @isTest
    static void getRecentPortfolioDeals_aMemberlessPortfolioDealReportsZeroCountsRatherThanFailing() {
        // Design residual R6: a multi-property email whose properties all failed to route after the
        // portfolio deal row was created. It is a real, accepted state, and the row must still render — the
        // portfolio deal link is how a human reaches the routing audit that explains where they went.
        //
        // What this pins is the DTO's null-guard on both subqueries. The platform returns an EMPTY
        // child collection rather than null, so this passes either way today; it exists so that if that
        // ever changes, the failure is a red test rather than an NPE that blanks all five rows of the
        // homepage widget over one memberless portfolio deal.
        insertPortfolioDeal('FW: nothing routed');

        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'the portfolio deal itself still renders');
        Assert.areEqual(0, rows[0].leadCount, 'with zero Leads');
        Assert.areEqual(0, rows[0].opportunityCount, 'and zero Opportunities');
        Assert.areEqual(3, rows[0].propertyCount.intValue(),
            'while Property_Count__c still reports what the EMAIL said (insertPortfolioDeal seeds 3). The '
            + 'two numbers disagreeing is '
            + 'CORRECT here and must not be "fixed" (design residual R9) — one is a fact about the '
            + 'email, the other about what exists in the database now');
    }

    @isTest
    static void getRecentPortfolioDeals_doesNotDoubleCountAConvertedMember() {
        // The controller-layer twin of
        // `PortfolioDealSelectorTest.selectRecent_aConvertedMemberIsCountedOnceNotTwice`. That one
        // pins the QUERY's `IsConverted = false` filter; this one pins what the WIDGET is handed, which
        // is the number a human actually reads.
        //
        // ⚠ IT NEEDS A REAL CONVERSION. The bug requires a Lead and an Opportunity that are the SAME
        // ASSET, both pointing at the portfolio deal — `LeadConvertService.applyDealFields` copies the portfolio deal
        // forward and nothing nulls the husk Lead's copy. Inserting the two independently cannot
        // produce that state, so such a fixture would show correct counts at any member count.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: two assets, one worked');
        List<Lead> members = insertMemberLeads(2, deal.Id);

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(members[0].Id);
        lc.setConvertedStatus(convertedStatus());
        Assert.isTrue(Database.convertLead(lc).isSuccess(),
            'Precondition: the conversion must succeed');

        Test.startTest();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Test.stopTest();

        PortfolioDealController.RecentPortfolioDealRow row = rows[0];
        Assert.areEqual(1, row.leadCount,
            '🔴 ONE open Lead, not two. The converted member\'s husk Lead still carries the portfolio deal, so '
            + 'an unfiltered count would report 2 Leads AND 1 Opportunity for TWO assets — and unlike '
            + 'the sibling card, which shows rows a human can compare, this widget shows only the '
            + 'numbers, with nothing to cross-check them against');
        Assert.areEqual(1, row.opportunityCount, 'and the worked asset appears once, as a deal');
        Assert.areEqual(2, row.leadCount + row.opportunityCount,
            'TWO members for two assets. A conversion MOVES an asset between the two counts; it does '
            + 'not add one');
    }

    @isTest
    static void getRecentPortfolioDeals_costsExactlyOneQueryAtVolume() {
        // The replacement for the 251-record mandate (see the class header), and a sharper instrument.
        // This is a HOMEPAGE read that runs beside four other widgets, so the risk is not volume — the
        // limit is 5 — it is a per-portfolio-deal or per-member query creeping in. ONE, at RECENT_LIMIT
        // portfolio deals each carrying members.
        List<Portfolio_Deal__c> deals = insertPortfolioDealsOldestFirst(
            PortfolioDealController.RECENT_LIMIT);
        for (Portfolio_Deal__c deal : deals) {
            insertMemberLeads(2, deal.Id);
        }

        Test.startTest();
        Integer q0 = Limits.getQueries();
        List<PortfolioDealController.RecentPortfolioDealRow> rows =
            PortfolioDealController.getRecentPortfolioDeals();
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(1, queryDelta,
            'EXACTLY ONE query for ' + PortfolioDealController.RECENT_LIMIT
            + ' portfolio deals and their members. Two would mean the members are fetched separately; six '
            + 'would mean one read per portfolio deal on a homepage that already runs four other widgets');
        Assert.areEqual(PortfolioDealController.RECENT_LIMIT, rows.size(), '');
        for (PortfolioDealController.RecentPortfolioDealRow row : rows) {
            Assert.areEqual(2, row.leadCount,
                'and every row got its real counts — otherwise the query count above is cheap for the '
                + 'wrong reason');
        }
    }

    @isTest
    static void getRecentPortfolioDeals_aDeniedReadSurfacesAsAnAuraHandledExceptionWithItsOWNMessage() {
        // The same BARE-USER technique as the sibling method above: a user on `Minimum Access -
        // Salesforce` has no FLS on Portfolio_Deal__c, so `WITH USER_MODE` throws
        // `System.QueryException` ("No such column ..." — how the platform reports an FLS denial) and
        // the catch runs.
        //
        // 🔴 THIS TEST STOPS PROVING ANYTHING IF ANYONE "SIMPLIFIES" selectRecent TO SYSTEM_MODE —
        // SYSTEM_MODE is precisely what suppresses the throw. It is USER_MODE deliberately: this backs
        // a read a human requested by opening their own homepage.
        insertPortfolioDeal('FW: denied');
        User bare = insertBareUser();

        Test.startTest();
        System.runAs(bare) {
            try {
                PortfolioDealController.getRecentPortfolioDeals();
                Assert.fail('A user with no FLS on Portfolio_Deal__c must be refused. If this line '
                    + 'is reached, either selectRecent stopped being USER_MODE or the bare user '
                    + 'acquired a grant — and this test now proves nothing');
            } catch (AuraHandledException e) {
                // ⚠ "Portfolio deals" — the card's title, re-worded FIVE times in two days and
                // NOW BACK WHERE IT STARTED. On 2026-08-17: `Recent Packages` -> `Recent
                // Portfolios` (RETRACTED) -> `Portfolio Deals` (RETRACTED) -> `Property Packages`
                // (settled). Then on 2026-08-18 phase B4 of the Portfolio Deal rename took it to
                // `Portfolio Deals` for good. It moves only in lockstep with the homepage
                // component's client-side `GENERIC_ERROR`.
                //
                // 🔴 THE 2026-08-17 RETRACTION OF THIS EXACT WORDING WAS MEASURED, NOT STYLISTIC —
                // AND IT IS NOW SPENT, WHICH IS WHY REVIVING IT IS CORRECT RATHER THAN A RELAPSE.
                // On the day it shipped it collided with a live `Opportunity` STAGE of exactly that
                // name, from a manual, dormant feature answering a DIFFERENT question ("which
                // seller's deal bundle is this part of?") than this card ("which inbound broker
                // emails arrived?"). Phases A1-A3 retired that feature outright — the stage value,
                // the path step, the funnel stage list, the FLS grants, then the Opportunity fields
                // — so the collision the retraction was contingent on no longer exists, and phase B
                // took the freed name into the schema on purpose.
                //
                // 🔴 WHAT SURVIVES IS THE PART THAT WAS NEVER ABOUT THE WORDING: those two
                // questions are still SEPARATE FACTS, and a revived seller-bundle requirement must
                // get its OWN new field rather than be poured into `Portfolio_Deal__c` because the
                // name now happens to fit it in English. See `LeadConvertService.applyDealFields`,
                // which carries that rule at the assignment and is written to be independent of
                // what either concept is called. This assertion guards only the string.
                Assert.isTrue(e.getMessage().contains('Portfolio deals could not be loaded'),
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
