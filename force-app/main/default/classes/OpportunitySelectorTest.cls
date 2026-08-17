/**
 * Tests for OpportunitySelector.
 *
 * Coverage: every method (aggregate, count, dynamic count, top-N list, two
 * fetch-for-use single-row reads) plus a 251-record bulk aggregate and a
 * `System.runAs(Standard User)` proof that **`countByStage` specifically** does not throw
 * under USER_MODE for the restricted persona the P4 design §5 measured.
 *
 * 🔴 THAT PROOF IS SCOPED TO ONE METHOD AND DOES **NOT** GENERALISE TO THIS CLASS.
 * `userMode_standardUser_doesNotThrow` calls only `countByStage()`, a `StageName`-only
 * aggregate — and `StageName` is `permissionable=false`, so USER_MODE has nothing to deny.
 * Every method here that selects a CUSTOM field, or the permissionable standard field
 * `Amount`, behaves the OPPOSITE way for that same persona: `WITH USER_MODE` throws on the
 * WHOLE ROW for ONE inaccessible field.
 *
 * ⚠ THIS SENTENCE USED TO READ AS A CLASS-WIDE CLAIM ("a proof that USER_MODE does not throw
 * for the restricted persona") AND WAS CORRECTED ON 2026-08-17 (code review W2) RATHER THAN
 * LEFT STANDING. It is not a hypothetical drift: a test asserting exactly that premise for
 * `selectTopByAmount` FAILED ON FIRST EXECUTION on 2026-08-16 (`RunLocalTests`) and had to be
 * rewritten to assert the throw — see
 * `TopDealsControllerTest.anUnprovisionedPersonaGetsTheUserSafeMessageNotARawQueryException`.
 * ⇒ **Before adding a field to any `WITH USER_MODE` method on this class, read
 * `OpportunitySelector`'s own header** (the grant list, and the 🔴 `Amount` counterexample
 * showing the trap is not custom-field-only). This header is not evidence that the addition
 * is safe for a restricted persona, and reading it as such is how that trap gets re-entered.
 *
 * @TestSetup builds 251 'New' Opportunities (factory default CloseDate = today+90,
 * Deal_Type__c = 'Retail'); test methods QUERY that data — they never call
 * default*() (TestDataFactory ⚠1 cache trap).
 */
@isTest
private class OpportunitySelectorTest {

    private static final Integer BULK_N = 251;

    @TestSetup
    static void setup() {
        TestDataFactory.createOpportunities(BULK_N, true);
    }

    @isTest
    static void countByStage_bulk_groupsAllRecords() {
        Test.startTest();
        List<AggregateResult> results = OpportunitySelector.countByStage();
        Test.stopTest();

        Integer newCount = null;
        for (AggregateResult ar : results) {
            if ('New'.equals((String) ar.get('st'))) {
                newCount = (Integer) ar.get('c');
            }
        }
        Assert.areEqual(BULK_N, newCount, 'All 251 New Opportunities should be grouped into the New bucket');
    }

    @isTest
    static void countByStageInLastNDays_countsOnlyInWindow() {
        // The 251 setup Opportunities have a future CloseDate and must be excluded;
        // create 3 with CloseDate = today so only they fall inside LAST_N_DAYS:90.
        List<Opportunity> recent = TestDataFactory.createOpportunities(3, false);
        for (Opportunity o : recent) {
            o.CloseDate = Date.today();
        }
        insert recent;

        Test.startTest();
        Integer count = OpportunitySelector.countByStageInLastNDays('New', 90);
        Test.stopTest();

        Assert.areEqual(3, count, 'Only the 3 Opportunities with CloseDate = today are within LAST_N_DAYS:90');
    }

    @isTest
    static void selectTopByAskingPrice_ordersDescendingAndLimits() {
        Test.startTest();
        List<Opportunity> top = OpportunitySelector.selectTopByAskingPrice(5);
        Test.stopTest();

        Assert.areEqual(5, top.size(), 'LIMIT should cap the result at 5');
        for (Integer i = 1; i < top.size(); i++) {
            Assert.isTrue(
                top[i - 1].Asking_Price__c >= top[i].Asking_Price__c,
                'Rows must be ordered by Asking_Price__c descending'
            );
        }
        Assert.isNotNull(top[0].Name, 'Name must be populated for the row-mapping caller');
        Assert.isNotNull(top[0].StageName, 'StageName must be populated');
    }

