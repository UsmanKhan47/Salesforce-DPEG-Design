/**
 * Test class for BrokerLeaderboardService — the live broker leaderboard computed from the
 * Competing_Broker_Submission__c ledger (FSD §27.3 / §27.4, tranche 3 item 2).
 *
 * ═══ WHY THE FIXTURES ARE BUILT UNSAVED AND THEN MUTATED ═══
 * `TestDataFactory.createCompetingBrokerSubmissions` mints a UNIQUE broker email per row
 * and flags only index 0 as the winner — correct for its original callers, and the exact
 * opposite of what a leaderboard needs, which is SEVERAL rows sharing ONE address with a
 * caller-chosen win pattern. Every test below therefore asks the factory for unsaved rows
 * (`doInsert = false`), sets the two fields under test, and inserts once. That keeps the
 * org-wide factory as the single source of the object's shape (ARCHITECTURE.md §2) without
 * adding an overload to a heavily-shared file.
 *
 * ═══ BULK SCOPE (.claude/rules/bulk-test-rule.md) ═══
 * `BrokerLeaderboardService` performs ZERO DML and is not a trigger, batch or queueable, so
 * the 251-record mandate's stated purposes (forcing a second trigger chunk; exposing
 * SOQL/DML in a loop) do not apply literally. A 251-row test is included ANYWAY, because
 * the property that actually matters here is arithmetic rather than chunking: the pair of
 * aggregates must stay **2 SOQL regardless of how many brokers exist**, and the only way a
 * future change breaks that is by adding a per-broker read. See
 * `leaderboard_at251Submissions_stillCostsExactlyTwoQueries`.
 * ⚠ `.claude/rules/content-publication-rule.md` does NOT apply — nothing here writes
 * ContentVersion / ContentNote.
 *
 * ⚠ GOVERNOR ASSERTIONS ARE COMPUTED INSIDE THE Test.startTest()/stopTest() BLOCK. Reading
 * `Limits.getQueries()` after `stopTest()` is silently vacuous — stopTest restores the
 * pre-test counters — which is the trap `ExtractAddressQueueableTest`'s header records.
 */
@isTest
private class BrokerLeaderboardServiceTest {

    private static final String BUSY = 'busy.broker@example.invalid';
    private static final String QUIET = 'quiet.broker@example.invalid';

    /**
     * Insert `count` submissions from one address against one winning Lead, flagging the
     * first `wins` of them as winning submissions.
     *
     * @param winningLeadId The winner anchor (an OPEN Lead).
     * @param brokerEmail   The address every row shares — the leaderboard's identity key.
     * @param brokerName    Broker_Name__c for every row.
     * @param count         How many submissions.
     * @param wins          How many of them are winning submissions (0 <= wins <= count).
     * @return The inserted rows.
     */
    private static List<Competing_Broker_Submission__c> submissions(
            Id winningLeadId, String brokerEmail, String brokerName, Integer count, Integer wins) {
        List<Competing_Broker_Submission__c> rows =
            TestDataFactory.createCompetingBrokerSubmissions(count, winningLeadId, false);
        stamp(rows, brokerEmail, brokerName, wins);
        insert rows;
        return rows;
    }

    /** The same, anchored on a CONVERTED winner's Opportunity instead of a Lead. */
    private static List<Competing_Broker_Submission__c> submissionsOnOpportunity(
            Id winningOpportunityId, String brokerEmail, String brokerName, Integer count, Integer wins) {
        List<Competing_Broker_Submission__c> rows =
            TestDataFactory.createCompetingBrokerSubmissions(count, null, winningOpportunityId, false);
        stamp(rows, brokerEmail, brokerName, wins);
        insert rows;
        return rows;
    }

    private static void stamp(List<Competing_Broker_Submission__c> rows, String brokerEmail,
                              String brokerName, Integer wins) {
        for (Integer i = 0; i < rows.size(); i++) {
            rows[i].Broker_Email__c = brokerEmail;
            rows[i].Broker_Name__c = brokerName;
            rows[i].Is_Winning_Submission__c = (i < wins);
            // Ascending by index, so MIN/MAX(Submitted_DateTime__c) are distinguishable and
            // "first submission" cannot accidentally equal "last submission".
            rows[i].Submitted_DateTime__c = Datetime.now().addDays(-100 + i);
        }
    }

    private static Id leadId() {
        return TestDataFactory.createLead(true).Id;
    }

