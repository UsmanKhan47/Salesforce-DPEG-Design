/**
 * The ONE runtime read of `Broker_Protection_Config__mdt` — the single Setup-editable
 * source for the Broker Protection window, the fuzzy lookback, the two confidence
 * thresholds, and the four LLM callout knobs (model, temperature, max tokens, prompt).
 *
 * WS5, 2026-08-30. Before this class those values were nine Apex literals spread across
 * four classes and one formula field. They still exist here — as this class's DEFAULTS —
 * so the behaviour with no config record is byte-identical to the behaviour before WS5.
 *
 * ═══ 🔴 GATE A — THIS CLASS EXISTS BECAUSE A PRIOR REFUSAL WAS OVERRULED ═══
 * `PropertyMatchingService.cls` refused exactly this on the arbitration constants:
 * "lowering it in Setup retroactively re-decides who owns properties that are already
 * claimed... That is a data migration wearing a checkbox. Change it by deploy."
 * The user OVERRULED that on 2026-08-30 (design-requirements.md §0/GATE A, decision A1),
 * accepting the retroactive-release risk ON CONDITION that the mitigation ships WITH the
 * configurability, not after it. Three parts, all live:
 *   • the two arbitration fields carry the warning in their CMDT `description` and
 *     `inlineHelpText`, so it is visible to whoever edits the record in Setup;
 *   • 🔴 THE PRIMARY AUDIT TRAIL IS A DURABLE STAMP, NOT A LOG. `PropertyClaimService`
 *     writes the resolved window onto `Property_Registry__c.Protection_Window_Days__c` on
 *     the row itself, at claim time, on every path that sets `Registered_DateTime__c` (the
 *     new-winner insert and both adoptions). A disputed claim is therefore settled by
 *     querying the row, months later, by anyone;
 *   • `PropertyMatchingService.logResolvedWindow` ALSO logs the resolved window at WARN on
 *     every claim run. That is now the SECONDARY, best-effort half — it costs nothing and
 *     is genuinely useful while a trace flag is active — and it is kept for that reason.
 * None of the three is optional and none may be removed without re-opening GATE A.
 *
 * ⚠ UPGRADED 2026-08-30 (WS8 review, finding W6), AND THE REASON MATTERS MORE THAN THE
 * CHANGE. This block used to name the WARN log as THE audit trail: "the value in force at
 * the time of a disputed claim is reconstructible from the logs after the fact." It is not.
 * A Salesforce debug log exists only while a trace flag is active ON THE EXECUTING
 * PRINCIPAL, and expires (24h retention, 20MB per flag). The claim runs inside an async
 * queueable as the Email Service context user — the principal least likely to be traced.
 * So the condition the user attached to GATE A was, in practice, usually not being met at
 * all. Do not re-demote the stamp to "nice to have": it IS the accepted condition.
 *
 * ═══ LAYER — WHY THERE IS NO SELECTOR ═══
 * `.claude/rules/apex-layering-rule.md` puts ALL SOQL in selector classes. This class
 * issues NO SOQL: `Broker_Protection_Config__mdt.getInstance(...)` is the platform's
 * custom-metadata accessor, not a query. Measured on `usman-dpeg` 2026-08-30 with
 * anonymous Apex: two `getInstance` calls, `Limits.getQueries() == 0`. There is therefore
 * nothing for a selector to own, and adding `[SELECT ... FROM Broker_Protection_Config__mdt]`
 * would ADD a governor cost this class does not currently pay —
 * `ExtractAddressQueueable`'s pinned QUERY_BUDGET (30 at N=1, 120 at N=10) is precisely why
 * that matters.
 *
 * ═══ THE STATIC CACHE, AND WHY IT IS NOT JUST A SPEED TRICK ═══
 * `getInstance` is cheap but not free (it costs CPU, and a 10-property email would resolve
 * the same record dozens of times). More importantly the cache makes the config
 * TRANSACTION-STABLE: one inbound email cannot see a 90-day window on property 3 and a
 * 30-day window on property 7 because an admin saved the record mid-transaction. For a
 * CLAIM-ARBITRATION value that stability is a correctness property, not an optimisation.
 *
 * ═══ 🔴 EVERY ACCESSOR RETURNS A HARDCODED DEFAULT WHEN THE RECORD IS MISSING ═══
 * `.forceignore` excludes the whole `customMetadata` tree (the glob is written without its
 * asterisks here on purpose — the literal pattern contains a comment-terminator sequence and
 * would close this block comment mid-sentence). File-based CMDT record deploy throws
 * UNKNOWN_EXCEPTION in this org, so the `Default` record is created by
 * `scripts/load-broker-protection-config.apex`, NOT by a deploy. "Record absent" is
 * therefore a REACHABLE state in every freshly-built org and in every test run made before
 * the loader is run — measured on `usman-dpeg` 2026-08-30: `getInstance('<missing>')`
 * returns **null**, it does not return an empty row. A null escaping from here would take
 * the whole claim engine down, so nothing here may return null except
 * `extractionPromptOverride()`, which is documented at its own declaration.
 *
 * ═══ NULL AND OUT-OF-RANGE ARE HANDLED DIFFERENTLY, ON PURPOSE ═══
 * A NULL field means "not configured" and silently yields the Apex default — that is the
 * fresh-org case and it is not an error. An OUT-OF-RANGE value is different: it is an
 * admin's typo, and every one of them inverts or disables the thing the value controls.
 * Out-of-range values therefore fall back to the default AND log at WARN, so the
 * misconfiguration is diagnosable instead of silent. Two validators, one per value shape:
 *   • `resolveDays` — rejects NEGATIVES. `Datetime.now().addDays(-(-30))` puts the
 *     protection cutoff 30 days into the FUTURE, expiring EVERY live claim at once — the
 *     exact catastrophe GATE A is about.
 *   • `resolveThreshold` — rejects anything outside `[0, 1]`, because the value is compared
 *     against a model-emitted probability. `confidenceHighMin()` additionally rejects
 *     exactly `0`; the reason is at its own declaration and is not a range question.
 *
 * ⚠ TWO INVARIANTS BETWEEN PAIRS OF FIELDS ARE CLAMPED, NOT REJECTED, because neither can
 * be judged one field at a time: `effectiveLookbackDays()` (lookback >= window) and
 * `effectiveConfidenceMediumMin()` (high >= medium). Each clamp WARNs once per transaction.
 * 🔴 A CALLER THAT READS THE RAW ACCESSOR INSTEAD OF THE `effective*` ONE SILENTLY OPTS OUT
 * OF ITS INVARIANT. That is why both raw accessors say so at their own declarations.
 *
 * ═══ SCOPE — WHAT DELIBERATELY DID *NOT* MOVE HERE ═══
 *   • `LLMExtractionCalloutService.ENDPOINT` — ARCHITECTURE.md §3.3's retirement lever for
 *     the direct-OpenAI exception. A retirement lever in editable Setup config is not a
 *     lever.
 *   • `LLMExtractionCalloutService.LEGACY_RESPONSE_FORMAT` — a deliberately inert rollback
 *     lever (P4). Same reasoning.
 *   • `TIMEOUT_MS`, `MAX_INPUT_CHARS`, `MAX_PROPERTIES_IN_PROMPT` — out of scope (P2), not
 *     requested. ⚠ `MAX_PROPERTIES_IN_PROMPT` staying in Apex while the prompt PROSE that
 *     states the same number moves here is a real divergence risk; it is recorded in
 *     `Extraction_Prompt__c`'s field description.
 *
 * @see Broker_Protection_Config__mdt (the type; its field XML carries the full risk text)
 * @see scripts/load-broker-protection-config.apex (creates the one `Default` record)
 * @see PropertyMatchingService.cls (the arbitration consumer + the GATE A WARN logging)
 * @see LLMExtractionCalloutService.cls (model / temperature / max tokens / prompt)
 * @see LLMExtractionParser.cls (the two confidence thresholds)
 * @see LeadFunnelController.cls (the display window)
 */
