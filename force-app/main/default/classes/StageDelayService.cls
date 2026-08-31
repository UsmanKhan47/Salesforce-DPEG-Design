/**
 * The single derivation of "this deal has been sitting in its stage too long" in this application:
 * the per-stage threshold, the days-in-stage count, and the fire/suppress decision that stops the
 * reminder repeating.
 *
 * ONE consumer today — `StageDelayAlertBatch`, the daily stalled-deal reminder (design
 * `agent-output/design-requirements.md` §2 ITEM 4). It is a SERVICE rather than private batch logic
 * for the reason `NdaExpiryService` and `CallForOffersService` are: the thresholds are the thing the
 * design calls tunable, so they need exactly ONE home, and a second consumer is already plausible
 * (a badge on the deal card, or the `Delayed_Opportunities` report's Apex equivalent). If a badge
 * ever appears it must not be able to disagree with the bell about whether a deal is stalled.
 *
 * ⚠ DELIVERY IS IN-APP ONLY, AND THAT IS A DECISION RATHER THAN A GAP. The requirement was in-app
 * notification AND email; only in-app shipped, by user decision on 2026-08-31. `shouldFire` is
 * therefore a SINGLE-CHANNEL decision — it answers "is a reminder owed", not "is a reminder owed on
 * channel X". 🔴 Anyone adding the email half must answer "if the bell succeeds and the email
 * fails, does the marker still stamp?" BEFORE writing code, because the honest answer needs a third
 * marker field and a rewrite of `shouldFire` — it is not a change to the batch alone. The full
 * argument, and the two org facts behind the deferral, are in `StageDelayAlertBatch`'s header §0.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE PURE CORE, AND WHY THE SIGNATURE TAKES THE CLOCK
 * ═══════════════════════════════════════════════════════════════════════════
 * `evaluate(String stageName, Date stageEntryDate, Date asOf)` has NO SOQL and NO DML, and it never
 * reads the clock when it is given one — the clock is an ARGUMENT. That is what lets every band be
 * reached from a test with no frozen-clock hack, and what lets the batch evaluate a whole chunk
 * against ONE `asOf` rather than re-reading `Date.today()` per record (two deals in one chunk
 * straddling midnight would otherwise produce a run in which one is "day 14" and its neighbour is
 * already "day 15").
 *
 * ⚠ PRECISELY, because the equivalent absolute in `CallForOffersService`'s header turned out to be
 * false when it was checked: there are TWO executable `Date.today()` calls in this class. One is the
 * null-`asOf` guard on the first line of `evaluate`, so a careless caller gets today's answer
 * instead of a `NullPointerException` inside a batch chunk; the other is the one-line convenience
 * overload `evaluate(String, Date)` that exists in order to read the clock. **`shouldFire` takes no
 * clock at all**, and no threshold decision anywhere in this class reads one. That is the invariant.
 *
 * ⚠ IT DELIBERATELY DOES NOT READ `Opportunity.Days_In_Stage__c`, THE DEPLOYED FORMULA FIELD, EVEN
 * THOUGH THAT FIELD EXISTS AND SAYS THE SAME THING. A formula is evaluated by the platform at QUERY
 * time, per row; this class is evaluated once per chunk against one `asOf`. Reading the formula
 * would reintroduce exactly the midnight straddle the `asOf` argument exists to prevent, and would
 * make the batch depend on the FLS of a field it does not need. The formula's job is the report and
 * the dashboard; this class's job is the decision. They are computed from the same
 * `Stage_Entry_Date__c` and cannot drift.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. THE THRESHOLDS LIVE IN CUSTOM METADATA, AND THE FALLBACK IS 14 — BOTH HALVES MATTER
 * ═══════════════════════════════════════════════════════════════════════════
 * `Stage_Threshold_Def__mdt` carries one row per OPEN stage: `Stage_Value__c` (the `StageName` API
 * value), `Threshold_Days__c`, `Is_Active__c`. The shipped configuration is a FLAT 14 DAYS for all
 * eight open stages (recorded user decision), seeded by `scripts/load-stage-threshold-defs.apex`.
 *
 * 🔴 **THIS IS THE ONLY PLACE THE NUMBER 14 APPEARS IN APEX.** If you find yourself writing `14` in
 * `StageDelayAlertBatch`, in the selector, or anywhere else, stop.
 *
 * 🔴 **AND `DEFAULT_THRESHOLD_DAYS` IS NOT DEAD CODE — IT IS WHAT MAKES THE DEPLOY SAFE.** CMDT
 * *records* are not deployable in this repo (`.forceignore` excludes the `customMetadata`
 * directory — ⚠ do NOT write that glob out in full inside a block comment: the `*` `/` pair in it
 * TERMINATES the comment and the compiler reports `Unexpected token 'customMetadata'`, measured
 * here 2026-08-31; four
 * loader-script precedents), so the type ships EMPTY and the rows arrive only when a human runs the
 * loader — post-deploy step P3. Without a fallback, "the loader was never run" would leave every
 * deal classified as not-delayed, the job would log a healthy all-zeros summary, and the whole
 * feature would be dead with nothing anywhere reporting it. Exactly the silent failure this
 * design fights everywhere else. `CallForOffersService.DEFAULT_ALERT_INTERVALS` is the precedent
 * and its loader script's header says the same thing: **do not delete the fallback on the strength
 * of the script existing.** The script is a manual step; the fallback is what makes the deploy safe.
 *
 * ── THREE DEGENERATE INPUTS, THREE DIFFERENT ANSWERS, ON PURPOSE ────────────
 *   • NO ROWS AT ALL          -> every open stage gets `DEFAULT_THRESHOLD_DAYS`, and a WARN says so.
 *                                The fresh-org / pre-loader state.
 *   • ROWS EXIST, NONE ACTIVE -> an EMPTY threshold map is HONOURED, and warned about. That is an
 *                                admin deliberately switching the reminder off by unchecking
 *                                `Is_Active__c`, and overriding it with the default would make that
 *                                intent unexpressible. 🔴 THE DISTINCTION FROM THE CASE ABOVE IS THE
 *                                ENTIRE REASON THIS METHOD COUNTS ROWS AND ACTIVE ROWS SEPARATELY —
 *                                do not collapse them into one `isEmpty()` test.
 *   • ROWS EXIST, THIS STAGE  -> that stage has NO threshold and NEVER fires. This is not an error:
 *     IS NOT AMONG THEM          it is how the loader excludes `Closed Won` / `Dead/Pass` and how an
 *                                admin switches off one stage without switching off the rest.
 *
 * ⚠ THE MAP IS KEYED CASE-INSENSITIVELY, DELIBERATELY. Apex `String` equality with `==` is
 * case-INSENSITIVE but `Map<String, ...>.get()` is case-SENSITIVE, so an admin who types
 * `under review` into `Stage_Value__c` would get a silent miss and a stage that never alerts.
 * Every key is lower-cased on the way in and every lookup is lower-cased on the way out.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. 🔴 THE SUPPRESSION RULE — FIRE ONCE PER STAGE OCCUPANCY, AND RE-ARM ON A MOVE
 * ═══════════════════════════════════════════════════════════════════════════
 * `shouldFire(...)` is the entire marker decision and it lives here, pure, so it can be falsified
 * without running a job. TWO marker fields, two jobs:
 *
 *   `Stage_Alert_Stage__c`           THE SNAPSHOT — the stage the reminder was sent about.
 *   `Stage_Alert_Last_Sent_Date__c`  the date it was sent.
 *
 * 🔴 THE SNAPSHOT IS NOT DEFENSIVE POLISH AND IT IS THE HALF THAT IS EASY TO GET WRONG. The
 * `Offer_Alert_*` and `NDA_Alert_*` markers this feature is modelled on snapshot a DATE, because the
 * thing that re-arms them is a date moving. **Here the thing that must re-arm the reminder is a
 * STAGE CHANGE.** A date-only marker would leave a deal that moved on and stalled again
 * PERMANENTLY SILENT — on exactly the deals someone cared enough to progress.
 *
 * Two independent re-arm legs, and each covers a case the other cannot:
 *   A. `markerStage != liveStage`             the deal moved to a different stage.
 *   B. `markerSentDate <= liveStageEntryDate` the deal LEFT and RE-ENTERED the SAME stage, so its
 *                                             entry date moved forward past the marker. Leg A is
 *                                             blind to this — the stage name is unchanged.
 *
 * ⚠ LEG B IS `<=`, NOT `<`, AND THAT IS A DELIBERATE ONE-CHARACTER DEVIATION FROM THE DESIGN
 * DOCUMENT'S LITERAL TEXT (§2 ITEM 4 writes `Stage_Alert_Last_Sent_Date__c < Stage_Entry_Date__c`).
 * The reason: with `<`, a deal that is reminded on day 14 and then bounces out of and back into the
 * SAME stage ON THAT SAME DAY ends up with `markerSentDate == liveStageEntryDate`, neither leg
 * fires, and that occupancy is silent FOREVER. With `<=` that hole closes, and it **cannot**
 * introduce a double-fire for any threshold >= 1: firing requires `daysInStage >= threshold >= 1`,
 * so a marker written inside an occupancy always carries a date STRICTLY LATER than that occupancy's
 * entry date, and leg B is false for the rest of it. (At a threshold of 0 — which nothing ships and
 * `resolveThresholds` warns about — `<=` yields at most one extra reminder.) This repo's own stated
 * preference decides the tie: *"an extra reminder is recoverable, a permanently silent NDA is
 * not."* Do not "correct" this back to `<`.
 * ✅ REVIEWED AND ACCEPTED 2026-08-31. The deviation and the reasoning above were put to the
 * coordinator and confirmed, and the pinning test
 * `StageDelayServiceTest.aSameDayReEntryStillReArms_whichIsWhyLegBUsesLessThanOrEqual` was required
 * to stay. This is an argued departure from the design document, on file — not an undocumented one
 * for a later reader to "tidy up".
 *
 * ⚠ A STALLED DEAL DOES NOT SPAM. Once a marker is written for an occupancy, neither leg can fire
 * again until the deal actually moves. A deal that sits in `Underwriting` for a year gets exactly
 * ONE reminder, which is the recorded user decision (fire once per stage occupancy, not an
 * escalating ladder).
 *
 * ⚠ AN ANOMALOUS MARKER RE-ARMS. A stage stamped with no date, or a date stamped with no stage, is
 * treated as no marker at all and fires. An extra reminder is recoverable; a permanently silent
 * deal is not. Same trade, same wording, as `NdaExpiryService.shouldFire`.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `.claude/rules/apex-layering-rule.md`). ZERO SOQL and ZERO DML — this
 * class never touches the database. The work queue belongs to
 * `OpportunitySelector.queryStalledDeals`; the marker write belongs to `StageDelayAlertBatch`, which
 * owns the transaction.
 *
 * ⚠ `Stage_Threshold_Def__mdt.getAll()` IS NOT SOQL AND NEEDS NO SELECTOR. It is the platform's
 * custom metadata accessor and costs ZERO governor queries (the fact `BrokerProtectionConfig` and
 * `CallForOffersService` both record as measured). Relocating a `[SELECT ... FROM
 * Stage_Threshold_Def__mdt]` into a selector would ADD a query this class does not currently spend,
 * inside a batch whose whole governor claim is "0 SOQL of its own per chunk".
 *
 * @see StageDelayAlertBatch.cls                  (the consumer, and the SCOPE arithmetic)
 * @see StageDelayAlertSchedule.cls               (🔴 the post-deploy scheduling gate)
 * @see OpportunitySelector.queryStalledDeals     (the work queue — SYSTEM_MODE, and the ceiling)
 * @see scripts/load-stage-threshold-defs.apex    (the rows; they are NOT deployed)
 * @see NdaExpiryService.cls                      (the shape this follows, marker for marker)
 * @see CallForOffersService.cls                  (the CMDT resolution shape this copies)
 */
