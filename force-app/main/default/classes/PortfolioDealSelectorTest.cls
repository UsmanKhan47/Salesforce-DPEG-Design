/**
 * Test class for `PortfolioDealSelector` — the first and only `Portfolio_Deal__c` SOQL in the
 * application.
 *
 * Renamed from `PropertyPackageSelectorTest` in phase B4 of the Portfolio Deal rename (2026-08-18).
 * ⚠ TWO KINDS OF NAME APPEAR BELOW AND BOTH OF THEM MOVED — in two separate tasks. The OBJECT and
 * its fields are now `Portfolio_Deal__c` — every query, fixture and assertion here was repointed.
 * The CLIENT BUNDLE names were renamed straight afterwards by the LWC half of B4
 * (`packageSiblings` -> `portfolioDealSiblings`, `recentPackages` -> `recentPortfolioDeals`;
 * design §5 B4, B-Q3 now resolved), and every reference below was updated to match.
 * 🔴 A STALE BUNDLE NAME IN A COMMENT CANNOT FAIL — it is not compiled and no test asserts it — so
 * any future bundle rename must sweep this file BY HAND rather than expect a red test to say so.
 *
 * The whole point of this selector is that ONE query returns the portfolio deal AND both member
 * collections, through the `Leads__r` / `Opportunities__r` relationship subqueries (the lookups'
 * `relationshipName` plus `__r` — see the selector's own header). So the tests here are
 * about two things: that both collections actually arrive populated, and that the cost is one query
 * no matter how many members there are.
 *
 * ⚠ TWO METHODS UNDER TEST, AND THEY ARE NOT VARIANTS OF ONE ANOTHER — see the selector's header.
 *   • `selectWithMembersById` — ONE portfolio deal by Id, with member ROWS (name + status) for a list a human
 *     clicks. Backs `c/portfolioDealSiblings`.
 *   • `selectRecent` — the N NEWEST portfolio deals, with member ID's ONLY, for counts. Backs
 *     `c/recentPortfolioDeals` (added 2026-08-17, design §8).
 * The `selectRecent` methods live in their own section at the foot of this class. Two of them
 * (`_returnsNewestFirstByCreatedDate`, `_honoursTheLimitAndKeepsTheNEWESTRows`) depend on
 * `Test.setCreatedDate`, because rows inserted in one transaction can tie on `CreatedDate` and
 * `ORDER BY` over ties is unspecified — an ordering assertion without it passes by luck.
 *
 * ═══ ⚠ VOLUME IS 25, NOT 251 — ARGUED, NOT ASSUMED ═══
 * `.claude/rules/bulk-test-rule.md`'s 251 mandate exists to force a SECOND trigger batch chunk and
 * to expose per-record queries. Neither applies, and one of the reasons is a hard structural cap:
 *   • THIS IS A READ. A single-row query with subqueries has no batch chunking, so its behaviour at
 *     251 members is identical to its behaviour at 25. The same reasoning
 *     `.claude/rules/content-publication-rule.md` uses to cut the content selectors to 20 rows.
 *   • A PORTFOLIO DEAL CANNOT HAVE 251 MEMBERS. `ExtractAddressQueueable.MAX_PROPERTIES` is 10, so one
 *     inbound email routes at most 10 properties -> at most 10 Leads, and after conversion at most
 *     10 Opportunities. 25 members is already 2.5x the ceiling production can reach; 251 would
 *     encode a state that cannot occur.
 *   • THE REAL RISK IS PER-MEMBER COST, and that is what
 *     `selectWithMembersById_costsExactlyOneQueryRegardlessOfMemberCount` asserts directly — a far
 *     sharper instrument than a row count.
 * ⚠ AND A 251-MEMBER FIXTURE WOULD BE WORSE THAN USELESS HERE: relationship-subquery rows are
 * documented as capped per parent record, so a 251-member assertion could fail for a reason that has
 * nothing to do with this selector, and pass only by encoding a guess about that cap.
 *
 * ═══ ⚠ TWO METHODS HERE RUN A REAL `Database.convertLead`, AND NEITHER IS OPTIONAL ═══
 * Every other fixture below inserts member Leads and member Opportunities INDEPENDENTLY, which is
 * right for what they test and structurally unable to catch the review-C3 duplication: the bug needs
 * a Lead and an Opportunity that are THE SAME ASSET, both pointing at the portfolio deal, and only an actual
 * conversion produces that (`LeadConvertService` copies the portfolio deal forward and nothing nulls the
 * husk Lead's copy). `aConvertedMemberIsCountedOnceNotTwice` and its `selectRecent` twin
 * `selectRecent_aConvertedMemberIsCountedOnceNotTwice` are therefore the only methods that pay for a
 * full Account/Contact/Opportunity cascade — deliberately, on a single Lead each.
 *
 * ⚠ THE TWIN IS NOT REDUNDANT: the two queries carry the `IsConverted = false` filter INDEPENDENTLY
 * (they are separate SOQL statements, not one shared query), so a filter deleted from either one is
 * invisible to the other's test. And the SYMPTOM differs — on the sibling card a human sees two rows
 * and can tell they are one property; on the homepage they see only a count, with nothing to
 * cross-check it against.
 */
