/**
 * The Active Listing traction monitor — the single place in this application that decides whether a
 * broker-listed property is getting traction, and the successor to the hardcoded 21/28/42-day
 * ladder that used to live inside `BrokerListingController.getListing`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE CLOCK IS SIX WEEKS, WITH RUNGS AT WEEK 2, WEEK 4 AND WEEK 6
 *    (user decision A2, 2026-09-02 — BA story 30. THIS IS THE FOURTH REVISION
 *     OF THESE THRESHOLDS AND `DPEG-Stage-by-Stage.docx` IS NOW **TWO**
 *     REVISIONS OUT OF DATE.)
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 RETRACTION IN PLACE, NOT A DELETION — TWICE OVER NOW. Every prior version of this block is
 * quoted below rather than overwritten, because each one's reasoning was sound and each was
 * OVERRULED rather than found wrong. A future reader who finds the docx, the deployed Path
 * guidance and this file all disagreeing needs to be able to see that every disagreement was
 * DECIDED, not overlooked. 🔴 THE NEXT PERSON TO CHANGE THESE NUMBERS MUST ADD A FIFTH QUOTED
 * BLOCK AND NAME THE DECISION. Re-deriving them from any document is how this file got here.
 *
 *   RETRACTED 2026-09-02 — the 2026-08-21 block said, in full:
 *
 *     *"1. THE CLOCK IS SIX WEEKS, WITH RUNGS AT WEEK 1, WEEK 4 AND WEEK 6 (user decision,
 *     2026-08-21 — THIS OVERRIDES `DPEG-Stage-by-Stage.docx`) … This was the THIRD dispute, which
 *     is the condition the retracted text itself set for revisiting. The user settled it on
 *     2026-08-21: **Week 1 / Week 4 / Week 6 wins, and it overrides `DPEG-Stage-by-Stage.docx`
 *     Part 2 line 213.** The document is not 'reconciled' or reinterpreted here — it is overridden,
 *     deliberately and on the record, by the client whose process it describes. The docx itself is
 *     unchanged and now disagrees with this file; that is a documentation debt to settle in the
 *     document, not a licence to re-derive 60 days from it.
 *       7  WEEK_1_DAYS   the first check-in
 *       28 WEEK_4_DAYS   the at-risk mark — the ONE label the user gave verbatim ('Week 4 — At Risk')
 *       42 WEEK_6_DAYS   the end of the marketing period, and MARKETING_PERIOD_DAYS
 *     ⚠ NONE OF THE THREE IS DERIVED. All three are given numbers, so no ratio argument survives
 *     from the retracted text and a future revision cannot claim one threshold is 'the derived
 *     one'."*
 *
 *   …and the block IT retracted, from before 2026-08-21, said:
 *
 *     *"1. THE CLOCK IS 60 DAYS WITH A 30-DAY CHECKPOINT (D27.1 / D28-Q2).
 *     `docs/DPEG-Stage-by-Stage.docx` Part 2 line 213: 'The property is given about two months on
 *     the market. If there is no traction within the first month — no offers and no real interest —
 *     the team discusses it internally and decides whether to change the broker.' D27.1 made the
 *     document authoritative over the deployed 6-week Path guidance. … ½ × 60 = 30
 *     TRACTION_CHECKPOINT_DAYS, ⅔ × 60 = 40 REVIEW_OVERDUE_DAYS, 1 × 60 = 60
 *     MARKETING_PERIOD_DAYS … D28 also notes this is the SECOND time these numbers have been
 *     disputed; a third revision is the point at which to revisit, not before."*
 *
 * ── WHAT CHANGED ON 2026-09-02, AND WHAT DID NOT ────────────────────────────
 * EXACTLY ONE NUMBER MOVED: the FIRST rung, from **7 days (Week 1)** to **14 days (Week 2)**.
 * `WEEK_4_DAYS` (28) and `WEEK_6_DAYS` (42) are untouched, and so is `MARKETING_PERIOD_DAYS`.
 * The disputed question was only ever "how long before the first broker check-in is due", and the
 * answer is now two weeks.
 *
 * ── WHAT DECIDED IT ─────────────────────────────────────────────────────────
 * User decision **A2, taken at Gate 1 on 2026-09-02**, against BA story 30 (the broker check-in
 * clock). It was confirmed a second time in the same session after the justification below was
 * corrected. The 2026-08-21 block's own escalation clause — "a third revision is the point at
 * which to revisit" — has now been passed twice; this is the FOURTH revision and it is recorded as
 * a DECISION rather than derived from any source, which is what that clause was asking for.
 *
 * 🔴 AND THE JUSTIFICATION THE REQUEST ARRIVED WITH WAS WRONG, WHICH IS WORTH MORE THAN THE CHANGE
 * ITSELF. The change was proposed as affecting "the badge and the `Broker Alert Due` KPI". It does
 * NOT affect that KPI, and nothing in this class ever could. `reports/Dispositions/Broker_Alert_Due`
 * filters on `Disposition__c.Next_Broker_Checkin__c NEXT_N_DAYS:7` — a bare `<type>Date</type>`
 * field with no formula, no default and, on a repo-wide grep, NO WRITER anywhere in Apex, Flow,
 * trigger or process (only two seed scripts assign it). It is hand-maintained, and as of 2026-09-02
 * it carries an `inlineHelpText` saying so. The rungs and that KPI are ENTIRELY DECOUPLED.
 * ⇒ Changing the first rung changes **the badge, the rung panel and the detail sentence, and
 * nothing else in the org.** Do not "fix" the KPI to match; the detection job that would maintain
 * that field was DEFERRED at the same gate (G-3).
 *
 *   14 WEEK_2_DAYS   the first check-in  (was 7 / WEEK_1_DAYS until 2026-09-02)
 *   28 WEEK_4_DAYS   the at-risk mark — the ONE label the user gave verbatim ("Week 4 — At Risk")
 *   42 WEEK_6_DAYS   the end of the marketing period, and MARKETING_PERIOD_DAYS
 *
 * ⚠ NONE OF THE THREE IS DERIVED. All three are given numbers, so no ratio argument survives from
 * either retracted text and a future revision cannot claim one threshold is "the derived one".
 * ⚠ THE FIRST TWO RUNGS ARE NOW 14 DAYS APART RATHER THAN 21, AND THAT IS THE DECISION, NOT AN
 * ARTEFACT. Week 2 -> Week 4 -> Week 6 is an even fortnightly ladder; Week 1 -> Week 4 -> Week 6
 * was not. Nothing in the code depends on the spacing.
 *
 * ⚠ THE NUMBERS ARE STILL HARDCODED ON PURPOSE. Configurable thresholds (Custom Metadata / a Custom
 * Setting) were offered at Gate 1 and NOT chosen — D28/Q2, unaffected by this revision or the
 * previous one. Do not "improve" them into config.
 *
 * 🔴 DO NOT TOUCH `const DUE_SOON_DAYS = 7` IN `lwc/brokerListing/brokerListing.js`. Its own header
 * states that it is `CallForOffersService.APPROACHING_DAYS` — an ACQUISITIONS constant — and that
 * its equality with the old first rung was "a COINCIDENCE OF VALUE, not a derivation". As of
 * 2026-09-02 the coincidence is GONE (7 vs 14), which removes the temptation rather than creating
 * one; the two were never linked and must not now be "re-aligned" in either direction.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. 🔴 THE CLOCK PAUSES AT THE FIRST OFFER (user decision, 2026-08-21 — NEW)
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ PROVENANCE, STATED PLAINLY BECAUSE IT HAS NONE OTHER. This rule appears in NO DPEG document and
 * in no prior decision. `lwc/listingAlerts`'s retired mock asserted it, and it was deleted on
 * 2026-08-10 for exactly that reason — the header of that file called it *"a 'Clock PAUSES' rule
 * that appears in NO document, NO decision and NO code."* It is now a decision: **the user asked for
 * it on 2026-08-21.** That is its whole authority, and it is enough — but the sentence above must
 * not be reinstated as an objection, because it is answered.
 *
 * ── HOW THE PAUSE IS ACHIEVED: BY CHANGING THE INPUT, NOT BY FREEZING A FIELD ──
 * `evaluate` measures the clock from the listing date to `min(today, firstOfferDate)`. Once an offer
 * exists, `firstOfferDate` is fixed, so `days` STOPS ADVANCING by construction. There is no frozen
 * field to maintain, nothing to backfill, and the pure function stays pure. A stored freeze would
 * have to be kept true; this one is true on every evaluation.
 *
 * ⚠ WHAT CHANGED VISIBLY, AND IT IS NOT COSMETIC. The shipped rule (D28/Q1) SUPPRESSED THE LEVEL and
 * let the counter keep running: a listing with an offer at day 20 read "Day 55 of 60 — On Track" on
 * day 55. It now reads "Day 20 — Offer received, clock paused". Both are defensible; they are not
 * the same statement, and the second is the one that was asked for.
 *
 * ⚠ PAUSING AND SUPPRESSING ARE STILL TWO DECISIONS, BECAUSE THEY CAN DISAGREE. `MIN` ignores nulls,
 * so a disposition whose only offer carries no `Offer_Date__c` has `offerCount > 0` and
 * `firstOfferDate == null`. That listing is SUPPRESSED (an offer is traction — D28/Q1 survives
 * untouched) but NOT PAUSED, because there is no honest date to pause at, and the detail text says
 * so rather than pretending. Collapsing the two into one flag would either escalate a listing that
 * has an offer, or claim a pause with no date behind it.
 *
 * ⚠ A SECOND OFFER NEVER UN-PAUSES IT; DELETING THE FIRST ONE DOES. `firstOfferDate` is a `MIN`, so
 * it only ever moves EARLIER. If the only offer is deleted the clock resumes and back-dates, and the
 * level can jump several rungs at once. That is accepted deliberately (design O-2): the alternative
 * is a latching stored flag, which is the `NDA_Signed__c` failure mode this repo has already paid
 * for once — a latch that is true because it was once true, maintained by nobody.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. "NO TRACTION" STILL MEANS ZERO OFFERS. NOTHING ELSE. (D28-Q1, UNCHANGED)
 * ═══════════════════════════════════════════════════════════════════════════
 * The rungs fire on an offer count of zero. "Real interest" stays exactly what the document says it
 * is — a human judgement made in the internal discussion — and is deliberately NOT modelled as a
 * field. Gate 1 rejected both alternatives and the reasons are worth keeping: a recordable interest
 * signal works only if it is maintained, and an unmaintained field reads as *zero interest*; a
 * manual "there is interest" flag inverts the burden, so silence becomes a positive assertion that
 * there is none rather than an absence of data.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. WHERE THE COMPUTATION LIVES, AND WHY IT IS NOT A FORMULA OR A JOB
 * ═══════════════════════════════════════════════════════════════════════════
 * FORMULA — IMPOSSIBLE, not merely unattractive. `Disposition_Offer__c.Disposition__c` is a
 * `<type>Lookup</type>` (measured in the field file), and a roll-up summary requires Master-Detail.
 * There is therefore no way for a `Disposition__c` formula to count offers at any price, so the
 * offer half of D28/Q1 cannot be expressed declaratively — and the pause, which needs `MIN` over the
 * same children, is further out of reach still.
 *
 * SCHEDULED JOB — NOT BUILT, AND STILL NOT BUILT AFTER THE 2026-08-21 revision. The user scoped this
 * change to VISUAL state only: no emails, no dashboard flag. So a job's only product would again be
 * a STORED COPY of a value that is a pure function of stored facts, arriving with a post-deploy
 * scheduling gate that a deploy can silently miss.
 *
 * APEX AT READ TIME — CHOSEN. Nothing has to be maintained and there is no schedule to forget.
 *
 * ⚠ THE COST, STATED: a computed band is NOT reportable and NOT filterable. `Listing_Status__c` and
 * the `Broker_Alert_Due` report cannot see it. That is the real argument for a job, and it is why
 * `listingStatusValue` below exists.
 *
 * ── 🔴 RESIDUAL: "IT CANNOT GO STALE" IS TRUE OF THIS CLASS AND FALSE OF THE SCREEN ─────────
 * Recorded 2026-08-10 (review W1). Both consumers — `DispositionTractionController.getTraction` and
 * `BrokerListingController.getListing` — are `cacheable=true`, so the CLIENT holds the payload and
 * nothing in this feature invalidates it. The concrete sequence, all on one Disposition record page:
 *
 *   1. `c-disposition-offer` (sidebar) navigates to the standard new-record page for
 *      `Disposition_Offer__c` and the user saves.
 *   2. That component's LDS `getRelatedListRecords` wire is invalidated by the create, so the
 *      offers list comes back showing the new offer.
 *   3. `c-listing-alerts` and `c-broker-listing` (main region) are plain Apex wires and may keep
 *      serving the cached payload.
 *
 * ⚠ THE PAUSE MAKES THIS RESIDUAL MORE VISIBLE, NOT LESS. Logging the FIRST offer now changes the
 * day number as well as the band, so a stale panel is wrong about two things at once. The window is
 * still unmeasured and a page reload still shows the truth.
 *
 * ── WHY THE REFRESH RELAY WAS NOT BUILT — A STRUCTURAL MEASUREMENT, NOT A PREFERENCE ────────
 * The obvious fix ("`c-disposition-offer` fires a CustomEvent, `c-disposition-main` relays it, the
 * two panels call `refreshApex`") CANNOT BE BUILT AS DESCRIBED, because the two components are not
 * in one tree. Measured against `flexipages/Disposition_Record_Page.flexipage-meta.xml`:
 * `dispositionMain` sits in the **`main`** region and `dispositionSidebar` — the only component in
 * the repo that renders `c-disposition-offer` — sits in the **`sidebar`** region. A DOM
 * `CustomEvent` propagates up its OWN tree and stops there. The real mechanism would be Lightning
 * Message Service, and `force-app/main/default/` contains **no `messageChannels/` directory at
 * all**.
 *
 * ⚠ FOR THE AUTHOR WHO PICKS THIS UP: do NOT reach for `getRecordNotifyChange`. The band is an
 * Apex computation, not a field on the `Disposition__c` record. `refreshApex` on a retained wire
 * result is the only tool. ⚠ `c-broker-listing` DOES now retain its wire results (it has to, for the
 * Replace Broker button), so it is half-built there already — `c-listing-alerts` is not.
 *
 * ── 🔴 THE SEAM FOR A FUTURE ALERT — "a later addition, not a rewrite" ──
 * `evaluate(...)` is PURE: no SOQL, no DML, no `Date.today()` beyond the clock it derives from its
 * own arguments. A future `Schedulable` that writes `Listing_Status__c` calls THIS method over a
 * batch and calls `listingStatusValue(...)` for the picklist value — it does not re-derive a
 * threshold, so the stored value and the displayed badge cannot drift. That job additionally needs a
 * recipient population (still neither a queue nor a public group in this repo), a
 * `notificationtypes/*.notiftype-meta.xml` (the module has zero), and a post-deploy scheduling gate.
 * 🔴 None of those is built here, and on 2026-08-21 the user EXPLICITLY DEFERRED all of it: no
 * emails, no dashboard flag. Nothing in this file promises anyone will be told.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 5. 🔴 WHICH "DAYS ON MARKET" — AND WHY NEITHER STORED FIELD IS USED
 * ═══════════════════════════════════════════════════════════════════════════
 * Two fields share the name `Days_On_Market__c` and they are not the same kind of thing:
 *
 *   `Broker_Listing__c.Days_On_Market__c`  Number(4,0), NO formula, written by NOTHING. The
 *                                          retired ladder read THIS — a static number a human
 *                                          typed, which is why the deployed clock could not tick.
 *   `Disposition__c.Days_On_Market__c`     Formula `IF(ISBLANK(Listing_Date__c), null, TODAY() -
 *                                          Listing_Date__c)` with `formulaTreatBlanksAs =
 *                                          BlankAsZero`.
 *
 * This class reads NEITHER. It computes from the raw `Disposition__c.Listing_Date__c`, because
 * `BlankAsZero` makes the formula return **0** for an unset date — indistinguishable from "listed
 * today", which is the precise shape of "a clock that looks healthy and never ticks" (D28/Q3).
 * 🔴 AND THE FORMULA COULD NOT EXPRESS THE PAUSE ANYWAY: it is `TODAY() - Listing_Date__c`, which
 * advances every night no matter how many offers exist.
 *
 * ⚠ THE CLOCK IS THE PARENT'S, NOT THE LISTING'S — UNCHANGED BY THIS REVISION, AND IT WAS
 * DELIBERATELY LEFT ALONE. `Disposition__c.Listing_Date__c` is the start of the MARKETING PERIOD,
 * which survives a broker change; `Broker_Listing__c.List_Date__c` is per-broker and restarts when a
 * second listing row opens. Using the child's date would silently reset the clock the moment a
 * broker was replaced — i.e. exactly when the clock matters most. The 2026-08-21 revision changed
 * the THRESHOLDS and added the PAUSE; it did not move the clock's origin, and the Replace Broker
 * button added in the same change does not open a second listing row.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). Zero inline SOQL — the two reads go to
 * `DispositionSelector.selectListingClockByIds` and
 * `DispositionOfferSelector.selectOfferTractionByDispositionIds`. Zero DML. `evaluateAll` is 2 SOQL
 * for ANY number of dispositions.
 *
 * @see force-app/main/default/classes/DispositionOfferSelector.cls
 * @see force-app/main/default/classes/DispositionTractionController.cls (the LWC boundary)
 * @see force-app/main/default/classes/BrokerListingController.cls (the second consumer)
 */