public with sharing class StageDelayService {

    /**
     * The shipped threshold, in days, used for EVERY open stage when `Stage_Threshold_Def__mdt`
     * carries no rows at all. A FLAT 14 across all eight open stages is the recorded user decision,
     * and this constant must equal the value `scripts/load-stage-threshold-defs.apex` seeds, or
     * running the loader would CHANGE behaviour rather than merely make it tunable.
     *
     * 🔴 NOT DEAD CODE. See the class header §2 — it is what stops a forgotten loader script
     * silently disabling the whole feature.
     */
    @TestVisible
    private static final Integer DEFAULT_THRESHOLD_DAYS = 14;

    /** Resolved once per transaction; see `thresholds()` for why the cache is a correctness
     *  property rather than a speed trick. Keys are LOWER-CASED stage API names. */
    private static Map<String, Integer> cachedThresholds;
    private static Boolean thresholdsLoaded = false;

    /** One WARN per condition per transaction, so a 251-deal chunk emits one line and not 251. */
    private static Set<String> configWarnings = new Set<String>();

    /**
     * How stalled one deal is.
     *
     * ⚠ ORDER IS MEANINGFUL and is relied on by `isDelayed` in `StageDelay`: everything from
     * `DELAYED` onward is a state a human is expected to act on. Insert a new member in the right
     * place — the `NdaExpiryService.Urgency` / `CallForOffersService.Urgency` convention.
     */
    public enum Delay {
        /** No `Stage_Entry_Date__c`. NOT "entered today" — there is no anchor at all, so nothing
         *  can be measured and nothing fires. The un-backfilled legacy population. */
        NO_ENTRY_DATE,
        /** No active threshold configured for this stage, so it is not chased. Closed stages, and
         *  any stage an admin has switched off, land here. */
        NOT_TRACKED,
        /** Inside its stage's threshold. Healthy. */
        ON_TRACK,
        /** At or past its stage's threshold. */
        DELAYED
    }

    /** One deal's computed stall state. Every field is derived; none is stored. */
    public class StageDelay {
        /** `Opportunity.StageName` verbatim. */
        @AuraEnabled public String stageName;
        /** `Opportunity.Stage_Entry_Date__c` verbatim; null means `NO_ENTRY_DATE`. */
        @AuraEnabled public Date stageEntryDate;
        /** Whole days from the entry date to `asOf`. Null when there is no entry date. */
        @AuraEnabled public Integer daysInStage;
        /** The threshold that applied. Null when the stage is `NOT_TRACKED`. */
        @AuraEnabled public Integer thresholdDays;
        /** `Delay` name — an enum cannot cross the `@AuraEnabled` boundary, so it travels as text. */
        @AuraEnabled public String status;
        /** True only for `DELAYED`. The single flag a consumer would colour off. */
        @AuraEnabled public Boolean isDelayed;
        /** Short badge label, e.g. `17 days in Underwriting`. */
        @AuraEnabled public String label;
        /** One sentence saying what the state means. Never a promise that anyone was notified. */
        @AuraEnabled public String detail;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE PURE CORE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * THE PURE FUNCTION. Every stalled-deal decision in this application is made here and nowhere
     * else.
     *
     * No SOQL, no DML, and no clock READ when a clock is supplied — it is the third argument. See
     * the class header §1 for the one exception (the null-`asOf` guard on the first line).
     *
     * @param stageName      `Opportunity.StageName`.
     * @param stageEntryDate `Opportunity.Stage_Entry_Date__c`; null means there is no anchor, which
     *                       is the un-backfilled legacy state and is NOT "entered today".
     * @param asOf           The date to count from. Null is treated as `Date.today()` so a careless
     *                       caller gets today's answer rather than a `NullPointerException` inside a
     *                       batch chunk.
     * @return The computed state. Never null.
     */
    public static StageDelay evaluate(String stageName, Date stageEntryDate, Date asOf) {
        Date today = (asOf == null) ? Date.today() : asOf;
        StageDelay d = new StageDelay();
        d.stageName = stageName;
        d.stageEntryDate = stageEntryDate;
        d.isDelayed = false;

        // RETURN EARLY. "No entry date" is not "entered today". Collapsing those would make every
        // un-backfilled legacy deal look brand new — or, with the opposite default, alert the entire
        // back catalogue on day one. The selector excludes these rows too; this is the in-memory
        // half of the same guard.
        if (stageEntryDate == null) {
            d.status = Delay.NO_ENTRY_DATE.name();
            d.label = 'No stage entry date';
            d.detail = 'This deal has no stage entry date, so its time in stage cannot be measured.';
            return d;
        }

        Integer days = stageEntryDate.daysBetween(today);
        d.daysInStage = days;

        Integer threshold = thresholdFor(stageName);
        if (threshold == null) {
            d.status = Delay.NOT_TRACKED.name();
            d.label = String.valueOf(days) + (days == 1 ? ' day' : ' days')
                + ' in ' + describeStage(stageName);
            d.detail = 'No stalled-deal threshold is configured for ' + describeStage(stageName)
                + ', so this deal is not chased.';
            return d;
        }
        d.thresholdDays = threshold;

        if (days < threshold) {
            d.status = Delay.ON_TRACK.name();
            d.label = String.valueOf(days) + (days == 1 ? ' day' : ' days')
                + ' in ' + describeStage(stageName);
            d.detail = 'This deal entered ' + describeStage(stageName) + ' on '
                + formatDate(stageEntryDate) + ' and is inside its ' + threshold + '-day threshold.';
            return d;
        }

        d.status = Delay.DELAYED.name();
        d.isDelayed = true;
        d.label = String.valueOf(days) + (days == 1 ? ' day' : ' days')
                + ' in ' + describeStage(stageName);
        d.detail = 'This deal has been in ' + describeStage(stageName) + ' since '
            + formatDate(stageEntryDate) + ' — ' + days + (days == 1 ? ' day' : ' days')
            + ', past the ' + threshold + '-day threshold.';
        return d;
    }

    /**
     * `evaluate` against today's clock. The DELIBERATELY impure entry point — see the class header
     * §1, which also gives the honest count. Deliberately NOT used by the batch, which evaluates a
     * whole chunk against a single `asOf` so two deals in one run can never straddle midnight.
     *
     * @param stageName      `Opportunity.StageName`.
     * @param stageEntryDate `Opportunity.Stage_Entry_Date__c`.
     * @return The computed state as of today. Never null.
     */
    public static StageDelay evaluate(String stageName, Date stageEntryDate) {
        return evaluate(stageName, stageEntryDate, Date.today());
    }

    /**
     * 🔴 THE SUPPRESSION DECISION. Should the reminder job notify for this deal right now?
     *
     * Pure — no SOQL, no DML, no clock. See the class header §3 for what each marker field does,
     * why there are two, and why leg B uses `<=`.
     *
     * @param isDelayed            `StageDelay.isDelayed` — the only thing that makes a reminder
     *                             possible at all. Null is treated as false.
     * @param liveStage            `Opportunity.StageName` NOW.
     * @param liveStageEntryDate   `Opportunity.Stage_Entry_Date__c` NOW.
     * @param markerStage          `Stage_Alert_Stage__c` — the stage the last reminder was about.
     * @param markerSentDate       `Stage_Alert_Last_Sent_Date__c` — when it was sent.
     * @return True when a reminder is owed.
     */
    public static Boolean shouldFire(
        Boolean isDelayed,
        String liveStage,
        Date liveStageEntryDate,
        String markerStage,
        Date markerSentDate
    ) {
        if (isDelayed != true) {
            return false;
        }
        // AN ANOMALOUS OR ABSENT MARKER RE-ARMS. Half a marker is not an instruction; an extra
        // reminder is recoverable and a permanently silent deal is not.
        if (String.isBlank(markerStage) || markerSentDate == null) {
            return true;
        }
        // LEG A — the deal moved to a different stage. `equals` is case-sensitive and that is what
        // is wanted here: both sides are `StageName` API values, one of which THIS JOB wrote, so a
        // case difference would mean the picklist value itself changed and re-arming is correct.
        if (!markerStage.equals(liveStage)) {
            return true;
        }
        // LEG B — the deal LEFT and RE-ENTERED the same stage, so the anchor moved past the marker.
        // `<=`, not `<`; see the class header §3 for why, and do not "correct" it.
        if (liveStageEntryDate != null && markerSentDate <= liveStageEntryDate) {
            return true;
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE THRESHOLDS — read from Custom Metadata, resolved once per transaction
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * The live thresholds, keyed by LOWER-CASED stage API name.
     *
     * 🔴 THE CACHE IS A CORRECTNESS PROPERTY, NOT A SPEED TRICK. `StageDelayAlertBatch` evaluates a
     * whole chunk against ONE `asOf` specifically so two deals in one run cannot straddle midnight.
     * The thresholds deserve the same treatment: without the cache, an admin saving a row mid-chunk
     * could measure deal 3 against 14 days and deal 190 against 21, and the marker written for each
     * would be measured against a different configuration. Resolve once, per transaction.
     *
     * @return Stage-to-threshold, never null; may be empty (see `resolveThresholds`).
     */
    @TestVisible
    private static Map<String, Integer> thresholds() {
        if (!thresholdsLoaded) {
            cachedThresholds = resolveThresholds(Stage_Threshold_Def__mdt.getAll().values());
            thresholdsLoaded = true;
        }
        return cachedThresholds;
    }

    /**
     * The configured threshold for one stage, in days.
     *
     * @param stageName `Opportunity.StageName`; null/blank safe.
     * @return The threshold, or NULL when this stage is not tracked (no active row, and rows exist
     *         so the default does not apply). Null means "never fires", not "fires immediately".
     */
    public static Integer thresholdFor(String stageName) {
        if (String.isBlank(stageName)) {
            return null;
        }
        return thresholds().get(stageName.toLowerCase());
    }

    /**
     * THE WORK-QUEUE CEILING: the latest `Stage_Entry_Date__c` a deal can have and still possibly be
     * delayed. Backs `StageDelayAlertBatch.start`, which hands it to
     * `OpportunitySelector.queryStalledDeals`.
     *
     * It is the SMALLEST active threshold — the widest net — because the per-stage decision is made
     * in memory afterwards. A deal whose stage has a larger threshold is read and then skipped.
     *
     * 🔴 THIS IS WHY THE SELECTOR TAKES A PARAMETER RATHER THAN COMPUTING A CEILING ITSELF, AND IT
     * IS A DELIBERATE IMPROVEMENT ON `queryCallForOffersAlerts`, WHOSE HEADER HAS TO APOLOGISE FOR A
     * HARDCODED `+ 7`. That method could not read its ladder because a `Database.QueryLocator`
     * cannot bind an Apex collection — but it CAN bind a single Apex `Date`, computed by the caller.
     * So the thresholds stay in exactly one place and the selector holds no number at all.
     *
     * ⚠ THE CEILING IS A CHEAPNESS OPTIMISATION, NEVER A CORRECTNESS BOUNDARY. Widening it costs
     * rows that `evaluate` then classifies `ON_TRACK`; narrowing it below the smallest active
     * threshold is the only way to break the feature. That is why the empty-threshold case below
     * falls back to the default rather than returning something that selects nothing: an empty
     * configuration is enforced IN MEMORY (`thresholdFor` returns null for every stage, so nothing
     * fires), and letting the ceiling also carry that meaning would put the same rule in two places.
     *
     * @param asOf The date to count back from; null is treated as `Date.today()`.
     * @return The ceiling date. Never null.
     */
    public static Date locatorCeiling(Date asOf) {
        Date today = (asOf == null) ? Date.today() : asOf;
        Integer smallest = null;
        for (Integer t : thresholds().values()) {
            if (smallest == null || t < smallest) {
                smallest = t;
            }
        }
        return today.addDays(-1 * ((smallest == null) ? DEFAULT_THRESHOLD_DAYS : smallest));
    }

    /**
     * Turn CMDT rows into the threshold map: active rows only, lower-cased keys.
     *
     * See the class header §2 for the three degenerate inputs and why each gets a different answer.
     * Do not collapse the no-rows case and the none-active case into one `isEmpty()` test — the
     * distinction between "the loader was never run" and "an admin switched it off" is the entire
     * reason this method counts them separately.
     *
     * @param rows Every `Stage_Threshold_Def__mdt` row in the org; null-safe.
     * @return Lower-cased stage API name to threshold days. Never null.
     */
    @TestVisible
    private static Map<String, Integer> resolveThresholds(List<Stage_Threshold_Def__mdt> rows) {
        Map<String, Integer> resolved = new Map<String, Integer>();

        if (rows == null || rows.isEmpty()) {
            warnOnce('no-rows',
                'Stage_Threshold_Def__mdt HAS NO ROWS. Falling back to a flat '
                + DEFAULT_THRESHOLD_DAYS + '-day threshold for every open stage. This is expected in '
                + 'a fresh org: the rows are created by scripts/load-stage-threshold-defs.apex, NOT '
                + 'by a deploy. Run it — until you do, the thresholds are not tunable in Setup.');
            for (String stage : DEFAULT_TRACKED_STAGES) {
                resolved.put(stage.toLowerCase(), DEFAULT_THRESHOLD_DAYS);
            }
            return resolved;
        }

        for (Stage_Threshold_Def__mdt row : rows) {
            if (row == null || row.Is_Active__c != true) {
                continue;
            }
            if (String.isBlank(row.Stage_Value__c)) {
                warnOnce('blank-stage',
                    'Stage_Threshold_Def__mdt row "' + row.DeveloperName + '" is active but has a '
                    + 'blank Stage_Value__c and was SKIPPED. Set the Opportunity StageName API value '
                    + 'or deactivate the row.');
                continue;
            }
            if (row.Threshold_Days__c == null) {
                warnOnce('null-days',
                    'Stage_Threshold_Def__mdt row "' + row.DeveloperName + '" is active but has a '
                    + 'blank Threshold_Days__c and was SKIPPED. Set a value or deactivate the row.');
                continue;
            }
            Integer days = row.Threshold_Days__c.intValue();
            if (days < 1) {
                // Not skipped — an admin may genuinely want same-day chasing — but warned, because
                // a threshold below 1 is the ONE input under which the `<=` re-arm leg (class header
                // §3) can produce a second reminder inside a single occupancy.
                warnOnce('sub-one',
                    'Stage_Threshold_Def__mdt row "' + row.DeveloperName + '" has Threshold_Days__c = '
                    + days + '. Thresholds below 1 day are honoured but can produce a second reminder '
                    + 'within one stage occupancy — see StageDelayService header §3.');
            }
            resolved.put(row.Stage_Value__c.trim().toLowerCase(), days);
        }

        if (resolved.isEmpty()) {
            warnOnce('none-active',
                'Stage_Threshold_Def__mdt has rows but NONE is active. The stalled-deal reminder is '
                + 'switched OFF: no deal will ever be notified. If that is not intended, activate at '
                + 'least one row in Setup.');
        }
        return resolved;
    }

    /**
     * The eight OPEN Opportunity stages, used ONLY to build the no-rows fallback map.
     *
     * ⚠ THIS IS NOT A SECOND SOURCE OF TRUTH FOR WHICH STAGES ARE CHASED. The moment
     * `Stage_Threshold_Def__mdt` carries one active row, this list is not consulted at all — the
     * rows are. It exists so that the pre-loader fallback covers the same eight stages the loader
     * script seeds, and it deliberately omits `Closed Won` and `Dead/Pass`, both of which carry
     * `IsClosed = true` (verified against `OpportunityStage` in `usman-dpeg`, 2026-08-31) and are
     * already excluded by the selector.
     *
     * ⚠ `Development Review` is Land-only and `Construction Review` is Commercial/Retail-only. Both
     * are listed: a threshold for a stage a given record type cannot reach is inert, not wrong.
     */
    private static final List<String> DEFAULT_TRACKED_STAGES = new List<String>{
        'New',
        'Under Review',
        'Development Review',
        'Construction Review',
        'Underwriting',
        'LOI',
        'Under Contract (PSA)',
        'About to Close'
    };

    /**
     * Log a threshold misconfiguration once per transaction per condition.
     *
     * @param key     Condition key, so a 251-deal chunk emits one line, not 251.
     * @param message The WARN text.
     */
    private static void warnOnce(String key, String message) {
        if (configWarnings.contains(key)) {
            return;
        }
        configWarnings.add(key);
        System.debug(LoggingLevel.WARN, message);
    }

    /**
     * Test seam. Installs a threshold row set and resets the once-per-transaction WARN guards.
     *
     * Exists because **a test cannot insert a `__mdt` row via DML**, and the rows are script-loaded
     * rather than deployed — so an org running this suite may legitimately have none, and a test
     * that depended on the org's live rows would be green here and red there. Injecting the rows is
     * the only way to prove the active filter, the case-insensitive key, the blank/null skips and
     * the three degenerate cases. Same seam, same reason, as
     * `CallForOffersService.overrideRungsForTest` and `BrokerProtectionConfig.overrideForTest`.
     *
     * @param rows The rows to serve; an EMPTY list simulates "the loader was never run".
     */
    @TestVisible
    private static void overrideThresholdsForTest(List<Stage_Threshold_Def__mdt> rows) {
        configWarnings = new Set<String>();
        cachedThresholds = resolveThresholds(rows);
        thresholdsLoaded = true;
    }

    /**
     * Test seam. Drops the injected thresholds so the next read resolves from the org's own CMDT.
     */
    @TestVisible
    private static void clearThresholdOverrideForTest() {
        cachedThresholds = null;
        thresholdsLoaded = false;
        configWarnings = new Set<String>();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RENDERING — shared so the bell, a future badge and the report cannot diverge
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * A stage name safe to drop into a sentence.
     *
     * @param stageName `Opportunity.StageName`; null-safe.
     * @return The stage name, or a readable stand-in.
     */
    private static String describeStage(String stageName) {
        return String.isBlank(stageName) ? 'its current stage' : stageName;
    }

    /** Month abbreviations. See `formatDate` for why this is not `DateTime.format`. */
    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    /**
     * `Aug 20, 2026` — the one date format every consumer of this class shares, so a future badge
     * and the notification body cannot render the same date two ways.
     *
     * ⚠ DELIBERATELY NOT `DateTime.format('MMM d, yyyy')`. That renders in the RUNNING USER's locale
     * and time zone, so the same date reads differently for two people looking at one deal, and any
     * test asserting the string is silently locale-dependent — green on this machine, red on a CI
     * box with a different default. Copied verbatim from `NdaExpiryService.formatDate`.
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
