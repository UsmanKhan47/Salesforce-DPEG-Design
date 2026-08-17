/**
 * THE BROKER LEADERBOARD — who is actually bringing DPEG deals, ranked by submission
 * volume, with their win rate and their first/last submission dates. Backs
 * `lwc/brokerLeaderboard` through `BrokerLeaderboardController`.
 *
 * FSD §27.3 / §27.4, tranche 3 item 2. **BY BROKER PERSON, NOT BY FIRM** — a user
 * decision, and the identity key is `Competing_Broker_Submission__c.Broker_Email__c`.
 *
 * ═══ 🔴 WHY THIS IS COMPUTED LIVE AND NOT ROLLED UP ONTO Contact ═══
 * This is the decision that shapes the whole feature, and it is structural rather than a
 * preference. Six Number fields already exist on Contact — `Deals_Submitted__c`,
 * `Deals_Won__c`, `Offers_Received__c`, `Active_Listings__c`, `Closed_Volume__c`,
 * `Avg_Days_On_Market__c` — and they look like the natural storage. They are not, for
 * three independent reasons:
 *
 *   1. 🔴 MOST BROKERS IN THE LEDGER HAVE NO CONTACT AND NEVER WILL. Since 2026-07-31 a
 *      COMPETING broker receives no Lead at all, so no conversion, so no Contact, ever.
 *      `Competing_Broker_Submission__c` exists precisely because it is the only record of
 *      those brokers. A Contact-based rollup can therefore only ever describe the subset
 *      that WON and then CONVERTED — i.e. it would silently omit every losing broker,
 *      which is most of the population a leaderboard is about. That is not a trade-off;
 *      it is the metric inverting itself.
 *   2. THE SIX FIELDS ALREADY MEAN SOMETHING ELSE. `Active_Listings__c` /
 *      `Closed_Volume__c` / `Avg_Days_On_Market__c` describe brokers DPEG LISTS WITH — the
 *      disposition-side scorecard `BrokerController` renders on `Broker_Hub` /
 *      `Broker_Scorecard`. Repurposing two of them for inbound submissions would put two
 *      unrelated meanings on one card with no way for a reader to tell which is which.
 *   3. THE PLATFORM CANNOT ROLL UP ACROSS THIS RELATIONSHIP ANYWAY.
 *      `Competing_Broker_Submission__c` has NO Contact lookup — the identity is a Text
 *      email — so there is no roll-up summary to build. Any rollup would be Apex plus a
 *      fuzzy email match (`LeadConvertMatchService`'s job, which matches on Email alone and
 *      fails soft), under which a broker with two addresses becomes ONE SILENTLY
 *      UNDERCOUNTED Contact. Live, they become two visible rows — wrong in a way a human
 *      can see and correct.
 *
 * ⇒ ALL SIX CONTACT FIELDS ARE LEFT EXACTLY AS THEY ARE. This class neither reads nor
 * writes them. (That they are read by `BrokerController` and written by NOTHING — so the
 * Broker Hub renders permanent zeroes for `Deals_Submitted__c` / `Deals_Won__c` today — is
 * a real, separate finding. It is routed around here, not fixed; the fix is either to
 * retire the two submission-flavoured fields or to point that hub at this ledger, and
 * either is its own change.)
 *
 * ═══ 🔴 THE SPLIT WINNER ANCHOR DOES NOT AFFECT THESE COUNTS — AND SAYING SO IS THE POINT ═══
 * `Competing_Broker_Submission__c` names its winner as EITHER `Winning_Lead__c` (winner
 * still open) OR `Winning_Opportunity__c` (winner converted) — exactly one, never both.
 * Reading only the Lead half is a real, recorded defect: it re-files a converted winner's
 * own follow-ups as competing claims against themselves.
 *
 * Both aggregates behind this class read NEITHER anchor. They GROUP BY `Broker_Email__c`,
 * so a converted winner's rows are counted like any other and the trap simply does not
 * arise. ⚠ IT ARISES THE MOMENT SOMEONE ADDS A DRILL-THROUGH OR A DEAL-OUTCOME COLUMN —
 * at which point BOTH anchors must be read, and `CompetingBrokerSubmissionSelector.selectByWinningLead`
 * is Lead-only (ARCHITECTURE.md's named open gap). Recorded here as NOT APPLYING YET rather
 * than left to be rediscovered.
 *
 * ═══ ⚠ THE BLAST-PLATFORM IDENTITY COLLAPSE — DISPLAYED, NOT SUPPRESSED ═══
 * ARCHITECTURE.md records this as EXPECTED TRAFFIC: a broker submitting through RCM /
 * Crexi / Buildout can arrive with an envelope From of the PLATFORM
 * (`listings@buildout.com`), and intake rule U1 keys every such broker to that one
 * address. So the top row of this leaderboard may be a PLATFORM, not a person.
 *
 * It is displayed anyway. Suppressing it would hide real submission volume and make the
 * totals disagree with the ledger they are computed from, and a name/domain heuristic here
 * would be a second, unowned copy of an arbitration rule that lives in
 * `ExtractAddressQueueable`. The component's help text names the shape instead.
 * ARCHITECTURE's named eventual fix for U1 — a platform-sender list — repairs this surface
 * for free the day it lands, with no change to this class.
 *
 * ═══ WHAT IS DELIBERATELY ABSENT ═══
 *   • DEALS WON / LOST BY OPPORTUNITY OUTCOME. Three reasons: it needs both winner
 *     anchors plus a conversion hop through a selector method that does not exist; it needs
 *     `OpportunitySelector`; and "did DPEG close the deal" is a DIFFERENT question from
 *     "did this broker win the property", which `Is_Winning_Submission__c` answers exactly
 *     and with no hop. Attributing a LOST deal to the broker who introduced it is a metric
 *     nobody has defined. Priced separately.
 *   • FIRM-LEVEL GROUPING. The user asked for broker PERSON. `Broker_Name__c` is a display
 *     hint, not a key, and there is no firm field on this object at all.
 *
 * LAYER — Service (read side). Zero SOQL of its own and zero DML: every read goes through
 * `CompetingBrokerSubmissionSelector` per ARCHITECTURE.md §2 and
 * `.claude/rules/apex-layering-rule.md`. `with sharing`, and the sharing question is
 * argued at the selector methods (the object is `sharingModel = ReadWrite`, so nothing is
 * filtered and no `without sharing` inner class is warranted).
 *
 * GOVERNOR BUDGET — **2 SOQL / 0 DML, CONSTANT IN THE NUMBER OF BROKERS IN THE ORG.** Both
 * aggregates are bounded by `maxRows`; the merge is in memory. Pinned by
 * `BrokerLeaderboardServiceTest`.
 *
 * @see CompetingBrokerSubmissionSelector.cls (both aggregates, and the mode/sharing argument)
 * @see BrokerLeaderboardController.cls (the `@AuraEnabled` boundary)
 * @see PropertyClaimService.cls (what writes the ledger this reads)
 */
