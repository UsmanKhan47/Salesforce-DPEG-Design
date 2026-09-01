/**
 * The single derivation of call-for-offers state in this application: due date, days remaining,
 * urgency band, listing broker, sale process and deal room link.
 *
 * THREE consumers render from this class and nothing else — `lwc/callForOffersList` (the Lead
 * Funnel table), `lwc/callForOffersPanel` (the Opportunity record page) and
 * `CallForOffersAlertBatch` (the daily notification job). That is the whole point: the table, the
 * panel and the alert cannot disagree about whether a deal is urgent, because there is exactly one
 * ladder and it lives here. Same shape, and the same reason, as `DispositionTractionService` and
 * `EmailThreadAnchorService`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE PURE FUNCTION, AND WHY ITS SIGNATURE IS (Date, Date) NOT (Date, Integer)
 * ═══════════════════════════════════════════════════════════════════════════
 * `evaluate(Date dueDate, Date asOf)` has NO SOQL and NO DML, and it never reads the clock when it
 * is given one — the clock is an argument, so every band is reachable from a test without a
 * frozen-clock hack and the alert batch can evaluate the whole chunk against ONE `asOf` rather than
 * re-reading the clock per record.
 *
 * ⚠ PRECISELY: it contains ONE `Date.today()`, on the null-`asOf` guard (`asOf == null ? ... `), so
 * a careless caller gets today's answer instead of a `NullPointerException` inside a batch chunk.
 * Every caller in this repo passes a non-null `asOf`, so the branch is unreachable in practice and
 * the function is pure for them — but "NO `Date.today()`" was an absolute, and it was false. The
 * guard is deliberate and is pinned by its own test; what follows is the corrected count.
 *
 * ⚠ The design brief names the shape `evaluate(Date, Integer)`, copied from
 * `DispositionTractionService.evaluate(Date listingDate, Integer offerCount)`. That precedent's
 * second argument is a DOMAIN input (how many offers exist) and it reads `Date.today()` INTERNALLY.
 * Here the clock IS the second input — a countdown read at two different "todays" must give two
 * different answers — so copying the literal signature would have meant either an internal
 * `Date.today()` (which the same brief forbids in the same sentence) or asking the caller to
 * pre-compute `daysRemaining`, which is the one thing this class exists to own. The REQUIREMENT
 * (pure, testable without a clock fixture) is met exactly; the parameter TYPE is the deliberate
 * divergence. `evaluate(Date)` is a one-line convenience that supplies `Date.today()`; it is the
 * only DELIBERATELY impure entry point — the controllers use it, the batch does not — but it is
 * not the only `Date.today()` in the class. ⚠ THE WORD "ONLY" WAS WRONG AND IS CORRECTED: there
 * are SEVEN executable occurrences across FOUR methods, and all of them are the same decision.
 * `evaluate(Date)`, `upcoming()` and `forOpportunity()` are the three convenience entry points that
 * supply today's clock on the caller's behalf (`forOpportunity` alone accounts for four of the
 * seven, one per return path); `evaluate(Date, Date)`'s null-`asOf` guard is the fourth method. The
 * invariant that actually matters is narrower and survives intact: **the LADDER never reads a
 * clock** — every threshold decision is made from the two arguments, and `shouldFire` takes no
 * clock at all.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. ONE LADDER SERVES THE BADGE AND THE ALERT — `dueInterval` IS THE JOIN
 * ═══════════════════════════════════════════════════════════════════════════
 * The notification ladder is {7, 3, 1, 0} — 7 / 3 / 1 days before, and on the day. `dueInterval` on
 * the result is the SMALLEST interval `i` for which `daysRemaining <= i`, or null above 7 days out.
 * The urgency BAND the UI colours off is computed from the same two numbers in the same function,
 * so the badge, the pill and the alert are one derivation rather than three lists that happen to
 * agree today.
 *
 * ⚠ THE LADDER'S VALUES MOVED TO CUSTOM METADATA ON 2026-08-30 (`CFO_Alert_Rung__mdt`). This
 * paragraph said `ALERT_INTERVALS` = {7, 3, 1, 0}; that constant is now
 * `DEFAULT_ALERT_INTERVALS`, the FALLBACK, and the live values come from Setup via
 * `alertIntervals()`. 🔴 ONLY THE VALUES MOVED — four rungs, same numbers on day one, no stored
 * `Offer_Alert_Last_Interval__c` marker invalidated. See that constant's own header.
 *
 * ⚠ THEY ARE NOT THE SAME POPULATION, AND THIS SECTION USED TO SAY THEY WERE. The retracted
 * sentence, verbatim: *"a deal the batch is about to alert on and a deal the panel paints red are
 * the same population BY CONSTRUCTION, not by two lists that happen to agree today."* They diverge
 * at the TOP RUNG, deliberately: at 7 days out `dueInterval` is 7 — so the batch DOES alert — while
 * the band is `APPROACHING` with `isUrgent = false`, which the UI paints AMBER, not red. Red begins
 * at `CRITICAL` (3 days). So "alerted" is a strictly WIDER population than "red", by exactly the
 * 4-to-7-day window. That is the intended behaviour (a first warning a week out should not look
 * like an emergency); only the claim was wrong.
 *
 * ⚠ AND THE COUPLING IS ENFORCED BY A TEST, NOT BY CONSTRUCTION. `CRITICAL_DAYS` (3) and
 * `APPROACHING_DAYS` (7) are declared SEPARATELY from the ladder and merely happen to equal two of
 * its entries; nothing in the code derives one from the other, so changing the ladder alone
 * compiles and silently decouples the bell from the badge. What actually holds them together
 * is `CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand`, which walks every
 * boundary day (8/7, 4/3, 1/0, 0/-1) and asserts the band AND the interval at each. 🔴 That test is
 * the guarantee — if you change any of these three constants, it is the thing that must stay green,
 * and it is the reason not to "tidy" the three declarations into one.
 *
 * 🔴 AND THAT GUARANTEE GOT WEAKER ON 2026-08-30, WHICH IS THE REAL COST OF MAKING THE RUNGS
 * SETUP-EDITABLE. A test pin was sufficient while the ladder was an Apex literal: the only way to
 * break the coupling was a deploy, and the deploy went red. An admin editing `CFO_Alert_Rung__mdt`
 * in Setup changes the ladder with NO deploy and NO test run, and `CRITICAL_DAYS` /
 * `APPROACHING_DAYS` — the BADGE's thresholds — stay where they are. So the bell and the badge CAN
 * now be decoupled by a Setup edit that nothing here can see or refuse.
 * ⚠ THAT IS ACCEPTED, NOT OVERLOOKED. The badge bands are a DISPLAY decision (what a human should
 * see as urgent) and the rungs are a NOTIFICATION decision (when to interrupt someone); the design
 * (Q5) chose to make only the second tunable. The two were never derived from each other. What
 * this note buys is that the next reader diagnosing "the badge says amber but the bell fired" looks
 * at the CMDT rows FIRST, instead of at code that has not changed.
 *
 * ⚠ Do not add a threshold anywhere else. If a fourth consumer needs one, it calls `evaluate`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. 🔴 THE IDEMPOTENCY RULE IS PURE TOO, AND IT IS THE HALF THAT IS EASY TO GET WRONG
 * ═══════════════════════════════════════════════════════════════════════════
 * `shouldFire(...)` is the entire alert-marker decision, and it lives here rather than in the batch
 * so it can be falsified without running a job. Two fields, two jobs:
 *
 *   `Offer_Alert_Last_Interval__c`  the smallest interval already notified. Fire only when the
 *                                   interval we would fire is STRICTLY SMALLER. Monotone, so a
 *                                   MISSED DAY CATCHES UP (8 days out -> 2 days out fires the "3"
 *                                   rung) and a DOUBLE RUN IS A NO-OP.
 *   `Offer_Alert_Due_Date__c`       the due date the marker was computed against. When it differs
 *                                   from the live due date the marker is treated as BLANK and the
 *                                   whole ladder re-arms.
 *
 * 🔴 THE SECOND FIELD IS NOT DEFENSIVE POLISH. `CallForOffersStampService` is LAST-EMAIL-WINS on
 * `Offer_Due_Date__c` **on purpose** — ARCHITECTURE.md records the reason verbatim: *"a
 * call-for-offers deadline is a fact that changes ('extended to Friday'), so fill-if-blank would
 * freeze the first date and make an extension invisible."* Without the snapshot, an extension leaves
 * the marker armed against a date that no longer exists and the re-armed schedule NEVER FIRES —
 * silently, on exactly the deals whose deadline someone cared enough about to move. The snapshot is
 * also what lets `CallForOffersStampService` stay completely ignorant of this feature: it moves the
 * date, and the re-arm falls out of the comparison. Do not add a marker reset to that class.
 *
 * ⚠ AN OVERDUE DEAL DOES NOT SPAM. Past the due date `dueInterval` is 0, and once 0 is stamped the
 * strictly-smaller test can never pass again. That is the design's stated failure to avoid ("the
 * team gets the same alert every day and stops reading them").
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. 🔴 "RECEIVED DATE" IS A REAL FIELD AS OF 2026-08-14 — AND THE PROXY IS STILL HERE, UNDER A
 *    NAME THAT CANNOT BE MISTAKEN FOR IT
 * ═══════════════════════════════════════════════════════════════════════════
 * ⚠ THIS SECTION USED TO READ *"'RECEIVED DATE' IS DERIVED, BECAUSE NO FIELD HOLDS IT"* AND IS
 * SUPERSEDED, not merely reworded. `Opportunity.Call_For_Offers_Received_Date__c` now exists and
 * `CallForOffersStampService` stamps it from the inbound email itself. `receivedDate` on the DTO
 * is that field VERBATIM — no fallback, no coalesce, no derivation of any kind.
 *
 * 🔴 THE OLD DERIVATION WAS `Broker_First_Seen__c` FALLING BACK TO `CreatedDate`, AND ITS DEFECT
 * WAS NOT SUBTLETY — IT WAS THE OBJECT IT DESCRIBED. Both answer *when did this DEAL arrive*. On a
 * deal whose broker relationship predates the campaign by months, a column headed "Received"
 * showed a date months away from any email, which is exactly the reading its label invites. Two
 * further facts make it worse than the original header implied: nothing in this repo writes
 * `Broker_First_Seen__c` at all (`LeadConvertService` does not copy it, and no flow touches it), so
 * in practice the chain was ALWAYS the `CreatedDate` leg — the Opportunity RECORD's creation
 * moment, which for a converted deal is when a human clicked Convert.
 *
 * 🔴 THE SENTENCE IMMEDIATELY ABOVE — *"nothing in this repo writes `Broker_First_Seen__c` at
 * all"* — WAS TRUE WHEN WRITTEN (2026-08-14) AND IS FALSE AS OF 2026-08-30 (WS2). It is left
 * standing, quoted and retracted here rather than deleted, because the ARGUMENT it supports is
 * unaffected and a future reader who only sees the conclusion would not know the premise moved.
 * `LeadConvertService.applyDealFields` now copies `Lead.First_Seen_Date__c` into
 * `Broker_First_Seen__c` on EVERY conversion, and the field's type changed `Date` -> `DateTime` in
 * the same change (hence the `.date()` at the assignment below). Three consequences, all intended:
 *   1. `dealArrivedDate` now takes its FIRST leg for every newly converted deal, so
 *      `c/callForOffersList` starts rendering "Deal arrived <date>" as the broker-first-seen date
 *      instead of the Opportunity's creation date. A VISIBLE change in this module, caused by a
 *      change in another one. Deals converted BEFORE 2026-08-30 keep the `CreatedDate` leg, so the
 *      column is legitimately mixed for a while.
 *   2. The demotion decision itself is REINFORCED, not weakened: a populated
 *      `Broker_First_Seen__c` is exactly the "months adrift from any email" value the paragraph
 *      above describes, and it is now real rather than hypothetical. `receivedDate` must still
 *      never coalesce onto it.
 *   3. The RETIREMENT note below is unaffected — `dealArrivedDate` is still a migration
 *      affordance with a defined end; it now simply carries a more meaningful value until then.
 *
 * SO WHY IS IT STILL COMPUTED? Because the real field is stamped only when a call-for-offers email
 * MATCHES A CONVERTED WINNER, and `ExtractAddressQueueable`'s own header records that most registry
 * winners are unconverted at any given time — while a deal's `Offer_Due_Date__c` can equally have
 * arrived from `LeadConvertService` at conversion. So a large, long-lived population appears in
 * this table with a deadline and no received date. Dropping the derivation outright would empty
 * that column on day one; keeping it INSIDE `receivedDate` would hide a wrong answer inside a
 * right-looking one.
 *
 * 🔴 THE RESOLUTION IS THAT THEY ARE TWO DIFFERENT MEMBERS WITH TWO DIFFERENT NAMES, AND THE UI
 * SAYS WHICH ONE IT IS IN WORDS. `receivedDate` is the email. `dealArrivedDate` is the deal. No
 * caller can obtain the second by reading the first, a marker glyph or a tooltip is not relied on
 * to carry the distinction, and `c/callForOffersList` renders the fallback as the literal text
 * "Deal arrived <date>". ⚠ DO NOT "TIDY" THIS BY COALESCING THEM — the coalesce IS the defect this
 * change removes, and `receivedDateIsTheStampedFieldAndNeverTheProxy` in the test class exists to
 * go red the moment anyone does.
 *
 * ⚠ RETIREMENT: `dealArrivedDate` is a MIGRATION AFFORDANCE with a defined end. Once the stamped
 * field's coverage is high enough that the fallback is rarely rendered, delete the member, the two
 * source fields from `OpportunitySelector`'s two USER_MODE reads, and the fallback branch in the
 * component — in that order. It is not load-bearing for anything else.
 *
 * ⚠ PROPERTY NAME IS `Opportunity.Name`, DELIBERATELY, AND NOT `Property__r.Name`. `LeadConvertService`
 * names the deal after the property (marketing name -> address), so `Name` IS the property name for
 * every deal the pipeline created. Traversing `Property__r.Name` would add a cross-object CRUD/FLS
 * dependency to a `WITH USER_MODE` read, and `DPEG_Opportunity_View` — the Transactions team's
 * Opportunity subset — grants NOTHING on `Property__c`. `USER_MODE` throws rather than degrades, so
 * the traversal would not show a blank name, it would take the WHOLE TABLE down for that persona.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). Zero inline SOQL — every read goes to `OpportunitySelector`. Zero
 * DML (the alert marker stamp belongs to the batch, which owns the transaction). `upcoming()` and
 * `forOpportunity()` are **1 SOQL each, CONSTANT in the number of deals returned**, pinned at 251.
 *
 * ⚠ `CFO_Alert_Rung__mdt.getAll()` IS NOT SOQL AND NEEDS NO SELECTOR. It is the platform's custom
 * metadata accessor and costs ZERO governor queries. Adding
 * `[SELECT ... FROM CFO_Alert_Rung__mdt]` to a selector would ADD a query this class does not
 * currently pay and would break the pinned budget above. `.claude/rules/apex-layering-rule.md`'s
 * "all SOQL lives in a selector" is satisfied vacuously: there is no SOQL here to own.
 *
 * ⚠ CITATION CORRECTED 2026-08-31 — THE CONCLUSION IS UNCHANGED, THE SOURCE IS NOT. This block
 * used to attribute the zero-query claim to "`BrokerProtectionConfig`'s header,
 * `Limits.getQueries() == 0`". That header no longer says it: `BrokerProtectionConfig` now issues
 * exactly one SOQL (for a LongTextArea field `getAll()`/`getInstance()` silently clip to 255
 * characters — a live P0) and it RETRACTS its old measurement in the same block a reader would
 * land on. `getAll()` still costs zero queries; the current authority for that, and for the
 * long-text carve-out, is `.claude/skills/sf-apex/SKILL.md` and `ARCHITECTURE.md` §2.
 * 🔴 THE CARVE-OUT DOES NOT APPLY HERE — `CFO_Alert_Rung__mdt` has no LongTextArea or Html field.
 * Adding one would silently truncate it at 255 and would need a selector for THAT field alone.
 *
 * @see force-app/main/default/classes/CallForOffersAlertBatch.cls  (the alert consumer + SCOPE)
 * @see force-app/main/default/classes/CallForOffersController.cls  (the two LWC boundaries)
 * @see force-app/main/default/classes/CallForOffersStampService.cls (the only writer of Offer_Due_Date__c)
 * @see CFO_Alert_Rung__mdt (the ladder's values; structure deploys, ROWS DO NOT)
 * @see scripts/load-cfo-alert-rungs.apex (creates the four rungs — a required post-deploy step)
 * @see force-app/main/default/classes/DispositionTractionService.cls (the shape this copies)
 */
