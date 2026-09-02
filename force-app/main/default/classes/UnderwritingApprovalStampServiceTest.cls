/**
 * Tests UnderwritingApprovalStampService — the invocable that mirrors an approved Underwriting
 * record's decision onto its parent Opportunity.
 *
 * ── 🔴 THE LOAD-BEARING TEST IN THIS CLASS IS stampsBothMirrorFieldsInExactlyOneSave ──────────
 * Everything else here is ordinary coverage. That one test is the falsifier for the class's
 * central constraint: BOTH parent fields must land in a SINGLE Database.update, because the
 * market-data freeze (Opportunity_UW_Approved_Notify -> MarketDataSnapshotService) has
 * doesRequireRecordChangedToMeetCriteria = true and fires on the TRANSITION into
 * Underwriting_Status__c = 'Approved by Principals'. A refactor that splits the write into two
 * updates would leave every field correct — every value assertion in this file would still pass —
 * while silently killing the freeze. Only the DML-count assertion catches it.
 *
 * ⚠ IT COUNTS DML *INSIDE* THE CALL, NOT AROUND Test.stopTest(). Limits counters are restored
 * when stopTest() runs, so the obvious "assert Limits.getDmlStatements() afterwards" is silently
 * vacuous. The delta is captured immediately either side of the invocation.
 *
 * ── ⚠ 2026-09-02, WHY THREE FIXTURES SHRANK, AND WHY THAT IS NOT A LOST FALSIFIER ─────────────
 * Three inline Underwriting__c constructors here used to also set the CHILD's Status__c to
 * 'In Progress'. Underwriting__c.Status__c is retired (strict-subset duplicate of Stage__c) and
 * those assignments are gone. They were fixture noise: no assertion in this class ever read the
 * child's Status__c, and this service does not read it either — it reads Opportunity__c and writes
 * the PARENT's Opportunity.Underwriting_Status__c, a different field on a different object that is
 * DELIBERATELY RETAINED (it is the market-data freeze's only trigger, see above). So the removal
 * subtracts nothing any test claimed. 🔴 Do not read the two similar names as one field: every
 * `Underwriting_Status__c` in this file is the parent's and must stay.
 *
 * ── BULK POSTURE (.claude/rules/bulk-test-rule.md) ────────────────────────────────────────────
 * The 251-record mandate is NOT applied here, and the reasoning is recorded in place as that rule
 * requires. This method is invoked from a record-triggered flow, so it IS a bulk path in
 * principle — but 251 Underwriting records each carrying its own granted principal approval is
 * not a state production can reach (approvals are granted one human decision at a time), and the
 * bug class the 251 threshold exists to expose is "a second trigger batch reveals SOQL/DML in a
 * loop". That is falsified here directly and more cheaply: multipleUnderwritingsStayAtOneQueryAndOneDml
 * asserts a FIXED query/DML budget across a multi-record batch, so adding a per-record query or
 * update reds the test at any N. Row counts are kept modest deliberately; nothing in this class
 * touches ContentVersion/ContentNote, but the same "don't inflate fixtures for confidence" posture
 * from .claude/rules/content-publication-rule.md applies.
 *
 * @see force-app/main/default/classes/UnderwritingApprovalStampService.cls
 */
@isTest
private class UnderwritingApprovalStampServiceTest {

    private static final String STATUS_APPROVED = 'Approved by Principals';