    @isTest
    static void aggregateOpenPipeline_sumsOpenDeals() {
        Set<String> closedStages = new Set<String>{ 'Closed Won', 'Dead/Pass' };

        Test.startTest();
        List<AggregateResult> results = OpportunitySelector.aggregateOpenPipeline(closedStages);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'A pipeline aggregate returns a single summary row');
        Assert.areEqual(BULK_N, (Integer) results[0].get('c'), 'All 251 New deals are open');
        Assert.isNotNull(results[0].get('v'), 'SUM(Asking_Price__c) should be populated when rows match');
    }

    @isTest
    static void countByDealType_matchesRetailAndLand() {
        Test.startTest();
        Integer retail = OpportunitySelector.countByDealType('Retail');
        Integer land = OpportunitySelector.countByDealType('Land');
        Test.stopTest();

        Assert.areEqual(BULK_N, retail, 'All 251 factory Opportunities are Retail');
        Assert.areEqual(0, land, 'No Land Opportunities were created');
    }

    @isTest
    static void selectPrimaryRefsById_returnsRecord() {
        Opportunity existing = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        Opportunity result = OpportunitySelector.selectPrimaryRefsById(existing.Id);
        Test.stopTest();

        Assert.areEqual(existing.Id, result.Id, 'Should return the requested Opportunity');
    }

    @isTest
    static void selectPrimaryRefsById_missing_throwsQueryException() {
        Id ghostId = ghostOpportunityId();

        Test.startTest();
        try {
            OpportunitySelector.selectPrimaryRefsById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    @isTest
    static void selectStageRequiredById_returnsStage() {
        Opportunity existing = [SELECT Id, StageName FROM Opportunity LIMIT 1];

        Test.startTest();
        Opportunity result = OpportunitySelector.selectStageRequiredById(existing.Id);
        Test.stopTest();

        Assert.areEqual(existing.Id, result.Id, 'Should return the requested Opportunity');
        Assert.areEqual('New', result.StageName, 'StageName must be populated');
    }

    @isTest
    static void selectStageRequiredById_missing_throwsQueryException() {
        Id ghostId = ghostOpportunityId();

        Test.startTest();
        try {
            OpportunitySelector.selectStageRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    @isTest
    static void userMode_standardUser_doesNotThrow() {
        User standardUser = buildStandardUser();
        insert standardUser;

        Test.startTest();
        System.runAs(standardUser) {
            // Standard fields selected here are permissionable=false (always readable);
            // USER_MODE must not raise an FLS error for a Standard User (P4 design §5).
            List<AggregateResult> results = OpportunitySelector.countByStage();
            Assert.isNotNull(results, 'USER_MODE aggregate must not throw for a Standard User');
        }
        Test.stopTest();
    }

    @isTest
    static void selectExecutionHandoffByIds_returnsRecordsWithHeaderFields() {
        List<Opportunity> existing = [SELECT Id FROM Opportunity LIMIT 5];
        Set<Id> ids = (new Map<Id, Opportunity>(existing)).keySet();

        Test.startTest();
        List<Opportunity> result = OpportunitySelector.selectExecutionHandoffByIds(ids);
        Test.stopTest();

        Assert.areEqual(5, result.size(), 'Every requested Opportunity is returned as a bulk list');
        Assert.isNotNull(result[0].Name, 'Name must be selected — ContractExecutionService reads o.Name in the notification loop');
        Assert.isNotNull(result[0].Id, 'Id must be selected for the Opportunity stamp and Transaction parenting');
    }

    @isTest
    static void selectExecutionHandoffByIds_nullOrEmpty_returnsEmptyList() {
        Test.startTest();
        List<Opportunity> forNull = OpportunitySelector.selectExecutionHandoffByIds(null);
        List<Opportunity> forEmpty = OpportunitySelector.selectExecutionHandoffByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'Null ids short-circuit to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'Empty ids short-circuit to an empty list, not null');
    }

    @isTest
    static void selectExecutionHandoffByIds_bulk251_readsAll() {
        Set<Id> allOppIds = (new Map<Id, Opportunity>([SELECT Id FROM Opportunity])).keySet();

        Test.startTest();
        List<Opportunity> result = OpportunitySelector.selectExecutionHandoffByIds(allOppIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(),
            'All 251 setup Opportunities are read by their Ids in a single bulk Set<Id> query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectAccountRefById  (BrokerFirmController — sidebar firm reference)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectAccountRefById_returnsAccountReference() {
        Account acct = TestDataFactory.createAccount(true);
        Opportunity opp = TestDataFactory.createOpportunity(acct.Id, true);

        Test.startTest();
        Opportunity result = OpportunitySelector.selectAccountRefById(opp.Id);
        Test.stopTest();

        Assert.areEqual(opp.Id, result.Id, 'Should return the requested Opportunity');
        Assert.areEqual(acct.Id, result.AccountId, 'AccountId must be populated for the sidebar');
        Assert.areEqual(acct.Name, result.Account.Name, 'Account.Name must be populated for the firm name');
    }

    @isTest
    static void selectAccountRefById_missing_throwsQueryException() {
        Id ghostId = ghostOpportunityId();

        Test.startTest();
        try {
            OpportunitySelector.selectAccountRefById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // countByStageForAccount  (BrokerFirmController — firm-level deal counts)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void countByStageForAccount_scopesToAccountAndGroupsByStage() {
        Account acct = TestDataFactory.createAccount(true);
        TestDataFactory.createOpportunities(BULK_N, acct.Id, true);

        Test.startTest();
        List<AggregateResult> results = OpportunitySelector.countByStageForAccount(acct.Id);
        Test.stopTest();

        Integer newCount = null;
        for (AggregateResult ar : results) {
            if ('New'.equals((String) ar.get('st'))) {
                newCount = (Integer) ar.get('c');
            }
        }
        Assert.areEqual(BULK_N, newCount,
            'All 251 New Opportunities for the account group into the New bucket; the no-account setup Opps are excluded');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectPrimaryLoiByIds  (ApprovalAuditService — LOI-gate stamp)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectPrimaryLoiByIds_returnsOnlyDealsWithPrimaryLoi() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);
        opp.Primary_LOI__c = loi.Id;
        update opp;
        // A second deal with no Primary_LOI__c must be excluded even though its Id is
        // in the requested set.
        Opportunity oppNoLoi = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        List<Opportunity> result =
            OpportunitySelector.selectPrimaryLoiByIds(new Set<Id>{ opp.Id, oppNoLoi.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the deal with a non-null Primary_LOI__c is returned');
        Assert.areEqual(opp.Id, result[0].Id, 'The returned row is the deal that has a Primary LOI');
        Assert.areEqual(loi.Id, result[0].Primary_LOI__c, 'Primary_LOI__c must be selected for the LOI stamp');
    }

    @isTest
    static void selectPrimaryLoiByIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Opportunity> forNull = OpportunitySelector.selectPrimaryLoiByIds(null);
        List<Opportunity> forEmpty = OpportunitySelector.selectPrimaryLoiByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'Null ids short-circuit to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'Empty ids short-circuit to an empty list, not null');
    }

    @isTest
    static void selectPrimaryLoiByIds_bulk251_readsAll() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_N, true);
        // One LOI per deal (built unsaved, inserted once — no DML in the loop), then
        // each deal points to its own Primary LOI.
        List<LOI__c> lois = new List<LOI__c>();
        for (Opportunity o : opps) {
            lois.add(TestDataFactory.createLoi(o.Id, false));
        }
        insert lois;
        for (Integer i = 0; i < opps.size(); i++) {
            opps[i].Primary_LOI__c = lois[i].Id;
        }
        update opps;
        Set<Id> ids = (new Map<Id, Opportunity>(opps)).keySet();

        Test.startTest();
        List<Opportunity> result = OpportunitySelector.selectPrimaryLoiByIds(ids);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(),
            'All 251 deals with a Primary LOI are read by their Ids in a single bulk Set<Id> query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectCallForOffersTargetsByIds — Broker Protection's call-for-offers stamp
    // (Tranche 4B, 2026-08-10). The ONE WITH SYSTEM_MODE method on this class.
    //
    // ⚠ THERE IS DELIBERATELY NO System.runAs FLS TEST HERE, AND THAT IS NOT AN
    // OMISSION. A SYSTEM_MODE read cannot be made to fail on FLS by construction, so
    // a runAs test asserting "it did not throw" would pass identically if the method
    // were WITH USER_MODE against an admin — i.e. it would be UNFALSIFIABLE, the same
    // trap recorded for the system-mode write elsewhere in this repo. What CAN be
    // falsified is the field list (a narrowed SELECT breaks the no-change skip in
    // CallForOffersStampService, silently turning every redelivery into a write), and
    // that is what the tests below pin. The mode's real proof is post-deploy gate G5,
    // run as the pipeline principal rather than as an admin.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectCallForOffersTargetsByIds_selectsEveryFieldTheStampCompares() {
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Offer_Due_Date__c = Date.today().addDays(9);
        deal.Listing_Broker_Name__c = 'Pat Lister';
        deal.Listing_Broker_Email__c = 'pat.lister@example.invalid';
        deal.Sale_Process__c = 'On-Market Listing';
        deal.Call_For_Offers_Received_Date__c = Date.today().addDays(-5);
        insert deal;

        Test.startTest();
        List<Opportunity> result =
            OpportunitySelector.selectCallForOffersTargetsByIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The matched deal must come back');
        Assert.areEqual(Date.today().addDays(9), result[0].Offer_Due_Date__c,
            'Offer_Due_Date__c must be SELECTed — CallForOffersStampService compares against it to '
            + 'decide whether anything would change, and an unselected field would read null, '
            + 'making every redelivery an unnecessary write on a live deal');
        Assert.areEqual('Pat Lister', result[0].Listing_Broker_Name__c,
            'Listing_Broker_Name__c must be SELECTed for the same reason');
        Assert.areEqual('pat.lister@example.invalid', result[0].Listing_Broker_Email__c,
            'Listing_Broker_Email__c must be SELECTed for the same reason');
        Assert.areEqual('On-Market Listing', result[0].Sale_Process__c,
            '🔴 Sale_Process__c JOINED THIS FIELD SET 2026-08-12 and is not optional — it is read '
            + 'for the identical reason as the other three: an unselected field reads null, so '
            + 'buildChange would treat every deal as if it had no sale process on file and write '
            + 'the same value again on every redelivery of the same campaign email');
        Assert.areEqual(Date.today().addDays(-5), result[0].Call_For_Offers_Received_Date__c,
            '🔴 Call_For_Offers_Received_Date__c JOINED THIS FIELD SET 2026-08-14 on identical '
            + 'terms. Unselected it reads null, so the no-change skip could never fire for it and '
            + 'a re-sent campaign email would rewrite the same date onto a live deal');
    }

    @isTest
    static void selectCallForOffersTargetsByIds_nullOrEmpty_returnsEmptyListAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Opportunity> forNull = OpportunitySelector.selectCallForOffersTargetsByIds(null);
        List<Opportunity> forEmpty =
            OpportunitySelector.selectCallForOffersTargetsByIds(new Set<Id>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'Null ids short-circuit to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'Empty ids short-circuit to an empty list, not null');
        Assert.areEqual(before, after,
            'and the short-circuit must cost NO query — this is what keeps an all-unmatched '
            + 'call-for-offers blast exactly as cheap as it was before Tranche 4B');
    }

    @isTest
    static void selectCallForOffersTargetsByIds_isOneQueryForManyDeals() {
        // The constancy property, not the volume: CallForOffersStampService reads ONE time for a
        // whole email no matter how many of its properties matched. Ten is MAX_PROPERTIES, the
        // real production ceiling for one email — 251 deals in one call-for-offers email is
        // unreachable (ExtractAddressQueueable caps at 10) and testing it would encode a state
        // production cannot produce.
        List<Opportunity> deals = TestDataFactory.createOpportunities(10, true);
        Set<Id> ids = (new Map<Id, Opportunity>(deals)).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Opportunity> result = OpportunitySelector.selectCallForOffersTargetsByIds(ids);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(10, result.size(), 'Every requested deal is returned in one bulk read');
        Assert.areEqual(1, after - before,
            'EXACTLY one query for ten deals. If this becomes 10, someone has moved the read '
            + 'inside a per-property loop and the pinned call-for-offers governor budget is next');
    }

    /** A syntactically valid Opportunity Id that resolves to no row (create then delete). */
    private static Id ghostOpportunityId() {
        Opportunity ghost = TestDataFactory.createOpportunity(null, true);
        Id ghostId = ghost.Id;
        delete ghost;
        return ghostId;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CALL-FOR-OFFERS READS (Phase 4, 2026-08-14)
    //
    // ⚠ The @TestSetup above builds 251 Opportunities with NO Offer_Due_Date__c, which is exactly
    // the population these three methods must ignore. That makes it a free control: every count
    // below is "the deals I gave a deadline to", and a method that forgot its
    // `Offer_Due_Date__c != NULL` filter fails by 251.
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void selectCallForOffersOpen_returnsOnlyDealsWithADeadlineSoonestFirst() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(2, true);
        deals[0].Offer_Due_Date__c = Date.today().addDays(12);
        deals[1].Offer_Due_Date__c = Date.today().addDays(4);
        update deals;

        List<Opportunity> rows = OpportunitySelector.selectCallForOffersOpen();

        Assert.areEqual(2, rows.size(),
            'Only deals with a deadline are returned — the 251 @TestSetup deals have none');
        Assert.areEqual(deals[1].Id, rows[0].Id, 'Soonest deadline first');
        Assert.areEqual(deals[0].Id, rows[1].Id, 'then the later one');
    }

    @isTest
    static void selectCallForOffersOpen_excludesClosedDeals() {
        Opportunity open = TestDataFactory.createOpportunity(null, true);
        open.Offer_Due_Date__c = Date.today().addDays(3);
        update open;

        // Closed at INSERT so no ISCHANGED(StageName) rule is involved in the fixture.
        Opportunity closed = TestDataFactory.createOpportunity(null, false);
        closed.StageName = 'Dead/Pass';
        insert closed;
        update new Opportunity(Id = closed.Id, Offer_Due_Date__c = Date.today().addDays(3));

        List<Opportunity> rows = OpportunitySelector.selectCallForOffersOpen();

        Assert.areEqual(1, rows.size(), 'A won or dead deal has no live deadline to chase');
        Assert.areEqual(open.Id, rows[0].Id, 'and the open one is the survivor');
    }

    @isTest
    static void selectCallForOffersOpen_selectsEveryFieldTheServiceReads() {
        // 🔴 THE FIELD LISTS OF THE TWO USER_MODE METHODS MUST MATCH, because
        // CallForOffersService.evaluateAll reads all ten off BOTH. A field present in one and
        // absent from the other is a runtime SObjectException on exactly one of the two surfaces
        // and nothing at compile time. Touching every field is what makes that fail here instead.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        update deal;

        for (Opportunity row : new List<Opportunity>{
                OpportunitySelector.selectCallForOffersOpen()[0],
                OpportunitySelector.selectCallForOffersById(deal.Id) }) {
            // A field the query did not select throws SObjectException on access, so simply reading
            // each one is the assertion.
            Assert.isNotNull(row.Id, 'Id');
            Assert.isNotNull(row.Name, 'Name');
            Assert.isNotNull(row.CreatedDate, 'CreatedDate');
            Assert.isNotNull(row.Offer_Due_Date__c, 'Offer_Due_Date__c');
            // Added 2026-08-14. It is the field the "Received" column actually renders now, so a
            // read that dropped it would blank that column on BOTH surfaces at once.
            row.Call_For_Offers_Received_Date__c?.day();
            row.Broker_First_Seen__c?.day();
            String unusedProcess = row.Sale_Process__c;
            String unusedBroker = row.Listing_Broker_Name__c;
            String unusedEmail = row.Listing_Broker_Email__c;
            String unusedLink = row.Deal_Room_Link__c;
        }
    }

    @isTest
    static void selectCallForOffersById_isNullSafeAndReturnsNullForAMiss() {
        // NOT-FOUND CONTRACT: this one returns null rather than throwing, unlike its
        // fetch-for-use siblings, because its caller renders a "no deadline" state for a miss.
        Assert.isNull(OpportunitySelector.selectCallForOffersById(null), 'A null Id returns null');
        Assert.isNull(OpportunitySelector.selectCallForOffersById(ghostOpportunityId()),
            'An unresolvable Id returns null rather than throwing QueryException');
    }

    @isTest
    static void selectCallForOffersById_doesNotFilterOnClosed() {
        // ⚠ DELIBERATELY UNLIKE THE LIST METHOD. A user standing on a closed deal's record page is
        // entitled to see what its deadline was; the list excludes closed deals because a closed
        // deal is not something to chase. Do not "harmonise" the two.
        Opportunity closed = TestDataFactory.createOpportunity(null, false);
        closed.StageName = 'Dead/Pass';
        insert closed;
        update new Opportunity(Id = closed.Id, Offer_Due_Date__c = Date.today().addDays(3));

        Assert.isNotNull(OpportunitySelector.selectCallForOffersById(closed.Id),
            'The record-page read must still resolve a closed deal');
    }

    /**
     * Walk the alert locator and collect its rows.
     *
     * 🔴 IT MUST BE THE ITERATOR, NOT `Database.query(locator.getQuery())`. `getQuery()` returns the
     * SOQL with every bind variable already replaced by an opaque `:tmpVar1` placeholder that
     * nothing in scope can satisfy, so re-running the string throws
     * `System.QueryException: Variable does not exist: tmpVar1` — measured, not theorised. The
     * locator binds a `ceiling` date, so this trap applies to it permanently.
     */
    private static List<Opportunity> drainLocator() {
        List<Opportunity> rows = new List<Opportunity>();
        Database.QueryLocatorIterator it = OpportunitySelector.queryCallForOffersAlerts().iterator();
        while (it.hasNext()) {
            rows.add((Opportunity) it.next());
        }
        return rows;
    }

    @isTest
    static void queryCallForOffersAlerts_appliesTheLadderCeilingAndTheClosedFilter() {
        Opportunity inLadder = TestDataFactory.createOpportunity(null, true);
        inLadder.Offer_Due_Date__c = Date.today().addDays(7);
        Opportunity onCeiling = TestDataFactory.createOpportunity(null, true);
        onCeiling.Offer_Due_Date__c = Date.today().addDays(8);
        Opportunity overdue = TestDataFactory.createOpportunity(null, true);
        overdue.Offer_Due_Date__c = Date.today().addDays(-90);
        update new List<Opportunity>{ inLadder, onCeiling, overdue };

        Set<Id> selected = new Map<Id, Opportunity>(drainLocator()).keySet();

        Assert.isTrue(selected.contains(inLadder.Id), 'Exactly 7 days out is INSIDE the ladder');
        Assert.isFalse(selected.contains(onCeiling.Id),
            '8 days out is past the TODAY+7 ceiling and must not be read');
        Assert.isTrue(selected.contains(overdue.Id),
            'There is deliberately NO lower bound — a deal created after its deadline passed is '
            + 'still owed its one alert, and adding a floor would silence it');
    }

    @isTest
    static void queryCallForOffersAlerts_selectsBothMarkerFields() {
        // The batch cannot make its idempotency decision without them, and a locator that dropped
        // one would throw SObjectException deep inside a chunk rather than failing here.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        update deal;

        List<Opportunity> rows = drainLocator();

        Assert.areEqual(1, rows.size(), 'The deal is in the work queue');
        rows[0].Offer_Alert_Last_Interval__c?.intValue();
        rows[0].Offer_Alert_Due_Date__c?.day();
        Assert.isNotNull(rows[0].Name, 'and Name, which the notification body uses');
        String unusedBroker = rows[0].Listing_Broker_Name__c;
    }

    @isTest
    static void queryCallForOffersAlerts_doesNotSelectTheReceivedDate() {
        // ⚠ AN ABSENCE, ASSERTED ON PURPOSE — the confirmation that the 2026-08-14 received-date
        // field changed NOTHING about the alert ladder. The marker keys on the DUE date at every
        // point (the rung, the re-arm comparison and the snapshot it stamps), and the notification
        // body is derived from the deadline, so an email that moves only the received date must
        // change no alert decision. Selecting the field here would imply otherwise to the next
        // reader; this is what makes adding it a deliberate act rather than a tidy-up.
        //
        // The mechanism is that reading a field a query did not select throws SObjectException.
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        deal.Call_For_Offers_Received_Date__c = Date.today().addDays(-1);
        update deal;

        List<Opportunity> rows = drainLocator();
        Assert.areEqual(1, rows.size(), 'Precondition: the deal is in the work queue');

        try {
            Date unused = rows[0].Call_For_Offers_Received_Date__c;
            Assert.fail('The alert locator must NOT select Call_For_Offers_Received_Date__c — the '
                + 'alert ladder has no use for it. Got: ' + unused);
        } catch (System.SObjectException e) {
            Assert.isTrue(e.getMessage().contains('Call_For_Offers_Received_Date__c'),
                'and the platform names the unselected field: ' + e.getMessage());
        }
    }

    @isTest
    static void selectCallForOffersOpen_at251DealsIsOneQueryAndReturnsThemAll() {
        // Re-use the @TestSetup population rather than creating a second 251, and give every one of
        // them a deadline so the row count is the real thing being measured.
        List<Opportunity> deals = [SELECT Id FROM Opportunity LIMIT 251];
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Offer_Due_Date__c = Date.today().addDays(Math.mod(i, 40));
        }
        update deals;

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Opportunity> rows = OpportunitySelector.selectCallForOffersOpen();
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'Every deal with a deadline comes back');
        Assert.areEqual(1, used,
            'ONE query regardless of row count. Measured inside the transaction — Limits.* after '
            + 'Test.stopTest() is restored to pre-test values and would be silently vacuous');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectTopActiveByAskingPrice — the "Top 5 Largest Deals" card (FSD §24.2)
    //
    // 🔴 RENAMED FROM `selectTopByAmount` ON 2026-08-17 WITH THE RANKING IT NAMES. The card
    // was re-ranked onto `Asking_Price__c` and cut to two columns (user decision), so the
    // method's old name described an ORDER BY it no longer had. These tests were repointed,
    // and their FIXTURE WAS INVERTED with them — see `seedAskingPriceRanking`.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE FIXTURE INVERTS `Asking_Price__c` AGAINST `Amount`, AND WITHOUT THAT THESE TESTS
     * WOULD BE VACUOUS. `TestDataFactory.createOpportunities` seeds the two fields to the
     * SAME value, so against the plain setup data an asking-price ranking and an `Amount`
     * ranking return an IDENTICAL list and no assertion can tell them apart. The three rows
     * below make the two orderings opposite.
     *
     * ⚠ THE INVERSION POINTS THE OTHER WAY THAN IT USED TO. It formerly gave the leader the
     * biggest `Amount` and an asking price of 1; it now gives the leader the biggest ASKING
     * PRICE and an `Amount` of 1. A row that led under the old ordering must not lead under
     * the new one, or the falsifier is not a falsifier.
     *
     * ⚠ It also parks the two BIGGEST asking prices on closed stages, so a missing stage
     * filter shows up at positions 0 and 1 rather than at the tail of the list. Both closed
     * rows set BOTH fields, so the fixture stays meaningful if this card is ever re-ranked
     * again in either direction.
     *
     * 🔴 THE CLOSED STAGES ARE SET **BEFORE THE INSERT** — do not convert this to an
     * insert-then-update. Every Opportunity stage gate here is guarded by
     * `ISCHANGED(StageName)`, false on insert and true on update, so an update to
     * `'Closed Won'` is BLOCKED by `Contract_Signed_Before_Closed_Won` (no executed PSA on
     * this fixture) and by `NDA_Signed_Before_Deal_Progression` (no signed Primary NDA),
     * while the insert passes. Building a real NDA/LOI/PSA chain would be a large fixture for
     * a test that only needs rows to EXIST at closed stages.
     */
    private static void seedAskingPriceRanking() {
        List<Opportunity> ranked = TestDataFactory.createOpportunities(3, false);
        // Biggest Asking Price, smallest Amount — must lead an asking-price ranking, and
        // must NOT lead an Amount one (every setup row outranks an Amount of 1).
        ranked[0].Name = 'AskingPriceLeader';
        ranked[0].Asking_Price__c = 90000000;
        ranked[0].Amount = 1;
        // Closed, and larger than everything in the 251-row setup — must NEVER appear.
        ranked[1].Name = 'ClosedGiant';
        ranked[1].StageName = 'Closed Won';
        ranked[1].Asking_Price__c = 99000000;
        ranked[1].Amount = 99000000;
        ranked[2].Name = 'DeadGiant';
        ranked[2].StageName = 'Dead/Pass';
        ranked[2].Asking_Price__c = 98000000;
        ranked[2].Amount = 98000000;
        insert ranked;
    }

    @isTest
    static void selectTopActiveByAskingPrice_ordersByAskingPriceAndExcludesClosedDeals() {
        seedAskingPriceRanking();

        Test.startTest();
        List<Opportunity> top = OpportunitySelector.selectTopActiveByAskingPrice(5);
        Test.stopTest();

        Assert.areEqual(5, top.size(), 'LIMIT caps the result at 5');
        Assert.areEqual('AskingPriceLeader', top[0].Name,
            'The highest ACTIVE Asking_Price__c leads. Reading "ClosedGiant" means the stage '
            + 'filter was dropped; reading a setup row means the ORDER BY moved off '
            + 'Asking_Price__c (this row carries an Amount of 1 on purpose).');
        for (Integer i = 1; i < top.size(); i++) {
            Assert.isTrue(top[i - 1].Asking_Price__c >= top[i].Asking_Price__c,
                'Rows must be ordered by Asking_Price__c descending');
        }
        // 🔴 The stage predicate is pinned HERE rather than in TopDealsControllerTest,
        // because this is the only layer that still sees StageName: the two-column cut
        // removed `stage` from TopDealsController.TopDealRow.
        for (Opportunity o : top) {
            Assert.isTrue(
                !OpportunitySelector.CLOSED_STAGES.contains(o.StageName),
                'No closed deal may appear: ' + o.Name + ' at ' + o.StageName);
        }
    }

    /**
     * The filter runs in the QUERY, not after the LIMIT.
     *
     * ⚠ This is the falsifier for "filter in Apex after the selector returns". With the two
     * closed giants outranking every setup row, a post-LIMIT filter would return THREE rows
     * here instead of five — a subtly short list nobody would notice on a home page.
     */
    @isTest
    static void selectTopActiveByAskingPrice_stillFillsTheLimitWhenClosedDealsOutrankActiveOnes() {
        seedAskingPriceRanking();

        Test.startTest();
        List<Opportunity> top = OpportunitySelector.selectTopActiveByAskingPrice(5);
        Test.stopTest();

        Assert.areEqual(5, top.size(),
            'Five ACTIVE rows come back even though the two most expensive deals in the org '
            + 'are closed');
    }

    /**
     * The SELECT is exactly what the card and its own filter need — and NOTHING MORE.
     *
     * 🔴 THE SECOND HALF IS THE MORE VALUABLE ONE. A field the caller reads but the SELECT
     * omits throws `SObjectException` at RUNTIME, not at compile time, so the presence half
     * has to be pinned. But under `WITH USER_MODE` the ABSENCE half matters just as much:
     * USER_MODE throws on the WHOLE ROW for ONE inaccessible field, so every field this
     * query does not need is a way for the card to fail for a persona in exchange for
     * nothing on screen. `Amount` is asserted absent as the representative — it was in this
     * SELECT until 2026-08-17 and is the one a revert would put back first.
     */
    @isTest
    static void selectTopActiveByAskingPrice_selectsTheCardsFieldsAndNoOthers() {
        Test.startTest();
        List<Opportunity> top = OpportunitySelector.selectTopActiveByAskingPrice(1);
        Test.stopTest();

        Assert.areEqual(1, top.size(), 'precondition: the setup data yields a row');
        Assert.isNotNull(top[0].Name, 'Name backs the Property Name link label');
        Assert.isNotNull(top[0].Asking_Price__c,
            'Asking_Price__c is the ranking value and the Asking Price column');
        Assert.isNotNull(top[0].CreatedDate, 'CreatedDate is the ORDER BY tiebreak');
        Assert.isNotNull(top[0].StageName,
            'StageName is not rendered but IS asserted row-by-row above, so it stays selected');

        try {
            Decimal unused = top[0].Amount;
            Assert.fail('Amount must NOT be in this SELECT. It was removed with the Amount '
                + 'column on 2026-08-17; re-adding it re-adds a permissionable standard '
                + 'field to a WITH USER_MODE query that no longer renders it. Read back: '
                + unused);
        } catch (SObjectException e) {
            // Expected: "SObject row was retrieved via SOQL without querying the requested field".
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectMarketSnapshotSourceByIds — the underwriting market freeze (FSD §18.3)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The traversed `Property__r` block comes back populated, so `MarketDataSnapshotService`
     * can compose from it without a second query.
     *
     * ⚠ ONE VALUE FROM EACH PROVIDER BLOCK IS ASSERTED. A SELECT that dropped a whole
     * provider would still return rows and still populate `Property__r`, so asserting only
     * "Property__r is not null" would pass on a half-built field list.
     */
    @isTest
    static void selectMarketSnapshotSourceByIds_returnsTheTraversedMarketBlock() {
        Property__c property = TestDataFactory.createProperty(false);
        property.Placer_State_Rank__c = 7;
        property.CoStar_Pct_Leased__c = 88.00;
        insert property;

        Opportunity deal = TestDataFactory.createOpportunity((Id) null, false);
        deal.Property__c = property.Id;
        insert deal;

        Test.startTest();
        List<Opportunity> rows =
            OpportunitySelector.selectMarketSnapshotSourceByIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The requested deal comes back');
        Assert.areEqual(property.Id, rows[0].Property__c, 'with its Property lookup');
        Assert.isNotNull(rows[0].Property__r, 'and the parent traversal populated');
        // ⚠ Compared with `==` rather than Assert.areEqual: these fields come back as Decimal,
        // and Assert.areEqual(Object, Object) treats an Integer literal and a Decimal as
        // UNEQUAL even when they denote the same number. Decimal `==` compares by value and
        // ignores scale, which is what is wanted for a Number(6,0) / Percent(5,2) read-back.
        Assert.isTrue(rows[0].Property__r.Placer_State_Rank__c == 7, 'a Placer-block value');
        Assert.isTrue(rows[0].Property__r.CoStar_Pct_Leased__c == 88.00, 'and a CoStar-block value');
    }

    /**
     * A deal with no Property still comes back, with `Property__r` null.
     *
     * 🔴 THE ROW MUST NOT BE FILTERED OUT. `MarketDataSnapshotService` distinguishes "no
     * Property" (a legitimate outcome it explains on the record) from "the deal could not be
     * read" (a failure it reports as one). A selector that dropped Property-less deals would
     * silently collapse the two into the failure branch.
     */
    @isTest
    static void selectMarketSnapshotSourceByIds_returnsADealWithNoPropertyRatherThanDroppingIt() {
        Opportunity deal = TestDataFactory.createOpportunity((Id) null, true);

        Test.startTest();
        List<Opportunity> rows =
            OpportunitySelector.selectMarketSnapshotSourceByIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A Property-less deal is still returned');
        Assert.isNull(rows[0].Property__c, 'with a null Property lookup');
        Assert.isNull(rows[0].Property__r, 'and a null parent, which the service reports explicitly');
    }

    @isTest
    static void selectMarketSnapshotSourceByIds_isEmptySafeAndCostsOneQueryAtBulk() {
        Set<Id> ids = new Map<Id, Opportunity>([SELECT Id FROM Opportunity]).keySet();
        Assert.areEqual(BULK_N, ids.size(), 'precondition: the 251-row setup is in place');

        Test.startTest();
        List<Opportunity> none =
            OpportunitySelector.selectMarketSnapshotSourceByIds(new Set<Id>());

        Integer before = Limits.getQueries();
        List<Opportunity> all = OpportunitySelector.selectMarketSnapshotSourceByIds(ids);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isTrue(none.isEmpty(), 'An empty Id set returns an empty list, never null');
        Assert.areEqual(BULK_N, all.size(), 'All 251 deals come back in one read');
        Assert.areEqual(1, used,
            'ONE query regardless of deal count. Measured inside the transaction — Limits.* '
            + 'after Test.stopTest() is restored to pre-test values and would be silently vacuous');
    }

    private static User buildStandardUser() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'oppsel' + System.currentTimeMillis();
        return new User(
            ProfileId = standard.Id,
            LastName = 'OppSelTest',
            Email = 'oppseltest@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            Alias = 'osel',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