public with sharing class CallForOffersService {

    /**
     * The notification ladder's SHIPPED DEFAULT: alert at 7, 3 and 1 days before the due date, and
     * on the day.
     *
     * ═══ ⚠ IT WAS `ALERT_INTERVALS`, THE LIVE LADDER, UNTIL 2026-08-30 ═══
     * RETRACTED, verbatim, from the declaration this replaces:
     *     "The notification ladder: alert at 7, 3 and 1 days before the due date, and on the day.
     *      DESCENDING and it must stay descending — `intervalFor` returns the first entry the
     *      countdown is still inside, which is only the SMALLEST such entry when the list is
     *      ordered this way."
     * The VALUES now live in `CFO_Alert_Rung__mdt` so an admin can retune the ladder without a
     * deploy (design Item 5(d), user decision Q5 = option (i)). 🔴 ONLY THE VALUES MOVED. The
     * ladder is still FOUR RUNGS, still `{7, 3, 1, 0}` on day one — seeded byte-identically by
     * `scripts/load-cfo-alert-rungs.apex` — so every `Offer_Alert_Last_Interval__c` marker already
     * stored on a live deal stays valid and NO deal changes behaviour. The ladder was NOT
     * collapsed to a single interval and must not be.
     *
     * 🔴 THE DESCENDING RULE DID NOT MOVE WITH THE VALUES — IT GOT MORE IMPORTANT. It is now
     * enforced by `resolveRungs`, which sorts explicitly, because `getAll()` returns a `Map` and
     * **a Map's iteration order is not guaranteed**. Getting that wrong does not error; it changes
     * which rung fires, silently. See `resolveRungs`.
     *
     * WHY THE LITERALS SURVIVE HERE AT ALL: this is the FALLBACK when the type carries no rows,
     * i.e. every org where `scripts/load-cfo-alert-rungs.apex` has not been run — which is every
     * freshly built org and every test run made before it. A CustomMetadata RECORD cannot be
     * deployed in this repo (`.forceignore` excludes the tree; file-based record deploy throws
     * UNKNOWN_EXCEPTION), so "no rows" is a REACHABLE state, not a hypothetical. Without this
     * fallback the deploy would ship a working feature and silently kill it until a manual script
     * was remembered. Exactly the shape, and exactly the reasoning, of `BrokerProtectionConfig`'s
     * per-accessor defaults.
     *
     * ✅ `CallForOffersAlertBatch`'s rule — "If you find yourself writing 7 or 3 in this file,
     * stop" — is UNAFFECTED AND STRENGTHENED. It is a rule about THAT file. The values live here
     * and in Setup; the batch still contains no literal and no logic moved into it.
     */
    @TestVisible
    private static final List<Integer> DEFAULT_ALERT_INTERVALS = new List<Integer>{ 7, 3, 1, 0 };

    /**
     * The widest rung `OpportunitySelector.queryCallForOffersAlerts`'s locator will read.
     *
     * ⚠ THIS IS A MIRROR OF A LITERAL IN ANOTHER FILE AND IT EXISTS ONLY TO WARN. That selector
     * bounds its work queue at `TODAY + 7` and its own header explains why the number cannot be
     * read from here: "A `Database.QueryLocator` cannot bind an Apex collection, so the ladder's
     * widest rung cannot be read from `CallForOffersService`." That was a safe duplication while
     * the ladder was an Apex constant — the two could only diverge through a deploy, which a
     * reviewer sees.
     *
     * 🔴 MAKING THE RUNGS SETUP-EDITABLE CREATED A NEW SILENT FAILURE, AND THIS IS THE MITIGATION.
     * An admin can now add a `Days_Before_Due__c = 14` rung in Setup, with no deploy and no
     * review. The locator will never read a deal 14 days out, so that rung fires for nobody and
     * NOTHING reports it. `resolveRungs` logs a WARN when the widest ACTIVE rung exceeds this, so
     * the misconfiguration is diagnosable rather than invisible. The warn is not enforcement: the
     * real fix is to widen the locator's ceiling in the same change that adds the rung.
     */
    private static final Integer LOCATOR_CEILING_DAYS = 7;

    /** Cached resolved ladder — see `alertIntervals()` for why the cache is a correctness property. */
    private static List<Integer> cachedRungs;

    /** Separate from `cachedRungs` because an EMPTY resolved ladder is a meaningful cached value. */
    private static Boolean rungsLoaded = false;

    /** One WARN per transaction per condition, so a 251-deal chunk does not emit 251 identical lines. */
    private static Set<String> rungWarnings = new Set<String>();

    /**
     * Days out at or below which the UI paints the deal red. Numerically equal to the ladder's
     * `3` rung — but ⚠ NOT DERIVED FROM IT. This is an independent declaration; changing
     * `ALERT_INTERVALS` without changing this compiles and silently decouples the badge from the
     * bell. `CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand` is what couples
     * them; see the class header §2.
     */
    @TestVisible
    private static final Integer CRITICAL_DAYS = 3;

    /**
     * Days out at or below which the UI paints the deal amber. Numerically equal to the ladder's
     * `7` rung, and independent of it in the same way `CRITICAL_DAYS` is. ⚠ Note the consequence
     * the class header §2 spells out: a deal exactly here IS alerted on but is NOT painted red, so
     * the alerted population is wider than the red one.
     */
    @TestVisible
    private static final Integer APPROACHING_DAYS = 7;

    /**
     * How urgent one deal's call-for-offers deadline is.
     *
     * ⚠ ORDER IS MEANINGFUL and is relied on by `isUrgent`: everything from `CRITICAL` onward is a
     * state a human is expected to act on today. Insert a new member in the right place or
     * `isUrgent` silently changes meaning — the `DispositionTractionService.Band` convention.
     */
    public enum Urgency {
        /** No `Offer_Due_Date__c`. NOT "due today" and not "overdue" — there is no deadline at all. */
        NO_DUE_DATE,
        /** More than 7 days out. Outside the alert ladder entirely. */
        SCHEDULED,
        /** 4-7 days out. The "7 day" rung has fired or is about to. */
        APPROACHING,
        /** 1-3 days out. */
        CRITICAL,
        /** The due date is today. */
        DUE_TODAY,
        /** The due date has passed. */
        OVERDUE
    }

    /** One deal's computed call-for-offers state. Every field is derived; none is stored. */
    public class CallForOffers {
        /** The Opportunity. Null when the state came from `evaluate` alone rather than a record. */
        @AuraEnabled public Id opportunityId;
        /** `Opportunity.Name` — which is the property name; see the class header §4. */
        @AuraEnabled public String propertyName;
        /** Relative URL to the deal, so the table's link does not build one client-side. */
        @AuraEnabled public String recordUrl;
        /**
         * `Opportunity.Call_For_Offers_Received_Date__c` VERBATIM — the day a call-for-offers
         * email for this deal reached DPEG. NULL when no such email has been stamped, and null is
         * the honest answer: see the class header §4 for why nothing is coalesced in here.
         */
        @AuraEnabled public Date receivedDate;
        /**
         * When the DEAL arrived — `Broker_First_Seen__c` falling back to the Opportunity's own
         * created date. ⚠ STAYS A `Date` DELIBERATELY (WS2, 2026-08-30). Both sources are now
         * `Datetime` and both are truncated with `.date()` at the assignment; this member is a
         * live UI column and widening it would change that column's shape for no requirement.
         * ⚠ THIS IS NOT AN EMAIL TIMESTAMP AND IS NOT A FALLBACK FOR ONE. It is a
         * separate fact, carried under a separate name so a consumer must choose it deliberately;
         * `c/callForOffersList` renders it as the words "Deal arrived <date>" and only when
         * `receivedDate` is null. Header §4 records when to delete it.
         */
        @AuraEnabled public Date dealArrivedDate;
        /** `Opportunity.Offer_Due_Date__c` verbatim; null means `NO_DUE_DATE`. */
        @AuraEnabled public Date dueDate;
        /** Whole days from `asOf` to the due date. NEGATIVE once overdue; null with no due date. */
        @AuraEnabled public Integer daysRemaining;
        /** `Urgency` name — an enum cannot cross the `@AuraEnabled` boundary, so it travels as text. */
        @AuraEnabled public String urgency;
        /** Short badge label, e.g. `Due in 3 days`. */
        @AuraEnabled public String label;
        /** One sentence saying what the state means. Never a promise that anyone was notified. */
        @AuraEnabled public String detail;
        /** True from `CRITICAL` onward — the single flag the UI colours off. */
        @AuraEnabled public Boolean isUrgent;
        /** False when there is no deadline, so a caller can render that differently from "0 days". */
        @AuraEnabled public Boolean hasDueDate;
        /** The alert rung this countdown sits in (7/3/1/0), or null above 7 days out. */
        @AuraEnabled public Integer dueInterval;
        /** `Sale_Process__c`. */
        @AuraEnabled public String saleProcess;
        /** `Listing_Broker_Name__c`. */
        @AuraEnabled public String listingBrokerName;
        /** `Listing_Broker_Email__c`. */
        @AuraEnabled public String listingBrokerEmail;
        /** `Deal_Room_Link__c`. */
        @AuraEnabled public String dealRoomLink;
        /**
         * `Opportunity.Offer_Status__c` VERBATIM — `Open` / `Submitted` / `Closed`, or NULL.
         *
         * 🔴 NULL IS A REAL AND COMMON VALUE, NOT A DEFECT, AND IT MUST NOT BE COALESCED TO
         * `'Open'` HERE. A picklist `<default>` applies on INSERT ONLY, so every deal that existed
         * before 2026-08-30 carries null and always will unless something writes it. Defaulting it
         * in this DTO would tell the panel and the table that a deal whose campaign nobody has
         * touched is definitively "Open" — a claim the data does not support — and would hide the
         * backfill gap from the only two surfaces that could reveal it. Both consumers render the
         * row/column only when this is populated.
         *
         * ⚠ IT IS NOT WHAT SUPPRESSES THE ALERT. The suppression is a WHERE clause in
         * `OpportunitySelector.queryCallForOffersAlerts` — a suppressed deal never reaches the
         * batch — and that query deliberately does not even select this field. This member exists
         * purely so a human can SEE the status that is doing the suppressing.
         */
        @AuraEnabled public String offerStatus;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE PURE CORE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * THE PURE FUNCTION. Every urgency decision in this application is made here and nowhere else.
     *
     * No SOQL, no DML, and no clock READ when a clock is supplied — it is the second argument. See
     * the class header §1 for why the signature is (Date, Date). ⚠ The one exception is the
     * null-`asOf` guard on the first line of the body, which falls back to `Date.today()`; every
     * caller in this repo passes a real `asOf`, so the function is pure on every live path, but
     * "no `Date.today()`" was an absolute and this method contains one.
     *
     * @param dueDate `Opportunity.Offer_Due_Date__c`; null means there is no deadline.
     * @param asOf    The date to count from. Null is treated as `Date.today()` so a careless caller
     *                gets today's answer rather than a `NullPointerException` inside a batch chunk.
     * @return The computed state. Never null. Record-derived fields are left null.
     */
    public static CallForOffers evaluate(Date dueDate, Date asOf) {
        Date today = (asOf == null) ? Date.today() : asOf;
        CallForOffers c = new CallForOffers();
        c.dueDate = dueDate;

        // RETURN EARLY. No deadline is not "due today" and not "overdue" — collapsing those is how a
        // deal with no call-for-offers campaign ends up painted red on a dashboard.
        if (dueDate == null) {
            c.urgency = Urgency.NO_DUE_DATE.name();
            c.hasDueDate = false;
            c.isUrgent = false;
            c.label = 'No offer deadline';
            c.detail = 'This deal has no call-for-offers due date.';
            return c;
        }

        Integer days = today.daysBetween(dueDate);
        c.hasDueDate = true;
        c.daysRemaining = days;
        c.dueInterval = intervalFor(days);

        if (days < 0) {
            Integer past = Math.abs(days);
            c.urgency = Urgency.OVERDUE.name();
            c.isUrgent = true;
            c.label = 'Overdue by ' + past + (past == 1 ? ' day' : ' days');
            c.detail = 'The offer deadline passed on ' + formatDate(dueDate) + '.';
            return c;
        }
        if (days == 0) {
            c.urgency = Urgency.DUE_TODAY.name();
            c.isUrgent = true;
            c.label = 'Due today';
            c.detail = 'Offers are due today, ' + formatDate(dueDate) + '.';
            return c;
        }
        if (days <= CRITICAL_DAYS) {
            c.urgency = Urgency.CRITICAL.name();
            c.isUrgent = true;
            c.label = 'Due in ' + days + (days == 1 ? ' day' : ' days');
            c.detail = 'Offers are due ' + formatDate(dueDate) + '.';
            return c;
        }
        if (days <= APPROACHING_DAYS) {
            c.urgency = Urgency.APPROACHING.name();
            c.isUrgent = false;
            c.label = 'Due in ' + days + ' days';
            c.detail = 'Offers are due ' + formatDate(dueDate) + '.';
            return c;
        }

        c.urgency = Urgency.SCHEDULED.name();
        c.isUrgent = false;
        c.label = 'Due in ' + days + ' days';
        c.detail = 'Offers are due ' + formatDate(dueDate) + '.';
        return c;
    }

    /**
     * `evaluate` against today's clock. The DELIBERATELY impure entry point — see the header §1,
     * which also corrects the count: this is not the class's only `Date.today()` (there are seven,
     * across four methods), it is the one that exists in order to read the clock.
     * Used by the controllers; deliberately NOT used by the batch, which evaluates a whole chunk
     * against a single `asOf` so two records in one run can never straddle midnight.
     *
     * @param dueDate `Opportunity.Offer_Due_Date__c`; null means there is no deadline.
     * @return The computed state as of today. Never null.
     */
    public static CallForOffers evaluate(Date dueDate) {
        return evaluate(dueDate, Date.today());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE LADDER'S VALUES — read from Custom Metadata, resolved once per transaction
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * The live notification ladder, DESCENDING.
     *
     * ⚠ A CUSTOM METADATA READ IS NOT SOQL. `CFO_Alert_Rung__mdt.getAll()` is the platform's
     * metadata accessor and costs ZERO governor queries — the same fact `BrokerProtectionConfig`'s
     * header records as measured (`Limits.getQueries() == 0`). This class's pinned budget ("1 SOQL
     * for `upcoming()`, CONSTANT in the number of deals") is therefore untouched, which is what
     * makes it safe to call this from inside `evaluate`.
     *
     * 🔴 THE CACHE IS A CORRECTNESS PROPERTY, NOT A SPEED TRICK, AND THAT MATTERS MORE HERE THAN
     * IT DID FOR THE CONFIG RECORD. `CallForOffersAlertBatch` evaluates a whole chunk against ONE
     * `asOf` specifically so two deals in one run cannot straddle midnight. The ladder deserves the
     * same treatment: without the cache, an admin saving a rung mid-chunk could give deal 3 a
     * four-rung ladder and deal 190 a three-rung one, and the marker written for each would be
     * measured against a different ladder. Resolve once, per transaction.
     *
     * @return The active rungs, largest first. Never null; may be empty (see `resolveRungs`).
     */
    @TestVisible
    private static List<Integer> alertIntervals() {
        if (!rungsLoaded) {
            cachedRungs = resolveRungs(CFO_Alert_Rung__mdt.getAll().values());
            rungsLoaded = true;
        }
        return cachedRungs;
    }

    /**
     * Turn CMDT rows into the ladder: active only, de-duplicated, DESCENDING.
     *
     * ═══ 🔴 THE SORT IS THE WHOLE POINT OF THIS METHOD ═══
     * `intervalFor` walks the list and keeps the LAST entry the countdown is still inside. That
     * only yields "the smallest rung the deal is inside" when the list is in DESCENDING order. The
     * old Apex constant was hand-written descending, so the property was free.
     * **`getAll()` RETURNS A `Map`, AND A MAP HAS NO GUARANTEED ITERATION ORDER.** Relying on it
     * would make the ladder's behaviour depend on an unspecified detail: with `{0, 7, 3, 1}` the
     * last match for a deal 2 days out is `1`, not `3` — the wrong rung, fired one day early, for
     * every deal, with no error anywhere. `rungsAreSortedDescendingRegardlessOfSourceOrder` in the
     * test class injects a deliberately scrambled row set and is the falsifier.
     *
     * ═══ THREE DEGENERATE INPUTS, THREE DIFFERENT ANSWERS, ON PURPOSE ═══
     *   • NO ROWS AT ALL -> fall back to `DEFAULT_ALERT_INTERVALS` and WARN. The type ships empty
     *     (records are script-loaded, not deployed), so this is the fresh-org and pre-loader state.
     *     "The loader was never run" must not silently disable a shipped, working feature.
     *   • ROWS EXIST BUT NONE IS ACTIVE -> an EMPTY ladder is HONOURED, and warned about. That is
     *     an admin deliberately switching the alerts off by unchecking `Is_Active__c`, and
     *     overriding it with the default would make that intent unexpressible. 🔴 THE DISTINCTION
     *     FROM THE CASE ABOVE IS THE ENTIRE REASON THIS METHOD LOOKS AT ROW COUNT AND ACTIVE COUNT
     *     SEPARATELY — do not collapse them into one `isEmpty()` test.
     *   • A ROW WITH A NULL `Days_Before_Due__c` -> skipped and warned. It is an incomplete record,
     *     not an instruction, and a null cannot participate in a `<=` comparison.
     *
     * ⚠ NEGATIVE RUNGS ARE ALLOWED AND ARE NOT A MISTAKE. `-2` means "two days AFTER the deadline",
     * which the marker handles correctly (it is strictly smaller than 0, so it fires exactly once).
     * The locator has no lower bound, so overdue deals are still read. Do not add a `>= 0` filter.
     *
     * @param rows Every `CFO_Alert_Rung__mdt` row in the org; null-safe.
     * @return The active rungs, largest first, de-duplicated. Never null.
     */
    @TestVisible
    private static List<Integer> resolveRungs(List<CFO_Alert_Rung__mdt> rows) {
        if (rows == null || rows.isEmpty()) {
            warnOnce('no-rows',
                'CFO_Alert_Rung__mdt HAS NO ROWS. Falling back to the shipped ladder '
                + DEFAULT_ALERT_INTERVALS + '. This is expected in a fresh org: the rungs are '
                + 'created by scripts/load-cfo-alert-rungs.apex, NOT by a deploy. Run it.');
            return DEFAULT_ALERT_INTERVALS.clone();
        }
        Set<Integer> unique = new Set<Integer>();
        for (CFO_Alert_Rung__mdt row : rows) {
            if (row == null || row.Is_Active__c != true) {
                continue;
            }
            if (row.Days_Before_Due__c == null) {
                warnOnce('null-days',
                    'CFO_Alert_Rung__mdt row "' + row.DeveloperName + '" is active but has a blank '
                    + 'Days_Before_Due__c and was SKIPPED. Set a value or deactivate the row.');
                continue;
            }
            unique.add(row.Days_Before_Due__c.intValue());
        }
        if (unique.isEmpty()) {
            warnOnce('none-active',
                'CFO_Alert_Rung__mdt has rows but NONE is active. The call-for-offers alert ladder '
                + 'is EMPTY, so no deal will ever be notified and no urgency rung is derived. If '
                + 'that is not intended, activate at least one rung in Setup.');
            return new List<Integer>();
        }

        // Ascending, then walked backwards — Apex has no List.reverse().
        List<Integer> ascending = new List<Integer>(unique);
        ascending.sort();
        List<Integer> descending = new List<Integer>();
        for (Integer i = ascending.size() - 1; i >= 0; i--) {
            descending.add(ascending[i]);
        }

        if (descending[0] > LOCATOR_CEILING_DAYS) {
            warnOnce('above-ceiling',
                'CFO_Alert_Rung__mdt has an active rung of ' + descending[0] + ' days, which is '
                + 'WIDER than OpportunitySelector.queryCallForOffersAlerts\'s TODAY+'
                + LOCATOR_CEILING_DAYS + ' work-queue ceiling. Deals that far out are never read, '
                + 'so that rung fires for NOBODY. Widen the locator ceiling in the same change.');
        }
        return descending;
    }

    /**
     * Log a rung misconfiguration once per transaction per condition.
     *
     * @param key     Condition key, so a 251-deal chunk emits one line, not 251.
     * @param message The WARN text.
     */
    private static void warnOnce(String key, String message) {
        if (rungWarnings.contains(key)) {
            return;
        }
        rungWarnings.add(key);
        System.debug(LoggingLevel.WARN, message);
    }

    /**
     * Test seam. Installs a rung set (in whatever order the test likes) and resets the
     * once-per-transaction WARN guards.
     *
     * Exists because **a test cannot insert a `__mdt` row via DML**, and the rows are script-loaded
     * rather than deployed — so an org running the suite may legitimately have none. Injecting the
     * rows is the only way to prove the sort, the de-duplication, the active filter and the two
     * degenerate cases. Same seam, same reason, as `BrokerProtectionConfig.overrideForTest`.
     *
     * @param rows The rows to serve; an EMPTY list simulates "the loader was never run".
     */
    @TestVisible
    private static void overrideRungsForTest(List<CFO_Alert_Rung__mdt> rows) {
        rungWarnings = new Set<String>();
        cachedRungs = resolveRungs(rows);
        rungsLoaded = true;
    }

    /**
     * Test seam. Drops the injected ladder so the next read resolves from the org's own CMDT.
     */
    @TestVisible
    private static void clearRungOverrideForTest() {
        cachedRungs = null;
        rungsLoaded = false;
        rungWarnings = new Set<String>();
    }

    /**
     * The alert rung a countdown sits in: the SMALLEST configured interval the deal is still inside.
     *
     * Pure with respect to the database and the clock. Null above the widest rung, so a deal 30
     * days out is not "in the 7-day window" — and null for EVERY countdown when the ladder is empty
     * (an admin has deactivated every rung), which correctly means nothing is ever owed an alert.
     *
     * ⚠ IT NO LONGER READS AN APEX CONSTANT. `alertIntervals()` resolves the ladder from
     * `CFO_Alert_Rung__mdt` once per transaction and GUARANTEES DESCENDING ORDER — which this loop
     * depends on and cannot itself verify. See `resolveRungs`.
     *
     * @param daysRemaining Whole days to the due date; negative once overdue.
     * @return The rung (7, 3, 1 or 0 with the shipped ladder), or null.
     */
    @TestVisible
    private static Integer intervalFor(Integer daysRemaining) {
        if (daysRemaining == null) {
            return null;
        }
        Integer chosen = null;
        for (Integer interval : alertIntervals()) {
            if (daysRemaining <= interval) {
                chosen = interval;
            }
        }
        return chosen;
    }

    /**
     * 🔴 THE IDEMPOTENCY DECISION. Should the alert job notify for this deal right now?
     *
     * Pure — no SOQL, no DML, no clock. See the class header §3 for what each field does and why the
     * second one exists at all.
     *
     * @param dueInterval    The rung this deal currently sits in (`CallForOffers.dueInterval`); null
     *                       means it is outside the ladder and nothing fires.
     * @param lastInterval   `Offer_Alert_Last_Interval__c`; null means nothing has fired yet.
     * @param liveDueDate    The deal's CURRENT `Offer_Due_Date__c`.
     * @param markerDueDate  `Offer_Alert_Due_Date__c` — the due date the marker was computed against.
     * @return True when an alert is owed.
     */
    public static Boolean shouldFire(
        Integer dueInterval,
        Integer lastInterval,
        Date liveDueDate,
        Date markerDueDate
    ) {
        if (dueInterval == null) {
            return false;
        }
        // A DEADLINE THAT MOVED RE-ARMS EVERYTHING. `==` on Date is null-safe in Apex, so a never-
        // alerted deal (both null, or marker null against a real date) also lands here and fires.
        // The anomalous shape — an interval stamped with no snapshot — deliberately re-arms too:
        // an extra alert is recoverable, a permanently silent deal is not.
        Integer effective = (markerDueDate == liveDueDate) ? lastInterval : null;
        return effective == null || dueInterval < effective;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECORD-BACKED ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Decorate the pure state of each supplied deal with its record fields.
     *
     * Pure with respect to the database — it reads nothing. The caller supplies both the rows and
     * the clock, which is what lets the batch evaluate a whole chunk against one `asOf`.
     *
     * @param deals Opportunities carrying at least Id, Name and `Offer_Due_Date__c`; null/empty safe.
     * @param asOf  The date to count from.
     * @return One state per input row, in input order. Never null.
     */
    public static List<CallForOffers> evaluateAll(List<Opportunity> deals, Date asOf) {
        List<CallForOffers> results = new List<CallForOffers>();
        if (deals == null || deals.isEmpty()) {
            return results;
        }
        for (Opportunity deal : deals) {
            if (deal == null) {
                continue;
            }
            CallForOffers c = evaluate(deal.Offer_Due_Date__c, asOf);
            c.opportunityId = deal.Id;
            c.propertyName = deal.Name;
            c.recordUrl = (deal.Id == null) ? null : '/lightning/r/Opportunity/' + deal.Id + '/view';
            // 🔴 THE STAMPED FIELD, VERBATIM. No coalesce, no fallback — see the class header §4.
            // If this line ever regains a `? :`, the column has gone back to reporting the deal's
            // age as the email's arrival.
            c.receivedDate = deal.Call_For_Offers_Received_Date__c;
            // A DIFFERENT FACT UNDER A DIFFERENT NAME — when the DEAL arrived. Kept while the
            // stamped field's coverage grows; the UI labels it in words rather than showing it as
            // if it were the line above.
            // ⚠ `.date()` ADDED 2026-08-30 (WS2). `Broker_First_Seen__c` changed Date -> DateTime
            // in that change, and Datetime does not implicitly convert to Date in Apex — without
            // this call the class does not COMPILE. Both legs now truncate the same way, in the
            // running user's time zone (`Datetime.date()`, never `dateGMT()`), so the two branches
            // cannot disagree about which calendar day they mean. 🔴 The DTO member stays `Date`
            // on purpose — see the header §4 and `receivedDateIsTheStampedFieldAndNeverTheProxy`;
            // widening it to Datetime would change a live UI column's shape, which WS2 does not ask
            // for and this class's own retirement note argues against.
            c.dealArrivedDate = (deal.Broker_First_Seen__c != null)
                ? deal.Broker_First_Seen__c.date()
                : (deal.CreatedDate == null ? null : deal.CreatedDate.date());
            c.saleProcess = deal.Sale_Process__c;
            c.listingBrokerName = deal.Listing_Broker_Name__c;
            c.listingBrokerEmail = deal.Listing_Broker_Email__c;
            c.dealRoomLink = deal.Deal_Room_Link__c;
            // VERBATIM, null included — see the member's own header for why a `?? 'Open'` here
            // would be a false claim about every deal created before 2026-08-30.
            c.offerStatus = deal.Offer_Status__c;
            results.add(c);
        }
        return results;
    }

    /**
     * Every open deal carrying a call-for-offers due date, soonest first — the Lead Funnel table.
     *
     * 🔴 BUDGET: 1 SOQL, 0 DML, CONSTANT IN THE NUMBER OF DEALS RETURNED. That constancy is what
     * makes the table safe on a growing pipeline and it is asserted by a 251-record test rather than
     * left to inspection.
     *
     * @return Computed states, soonest deadline first. Empty when nothing is matched. Never null.
     */
    public static List<CallForOffers> upcoming() {
        return evaluateAll(OpportunitySelector.selectCallForOffersOpen(), Date.today());
    }

    /**
     * One deal's call-for-offers state — the Opportunity record-page panel.
     *
     * NOT-FOUND CONTRACT: an Id that resolves to no readable row returns the `NO_DUE_DATE` state
     * rather than null. "This deal has no offer deadline" is a true and useful answer; a null would
     * render an empty box indistinguishable from a load failure.
     *
     * @param opportunityId The deal to evaluate.
     * @return Its computed state. Never null.
     */
    public static CallForOffers forOpportunity(Id opportunityId) {
        if (opportunityId == null) {
            return evaluate(null, Date.today());
        }
        Opportunity deal = OpportunitySelector.selectCallForOffersById(opportunityId);
        if (deal == null) {
            return evaluate(null, Date.today());
        }
        List<CallForOffers> states = evaluateAll(new List<Opportunity>{ deal }, Date.today());
        return states.isEmpty() ? evaluate(null, Date.today()) : states[0];
    }

    /** Month abbreviations. See `formatDate` for why this is not `DateTime.format`. */
    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    /**
     * `Aug 20, 2026` — the one date format these three surfaces share, so the badge, the panel and
     * the notification body cannot render the same deadline three ways.
     *
     * ⚠ DELIBERATELY NOT `DateTime.format('MMM d, yyyy')`. That renders in the RUNNING USER's locale
     * and time zone, so the same deadline reads differently for two people looking at one deal, and
     * any test asserting the string is silently locale-dependent — green on this machine, red on a
     * CI box with a different default. This is a fixed, asserted format.
     *
     * @param value The date to render; null-safe.
     * @return The formatted date, or an em dash.
     */
    @TestVisible
    private static String formatDate(Date value) {
        if (value == null) {
            return '—';
        }
        return MONTHS[value.month() - 1] + ' ' + value.day() + ', ' + value.year();
    }
}