@isTest
private class PortfolioDealSelectorTest {

    /** 2.5x the production ceiling (MAX_PROPERTIES = 10). See the class header. */
    private static final Integer VOLUME_MEMBERS = 25;

    private static Portfolio_Deal__c insertPortfolioDeal(String name) {
        Portfolio_Deal__c deal = new Portfolio_Deal__c(Name = name, Property_Count__c = 3);
        insert deal;
        return deal;
    }

    /** N Leads, all members of `portfolioDealId`, inserted in ONE bulk DML. */
    private static List<Lead> insertMemberLeads(Integer count, Id portfolioDealId) {
        List<Lead> leads = TestDataFactory.createLeads(count, false);
        for (Lead l : leads) {
            l.Portfolio_Deal__c = portfolioDealId;
        }
        insert leads;
        return leads;
    }

    @isTest
    static void selectWithMembersById_returnsThePortfolioDealAndBothMemberCollections() {
        // The load-bearing behaviour: BOTH subqueries populated from ONE query. If either
        // relationship name were wrong this would not compile, which is the good failure mode — but
        // a subquery pointing at the wrong relationship WOULD compile and return the wrong rows.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: two-asset portfolio');
        List<Lead> memberLeads = insertMemberLeads(2, deal.Id);
        List<Opportunity> memberOpps = TestDataFactory.createOpportunities(2, null, false);
        for (Opportunity o : memberOpps) {
            o.Portfolio_Deal__c = deal.Id;
        }
        insert memberOpps;

        Test.startTest();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(deal.Id);
        Test.stopTest();

        Assert.isNotNull(loaded, 'An existing portfolio deal must come back');
        Assert.areEqual('FW: two-asset portfolio', loaded.Name, 'with its Name — the card\'s heading');
        Assert.areEqual(2, loaded.Leads__r.size(),
            'both OPEN Lead members, via the Leads__r subquery. ⚠ Every Lead in this fixture is '
            + 'open, so this method says NOTHING about the IsConverted filter — that is '
            + 'aConvertedMemberIsCountedOnceNotTwice\'s job, and it has to run a real conversion to '
            + 'do it');
        Assert.areEqual(2, loaded.Opportunities__r.size(),
            'AND both Opportunity members, from the second subquery. Losing the Opportunity half '
            + 'would empty the card at exactly the point the deals became workable');

        Set<Id> returnedLeadIds = new Set<Id>();
        for (Lead l : loaded.Leads__r) {
            returnedLeadIds.add(l.Id);
            Assert.isNotNull(l.Name, 'Name is selected — the row label');
            Assert.isNotNull(l.Status, 'and Status — the row\'s state column');
        }
        Assert.areEqual(new Map<Id, Lead>(memberLeads).keySet(), returnedLeadIds,
            'exactly the member Leads, no others');
        for (Opportunity o : loaded.Opportunities__r) {
            Assert.isNotNull(o.StageName,
                'StageName is the Opportunity\'s state column — the counterpart to Lead.Status');
        }
    }

