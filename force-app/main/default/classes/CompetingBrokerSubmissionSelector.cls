/**
 * Selector for Competing_Broker_Submission__c. Encapsulates ALL SOQL against
 * Competing_Broker_Submission__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * Broker Protection module (CHUNK 1). Competing_Broker_Submission__c is the
 * append-only log of every broker who submitted the same property: the first
 * becomes the Winning_Lead__c (Is_Winning_Submission__c = true) and later brokers
 * are recorded as competing submissions against that same winner. Consumers land in
 * CHUNK 2/3.
 *
 * MODE — every query uses `WITH USER_MODE` (API 67), the two 2026-08-17 aggregates
 * included. Competing_Broker_Submission__c is a custom object; P3 proved the custom-field
 * FLS gap is 0, so USER_MODE is safe and enforces the running user's sharing + FLS. No
 * guest path — no SYSTEM_MODE here, and none of ARCHITECTURE.md §2's automation-path
 * exception applies: every read on this class backs something a human explicitly asked
 * for.
 *
 * SIGNATURE CONTRACT — the public methods are STATIC, matching the repo selector norm
 * (BovSubmissionSelector, CounterOfferSelector, ContactSelector, LeadSelector all
 * expose `public static` query methods). The original two keep the exact signatures the
 * Broker-Protection chunk plan fixed; CHUNK 2/3 bind to them by name
 * (`CompetingBrokerSubmissionSelector.selectByWinningLead(...)`). Do not rename or
 * change their parameters/return types — the 2026-08-17 leaderboard aggregates were
 * ADDED alongside them, never retrofitted onto one.
 *
 * NOT-FOUND CONTRACT — read-for-display: a winning lead with no competing
 * submissions is normal, so this returns its natural empty List, never null.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see PropertyRegistrySelector.cls (sibling Broker-Protection selector)
 */