    /** A deal at Underwriting, whose stage entry auto-creates the Underwriting child. */
    private static Opportunity dealWithUnderwriting() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        insert o;
        return o;
    }

    private static Underwriting__c underwritingFor(Id dealId) {
        return [SELECT Id, Opportunity__c FROM Underwriting__c WHERE Opportunity__c = :dealId LIMIT 1];
    }

    private static UnderwritingApprovalStampService.Request request(Id underwritingId) {
        UnderwritingApprovalStampService.Request r = new UnderwritingApprovalStampService.Request();
        r.underwritingId = underwritingId;
        return r;
    }

    /**
     * 🔴 Requirement (iii), and the strongest test in this change: both mirror fields land in ONE
     * save, and THE MARKET-DATA FREEZE ACTUALLY FIRES AS A RESULT.
     *
     * The freeze is the whole reason the single-save rule exists. flows/Opportunity_UW_Approved_Notify
     * has doesRequireRecordChangedToMeetCriteria = true and an entry filter of
     * Underwriting_Status__c = 'Approved by Principals', so it fires only on the TRANSITION into
     * that value. MarketDataSnapshotService then stamps Market_Data_As_Of_Date__c — which makes
     * that field a direct, observable receipt that the transition was seen.
     *
     * ⚠ Asserting the receipt is far stronger than asserting field values. A refactor that wrote
     * the status twice (or wrote it on a save where it was already set) leaves every value
     * assertion in this file green while the freeze silently never runs. Only this test notices.
     *
     * ⚠ AND IT MEANS THE APEX SUITE *DOES* COVER THE FREEZE PATH. The design pack assumed it could
     * not (MarketDataSnapshotServiceTest calls the service directly and never drives an approval),
     * so post-deploy check P-4 was to be the only proof. P-4 is STILL REQUIRED — it verifies the
     * snapshot BODY against a real Property__c with real market data, and it verifies the approver
     * identity, neither of which a test fixture establishes — but the transition mechanics are
     * pinned here.
     */
    @isTest
    static void stampsBothMirrorFieldsInOneSaveAndFiresTheMarketDataFreeze() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c uw = underwritingFor(deal.Id);

        Assert.isNull(
            [SELECT Market_Data_As_Of_Date__c FROM Opportunity WHERE Id = :deal.Id]
                .Market_Data_As_Of_Date__c,
            'Fixture precondition: the freeze must NOT have fired before the stamp, or the '
                + 'assertion below proves nothing');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>{ request(uw.Id) });
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Opportunity stamped = [
            SELECT UW_Approved__c, Underwriting_Status__c,
                   Market_Data_As_Of_Date__c, Market_Data_Snapshot__c
            FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.isTrue(stamped.UW_Approved__c, 'UW_Approved__c is set on the parent deal');
        Assert.areEqual(STATUS_APPROVED, stamped.Underwriting_Status__c,
            'Underwriting_Status__c is set on the parent deal — this is the freeze trigger');

        // 🔴 THE RECEIPT.
        Assert.areEqual(Date.today(), stamped.Market_Data_As_Of_Date__c,
            'The market-data freeze must fire on the stamp\'s save. A null here means the '
                + 'transition into ' + STATUS_APPROVED + ' was not visible as a single change.');
        Assert.isNotNull(stamped.Market_Data_Snapshot__c,
            'The freeze always writes a snapshot body, even when it has nothing to snapshot');

        // ⚠ MEASURED BUDGET, NOT A PURE COUNT OF THIS SERVICE'S OWN DML. Limits.getDmlStatements()
        // counts the WHOLE transaction, so the downstream automation this save deliberately
        // triggers is included. The two are:
        //     1. UnderwritingApprovalStampService's own Database.update on the deal;
        //     2. MarketDataSnapshotService's write-back of the snapshot, via the freeze flow.
        // Splitting statement 1 into two saves makes this 3 and reds the test — which is the
        // tripwire this assertion exists to be. If unrelated automation legitimately changes the
        // budget, RE-MEASURE and update this number and comment; do not delete the assertion.
        Assert.areEqual(2, dmlUsed,
            'Expected exactly two saves: the parent stamp, plus the market-data freeze it fires. '
                + 'A third means the stamp was split across multiple updates.');
    }

    /**
     * The bulk-safety proof that stands in for a 251-record run (see the class header).
     *
     * ⚠ IT ASSERTS FLATNESS, NOT AN ABSOLUTE COUNT, AND THAT IS THE WHOLE DESIGN. An earlier
     * revision asserted "exactly one query / one DML" and failed at 4 and 2 — not because the
     * service loops, but because Limits counters are transaction-wide and the parent save fires
     * the market-data freeze and the Opportunity triggers. Any absolute number here would be a
     * measurement of unrelated automation, and would red every time that automation changed.
     *
     * So the test calibrates itself: it stamps ONE deal, measures, then stamps FIVE OTHER deals
     * and measures again. A bulk-safe implementation spends the same amount both times, because
     * its cost is per-BATCH. An implementation that queries or updates per record spends four more
     * on the second call. The deals are disjoint and none has been stamped before, so both calls
     * are genuine first-time transitions and the downstream cascade is directly comparable.
     */
    @isTest
    static void perRecordCostDoesNotGrowWithBatchSize() {
        List<Opportunity> deals = new List<Opportunity>();
        for (Integer i = 0; i < 6; i++) {
            Opportunity o = TestDataFactory.createOpportunity(null, false);
            o.StageName = 'Underwriting';
            deals.add(o);
        }
        insert deals;

        Set<Id> dealIds = new Map<Id, Opportunity>(deals).keySet();
        Map<Id, Id> underwritingByDeal = new Map<Id, Id>();
        for (Underwriting__c uw : [
            SELECT Id, Opportunity__c FROM Underwriting__c WHERE Opportunity__c IN :dealIds
        ]) {
            underwritingByDeal.put(uw.Opportunity__c, uw.Id);
        }
        Assert.areEqual(6, underwritingByDeal.size(),
            'Fixture precondition: six underwriting children, one per deal');

        List<UnderwritingApprovalStampService.Request> single =
            new List<UnderwritingApprovalStampService.Request>{
                request(underwritingByDeal.get(deals[0].Id))
            };
        List<UnderwritingApprovalStampService.Request> batchOfFive =
            new List<UnderwritingApprovalStampService.Request>();
        for (Integer i = 1; i < 6; i++) {
            batchOfFive.add(request(underwritingByDeal.get(deals[i].Id)));
        }

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        UnderwritingApprovalStampService.stampParent(single);
        Integer soqlForOne = Limits.getQueries() - soqlBefore;
        Integer dmlForOne = Limits.getDmlStatements() - dmlBefore;

        soqlBefore = Limits.getQueries();
        dmlBefore = Limits.getDmlStatements();
        UnderwritingApprovalStampService.stampParent(batchOfFive);
        Integer soqlForFive = Limits.getQueries() - soqlBefore;
        Integer dmlForFive = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(soqlForOne, soqlForFive,
            'Five deals must cost the same number of queries as one (' + soqlForOne + '). '
                + 'A larger number for the batch is SOQL in a loop.');
        Assert.areEqual(dmlForOne, dmlForFive,
            'Five deals must cost the same number of DML statements as one (' + dmlForOne + '). '
                + 'A larger number for the batch is DML in a loop.');

        Assert.areEqual(6, [
            SELECT COUNT() FROM Opportunity
            WHERE Id IN :dealIds AND UW_Approved__c = true
                  AND Underwriting_Status__c = :STATUS_APPROVED
        ], 'Every deal across both calls is stamped');
    }

    /**
     * Two underwritings on ONE deal must not put the same row in an update list twice
     * (DUPLICATE_VALUE / "Duplicate id in list"), which is what a naive List accumulator does.
     */
    @isTest
    static void twoUnderwritingsOnOneDealCollapseToASingleUpdateShell() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c first = underwritingFor(deal.Id);
        Underwriting__c second = new Underwriting__c(
            Opportunity__c = deal.Id, Stage__c = 'Requested');
        insert second;

        Test.startTest();
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>{
                request(first.Id), request(second.Id)
            });
        Test.stopTest();

        Assert.areEqual(STATUS_APPROVED,
            [SELECT Underwriting_Status__c FROM Opportunity WHERE Id = :deal.Id]
                .Underwriting_Status__c,
            'Two underwritings on one deal stamp it once, without a duplicate-id DML failure');
    }

    /**
     * An underwriting with no parent is a LEGAL state — Opportunity__c is a Lookup with
     * deleteConstraint SetNull — so it must be skipped, not thrown on. A throw here would abort
     * the whole batch, and (because this runs from an after-save flow) the approval save with it.
     */
    @isTest
    static void orphanUnderwritingIsSkippedNotThrown() {
        Underwriting__c orphan = new Underwriting__c(Stage__c = 'Requested');
        insert orphan;

        Test.startTest();
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>{ request(orphan.Id) });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE UW_Approved__c = true],
            'An underwriting with no parent stamps nothing and raises nothing');
    }

    /**
     * A mixed batch must not be all-or-nothing on the SELECTION side: one orphan must not stop
     * the valid rows in the same invocation from being stamped.
     */
    @isTest
    static void aValidRequestIsStampedEvenWhenBatchedWithAnOrphan() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c uw = underwritingFor(deal.Id);
        Underwriting__c orphan = new Underwriting__c(Stage__c = 'Requested');
        insert orphan;

        Test.startTest();
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>{ request(orphan.Id), request(uw.Id) });
        Test.stopTest();

        Assert.isTrue([SELECT UW_Approved__c FROM Opportunity WHERE Id = :deal.Id].UW_Approved__c,
            'The valid underwriting in a mixed batch is still stamped');
    }

    /**
     * Degenerate inputs. A Flow can hand over an empty collection, and a Request whose
     * underwritingId was never set arrives with a null member despite required=true (required is
     * a design-time affordance in the Flow builder, not a runtime guarantee for an Apex caller).
     */
    @isTest
    static void nullEmptyAndBlankRequestsDoNothing() {
        Test.startTest();
        UnderwritingApprovalStampService.stampParent(null);
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>());
        UnderwritingApprovalStampService.stampParent(
            new List<UnderwritingApprovalStampService.Request>{
                null, new UnderwritingApprovalStampService.Request()
            });
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dmlUsed, 'Degenerate input performs no DML at all');
    }

    /**
     * Idempotence. Re-running the stamp writes the same two values rather than failing or
     * flipping anything back — this matters because a flow can legitimately re-fire.
     */
    @isTest
    static void reStampingIsIdempotent() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c uw = underwritingFor(deal.Id);
        List<UnderwritingApprovalStampService.Request> requests =
            new List<UnderwritingApprovalStampService.Request>{ request(uw.Id) };

        Test.startTest();
        UnderwritingApprovalStampService.stampParent(requests);
        UnderwritingApprovalStampService.stampParent(requests);
        Test.stopTest();

        Opportunity stamped = [
            SELECT UW_Approved__c, Underwriting_Status__c FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.isTrue(stamped.UW_Approved__c, 'Re-stamping leaves UW_Approved__c true');
        Assert.areEqual(STATUS_APPROVED, stamped.Underwriting_Status__c,
            'Re-stamping leaves the status at ' + STATUS_APPROVED);
    }
}