    /**
     * The converted-Lead status label this org uses. Read from `LeadStatus` rather than hardcoded,
     * because this org's Lead Status picklist is custom (New / Under Review / Qualified / Converted
     * / Disqualified) and only the row flagged `IsConverted` is accepted by `Database.convertLead`.
     * Same helper as `LeadConvertServiceTest.convertedStatus`.
     */
    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    /**
     * A REAL standard conversion — the recipe proven on this org and used throughout
     * `LeadConvertServiceTest`.
     *
     * ⚠ NEVER `setDoNotCreateOpportunity(true)` to "keep the fixture light": on this org that throws
     * `UNKNOWN_EXCEPTION, There was an error converting the lead` at the `convertLead` call. Let the
     * Account / Contact / Opportunity cascade run — which this test WANTS anyway, because the
     * Opportunity it creates is the very row `LeadConvertService` stamps the portfolio deal onto.
     *
     * @param l The Lead to convert (must carry Email + Property_Address__c to clear
     *          `Property_And_Email_Required_To_Convert`; `TestDataFactory.createLeads` supplies both).
     * @return The conversion result, so the caller can name the new Opportunity.
     */
    private static Database.LeadConvertResult convertOne(Lead l) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        Assert.isTrue(res.isSuccess(), 'Precondition: the conversion itself must succeed');
        return res;
    }

    @isTest
    static void aConvertedMemberIsCountedOnceNotTwice() {
        // 🔴 THE FALSIFIER FOR THE `IsConverted = false` FILTER ON THE LEADS SUBQUERY (review C3),
        // AND IT HAS TO RUN A REAL CONVERSION TO BE ONE.
        //
        // A fixture that inserts member Leads and member Opportunities INDEPENDENTLY — which is what
        // every other method in this class does, correctly, for what they test — cannot catch this
        // bug at any member count, because it never produces the state that causes it. Production
        // produces exactly one state:
        //   `LeadConvertService.applyDealFields` copies Portfolio_Deal__c onto the new Opportunity,
        //   and NOTHING nulls it on the source Lead.
        // So every Opportunity member necessarily has a converted Lead twin still pointing at the
        // same portfolio deal. Two rows, ONE asset. Before the filter the card listed both — the same
        // address as a "Converted" Lead AND as an "Underwriting" Opportunity — and the Lead row was
        // not even reachable, since Salesforce always redirects a converted Lead's URL to the Contact.
        //
        // The measurement is MEMBER TOTAL ACROSS BOTH COLLECTIONS BEFORE vs AFTER a conversion that
        // adds no asset. It must not move. Removing the WHERE clause makes it 2 -> 3 and reds here.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: one converts, one does not');
        List<Lead> members = insertMemberLeads(2, deal.Id);
        Lead toConvert = members[0];
        Lead staysOpen = members[1];

        Portfolio_Deal__c before = PortfolioDealSelector.selectWithMembersById(deal.Id);
        Assert.areEqual(2, before.Leads__r.size() + before.Opportunities__r.size(),
            'Precondition: two open Leads, no deals yet — two members, two assets');

        // The conversion is FIXTURE — it sits outside the test block, as in
        // LeadConvertServiceTest.convertLeadOfType. What is under test is the read that follows it.
        Database.LeadConvertResult res = convertOne(toConvert);
        Id newOppId = res.getOpportunityId();
        Assert.areEqual(deal.Id,
            [SELECT Portfolio_Deal__c FROM Opportunity WHERE Id = :newOppId].Portfolio_Deal__c,
            'Precondition on the OTHER half of the mechanism: conversion really does carry the '
            + 'portfolio deal onto the new Opportunity (LeadConvertService.applyDealFields). If this ever '
            + 'stops being true the duplication cannot happen — and this test is then pinning a '
            + 'filter against a defect that no longer exists, so read that as a design change '
            + 'rather than deleting the WHERE clause');
        Assert.isTrue([SELECT IsConverted FROM Lead WHERE Id = :toConvert.Id].IsConverted,
            'and the source Lead really is converted');
        Assert.areEqual(deal.Id,
            [SELECT Portfolio_Deal__c FROM Lead WHERE Id = :toConvert.Id].Portfolio_Deal__c,
            '🔴 AND IT STILL CARRIES THE PORTFOLIO DEAL. This is the whole reason the filter is needed: '
            + 'nothing nulls the husk Lead\'s lookup, so it is still a portfolio deal member by the '
            + 'database\'s reckoning. If a future change DOES null it, this assertion is where that '
            + 'shows up');

        Test.startTest();
        Portfolio_Deal__c after = PortfolioDealSelector.selectWithMembersById(deal.Id);
        Test.stopTest();

        Assert.areEqual(2, after.Leads__r.size() + after.Opportunities__r.size(),
            '🔴 STILL TWO MEMBERS. A conversion moves one asset from the Lead collection to the '
            + 'Opportunity collection; it does not add an asset. Three here means the husk Lead is '
            + 'back and the card shows the same property twice — once as a "Converted" Lead whose '
            + 'link silently redirects to a Contact');
        Assert.areEqual(1, after.Leads__r.size(), 'one OPEN Lead remains');
        Assert.areEqual(staysOpen.Id, after.Leads__r[0].Id,
            'and it is the one that did NOT convert — so the filter removed the right row, not just '
            + 'the right NUMBER of rows');
        Assert.areEqual(1, after.Opportunities__r.size(),
            'and the converted member arrives as a deal');
        Assert.areEqual(newOppId, after.Opportunities__r[0].Id,
            'namely the Opportunity the conversion created. The asset is still in the portfolio deal — it '
            + 'has changed collection, which is exactly what the card should show');
    }

    @isTest
    static void selectWithMembersById_excludesRecordsBelongingToAnotherPortfolioDeal() {
        // Two portfolio deals in one org, each with its own members. A missing WHERE clause or a
        // mis-pointed subquery would show up here and nowhere else.
        Portfolio_Deal__c mine = insertPortfolioDeal('FW: mine');
        Portfolio_Deal__c theirs = insertPortfolioDeal('FW: theirs');
        List<Lead> myLeads = insertMemberLeads(2, mine.Id);
        insertMemberLeads(3, theirs.Id);

        Test.startTest();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(mine.Id);
        Test.stopTest();

        Assert.areEqual(2, loaded.Leads__r.size(),
            'Only this portfolio deal\'s members. Three foreign Leads exist and none may appear');
        Assert.areEqual(new Map<Id, Lead>(myLeads).keySet(),
            new Map<Id, Lead>(loaded.Leads__r).keySet(),
            'and they are the right two');
    }

    @isTest
    static void selectWithMembersById_dealWithNoMembersReturnsEmptyCollectionsNotNull() {
        // The memberless portfolio deal is a real, accepted residual (design R6): a multi-property email
        // whose properties all failed after the portfolio deal was created.
        //
        // `PortfolioDealController.buildSiblings` null-guards BOTH collections, so a null here
        // would not NPE. What this method pins is therefore the PLATFORM's own contract — a
        // zero-row child subquery arrives as an EMPTY list, never null (precedent:
        // `DispositionController.cls:87` calls `.isEmpty()` on `Wires__r` with no null check at
        // all) — and that a memberless portfolio deal still returns a ROW rather than nothing.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: nothing routed');

        Test.startTest();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(deal.Id);
        Test.stopTest();

        Assert.isNotNull(loaded, 'The portfolio deal itself still exists and must load');
        // 🔴 TWO STATEMENTS PER COLLECTION, NEVER A NULL-TOLERANT TERNARY. A
        // `loaded.Leads__r == null ? 0 : loaded.Leads__r.size()` assertion evaluates to 0 for BOTH
        // null and empty, so it cannot fail for the exact risk this method's name advertises.
        Assert.isNotNull(loaded.Leads__r,
            'The Leads child collection must never be null - the platform returns an empty list');
        Assert.areEqual(0, loaded.Leads__r.size(),
            'An empty child collection, never a populated one');
        Assert.isNotNull(loaded.Opportunities__r,
            'The Opportunities child collection must never be null either');
        Assert.areEqual(0, loaded.Opportunities__r.size(),
            'and the Opportunities collection is empty too, never a populated one');
    }

    @isTest
    static void selectWithMembersById_nullIdReturnsNullWithoutQuerying() {
        // 🔴 THE "WITHOUT QUERYING" HALF IS THE POINT. The controller calls this only after resolving
        // a portfolio deal Id, but the guard is what keeps a future caller from spending a query to learn
        // nothing — and the query budget it protects belongs to a record page, not to this class.
        Test.startTest();
        Integer q0 = Limits.getQueries();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(null);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.isNull(loaded, 'A null Id yields null');
        Assert.areEqual(0, queryDelta, 'and costs NO query at all');
    }

    @isTest
    static void selectWithMembersById_unknownIdReturnsNullRatherThanThrowing() {
        // NOT-FOUND CONTRACT, and it is DELIBERATELY the opposite of the fetch-for-use family
        // (OpportunitySelector.selectStageRequiredById and friends), which throw QueryException
        // because their callers dereference immediately. This backs a card whose job is to render
        // nothing, so a stale lookup on a record page must not raise.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: about to vanish');
        Id goneId = deal.Id;
        delete deal;

        Test.startTest();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(goneId);
        Test.stopTest();

        Assert.isNull(loaded,
            'A well-formed Id matching no row returns null. Throwing here would put a red error '
            + 'banner on a deal page over a deleted portfolio deal');
    }

    @isTest
    static void selectWithMembersById_costsExactlyOneQueryRegardlessOfMemberCount() {
        // 🔴 THE REPLACEMENT FOR THE 251-RECORD MANDATE, AND A SHARPER INSTRUMENT THAN ONE. The risk
        // this selector carries is not volume — a portfolio deal caps at ~10 members — it is that a future
        // change fetches the members with a SECOND query, or worse one per member. Both show up here
        // as a number other than 1, at a member count 2.5x the production ceiling.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: volume');
        insertMemberLeads(VOLUME_MEMBERS, deal.Id);

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Portfolio_Deal__c loaded = PortfolioDealSelector.selectWithMembersById(deal.Id);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(1, queryDelta,
            'ONE query for the portfolio deal AND both member collections, at ' + VOLUME_MEMBERS
            + ' members. Relationship subqueries are what make that true; a per-member read would '
            + 'report ' + (VOLUME_MEMBERS + 1) + ' and a second bulk read would report 2');
        Assert.areEqual(VOLUME_MEMBERS, loaded.Leads__r.size(),
            'and every member came back — otherwise the query count above is cheap for the wrong reason');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectRecent — the c/recentPortfolioDeals homepage widget (2026-08-17, design §8)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * `PortfolioDealController.RECENT_LIMIT` — restated here rather than imported, because these
     * methods test the SELECTOR's contract (it honours whatever limit it is handed), not the
     * controller's choice of value. `PortfolioDealControllerTest` asserts the constant itself.
     */
    private static final Integer RECENT_LIMIT = 5;

    /**
     * Insert `count` portfolio deals and give each a DISTINCT `CreatedDate`, newest last.
     *
     * 🔴 `Test.setCreatedDate` IS NOT OPTIONAL FOR AN ORDERING ASSERTION HERE. Every row inserted in
     * one test transaction can share a `CreatedDate` to the second, and `ORDER BY CreatedDate DESC`
     * over ties returns rows in an UNSPECIFIED order — so a fixture that just inserts five portfolio deals
     * and asserts the order would pass or fail by luck, and would keep passing if the `ORDER BY` were
     * deleted outright. Stamping distinct days makes the assertion falsifiable.
     *
     * @param count How many portfolio deals.
     * @return The portfolio deals in the order created — index 0 OLDEST, last index NEWEST. So the expected
     *         query result is this list REVERSED.
     */
    private static List<Portfolio_Deal__c> insertPortfolioDealsWithDistinctCreatedDates(Integer count) {
        List<Portfolio_Deal__c> deals = new List<Portfolio_Deal__c>();
        for (Integer i = 0; i < count; i++) {
            deals.add(new Portfolio_Deal__c(
                Name = 'FW: portfolio deal ' + i,
                Property_Count__c = 2
            ));
        }
        insert deals;
        for (Integer i = 0; i < count; i++) {
            // i = 0 is the oldest (furthest back), the last is "now".
            Test.setCreatedDate(deals[i].Id, Datetime.now().addDays(i - count));
        }
        return deals;
    }

    @isTest
    static void selectRecent_returnsNewestFirstByCreatedDate() {
        // 🔴 THE ORDER IS THE WIDGET'S ENTIRE VALUE PROPOSITION. It exists because a portfolio deal's Leads
        // can fall past `recentLeads`' priority-partitioned cutoff; if this read is not ordered
        // newest-first, the widget shows an arbitrary five portfolio deals instead of the recent ones and is
        // no better than the feed it replaced.
        List<Portfolio_Deal__c> oldestFirst = insertPortfolioDealsWithDistinctCreatedDates(3);

        Test.startTest();
        List<Portfolio_Deal__c> rows = PortfolioDealSelector.selectRecent(RECENT_LIMIT);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'All three fit inside the limit');
        Assert.areEqual(oldestFirst[2].Id, rows[0].Id,
            'NEWEST FIRST. The last portfolio deal created must be the first row — this is the assertion '
            + 'that reds if the ORDER BY is dropped, reversed, or moved onto another field');
        Assert.areEqual(oldestFirst[1].Id, rows[1].Id, 'then the next newest');
        Assert.areEqual(oldestFirst[0].Id, rows[2].Id, 'and the oldest last');
    }

    @isTest
    static void selectRecent_honoursTheLimitAndKeepsTheNEWESTRows() {
        // 🔴 TWO CLAIMS IN ONE METHOD, AND THE SECOND IS THE ONE THAT MATTERS. "Returns 5 of 7" is
        // satisfied by ANY five rows — including the five OLDEST, which is what a `LIMIT` without an
        // `ORDER BY` (or with an ascending one) would hand back. A widget showing the five oldest
        // portfolio deals in the org would look perfectly healthy and be exactly wrong.
        List<Portfolio_Deal__c> oldestFirst =
            insertPortfolioDealsWithDistinctCreatedDates(RECENT_LIMIT + 2);

        Test.startTest();
        List<Portfolio_Deal__c> rows = PortfolioDealSelector.selectRecent(RECENT_LIMIT);
        Test.stopTest();

        Assert.areEqual(RECENT_LIMIT, rows.size(),
            'The SOQL LIMIT truncates at ' + RECENT_LIMIT + ' of ' + (RECENT_LIMIT + 2)
            + ' — server-side, which is the feature\'s ONLY cutoff (c/recentPortfolioDeals deliberately '
            + 'performs no client-side slice)');

        Set<Id> returned = new Map<Id, Portfolio_Deal__c>(rows).keySet();
        Assert.isFalse(returned.contains(oldestFirst[0].Id),
            '🔴 THE OLDEST PORTFOLIO DEAL MUST BE DROPPED, not kept. This is the half that fails if the '
            + 'ORDER BY is missing or ascending');
        Assert.isFalse(returned.contains(oldestFirst[1].Id), 'and so must the second oldest');
        Assert.isTrue(returned.contains(oldestFirst[RECENT_LIMIT + 1].Id),
            'while the newest is present');
    }

    @isTest
    static void selectRecent_returnsBothMemberCollectionsForCountingWithoutASecondQuery() {
        // The widget renders COUNTS, and it gets them from `.size()` on these two subqueries — never
        // from a second read and never from an aggregate-subquery-as-scalar. So the collections have to
        // arrive populated on the SAME row, and the cost has to be one query.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: counted');
        insertMemberLeads(2, deal.Id);
        List<Opportunity> memberOpps = TestDataFactory.createOpportunities(3, null, false);
        for (Opportunity o : memberOpps) {
            o.Portfolio_Deal__c = deal.Id;
        }
        insert memberOpps;

        Test.startTest();
        Integer q0 = Limits.getQueries();
        List<Portfolio_Deal__c> rows = PortfolioDealSelector.selectRecent(RECENT_LIMIT);
        Integer queryDelta = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One portfolio deal in the org');
        Assert.areEqual(2, rows[0].Leads__r.size(),
            'both OPEN Lead members arrive on the row, ready to count');
        Assert.areEqual(3, rows[0].Opportunities__r.size(), 'and all three Opportunity members');
        Assert.areEqual(1, queryDelta,
            'for ONE query total. Two would mean the members are being fetched separately; six would '
            + 'mean per-member reads on a five-row homepage widget');
    }

    @isTest
    static void selectRecent_selectsEveryFieldTheWidgetDisplays() {
        // A widening/narrowing guard. This read backs a homepage card, and a field dropped from the
        // SELECT does not fail — it renders an empty cell, or (worse) an em dash that reads as "the
        // broker did not say", which is a different and plausible fact.
        //
        // ⚠ IT IS ALSO THE LIST THAT MUST NOT GROW. Every field here is a field whose FLS can throw
        // under WITH USER_MODE and blank the whole card, so member NAMES and STATUSES are deliberately
        // absent — the widget shows counts, not rows.
        Portfolio_Deal__c deal = new Portfolio_Deal__c(
            Name = 'FW: fully populated',
            Property_Count__c = 4,
            Broker_Name__c = 'Dana Reyes',
            Broker_Email__c = 'dana@brokerage.example.com',
            Received_DateTime__c = Datetime.newInstanceGmt(2026, 8, 14, 17, 30, 0)
        );
        insert deal;

        Test.startTest();
        Portfolio_Deal__c row = PortfolioDealSelector.selectRecent(RECENT_LIMIT)[0];
        Test.stopTest();

        Assert.areEqual('FW: fully populated', row.Name, 'Name — the row label and its link text');
        // ⚠ `.intValue()` makes the comparison type-explicit and scale-independent. It is belt and
        // braces, NOT a fix for a measured failure: `Assert.areEqual(Object, Object)` compares by
        // `equals`, so an Integer literal against a scale-BEARING Decimal is a real trap — but
        // `Property_Count__c` is Number(2,0), and the bare form is green on scale-0 Number fields in
        // this org (eight instances against `Inbound_Email_Staging__c.Property_Count__c` in
        // `ExtractAddressQueueableTest`). Do not churn those into this form on the strength of this
        // comment; do prefer it for `Percent` / `Currency` / any `scale > 0` field.
        Assert.areEqual(4, row.Property_Count__c.intValue(),
            'Property_Count__c — a fact about the EMAIL, which is why it can legitimately disagree '
            + 'with the member counts (design residual R9)');
        Assert.areEqual('Dana Reyes', row.Broker_Name__c, 'Broker_Name__c — the Broker cell');
        Assert.areEqual('dana@brokerage.example.com', row.Broker_Email__c,
            'Broker_Email__c — its supporting text in the same cell');
        Assert.areEqual(Datetime.newInstanceGmt(2026, 8, 14, 17, 30, 0), row.Received_DateTime__c,
            'Received_DateTime__c — what the Received column DISPLAYS');
        Assert.isNotNull(row.CreatedDate,
            'and CreatedDate, which is what it SORTS on. Both are needed: the sort key is not the '
            + 'displayed value, and the client uses CreatedDate for a relative-age fallback when '
            + 'Received_DateTime__c is null');
    }

    @isTest
    static void selectRecent_anOrgWithNoPortfolioDealsReturnsAnEmptyListNotNull() {
        // The permanent state until the first multi-property email arrives. The widget shows its empty
        // message for it, so this must be an ordinary answer rather than null (which the controller
        // would then iterate and NPE on).
        Test.startTest();
        List<Portfolio_Deal__c> rows = PortfolioDealSelector.selectRecent(RECENT_LIMIT);
        Test.stopTest();

        Assert.isNotNull(rows, 'A query returns a list, never null');
        Assert.areEqual(0, rows.size(), 'and it is empty');
    }

    @isTest
    static void selectRecent_aConvertedMemberIsCountedOnceNotTwice() {
        // 🔴 THE FALSIFIER FOR `IsConverted = false` ON THIS QUERY'S LEADS SUBQUERY, and it needs a
        // REAL conversion for the same reason its `selectWithMembersById` twin above does: the bug
        // requires a Lead and an Opportunity that are THE SAME ASSET, both pointing at the portfolio deal, and
        // only `Database.convertLead` produces that state (LeadConvertService copies the portfolio deal forward
        // and nothing nulls the husk Lead's copy). A fixture inserting the two independently cannot
        // catch it at any member count.
        //
        // ⚠ AND THE CONSEQUENCE IS WORSE HERE THAN ON THE SIBLING CARD. There a human sees two ROWS
        // and can see for themselves that they are one property. Here they see only "2 Leads · 1
        // Opportunity" — a number, with nothing to cross-check it against. A portfolio deal of 3 properties
        // whose deals are all live would read "3 Leads · 3 Opportunities" for 3 assets.
        Portfolio_Deal__c deal = insertPortfolioDeal('FW: one converts, one does not');
        List<Lead> members = insertMemberLeads(2, deal.Id);
        Lead toConvert = members[0];
        Lead staysOpen = members[1];

        Portfolio_Deal__c before = PortfolioDealSelector.selectRecent(RECENT_LIMIT)[0];
        Assert.areEqual(2, before.Leads__r.size() + before.Opportunities__r.size(),
            'Precondition: two open Leads, no deals yet — two members, two assets');

        // Fixture, so outside the test block. What is under test is the read that follows.
        Database.LeadConvertResult res = convertOne(toConvert);
        Id newOppId = res.getOpportunityId();
        Assert.areEqual(deal.Id,
            [SELECT Portfolio_Deal__c FROM Lead WHERE Id = :toConvert.Id].Portfolio_Deal__c,
            'Precondition on the MECHANISM: the converted husk Lead STILL carries the portfolio deal, so it '
            + 'is still a member by the database\'s reckoning. If a future change nulls it, this is '
            + 'where that shows up — and the filter would then be pinning a defect that no longer '
            + 'exists, which is a design change rather than licence to delete the WHERE clause');

        Test.startTest();
        Portfolio_Deal__c after = PortfolioDealSelector.selectRecent(RECENT_LIMIT)[0];
        Test.stopTest();

        Assert.areEqual(2, after.Leads__r.size() + after.Opportunities__r.size(),
            '🔴 STILL TWO MEMBERS, so the widget still says "2". A conversion MOVES an asset from the '
            + 'Lead collection to the Opportunity collection; it does not add one. Three here means '
            + 'the homepage inflates every worked portfolio deal');
        Assert.areEqual(1, after.Leads__r.size(),
            'one OPEN Lead — the "1 Lead" half of the Linked Records cell');
        Assert.areEqual(staysOpen.Id, after.Leads__r[0].Id,
            'and it is the member that did NOT convert, so the filter removed the right ROW and not '
            + 'merely the right NUMBER of rows');
        Assert.areEqual(1, after.Opportunities__r.size(), 'and the worked asset arrives as a deal');
        Assert.areEqual(newOppId, after.Opportunities__r[0].Id,
            'namely the Opportunity the conversion created');
    }
}