    private static Map<String, BrokerLeaderboardService.BrokerRow> byEmail(
            List<BrokerLeaderboardService.BrokerRow> rows) {
        Map<String, BrokerLeaderboardService.BrokerRow> indexed =
            new Map<String, BrokerLeaderboardService.BrokerRow>();
        for (BrokerLeaderboardService.BrokerRow row : rows) {
            indexed.put(row.brokerEmail, row);
        }
        return indexed;
    }

    // ── ranking ──────────────────────────────────────────────────────────────

    @isTest
    static void leaderboard_ranksBrokersBySubmissionVolumeBusiestFirst() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Busy Broker', 5, 3);
        submissions(winner, QUIET, 'Quiet Broker', 2, 0);

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard(10);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'One row per distinct broker address');
        Assert.areEqual(BUSY, rows[0].brokerEmail, 'The busiest broker must rank first');
        Assert.areEqual(1, rows[0].rank, 'Rank is 1-based and decided server-side');
        Assert.areEqual(5, rows[0].submissions, 'Submissions counts EVERY inbound row, winning and losing');
        Assert.areEqual(QUIET, rows[1].brokerEmail, 'The quieter broker follows');
        Assert.areEqual(2, rows[1].rank, 'Ranks must be consecutive');
    }

    @isTest
    static void leaderboard_countsWinsSeparatelyAndDefaultsAbsentBrokersToZero() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Busy Broker', 4, 1);
        submissions(winner, QUIET, 'Quiet Broker', 3, 0);

        Test.startTest();
        Map<String, BrokerLeaderboardService.BrokerRow> rows =
            byEmail(BrokerLeaderboardService.leaderboard(10));
        Test.stopTest();

        Assert.areEqual(1, rows.get(BUSY).propertiesWon, 'Only Is_Winning_Submission__c rows count as wins');
        // A broker with no win is ABSENT from the second aggregate entirely, so the merge
        // must default rather than assume a row per input. Dropping that default would
        // produce a null here and an exception in the win-rate divide.
        Assert.areEqual(0, rows.get(QUIET).propertiesWon,
            'A broker who has never won must read 0, not null — they are simply absent from aggregate B');
        // Decimal assertions use `==` rather than Assert.areEqual: Apex Object equality is
        // scale-sensitive, so comparing an Integer literal to a scale-1 Decimal fails on a
        // value that is numerically correct.
        Assert.isTrue(rows.get(QUIET).winRatePct == 0,
            'A winless broker has a 0% win rate, was ' + rows.get(QUIET).winRatePct);
    }

    @isTest
    static void leaderboard_winRateIsThePercentageOfSubmissionsThatWon() {
        submissions(leadId(), BUSY, 'Busy Broker', 4, 1);

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard(10);
        Test.stopTest();

        Assert.isTrue(rows[0].winRatePct == 25, '1 win of 4 submissions is 25%, was ' + rows[0].winRatePct);
    }

    @isTest
    static void winRate_roundsToOneDecimalPlaceAndNeverDividesByZero() {
        Test.startTest();
        Decimal twoThirds = BrokerLeaderboardService.winRate(8, 12);
        Decimal zeroSubmissions = BrokerLeaderboardService.winRate(3, 0);
        Decimal nullSubmissions = BrokerLeaderboardService.winRate(3, null);
        Decimal nullWins = BrokerLeaderboardService.winRate(null, 4);
        Test.stopTest();

        // `==` rather than Assert.areEqual throughout: Apex Object equality on Decimal is
        // scale-sensitive, so a numerically correct answer can fail an areEqual against an
        // Integer literal. `==` compares the value, which is what these tests are about.
        Assert.isTrue(twoThirds == 66.7,
            '8/12 must round to one decimal place, not truncate or run long; was ' + twoThirds);
        // GROUP BY cannot produce a zero-count row, so these guards are for a future
        // hand-built caller. They must degrade to 0, never throw on a reporting surface.
        Assert.isTrue(zeroSubmissions == 0, 'Zero submissions must yield 0%, not a divide-by-zero');
        Assert.isTrue(nullSubmissions == 0, 'Null submissions must yield 0%');
        Assert.isTrue(nullWins == 0, 'Null wins must be treated as none');
    }

    // ── FSD §27.4: First Submission Date ─────────────────────────────────────

    @isTest
    static void leaderboard_firstSubmissionIsTheEarliestAndLastIsTheLatest() {
        submissions(leadId(), BUSY, 'Busy Broker', 3, 0);
        List<Competing_Broker_Submission__c> stored = [
            SELECT Submitted_DateTime__c FROM Competing_Broker_Submission__c
            WHERE Broker_Email__c = :BUSY ORDER BY Submitted_DateTime__c ASC
        ];

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard(10);
        Test.stopTest();

        // §27.4's "First Submission Date" in full — no Contact field, no writer, no backfill.
        Assert.areEqual(stored[0].Submitted_DateTime__c, rows[0].firstSubmitted,
            'First Submission must be MIN(Submitted_DateTime__c) — the EARLIEST row');
        Assert.areEqual(stored[2].Submitted_DateTime__c, rows[0].lastSubmitted,
            'Last Submission must be MAX(Submitted_DateTime__c) — and must differ from the first');
    }

    // ── the split winner anchor ──────────────────────────────────────────────

    /**
     * 🔴 THE SPLIT-ANCHOR TEST. A submission written after the winning Lead was CONVERTED
     * carries `Winning_Opportunity__c` with BOTH Lead lookups null. Any read that filters on
     * `Winning_Lead__c` alone is blind to those rows — a recorded, live gap on
     * `CompetingBrokerSubmissionSelector.selectByWinningLead`.
     *
     * The leaderboard is immune because it groups on `Broker_Email__c` and reads NEITHER
     * anchor. This test is what keeps that true: it goes red the moment someone adds an
     * anchor filter to either aggregate, which is the natural first step toward a
     * drill-through column.
     */
    @isTest
    static void leaderboard_countsRowsAnchoredOnAConvertedWinnersOpportunity() {
        Id winner = leadId();
        Opportunity deal = TestDataFactory.createOpportunities(1, true)[0];
        submissions(winner, BUSY, 'Busy Broker', 2, 1);
        submissionsOnOpportunity(deal.Id, BUSY, 'Busy Broker', 3, 2);

        Test.startTest();
        Map<String, BrokerLeaderboardService.BrokerRow> rows =
            byEmail(BrokerLeaderboardService.leaderboard(10));
        Test.stopTest();

        Assert.areEqual(5, rows.get(BUSY).submissions,
            'Opportunity-anchored rows must be counted like any other — the leaderboard reads no anchor at all');
        Assert.areEqual(3, rows.get(BUSY).propertiesWon,
            'Wins on a converted winner must count too, or the metric under-reports exactly the deals that went furthest');
    }

    // ── identity ─────────────────────────────────────────────────────────────

    @isTest
    static void leaderboard_severalNameSpellingsOnOneAddressStillProduceOneRow() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Jane Broker', 2, 1);
        submissions(winner, BUSY, 'J. Broker', 2, 0);
        submissions(winner, BUSY, 'Jane R Broker', 1, 0);

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard(10);
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'The identity key is the EMAIL, so several name spellings are one broker, not three');
        Assert.areEqual(5, rows[0].submissions, 'All five submissions belong to that one broker');
        // MAX(Broker_Name__c) is deterministic-ARBITRARY, not "the latest" — the label is a
        // display hint. Asserting the exact winner would encode a promise the query does not
        // make; asserting membership pins the real contract.
        Assert.isTrue(
            new Set<String>{ 'Jane Broker', 'J. Broker', 'Jane R Broker' }.contains(rows[0].brokerName),
            'The displayed name must be one of the spellings actually used, but which one is arbitrary');
    }

    @isTest
    static void leaderboard_excludesSubmissionsWithNoBrokerEmail() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Busy Broker', 2, 1);
        List<Competing_Broker_Submission__c> anonymous =
            TestDataFactory.createCompetingBrokerSubmissions(2, winner, false);
        for (Competing_Broker_Submission__c row : anonymous) {
            row.Broker_Email__c = null;
        }
        insert anonymous;

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard(10);
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'A submission with no broker address has no identity to rank, so it cannot become a leaderboard row');
        Assert.areEqual(2, rows[0].submissions, 'The address-less rows must not inflate a real broker\'s count either');
    }

    // ── bounds ───────────────────────────────────────────────────────────────

    @isTest
    static void leaderboard_respectsMaxRowsAndClampsAtTheCeiling() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Busy Broker', 3, 0);
        submissions(winner, QUIET, 'Quiet Broker', 2, 0);

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> capped = BrokerLeaderboardService.leaderboard(1);
        List<BrokerLeaderboardService.BrokerRow> clamped =
            BrokerLeaderboardService.leaderboard(BrokerLeaderboardService.MAX_ROWS_CEILING + 5000);
        Test.stopTest();

        Assert.areEqual(1, capped.size(), 'maxRows must bound the result');
        Assert.areEqual(BUSY, capped[0].brokerEmail,
            'With a LIMIT, the ORDER BY decides WHICH brokers appear at all — the busiest must survive the cut');
        Assert.areEqual(2, clamped.size(),
            'Clamping to MAX_ROWS_CEILING must not lose rows that legitimately exist below the ceiling');
    }

    @isTest
    static void leaderboard_nullOrNonPositiveMaxRows_returnsEmptyWithoutQuerying() {
        submissions(leadId(), BUSY, 'Busy Broker', 2, 1);

        Test.startTest();
        Integer before = Limits.getQueries();
        List<BrokerLeaderboardService.BrokerRow> nullRows = BrokerLeaderboardService.leaderboard(null);
        List<BrokerLeaderboardService.BrokerRow> zeroRows = BrokerLeaderboardService.leaderboard(0);
        List<BrokerLeaderboardService.BrokerRow> negativeRows = BrokerLeaderboardService.leaderboard(-5);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isTrue(nullRows.isEmpty(), 'A caller that cannot say how many rows it wants gets none');
        Assert.isTrue(zeroRows.isEmpty(), 'Zero rows requested means zero rows returned');
        Assert.isTrue(negativeRows.isEmpty(), 'A negative depth is not an unbounded read');
        Assert.areEqual(0, used, 'A short-circuited call must not issue an aggregate at all');
    }

    @isTest
    static void leaderboard_emptyLedger_returnsEmptyListNotNull() {
        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard();
        Test.stopTest();

        Assert.isNotNull(rows, 'An empty ledger is normal on a fresh org, not an error');
        Assert.isTrue(rows.isEmpty(), 'No submissions means no leaderboard rows');
    }

    @isTest
    static void leaderboard_noArgOverload_usesTheDefaultDepth() {
        Id winner = leadId();
        submissions(winner, BUSY, 'Busy Broker', 2, 1);
        submissions(winner, QUIET, 'Quiet Broker', 1, 0);

        Test.startTest();
        List<BrokerLeaderboardService.BrokerRow> rows = BrokerLeaderboardService.leaderboard();
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'The no-arg overload must delegate to DEFAULT_MAX_ROWS ('
            + BrokerLeaderboardService.DEFAULT_MAX_ROWS + '), which comfortably covers two brokers');
    }

    // ── governor budget ──────────────────────────────────────────────────────

    /**
     * 🔴 THE BUDGET PIN — the highest-value test in this class.
     *
     * The whole design rests on "2 SOQL, constant in broker count". The obvious future
     * change that breaks it is a per-broker read (a Contact lookup, a deal-outcome hop, a
     * "better name" query), which would work perfectly at three brokers and exhaust the SOQL
     * limit in production. 251 distinct brokers makes that failure a red build instead.
     */
    @isTest
    static void leaderboard_at251Submissions_stillCostsExactlyTwoQueries() {
        Id winner = leadId();
        List<Competing_Broker_Submission__c> rows =
            TestDataFactory.createCompetingBrokerSubmissions(251, winner, false);
        for (Integer i = 0; i < rows.size(); i++) {
            // A DISTINCT address per row, so aggregate A genuinely produces 251 groups.
            rows[i].Broker_Email__c = 'broker' + i + '@example.invalid';
            rows[i].Is_Winning_Submission__c = (Math.mod(i, 2) == 0);
        }
        insert rows;

        Test.startTest();
        Integer before = Limits.getQueries();
        List<BrokerLeaderboardService.BrokerRow> board =
            BrokerLeaderboardService.leaderboard(BrokerLeaderboardService.MAX_ROWS_CEILING);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(2, used,
            'The leaderboard must cost exactly two aggregates regardless of broker count — a per-broker read here '
            + 'would pass at three brokers and exhaust SOQL in production');
        Assert.areEqual(BrokerLeaderboardService.MAX_ROWS_CEILING, board.size(),
            '251 brokers requested at the ceiling must return exactly the ceiling');
        for (BrokerLeaderboardService.BrokerRow row : board) {
            Assert.areEqual(1, row.submissions, 'Each fixture broker submitted exactly once');
            Assert.isNotNull(row.winRatePct, 'Every row must carry a win rate, including the winless ones');
        }
    }
}