public with sharing class BrokerLeaderboardService {

    /**
     * Default leaderboard depth. Chosen to fill a dashboard column without paging; the
     * component does not offer a control, so this is the only value in production use.
     * It is a DISPLAY bound, not an arbitration constant — changing it decides nothing.
     */
    public static final Integer DEFAULT_MAX_ROWS = 25;

    /** Hard ceiling on `maxRows`, so a hand-crafted controller call cannot ask for an
     *  unbounded aggregate. Well inside the 2,000-row `AggregateResult` platform cap. */
    public static final Integer MAX_ROWS_CEILING = 200;

    /**
     * One broker's row on the leaderboard. Crosses the `@AuraEnabled` boundary, so every
     * field is a primitive and the ordering decision (`rank`) is made here rather than in
     * JavaScript — two surfaces computing their own ranks is how they end up disagreeing.
     */
    public class BrokerRow {
        /** The identity key. ⚠ May be a blast PLATFORM address rather than a person — see
         *  the class header. Never null: the aggregate excludes null emails. */
        @AuraEnabled public String brokerEmail;

        /** Display hint only — `MAX(Broker_Name__c)`, i.e. deterministic-arbitrary across
         *  the spellings this address has used. May be null. Do not treat it as a key. */
        @AuraEnabled public String brokerName;

        /** 1-based position in the returned list, by submission volume. */
        @AuraEnabled public Integer rank;

        /** Total inbound submissions from this address — winning AND losing. */
        @AuraEnabled public Integer submissions;

        /** Submissions that WON the property claim (`Is_Winning_Submission__c`).
         *  ⚠ NOT "deals DPEG closed" — see the class header. */
        @AuraEnabled public Integer propertiesWon;

        /** `propertiesWon / submissions` as a percentage, one decimal place. Never null:
         *  `submissions` is at least 1 for any row that exists. */
        @AuraEnabled public Decimal winRatePct;

        /** FSD §27.4's "First Submission Date" — `MIN(Submitted_DateTime__c)`. */
        @AuraEnabled public Datetime firstSubmitted;

        /** `MAX(Submitted_DateTime__c)` — how recently this broker was active. */
        @AuraEnabled public Datetime lastSubmitted;
    }

    /**
     * The leaderboard at the default depth.
     *
     * @return Up to `DEFAULT_MAX_ROWS` rows, busiest broker first; empty when the ledger
     *         holds no submission carrying a broker email.
     */
    public static List<BrokerRow> leaderboard() {
        return leaderboard(DEFAULT_MAX_ROWS);
    }

    /**
     * The leaderboard, deepest-first, at a caller-chosen depth.
     *
     * Two aggregates and an in-memory merge — never a query per broker. Aggregate A ranks
     * every distinct `Broker_Email__c` by submission count; aggregate B counts wins for
     * exactly the addresses A returned. A broker with no winning submission is ABSENT from
     * B and is defaulted to zero here, which is why the merge is keyed off A and never off
     * B.
     *
     * ⚠ EMAIL KEYS ARE MATCHED CASE-INSENSITIVELY IN THE MERGE. SOQL `GROUP BY` on a Text
     * field is case-SENSITIVE, so 'Jane@Firm.com' and 'jane@firm.com' arrive as two rows
     * from A and would fail to line up with B's own casing. Lower-casing the merge key
     * cannot merge A's two rows into one (that would require a second pass and would then
     * disagree with the `LIMIT` A already applied), but it does guarantee each row finds
     * its own wins. The residual — one broker appearing twice under two spellings — is
     * visible and correctable by a human, which is the same failure direction the class
     * header argues for throughout.
     *
     * @param maxRows How many rows to return. Null or &lt; 1 yields an empty list; values
     *                above `MAX_ROWS_CEILING` are clamped to it.
     * @return Ranked rows, busiest first, ties broken by email ascending (a stable order
     *         matters because `maxRows` decides which brokers appear at all). Never null.
     * @example
     * List<BrokerLeaderboardService.BrokerRow> rows =
     *     BrokerLeaderboardService.leaderboard(10);
     */
    public static List<BrokerRow> leaderboard(Integer maxRows) {
        List<BrokerRow> rows = new List<BrokerRow>();
        if (maxRows == null || maxRows < 1) {
            return rows;
        }
        Integer effectiveMax = Math.min(maxRows, MAX_ROWS_CEILING);

        List<AggregateResult> totals =
            CompetingBrokerSubmissionSelector.aggregateSubmissionsByBroker(effectiveMax);
        if (totals.isEmpty()) {
            return rows;
        }

        Set<String> emails = new Set<String>();
        for (AggregateResult ar : totals) {
            emails.add((String) ar.get('brokerEmail'));
        }

        Map<String, Integer> winsByEmail = new Map<String, Integer>();
        for (AggregateResult ar : CompetingBrokerSubmissionSelector.aggregateWinsByBroker(emails)) {
            winsByEmail.put(mergeKey((String) ar.get('brokerEmail')), intOf(ar.get('wonCount')));
        }

        Integer rank = 1;
        for (AggregateResult ar : totals) {
            BrokerRow row = new BrokerRow();
            row.brokerEmail = (String) ar.get('brokerEmail');
            row.brokerName = (String) ar.get('brokerName');
            row.rank = rank++;
            row.submissions = intOf(ar.get('submissionCount'));
            Integer won = winsByEmail.get(mergeKey(row.brokerEmail));
            row.propertiesWon = (won == null) ? 0 : won;
            row.winRatePct = winRate(row.propertiesWon, row.submissions);
            row.firstSubmitted = (Datetime) ar.get('firstSubmitted');
            row.lastSubmitted = (Datetime) ar.get('lastSubmitted');
            rows.add(row);
        }
        return rows;
    }

    /**
     * Win rate as a percentage to one decimal place. Guards the divide rather than trusting
     * the aggregate: a zero `submissions` cannot occur for a row `GROUP BY` produced, but a
     * future caller building a row by hand would otherwise get a division-by-zero
     * exception on a reporting surface.
     *
     * ⚠ `Decimal.divide(divisor, scale, roundingMode)` RATHER THAN THE `/` OPERATOR. Bare
     * Decimal division picks its own scale for a non-terminating quotient (2 of 3 wins is
     * 66.666...), so the operator form makes the displayed precision an accident of the
     * inputs. Naming the scale here is what keeps every row on the card formatted alike.
     *
     * @param won         Winning submissions.
     * @param submissions Total submissions.
     * @return 0 when `submissions` is null/0, else `won / submissions * 100` at scale 1.
     */
    @TestVisible
    private static Decimal winRate(Integer won, Integer submissions) {
        if (submissions == null || submissions == 0) {
            return 0;
        }
        Decimal numerator = (won == null) ? 0 : won;
        return (numerator * 100).divide(submissions, 1, System.RoundingMode.HALF_UP);
    }

    /**
     * The case-insensitive key the two aggregates are merged on. See `leaderboard`'s note
     * on why this exists and what it can and cannot fix.
     *
     * @param email A broker address; null returns null.
     * @return The address lower-cased, or null.
     */
    private static String mergeKey(String email) {
        return (email == null) ? null : email.toLowerCase();
    }

    /**
     * `COUNT(Id)` comes back as an Integer-valued Object; this narrows it without assuming
     * the runtime type.
     *
     * @param value The aggregate value.
     * @return The value as an Integer, or 0 when null.
     */
    private static Integer intOf(Object value) {
        return (value == null) ? 0 : Integer.valueOf(value);
    }
}