public with sharing class DispositionTractionService {

    /**
     * Week 2 — the first check-in. Given, not derived (see the class header).
     *
     * ⚠ WAS `WEEK_1_DAYS = 7` UNTIL 2026-09-02 (user decision A2, BA story 30). The CONSTANT was
     * renamed as well as re-valued, deliberately: a `WEEK_1_DAYS = 14` would be a name that lies,
     * and the name is what every rung label, badge string and test assertion is written against.
     */
    @TestVisible
    private static final Integer WEEK_2_DAYS = 14;

    /** Week 4 — the at-risk mark. The one threshold the user named verbatim. */
    @TestVisible
    private static final Integer WEEK_4_DAYS = 28;

    /** Week 6 — the end of the marketing period, and the hard stop. */
    @TestVisible
    private static final Integer WEEK_6_DAYS = 42;

    /**
     * The full marketing period. IDENTICAL to `WEEK_6_DAYS` by definition rather than by
     * coincidence: week 6 IS the end of the period, and giving them two names that could drift is
     * how a ladder ends up disagreeing with its own progress bar.
     */
    @TestVisible
    private static final Integer MARKETING_PERIOD_DAYS = WEEK_6_DAYS;

    /** Rung state: reached, and it is the level the listing is currently ON. */
    @TestVisible
    private static final String STATE_CURRENT = 'Current';
    /** Rung state: reached, but the listing has moved past it (or the clock paused after it). */
    @TestVisible
    private static final String STATE_PASSED = 'Passed';
    /** Rung state: not reached. */
    @TestVisible
    private static final String STATE_AHEAD = 'Ahead';

    /**
     * The traction state of one broker-listed disposition.
     *
     * ⚠ ORDER IS MEANINGFUL. The escalation rungs ascend, so a reader can tell at a glance which
     * band is worse than which.
     *
     * 🔴 THE AT-RISK LINE IS DRAWN AT `WEEK_4`, NOT "EVERYTHING FROM INDEX 2 UP". That is a change
     * from the retired enum, whose header said index 2 upward was at-risk — true then, because index
     * 2 was the day-30 half-way checkpoint. Week 2 is day FOURTEEN: calling a listing at risk two
     * weeks after it went to market would mark almost every live listing, and the word would stop
     * meaning anything. (⚠ This paragraph said "Week 1 is day SEVEN" until 2026-09-02; the argument
     * is unchanged and if anything stronger at 14 days than it was at 7.) `isAtRisk` is set
     * explicitly per branch below, never derived from an ordinal, so inserting a value cannot
     * silently move that line — but read this note before you do.
     *
     * 🔴 `WEEK_1` WAS RENAMED TO `WEEK_2` ON 2026-09-02 (user decision A2) AND THE MEMBER NAME
     * CROSSES THE `@AuraEnabled` BOUNDARY TWICE — as `Traction.band` and as `Rung.key`. Measured
     * before the rename: NO production LWC branches on the literal `'WEEK_1'`. `listingAlerts.js`
     * uses `r.key` only as a `for:each` key and `brokerListing.js` colours off the boolean
     * `isAtRisk`, so the rename is confined to this file, its test, `BrokerListingControllerTest`
     * and the two Jest suites' FIXTURES. ⚠ That measurement is what made the rename cheap — a
     * future member rename must re-take it rather than cite this sentence.
     */
    public enum Band {
        /** `Listing_Date__c` is blank — the marketing clock has not started. NOT "day 0". */
        NOT_LISTED,
        /** Inside week 2, or an offer exists at any point (which pauses and/or suppresses). */
        ON_TRACK,
        /** Day 14+, zero offers. The week-2 check-in is due. NOT an at-risk state. */
        WEEK_2,
        /** Day 28+, zero offers. Four weeks on the market with nothing to show. AT RISK. */
        WEEK_4,
        /** Day 42+, zero offers. The whole six-week marketing period elapsed. HARD STOP. */
        WEEK_6
    }

    /**
     * One rung of the escalation ladder, with its REAL state on this listing.
     *
     * 🔴 THIS TYPE EXISTS SO THE PANEL CANNOT RENDER A FIXED LIST. `lwc/listingAlerts` previously
     * shipped a hardcoded four-row mock of exactly this ladder and it was deleted because it
     * *"rendered a fixed lie"*. The rungs are now COMPUTED — three of them, always, each carrying
     * which side of it this listing is on — so there is no arrangement of data for which the panel
     * shows a row that is not true of the record in front of it.
     */
    public class Rung {
        /** `Band` name of the rung — WEEK_2 / WEEK_4 / WEEK_6. The stable key for a `for:each`. */
        @AuraEnabled public String key;
        /** Short human label, e.g. `Week 4`. */
        @AuraEnabled public String label;
        /** The threshold in days. Surfaced so no consumer hardcodes 7/28/42 a second time. */
        @AuraEnabled public Integer days;
        /** Absolute date the rung falls due; null when the clock has not started. */
        @AuraEnabled public Date dueDate;
        /** `Passed`, `Current` or `Ahead` — mutually exclusive, exactly one per rung. */
        @AuraEnabled public String state;
        /** One short phrase explaining the state. Never promises a notification. */
        @AuraEnabled public String note;
        /** True on the single rung the listing is currently on; false on all three when paused. */
        @AuraEnabled public Boolean isCurrent;
        /** True once the rung's day has elapsed, whether or not it is the current one. */
        @AuraEnabled public Boolean isReached;
    }

    /** One disposition's computed traction state. All fields are derived; none is stored. */
    public class Traction {
        /** `Band` name — an enum cannot cross the `@AuraEnabled` boundary, so it travels as text. */
        @AuraEnabled public String band;
        /** Short human label for the badge, e.g. `Week 4 — At Risk`. */
        @AuraEnabled public String label;
        /** One sentence naming what the band means and what happens next. Never a promise of a notification. */
        @AuraEnabled public String detail;
        /**
         * Days from `Disposition__c.Listing_Date__c` to the clock's stop point; null when the clock
         * has not started.
         *
         * ⚠ THE STOP POINT IS `min(today, firstOfferDate)`, NOT TODAY. On a paused listing this
         * number does not move from one day to the next, and that is the pause (§2), not a bug.
         */
        @AuraEnabled public Integer daysOnMarket;
        /** Offers logged against the disposition. Always a number, never null. */
        @AuraEnabled public Integer offerCount;
        /** `Disposition__c.Listing_Date__c` verbatim; null means NOT_LISTED. */
        @AuraEnabled public Date listingDate;
        /** The earliest dated offer — the day the clock stopped. Null when nothing paused it. */
        @AuraEnabled public Date firstOfferDate;
        /** True when the clock is frozen at `firstOfferDate`. See §2 on why this is not `offerCount > 0`. */
        @AuraEnabled public Boolean isPaused;
        /** The three escalation rungs with their real state. Always exactly three, in ascending order. */
        @AuraEnabled public List<Rung> rungs;
        /** Whole days left of the six weeks; 0 once elapsed; null when the clock has not started. */
        @AuraEnabled public Integer daysRemaining;
        /** True from `WEEK_4` onward — the single flag the UI colours off. See the enum's note. */
        @AuraEnabled public Boolean isAtRisk;
        /** True once the clock has started, i.e. band != NOT_LISTED. */
        @AuraEnabled public Boolean isListed;
        /** The `Listing_Status__c` value this band maps to. Nothing writes it today — see the header. */
        @AuraEnabled public String listingStatusValue;
        /** The full period, surfaced so a caller never hardcodes 42 a second time. */
        @AuraEnabled public Integer marketingPeriodDays;
    }

    /**
     * Backwards-compatible entry point for a caller that has no offer date to give.
     *
     * ⚠ IT IS NOT "THE SIMPLE ONE" — it is the UNPAUSED one, and passing null here asserts that no
     * offer date is known, which is a different claim from "there are no offers". A caller that HAS
     * the date and omits it silently disables the pause for that surface.
     *
     * @param listingDate `Disposition__c.Listing_Date__c`; null means the clock has not started.
     * @param offerCount  Offers logged against the disposition; null is treated as 0.
     * @return The computed traction state. Never null.
     */
    public static Traction evaluate(Date listingDate, Integer offerCount) {
        return evaluate(listingDate, offerCount, null);
    }

    /**
     * THE PURE FUNCTION. Every band decision in the application is made here and nowhere else.
     *
     * No SOQL, no DML, and — deliberately — the only clock reading is the single `Date.today()`
     * below, so the same inputs always give the same answer and every branch is reachable from a
     * test without a clock fixture.
     *
     * ── ORDER IS LOAD-BEARING, IN TWO PLACES ────────────────────────────────
     * 1. OFFERS ARE TESTED BEFORE EVERY THRESHOLD. An offer is traction (D28/Q1) and it also stops
     *    the clock (§2), so no rung can fire while one exists.
     * 2. THRESHOLDS DESCEND. `>= 42` before `>= 28` before `>= 14`; ascending order would make day
     *    50 report Week 2 and every rung above it unreachable.
     *
     * @param listingDate    `Disposition__c.Listing_Date__c`; null means the clock has not started.
     * @param offerCount     Offers logged against the disposition; null is treated as 0.
     * @param firstOfferDate Earliest `Disposition_Offer__c.Offer_Date__c`; null when there are no
     *                       offers OR when none of them carries a date. IGNORED when `offerCount`
     *                       is 0 — a date with no offer behind it is not a pause.
     * @return The computed traction state. Never null.
     */
    public static Traction evaluate(Date listingDate, Integer offerCount, Date firstOfferDate) {
        Integer offers = (offerCount == null) ? 0 : offerCount;
        // A date with a zero count is a caller error, not a pause. Normalise it away here so no
        // branch below has to ask the question twice.
        Date pausedAt = (offers > 0) ? firstOfferDate : null;

        Traction t = new Traction();
        t.offerCount = offers;
        t.listingDate = listingDate;
        t.firstOfferDate = pausedAt;
        t.isPaused = (pausedAt != null);
        t.marketingPeriodDays = MARKETING_PERIOD_DAYS;

        // RETURN EARLY. A blank listing date is not "day 0" — it is "the clock has not started",
        // and collapsing the two is the defect this whole item exists to remove.
        if (listingDate == null) {
            t.band = Band.NOT_LISTED.name();
            t.isListed = false;
            t.isAtRisk = false;
            t.isPaused = false;
            t.label = 'Not listed yet';
            t.detail = 'The ' + MARKETING_PERIOD_DAYS
                + '-day marketing clock starts when a listing date is set.';
            t.listingStatusValue = 'On Track';
            t.rungs = buildRungs(null, null, null, false);
            return t;
        }

        // 🔴 THE PAUSE, IN ONE LINE. The clock stops at the first offer, so `days` is measured to
        // `min(today, firstOfferDate)` rather than to today. An offer dated in the FUTURE does not
        // run the clock forward past today — it simply pauses it here and now.
        Date clockStops = Date.today();
        if (pausedAt != null && pausedAt < clockStops) {
            clockStops = pausedAt;
        }
        // daysBetween is signed, so a future listing date reads negative. Clamp at 0: a listing
        // dated tomorrow is on day 0 of its clock, not day -1.
        Integer days = listingDate.daysBetween(clockStops);
        if (days < 0) {
            days = 0;
        }
        t.isListed = true;
        t.daysOnMarket = days;
        t.daysRemaining = Math.max(0, MARKETING_PERIOD_DAYS - days);

        // 🔴 OFFERS FIRST (D28/Q1, unchanged). An offer is traction, so it short-circuits every
        // threshold below. The retired ladder had no such branch, which is why it labelled a listing
        // with offers "Hard Stop".
        if (offers > 0) {
            t.band = Band.ON_TRACK.name();
            t.isAtRisk = false;
            t.listingStatusValue = 'On Track';
            String offerWords = offers + (offers == 1 ? ' offer ' : ' offers ') + 'received';
            if (t.isPaused) {
                t.label = 'Day ' + days + ' — Offer received, clock paused';
                t.detail = offerWords + ', so the marketing clock stopped at day ' + days
                    + ' and no week check-in is due.';
            } else {
                // Suppressed but not paused — no offer carries a date, so there is nothing honest
                // to pause AT. Say that rather than claim a pause with no day behind it.
                t.label = 'Day ' + days + ' of ' + MARKETING_PERIOD_DAYS + ' — On Track';
                t.detail = offerWords + ', so no week check-in is due. The clock is still running '
                    + 'because no offer carries an offer date.';
            }
            t.rungs = buildRungs(listingDate, days, null, t.isPaused);
            return t;
        }

        if (days >= WEEK_6_DAYS) {
            t.band = Band.WEEK_6.name();
            t.isAtRisk = true;
            t.label = 'Week 6 — Hard Stop';
            t.detail = 'Six weeks on the market with no offers. The full marketing period has '
                + 'elapsed; decide whether to replace the broker.';
            t.listingStatusValue = 'Hard Stop';
            t.rungs = buildRungs(listingDate, days, Band.WEEK_6, false);
            return t;
        }
        if (days >= WEEK_4_DAYS) {
            t.band = Band.WEEK_4.name();
            t.isAtRisk = true;
            t.label = 'Week 4 — At Risk';
            t.detail = 'Four weeks on the market with no offers, and ' + t.daysRemaining
                + ' days of the marketing period remain.';
            t.listingStatusValue = 'At Risk';
            t.rungs = buildRungs(listingDate, days, Band.WEEK_4, false);
            return t;
        }
        if (days >= WEEK_2_DAYS) {
            t.band = Band.WEEK_2.name();
            t.isAtRisk = false;
            t.label = 'Week 2 — Check-in due';
            t.detail = 'Two weeks on the market with no offers yet. Check in with the broker on '
                + 'interest and showings.';
            t.listingStatusValue = 'On Track';
            t.rungs = buildRungs(listingDate, days, Band.WEEK_2, false);
            return t;
        }

        t.band = Band.ON_TRACK.name();
        t.isAtRisk = false;
        t.label = 'Day ' + days + ' of ' + MARKETING_PERIOD_DAYS + ' — On Track';
        t.detail = 'The week-2 check-in is due in ' + (WEEK_2_DAYS - days)
            + ((WEEK_2_DAYS - days) == 1 ? ' day.' : ' days.');
        t.listingStatusValue = 'On Track';
        t.rungs = buildRungs(listingDate, days, null, false);
        return t;
    }

    /**
     * The three rungs with their real state — the whole of user decision 3 ("show which have been
     * passed, which is current, which is ahead").
     *
     * 🔴 EXACTLY ONE STATE PER RUNG, AND `Current` IS AWARDED AT MOST ONCE. `Current` is not "the
     * highest reached rung" — it is the rung matching the CURRENT BAND, which is why the band is
     * passed in rather than re-derived here. On a PAUSED listing no rung is current at all: reached
     * rungs read `Passed` and the rest read `Ahead`, because nothing is escalating. Re-deriving
     * "current = highest reached" locally would put a `Current` marker on a paused listing and make
     * the panel contradict the badge above it.
     *
     * @param listingDate  The clock's origin; null renders three undated `Ahead` rungs.
     * @param days         Days elapsed at the clock's stop point; null only when not listed.
     * @param currentBand  The band whose rung is `Current`, or null when none is (ON_TRACK, paused).
     * @param paused       True when the clock is frozen — changes the note on the unreached rungs.
     * @return Exactly three rungs, ascending.
     */
    private static List<Rung> buildRungs(
        Date listingDate,
        Integer days,
        Band currentBand,
        Boolean paused
    ) {
        List<Rung> rungs = new List<Rung>();
        rungs.add(rung(Band.WEEK_2, 'Week 2', WEEK_2_DAYS, listingDate, days, currentBand, paused));
        rungs.add(rung(Band.WEEK_4, 'Week 4', WEEK_4_DAYS, listingDate, days, currentBand, paused));
        rungs.add(rung(Band.WEEK_6, 'Week 6', WEEK_6_DAYS, listingDate, days, currentBand, paused));
        return rungs;
    }

    private static Rung rung(
        Band rungBand,
        String label,
        Integer thresholdDays,
        Date listingDate,
        Integer days,
        Band currentBand,
        Boolean paused
    ) {
        Rung r = new Rung();
        r.key = rungBand.name();
        r.label = label;
        r.days = thresholdDays;
        r.dueDate = (listingDate == null) ? null : listingDate.addDays(thresholdDays);

        if (days == null) {
            r.isReached = false;
            r.isCurrent = false;
            r.state = STATE_AHEAD;
            r.note = 'Not started.';
            return r;
        }

        r.isReached = (days >= thresholdDays);
        r.isCurrent = (currentBand != null && currentBand == rungBand);
        if (r.isCurrent) {
            r.state = STATE_CURRENT;
            r.note = 'Current — no offers.';
        } else if (r.isReached) {
            r.state = STATE_PASSED;
            r.note = paused ? 'Passed before the clock paused.' : 'Passed.';
        } else {
            r.state = STATE_AHEAD;
            Integer toGo = thresholdDays - days;
            r.note = paused
                ? 'Clock paused.'
                : 'In ' + toGo + (toGo == 1 ? ' day.' : ' days.');
        }
        return r;
    }

    /**
     * Bulk entry point: the traction state of every supplied disposition.
     *
     * 🔴 BUDGET: 2 SOQL, 0 DML, CONSTANT IN THE NUMBER OF DISPOSITIONS. That constancy is the
     * property that makes this safe to call from a future batch or Schedulable, and it is asserted
     * by the tests rather than left to inspection. ⚠ IT SURVIVED THE PAUSE ONLY BECAUSE THE COUNT
     * AND THE FIRST-OFFER DATE COME BACK FROM ONE AGGREGATE — see
     * `DispositionOfferSelector.selectOfferTractionByDispositionIds`.
     *
     * A disposition Id that resolves to no readable row is simply absent from the returned map —
     * callers must handle a miss, and `DispositionTractionController` renders it as "not listed".
     *
     * @param dispositionIds Dispositions to evaluate; null/empty safe.
     * @return Disposition__c Id -> Traction, omitting Ids that resolved to no row.
     */
    public static Map<Id, Traction> evaluateAll(Set<Id> dispositionIds) {
        Map<Id, Traction> result = new Map<Id, Traction>();
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return result;
        }
        List<Disposition__c> dispositions =
            DispositionSelector.selectListingClockByIds(dispositionIds);
        if (dispositions.isEmpty()) {
            return result;
        }
        // Read only for the dispositions that actually resolved, so an unreadable Id costs nothing
        // in the second query either.
        Map<Id, DispositionOfferSelector.OfferTraction> offerFacts =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(
                new Map<Id, Disposition__c>(dispositions).keySet());
        for (Disposition__c d : dispositions) {
            // A disposition with no offers is ABSENT from the map (GROUP BY emits no row for an
            // empty group), which is why the miss defaults to 0/null here rather than to null.get.
            DispositionOfferSelector.OfferTraction ot = offerFacts.get(d.Id);
            Integer offers = (ot == null) ? 0 : ot.offerCount;
            Date firstOffer = (ot == null) ? null : ot.firstOfferDate;
            result.put(d.Id, evaluate(d.Listing_Date__c, offers, firstOffer));
        }
        return result;
    }

    /**
     * The `Broker_Listing__c.Listing_Status__c` picklist value a band maps to.
     *
     * NOTHING CALLS THIS TODAY, AND THAT IS DELIBERATE — it is the seam a future stamping job writes
     * through, kept next to the thresholds so the stored value and the displayed badge can never
     * derive from two different ladders. The three values are the field's entire restricted value
     * set (`On Track` / `At Risk` / `Hard Stop`, measured), so this feature needs NO new picklist
     * value and the standing "grep the repo and query the org before touching a picklist" rule is
     * not engaged.
     *
     * ── 🔴 WHY `WEEK_2` MAPS TO `On Track` AND NOT TO `At Risk` (2026-08-21; the argument
     *      SURVIVED the 2026-09-02 rung move, it was not re-taken) ────
     * The ladder has four levels and the restricted picklist has three values, so one level has no
     * home of its own. `WEEK_2` is the one that gives way, for two reasons that agree:
     *   1. A FOURTH VALUE IS OUT OF SCOPE. The user's instruction for this change was explicit —
     *      create or modify no field. Adding a value to a restricted picklist is a field change.
     *      Decision A2 on 2026-09-02 did not reopen it.
     *   2. IT WOULD DILUTE THE SIGNAL ANYWAY. `At Risk` from day FOURTEEN would mark all but the
     *      first fortnight of every listing's life, and a flag that is almost always on is not a
     *      flag. (⚠ This clause said "day SEVEN" until 2026-09-02. Moving the rung to 14 WEAKENS
     *      the dilution argument slightly — a fortnight is a more defensible risk line than a
     *      week — and it is still the wrong line, because `WEEK_4` is where the user's own
     *      verbatim label puts "At Risk". Reason 1 is unaffected and remains decisive.)
     * ⚠ THE CONSEQUENCE, STATED: a listing at the week-2 check-in stores `On Track` while the card
     * shows "Week 2 — Check-in due". The card is the finer instrument; the stored value is a
     * three-position switch. This is the same choice `isAtRisk` makes, so the flag and the stored
     * value agree with each other — there is one rule here, not two.
     *
     * ⚠ THE PARAMETER IS NOT CALLED `band`, AND THAT IS NOT STYLE. Apex identifiers are
     * case-INSENSITIVE, so a parameter named `band` shadows the enum TYPE `Band` inside this
     * method and `Band.WEEK_6` then resolves against the parameter — which fails to compile with
     * the genuinely misleading `Static field cannot be referenced from a non static context:
     * WEEK_6`. Measured on this exact method 2026-08-10. Keep the names distinct.
     *
     * @param tractionBand The computed band.
     * @return `On Track`, `At Risk` or `Hard Stop`.
     */
    public static String listingStatusValue(Band tractionBand) {
        if (tractionBand == Band.WEEK_6) {
            return 'Hard Stop';
        }
        if (tractionBand == Band.WEEK_4) {
            return 'At Risk';
        }
        return 'On Track';
    }
}