public with sharing class BrokerProtectionConfig {

    /** DeveloperName of the single configuration record. The loader writes
     *  `Broker_Protection_Config.Default`; this is the second half of that name. */
    public static final String RECORD_NAME = 'Default';

    // ─────────────────────────────────────────────────────────────────────────
    // DEFAULTS. Each is the exact Apex literal this class replaced, so an org with
    // no config record behaves identically to the pre-WS5 code. Changing a value
    // here changes the FALLBACK, not the live value in an org whose record exists.
    // ─────────────────────────────────────────────────────────────────────────

    /** Was `PropertyMatchingService.PROTECTION_WINDOW_DAYS`. */
    @TestVisible
    private static final Integer DEFAULT_PROTECTION_WINDOW_DAYS = 90;

    /** Was `PropertyMatchingService.LOOKBACK_DAYS`. */
    @TestVisible
    private static final Integer DEFAULT_LOOKBACK_DAYS = 90;

    /** Was `LLMExtractionParser.CONFIDENCE_HIGH_MIN`. */
    @TestVisible
    private static final Decimal DEFAULT_CONFIDENCE_HIGH_MIN = 0.85;

    /** Was `LLMExtractionParser.CONFIDENCE_MEDIUM_MIN`. */
    @TestVisible
    private static final Decimal DEFAULT_CONFIDENCE_MEDIUM_MIN = 0.60;

    /** Was `LLMExtractionCalloutService.MODEL`. */
    @TestVisible
    private static final String DEFAULT_MODEL = 'gpt-4o-mini';

    /** Was the inline literal `0` at `LLMExtractionCalloutService.buildRequestBody` (P2 —
     *  it was never a named constant, which is why this move is an expression change). */
    @TestVisible
    private static final Decimal DEFAULT_TEMPERATURE = 0;

    /** Was `LLMExtractionCalloutService.MAX_TOKENS`. */
    @TestVisible
    private static final Integer DEFAULT_MAX_TOKENS = 4096;

    // ─────────────────────────────────────────────────────────────────────────
    // THE CACHE
    // ─────────────────────────────────────────────────────────────────────────

    /** Separate from `cached` because null is a MEANINGFUL cached value (record absent) —
     *  a null check alone would re-resolve the missing record on every accessor call. */
    private static Boolean cacheLoaded = false;
    private static Broker_Protection_Config__mdt cached;

    /** One WARN per transaction for each invariant clamp, and one for each malformed value,
     *  so a 10-property email does not emit 40 identical lines.
     *  ⚠ THE TWO CLAMPS NEED TWO FLAGS. A single shared boolean would let whichever clamp
     *  fired first silence the other for the rest of the transaction, and the two report
     *  different misconfigurations of different fields. */
    private static Boolean clampWarned = false;
    private static Boolean confidenceClampWarned = false;
    private static Set<String> warnedFields = new Set<String>();

    /**
     * The cached configuration row, or null when the `Default` record has not been loaded.
     * Private on purpose: callers must go through the typed accessors so the defaulting,
     * the clamp and the WARN logging cannot be bypassed by reading a field directly.
     *
     * @return The `Default` record, or null when it does not exist in this org.
     */
    private static Broker_Protection_Config__mdt config() {
        if (!cacheLoaded) {
            cached = Broker_Protection_Config__mdt.getInstance(RECORD_NAME);
            cacheLoaded = true;
        }
        return cached;
    }

    /**
     * Test seam. Installs a row (or null, to simulate a fresh org) into the cache and
     * resets the once-per-transaction WARN guards so a clamp test can observe the WARN.
     *
     * Exists because the `Default` record is script-loaded: a test CANNOT insert a
     * `__mdt` row via DML, so the only way to prove the clamp, the defaults and the
     * negative guard is to inject the row.
     *
     * @param row The configuration row to serve, or null to simulate "record absent".
     */
    @TestVisible
    private static void overrideForTest(Broker_Protection_Config__mdt row) {
        cached = row;
        cacheLoaded = true;
        clampWarned = false;
        confidenceClampWarned = false;
        warnedFields = new Set<String>();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ARBITRATION VALUES (GATE A)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Broker-protection window in days — how long after registration a claim releases.
     *
     * 🔴 CLAIM-ARBITRATION VALUE. Lowering this in Setup retroactively releases every live
     * claim between the old and new value, at once, with no deploy and no audit trail.
     * `PropertyMatchingService` logs the resolved value at WARN on every claim run so a
     * disputed claim can be reconciled against the window that was actually in force.
     *
     * @return The configured window, or 90 when unset/absent/negative.
     */
    public static Integer protectionWindowDays() {
        return resolveDays(
            config() == null ? null : config().Protection_Window_Days__c,
            DEFAULT_PROTECTION_WINDOW_DAYS,
            'Protection_Window_Days__c');
    }

    /**
     * The RAW configured fuzzy-match lookback, BEFORE the invariant clamp.
     *
     * ⚠ Almost nothing should call this — the arbitration path must use
     * `effectiveLookbackDays()`. It is public only so a test, or a future diagnostic, can
     * show what an admin actually typed versus what the engine actually used.
     *
     * @return The configured lookback, or 90 when unset/absent/negative.
     */
    public static Integer configuredLookbackDays() {
        return resolveDays(
            config() == null ? null : config().Lookback_Days__c,
            DEFAULT_LOOKBACK_DAYS,
            'Lookback_Days__c');
    }

    /**
     * The fuzzy-match lookback the engine actually uses — `max(configuredLookback, window)`.
     *
     * ═══ 🔴 THIS IS THE INVARIANT, ENFORCED BY CONSTRUCTION ═══
     * `PropertyMatchingService`'s header states the rule and what breaks:
     * "LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS IS AN INVARIANT, AND IT IS PINNED BY A TEST
     * RATHER THAN GUARANTEED BY CONSTRUCTION. If the protection window were ever set LONGER
     * than the fuzzy lookback, a claim in the gap would be protected on the exact path and
     * INVISIBLE on the fuzzy path."
     *
     * A test pin was sufficient while both values were Apex literals — a violation could
     * only arrive through a deploy, and the deploy would go red. WS5 makes both editable in
     * Setup, where NO Apex test can see them, so the pin alone is no longer enforcement at
     * all. The clamp is what replaces it: an admin can still type a violating pair, but the
     * engine cannot act on it. The WARN below is how that misconfiguration becomes visible
     * rather than merely harmless — a clamped org is running a lookback its admin did not
     * ask for, and someone needs to go fix the record.
     *
     * @return `max(configuredLookbackDays(), protectionWindowDays())`; never less than the
     *         protection window.
     */
    public static Integer effectiveLookbackDays() {
        Integer configured = configuredLookbackDays();
        Integer window = protectionWindowDays();
        if (configured >= window) {
            return configured;
        }
        if (!clampWarned) {
            clampWarned = true;
            System.debug(LoggingLevel.WARN,
                'BROKER PROTECTION CONFIG CLAMPED: Lookback_Days__c (' + configured
                + ') is less than Protection_Window_Days__c (' + window + '). Using '
                + window + ' as the effective lookback. A claim in that gap would be '
                + 'protected on the exact path and INVISIBLE on the fuzzy path. FIX THE '
                + 'Broker_Protection_Config__mdt.' + RECORD_NAME + ' RECORD IN SETUP.');
        }
        return window;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONFIDENCE BANDS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lower bound of the HIGH confidence band — AND THE SUPPRESSION GATE ITSELF.
     *
     * 🔴 NOT A DISPLAY BAND. `ExtractAddressQueueable`'s suppression HARD GATE is
     * `is_acquisition_related = false AND confidence >= this value`, so changing it in
     * Setup changes which emails are silently suppressed — no Lead, no registry claim, no
     * exception and no log. Restated in the field's `description`.
     *
     * ═══ 🔴 WHY THIS ACCESSOR IS GUARDED AND NOT A BARE NULL-COALESCE (WS8, 2026-08-30) ═══
     * It used to be `value == null ? DEFAULT : value` — every configured number accepted as
     * typed. `effectiveLookbackDays()` above states the argument that condemns that shape:
     * *"WS5 makes both editable in Setup, where NO Apex test can see them, so the pin alone
     * is no longer enforcement at all."* That argument was written for the day counts and
     * was never applied here, even though THIS value is the one wired to a gate that fails
     * SILENTLY. A negative or `0` here makes `confidence >= threshold` true for every
     * extraction the model marks non-acquisition, so every such email is suppressed with
     * nothing thrown and nothing logged — the failure mode with the fewest symptoms in the
     * whole module.
     *
     * TWO REJECTIONS, DELIBERATELY DIFFERENT FROM `confidenceMediumMin()`'s ONE:
     *   • OUTSIDE `[0, 1]` — structurally impossible for a probability. Shared with the
     *     MEDIUM accessor via `resolveThreshold`.
     *   • EXACTLY `0` — legal as a probability, catastrophic as THIS gate's floor, because
     *     at zero the gate stops discriminating and becomes "trust the model
     *     unconditionally". `null` already means "use the default", so `0` carries no
     *     meaning an admin could have intended; it is a cleared field or a typo. This
     *     rejection is NOT shared with `confidenceMediumMin()`, where `0` is a legitimate
     *     (if unusual) choice meaning "nothing is ever banded LOW" and drives no gate.
     *
     * A rejected value falls back to 0.85 AND logs at WARN — the same null-is-silent /
     * malformed-is-loud split the class header describes for the day counts.
     *
     * @return The configured threshold when it is in `(0, 1]`; otherwise 0.85.
     */
    public static Decimal confidenceHighMin() {
        Decimal resolved = resolveThreshold(
            config() == null ? null : config().Confidence_High_Min__c,
            DEFAULT_CONFIDENCE_HIGH_MIN,
            'Confidence_High_Min__c');
        if (resolved == 0) {
            warnOnce('Confidence_High_Min__c', resolved, DEFAULT_CONFIDENCE_HIGH_MIN);
            return DEFAULT_CONFIDENCE_HIGH_MIN;
        }
        return resolved;
    }

    /**
     * The RAW configured lower bound of the MEDIUM confidence band, BEFORE the invariant
     * clamp. Below this bound the band is LOW.
     *
     * ⚠ Almost nothing should call this — the banding path must use
     * `effectiveConfidenceMediumMin()`. It is public, exactly like `configuredLookbackDays()`
     * and for the same reason: so a test or a diagnostic can show what an admin typed versus
     * what the parser used.
     *
     * `0` is ACCEPTED here (it means "nothing is ever LOW") and is rejected by
     * `confidenceHighMin()` — see that method for why the two differ.
     *
     * @return The configured threshold when it is in `[0, 1]`; otherwise 0.60.
     */
    public static Decimal confidenceMediumMin() {
        return resolveThreshold(
            config() == null ? null : config().Confidence_Medium_Min__c,
            DEFAULT_CONFIDENCE_MEDIUM_MIN,
            'Confidence_Medium_Min__c');
    }

    /**
     * The MEDIUM floor the parser actually uses — `min(confidenceMediumMin(), confidenceHighMin())`.
     *
     * ═══ 🔴 THE ORDERING INVARIANT, ENFORCED BY CONSTRUCTION ═══
     * `LLMExtractionParser` bands HIGH at `>= CONFIDENCE_HIGH_MIN` and MEDIUM at
     * `>= CONFIDENCE_MEDIUM_MIN`, which is only coherent while `high >= medium`. Both were
     * Apex literals until WS5, so a violation could only arrive through a deploy. They are
     * now Setup data, where no Apex test can see them — the identical situation
     * `effectiveLookbackDays()` was built for, and it gets the identical answer: an admin can
     * still type a violating pair, but the engine cannot act on it.
     *
     * ⚠ THE CLAMP MOVES *MEDIUM*, NEVER *HIGH*, AND THAT DIRECTION IS THE WHOLE DESIGN.
     * `effectiveLookbackDays()` raises the lookback to meet the window; the symmetric move
     * here would be raising HIGH to meet MEDIUM. It must not: `confidenceHighMin()` IS the
     * suppression gate, so a clamp that moved it would let a mistyped MEDIUM silently change
     * which emails are suppressed — a clamp doing the exact thing GATE A exists to prevent.
     * Moving MEDIUM instead can only collapse the MEDIUM band to empty, which is visible on
     * the record (`Parse_Confidence__c` reads HIGH or LOW and never MEDIUM) and changes no
     * routing decision anywhere.
     *
     * @return `min(confidenceMediumMin(), confidenceHighMin())`; never above the HIGH floor.
     */
    public static Decimal effectiveConfidenceMediumMin() {
        Decimal configured = confidenceMediumMin();
        Decimal high = confidenceHighMin();
        if (configured <= high) {
            return configured;
        }
        if (!confidenceClampWarned) {
            confidenceClampWarned = true;
            System.debug(LoggingLevel.WARN,
                'BROKER PROTECTION CONFIG CLAMPED: Confidence_Medium_Min__c (' + configured
                + ') is greater than Confidence_High_Min__c (' + high + '). Using ' + high
                + ' as the effective MEDIUM floor, which collapses the MEDIUM band to empty. '
                + 'FIX THE Broker_Protection_Config__mdt.' + RECORD_NAME + ' RECORD IN SETUP.');
        }
        return high;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LLM CALLOUT KNOBS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The chat-completions model identifier sent in the request BODY.
     *
     * 🔴 This is the model only. The callout ENDPOINT stays hardcoded in
     * `LLMExtractionCalloutService` — it is ARCHITECTURE.md §3.3's retirement lever for the
     * direct-OpenAI exception and must not become editable.
     *
     * @return The configured model, or 'gpt-4o-mini' when unset/blank or the record is absent.
     */
    public static String model() {
        String value = config() == null ? null : config().Model__c;
        return String.isBlank(value) ? DEFAULT_MODEL : value;
    }

    /**
     * Sampling temperature. 0 is the value this pipeline was built and tested against;
     * anything higher introduces run-to-run variance in `broker_email` and
     * `property_address`, which ARE the registry claim key.
     *
     * @return The configured temperature, or 0 when unset or the record is absent.
     */
    public static Decimal temperature() {
        Decimal value = config() == null ? null : config().Temperature__c;
        return value == null ? DEFAULT_TEMPERATURE : value;
    }

    /**
     * Maximum completion tokens for the extraction callout. Returned as an Integer so the
     * serialized body reads `"max_tokens":4096` rather than a scaled Decimal.
     *
     * @return The configured cap, or 4096 when unset/absent/non-positive.
     */
    public static Integer maxTokens() {
        Decimal value = config() == null ? null : config().Max_Tokens__c;
        if (value == null) {
            return DEFAULT_MAX_TOKENS;
        }
        if (value <= 0) {
            warnOnce('Max_Tokens__c', value, DEFAULT_MAX_TOKENS);
            return DEFAULT_MAX_TOKENS;
        }
        return value.intValue();
    }

    /**
     * The Setup-configured extraction prompt, or NULL when there is no override.
     *
     * 🔴 THIS IS THE ONE ACCESSOR THAT MAY RETURN NULL, AND THE DEVIATION IS DELIBERATE.
     * Every other accessor holds its own hardcoded default. This one cannot: its default is
     * `LLMExtractionCalloutService.EXTRACTION_INSTRUCTION`, 20,592 characters of prompt
     * (post-WS7; this said 19,254 until WS8's review — the pre-WS7 figure, and the exact
     * stale number that had already caused one loader defect)
     * that is the property of the class that OWNS the OpenAI boundary. Copying it here
     * would create a second, silently-divergeable copy of the exact text whose drift
     * re-keys the broker registry — the precise failure this whole area is defended
     * against. Inverting the dependency (config reaching into the callout service) would be
     * worse still: a config accessor would then depend on an integration class.
     *
     * So the CONTRACT is "null means no override", and the single caller
     * (`LLMExtractionCalloutService.buildRequestBody`) resolves the default from its own
     * constant. That call site is the enforcement point; if a second caller ever appears it
     * must do the same, and it must not invent a different default.
     *
     * @return The configured prompt, or null when unset/blank or the record is absent.
     */
    public static String extractionPromptOverride() {
        String value = config() == null ? null : config().Extraction_Prompt__c;
        return String.isBlank(value) ? null : value;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Resolve a day-count field: null falls back silently (the fresh-org case, not an
     * error), a negative falls back LOUDLY (an admin typo that would invert the value's
     * meaning — a negative window puts the protection cutoff in the FUTURE and expires
     * every live claim at once).
     *
     * @param configured The raw CMDT value; may be null.
     * @param fallback   The Apex default for this field.
     * @param fieldName  API name, for the WARN message.
     * @return The configured value when usable, otherwise `fallback`.
     */
    private static Integer resolveDays(Decimal configured, Integer fallback, String fieldName) {
        if (configured == null) {
            return fallback;
        }
        if (configured < 0) {
            warnOnce(fieldName, configured, fallback);
            return fallback;
        }
        return configured.intValue();
    }

    /**
     * Resolve a CONFIDENCE-THRESHOLD field: null falls back silently (the fresh-org case,
     * not an error), a value outside `[0, 1]` falls back LOUDLY.
     *
     * The `resolveDays` mirror, for probabilities. `resolveDays` rejects only negatives
     * because a day count has no upper bound that means anything; a confidence threshold is
     * compared against a model-emitted probability, so `1` is a real ceiling — above it the
     * band it guards becomes unreachable, which for `Confidence_High_Min__c` means the
     * suppression gate silently stops firing.
     *
     * ⚠ IT DOES NOT ENFORCE `high >= medium` — that is an invariant BETWEEN two fields and
     * cannot be judged one field at a time. `effectiveConfidenceMediumMin()` owns it.
     *
     * @param configured The raw CMDT value; may be null.
     * @param fallback   The Apex default for this field.
     * @param fieldName  API name, for the WARN message.
     * @return The configured value when it is in `[0, 1]`, otherwise `fallback`.
     */
    private static Decimal resolveThreshold(Decimal configured, Decimal fallback, String fieldName) {
        if (configured == null) {
            return fallback;
        }
        if (configured < 0 || configured > 1) {
            warnOnce(fieldName, configured, fallback);
            return fallback;
        }
        return configured;
    }

    /**
     * Emit one WARN per field per transaction for a malformed configured value.
     *
     * ⚠ `fallback` is a Decimal so the day counts (Integer) and the confidence thresholds
     * (Decimal) share one implementation; Apex widens the Integer callers implicitly.
     *
     * @param fieldName API name of the offending field.
     * @param configured The rejected value.
     * @param fallback  The value used instead.
     */
    private static void warnOnce(String fieldName, Decimal configured, Decimal fallback) {
        if (warnedFields.contains(fieldName)) {
            return;
        }
        warnedFields.add(fieldName);
        System.debug(LoggingLevel.WARN,
            'BROKER PROTECTION CONFIG REJECTED A VALUE: Broker_Protection_Config__mdt.'
            + RECORD_NAME + '.' + fieldName + ' is ' + configured
            + ', which is not usable. Falling back to ' + fallback
            + '. FIX THE RECORD IN SETUP.');
    }
}