public with sharing class CompetingBrokerSubmissionSelector {

    /**
     * All submissions tied to one winning lead, oldest first — backs the
     * competing-broker timeline for a claimed property. ORDER BY
     * Submitted_DateTime__c ASC puts the earliest (winning) submission at the top so
     * the timeline reads in chronological order.
     *
     * ⚠ LEAD-ANCHORED ROWS ONLY, AND THAT IS A KNOWN, REPORTED GAP (2026-08-03) — NOT AN
     * OVERSIGHT, AND DELIBERATELY NOT WIDENED HERE. Since the winner-anchor change, a submission
     * written after the winning Lead was converted carries `Winning_Opportunity__c` and a NULL
     * `Winning_Lead__c`, so it is invisible to this method. The consequence is UI-side: a
     * converted winner's competing-broker trail stops growing on the Lead-page component, and
     * post-conversion rows have no read path at all until the timeline is given an Opportunity
     * surface. Closing it is NOT a one-line widen — `selectByWinningLead(Id)` takes a Lead Id
     * from a Lead record page, and a converted Lead's page is unreachable (it redirects), so the
     * fix is a sibling `selectByWinningOpportunity`, a controller method, and placing the
     * component on the Opportunity flexipage. Filed separately; do not bolt an OR onto this
     * method and call it done, because nothing would then be passing an Opportunity Id.
     *
     * @param leadId Winning_Lead__c Id whose submissions to read; null returns an
     *               empty list.
     * @return Competing_Broker_Submission__c rows (Id, Broker_Name__c,
     *         Broker_Email__c, Forwarded_By_Email__c, Property_Address_Raw__c,
     *         Submitted_DateTime__c, Is_Winning_Submission__c) for that winning lead,
     *         ordered by Submitted_DateTime__c ASC; empty when `leadId` is null or
     *         there are none.
     * @example
     * List<Competing_Broker_Submission__c> subs =
     *     CompetingBrokerSubmissionSelector.selectByWinningLead(leadId);
     */
    public static List<Competing_Broker_Submission__c> selectByWinningLead(Id leadId) {
        if (leadId == null) {
            return new List<Competing_Broker_Submission__c>();
        }
        return [
            SELECT Id, Broker_Name__c, Broker_Email__c, Forwarded_By_Email__c,
                   Property_Address_Raw__c, Submitted_DateTime__c,
                   Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :leadId
            WITH USER_MODE
            ORDER BY Submitted_DateTime__c ASC
        ];
    }

    /**
     * Recent submissions made by one broker — backs REPEAT detection
     * (PropertyMatchingService.findBrokerSubmission), which asks "has this same broker
     * already submitted this same property?" so a follow-up email is filed on the record the
     * broker's EARLIER email already produced instead of creating a second Lead.
     *
     * WHICH record that is depends on the broker, and the caller decides it from the two Lead
     * lookups on the rows returned here: the property's WINNER threads onto their own Lead
     * (`Source_Lead__c`), while a COMPETING broker — who since 2026-07-31 receives no Lead at
     * all — threads onto `Winning_Lead__c`. Both shapes are returned; see the NULL-SOURCE
     * paragraph below.
     *
     * NO PROPERTY FILTER IN SOQL — DELIBERATE, AND NOT AN OVERSIGHT.
     * Competing_Broker_Submission__c stores only Property_Address_Raw__c (the address as
     * the broker wrote it); it has no normalized Property_Key__c column — that field
     * exists on Property_Registry__c, not here. Filtering `Property_Address_Raw__c = :key`
     * would therefore compare a normalized key against raw text and miss every real match
     * ('100 Main St.' vs '100 main st'). The caller normalizes each row's raw address in
     * memory and applies the same exact-then-Jaccard comparison used everywhere else in
     * the module, which additionally gives repeat detection the SAME fuzzy tolerance as
     * the claim path for free. The recency window plus LIMIT 200 keep that in-memory scan
     * bounded.
     *
     * BROKER MATCH IS TWO-SIDED: `Broker_Email__c = :brokerEmail` is the current shape,
     * and `Source_Lead__r.Email = :brokerEmail` covers submissions written before
     * Broker_Email__c was populated (it is nullable, and older rows left it blank), where
     * the broker's address survives only on the Lead. SOQL `=` on text is
     * case-insensitive, so no address casing normalization is needed here.
     *
     * NULL-SOURCE ROWS ARE INCLUDED, NULL-WINNER ROWS ARE NOT. This is one filter swapped for
     * another on 2026-07-31, and the asymmetry is the whole point.
     *
     * `Source_Lead__c != null` was REMOVED. It was justified as "the caller's whole purpose is
     * to reuse that Lead, so a submission without one is unusable", and that justification
     * expired: a COMPETING broker no longer receives a Lead at all, so every competing
     * submission now legitimately carries a null Source_Lead__c. Keeping the filter would make
     * a competing broker's follow-up email invisible to repeat detection, and the pipeline
     * would treat each of their re-sends as a brand-new competing claim forever.
     *
     * `Winning_Lead__c != null` was ADDED in its place, and it is NOT cosmetic — it restores an
     * invariant the old filter had been enforcing by accident. BOTH Lead lookups on this object
     * are `deleteConstraint=SetNull`, so deleting or merging the winner's Lead leaves rows with
     * BOTH lookups null. Such a row satisfies no caller: the repeat branch would call
     * logRepeatSubmission(null, null, ...), whose insert then trips the Winning_Lead_Required
     * validation rule, and the DmlException kills the email — Status 'Error', no Lead, no Task.
     * Worse, it would ALSO defeat the module's orphan-adoption path: with the row filtered out
     * the email correctly falls through to branch (e), where registerWinner adopts the orphaned
     * registry key. So this filter is what keeps a deleted-winner property re-claimable rather
     * than permanently poisoned.
     *
     * ═══ 🔴 THE FILTER IS NOW ANCHOR-AGNOSTIC (2026-08-03) — DO NOT NARROW IT BACK ═══
     * It reads `(Winning_Lead__c != null OR Winning_Opportunity__c != null)`. A submission written
     * after the winning Lead was CONVERTED anchors on `Winning_Opportunity__c` instead, because
     * the platform rejects a lookup SET to a converted Lead (see
     * PropertyClaimService's WINNER ANCHOR note). Restoring `Winning_Lead__c != null` alone would
     * compile, deploy and pass every existing test while silently breaking arbitration: once a
     * property's winner converts, that broker's own follow-ups stop matching as REPEATS, fall
     * through to branch (d), and the WINNING broker is recorded as a COMPETING broker against
     * themselves — with no exception, no error row, and nothing in the UI to show for it.
     *
     * THE INVARIANT, RESTATED: every row this method returns carries at least one winner anchor
     * — `Winning_Lead__c` OR `Winning_Opportunity__c`, never both, never neither.
     * `Source_Lead__c` may legitimately be null, and is ALWAYS null on an Opportunity-anchored row.
     *
     * ⚠ CALLERS MUST READ BOTH ANCHORS. `ExtractAddressQueueable`'s repeat branch prefers
     * `Winning_Opportunity__c` when present (it is already a live record and needs no resolve)
     * and falls back to resolving `Winning_Lead__c`. A caller that reads only the Lead gets null
     * and loses the Task target.
     *
     * @param brokerEmail The broker's email address to match; null/blank returns empty.
     * @param cutoff      Inclusive lower bound on Submitted_DateTime__c (the recency
     *                    window); null returns empty.
     * @return Up to 200 submissions by that broker at/after `cutoff`, oldest first (so the
     *         caller's exact-match short-circuit returns the ORIGINAL submission rather
     *         than a later repeat), every one carrying a non-null winner anchor; empty when
     *         nothing matches (never null).
     * @example
     * List<Competing_Broker_Submission__c> prior =
     *     CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(
     *         brokerEmail, Datetime.now().addDays(-90));
     */
    public static List<Competing_Broker_Submission__c> selectRecentByBrokerEmail(
            String brokerEmail, Datetime cutoff) {
        if (String.isBlank(brokerEmail) || cutoff == null) {
            return new List<Competing_Broker_Submission__c>();
        }
        return [
            SELECT Id, Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c, Broker_Name__c,
                   Broker_Email__c, Forwarded_By_Email__c, Property_Address_Raw__c,
                   Submitted_DateTime__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE (Winning_Lead__c != null OR Winning_Opportunity__c != null)
              AND Submitted_DateTime__c >= :cutoff
              AND (Broker_Email__c = :brokerEmail OR Source_Lead__r.Email = :brokerEmail)
            WITH USER_MODE
            ORDER BY Submitted_DateTime__c ASC
            LIMIT 200
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // BROKER LEADERBOARD AGGREGATES (added 2026-08-17, FSD tranche 3 item 2 / §27.3-27.4)
    //
    // 🔴 NEITHER AGGREGATE READS A WINNER ANCHOR, AND THAT IS WHY THE SPLIT-ANCHOR TRAP
    // DOES NOT BITE THE LEADERBOARD. Both GROUP BY `Broker_Email__c` and select neither
    // `Winning_Lead__c` nor `Winning_Opportunity__c`. A converted winner's rows carry the
    // Opportunity anchor and are STILL COUNTED, because the anchor is not in the query at
    // all — whereas `selectByWinningLead` above, which does read one anchor, is blind to
    // exactly those rows (its own documented gap). Read that paragraph before adding a
    // drill-through or a deal-outcome column here: the moment either aggregate needs to
    // reach the winning record, BOTH anchors must be read, and this comment stops being
    // true.
    //
    // ⚠ THE IDENTITY KEY IS AN EMAIL ADDRESS, WITH A KNOWN COLLAPSE. ARCHITECTURE.md
    // records the blast-platform residual as EXPECTED TRAFFIC, not an edge case: a broker
    // submitting through RCM / Crexi / Buildout can arrive with an envelope From of the
    // PLATFORM (`listings@buildout.com`), and intake rule U1 then keys every such broker to
    // that one address. So a leaderboard row may be a PLATFORM, not a person. That is not
    // fixed here and must not be: a name/domain heuristic in a reporting query would be a
    // second, unowned copy of an arbitration rule. ARCHITECTURE's named eventual fix — a
    // platform-sender list that stands U1 down — repairs this surface for free.
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * TOTAL submissions per broker, busiest first — aggregate A of the two-query broker
     * leaderboard. One row per distinct `Broker_Email__c`.
     *
     * Aliases: `brokerEmail`, `brokerName`, `submissionCount`, `firstSubmitted`,
     * `lastSubmitted`.
     *
     * ⚠ `MAX(Broker_Name__c)` IS DETERMINISTIC-ARBITRARY, NOT "THE LATEST". One address can
     * legitimately carry several spellings across emails ("Jane Broker", "Jane R. Broker",
     * "J Broker"), and MAX picks the lexicographic maximum — stable, but not meaningful.
     * The row's IDENTITY is the email; the name is a display hint only. Do NOT add a third
     * query to fetch a "better" name.
     *
     * ✅ `MIN(Submitted_DateTime__c)` IS FSD §27.4's "First Submission Date" IN FULL — no
     * Contact field, no writer, no backfill, no trigger. It falls out of this aggregate for
     * free, which is a large part of why the leaderboard is computed live rather than
     * stored.
     *
     * ORDERING is `COUNT(Id) DESC, Broker_Email__c ASC`. The tie-break is not cosmetic: a
     * leaderboard whose rows reshuffle between two identical reads is unusable, and the
     * `LIMIT` makes an unstable sort decide WHICH brokers appear at all.
     *
     * MODE / SHARING — `WITH USER_MODE` on this `with sharing` class. MODE: this backs a
     * read a human explicitly requested by opening a page, so a permission gap SHOULD throw
     * rather than silently under-report a ranking; ARCHITECTURE.md §2's automation-path
     * exception is for reads performed on a principal's behalf, and this is not one.
     * SHARING (answered separately, per §2's standing warning): `Competing_Broker_Submission__c`
     * is `sharingModel = ReadWrite` (verified in its object-meta.xml), so `with sharing`
     * filters nothing here and a `without sharing` inner class would be an unargued
     * widening. ⚠ If that OWD is ever narrowed to Private, this aggregate does not fail —
     * it returns a CONFIDENT WRONG ANSWER (an under-count that looks like a real ranking),
     * which is the `DispositionOfferSelector.TractionReads` failure shape; the remedy then
     * is a narrow `private without sharing` inner class holding only these two queries.
     *
     * @param maxRows Maximum leaderboard rows to return; null or &lt; 1 returns an empty
     *                list (a caller that cannot say how many rows it wants gets none,
     *                rather than an unbounded aggregate).
     * @return Up to `maxRows` AggregateResult rows, busiest broker first; empty when there
     *         are no submissions carrying a broker email.
     * @example
     * List<AggregateResult> rows =
     *     CompetingBrokerSubmissionSelector.aggregateSubmissionsByBroker(25);
     */
    public static List<AggregateResult> aggregateSubmissionsByBroker(Integer maxRows) {
        if (maxRows == null || maxRows < 1) {
            return new List<AggregateResult>();
        }
        return [
            SELECT Broker_Email__c brokerEmail,
                   MAX(Broker_Name__c) brokerName,
                   COUNT(Id) submissionCount,
                   MIN(Submitted_DateTime__c) firstSubmitted,
                   MAX(Submitted_DateTime__c) lastSubmitted
            FROM Competing_Broker_Submission__c
            WHERE Broker_Email__c != null
            WITH USER_MODE
            GROUP BY Broker_Email__c
            ORDER BY COUNT(Id) DESC, Broker_Email__c ASC
            LIMIT :maxRows
        ];
    }

    /**
     * WINNING submissions per broker, for a named set of broker addresses — aggregate B of
     * the two-query broker leaderboard. Aliases: `brokerEmail`, `wonCount`.
     *
     * ⚠ IT IS SCOPED TO THE ADDRESSES AGGREGATE A ALREADY RETURNED, deliberately. The
     * caller only ever renders A's rows, so an unbounded second aggregate would compute
     * wins for brokers nobody will see and would grow without limit as the ledger does.
     * Binding the set keeps the pair at **2 SOQL, both bounded by the caller's `maxRows`,
     * constant in the number of brokers in the org**.
     *
     * ⚠ "WON" HERE MEANS `Is_Winning_Submission__c` — THE BROKER WON THE PROPERTY CLAIM. It
     * does NOT mean DPEG closed the deal. Deal outcome is a different question needing both
     * winner anchors plus a conversion hop, and it is deliberately not built (design §2.3);
     * do not relabel this column "Deals Won" without building that.
     *
     * MODE / SHARING — identical reasoning to `aggregateSubmissionsByBroker`; see that
     * method.
     *
     * @param brokerEmails The addresses to count wins for (aggregate A's keys); null/empty
     *                     returns an empty list.
     * @return One AggregateResult per address that has at least one winning submission;
     *         addresses with none are simply ABSENT (the caller must default them to 0,
     *         never assume a row per input).
     * @example
     * List<AggregateResult> wins =
     *     CompetingBrokerSubmissionSelector.aggregateWinsByBroker(brokerEmails);
     */
    public static List<AggregateResult> aggregateWinsByBroker(Set<String> brokerEmails) {
        if (brokerEmails == null || brokerEmails.isEmpty()) {
            return new List<AggregateResult>();
        }
        return [
            SELECT Broker_Email__c brokerEmail, COUNT(Id) wonCount
            FROM Competing_Broker_Submission__c
            WHERE Broker_Email__c != null
              AND Broker_Email__c IN :brokerEmails
              AND Is_Winning_Submission__c = true
            WITH USER_MODE
            GROUP BY Broker_Email__c
        ];
    }
}
