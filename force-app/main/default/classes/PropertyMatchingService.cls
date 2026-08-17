/**
 * Broker-Protection first-broker-wins matching (CHUNK 2). Pure address-normalization
 * and Jaccard similarity plus selector-backed lookups against the Property_Registry__c
 * ledger — it decides WHETHER an inbound property already has a winner, an orphaned
 * registration, or nothing. It never writes; PropertyClaimService owns all claim /
 * duplicate DML and calls back into these read helpers.
 *
 * STAGING MODEL — this class also owns the two READ decisions that let the routing tree
 * recognise an email that must NOT become a new Lead: findRecordByReplyHeaders (an RFC
 * reply inside an existing conversation) and findBrokerSubmission (a repeat from a broker
 * who already submitted the same property), plus the two pure helpers those need —
 * computeThreadKey (the RFC conversation root) and resolveLiveRecord (a converted Lead's
 * live Opportunity/Contact). They live here, next to normalizeAddress and
 * calculateSimilarity, because repeat detection reuses the module's exact-then-Jaccard
 * address comparison verbatim; splitting them out would fork that matching logic.
 *
 * LAYER — Service (read side). Per ARCHITECTURE.md §2 all SOQL stays in the selectors:
 * this class never queries an SObject itself, it delegates every read to
 * PropertyRegistrySelector, CompetingBrokerSubmissionSelector, TaskSelector and
 * LeadSelector. No DML, no callouts. normalizeAddress, calculateSimilarity,
 * deriveClusterKey and computeThreadKey are pure functions with no platform dependency,
 * so tests can assert them directly.
 *
 * SIGNATURE CONTRACT — the constants and the ten public static methods are the exact
 * bindings CHUNK 3 / the claim writer wire to (SIMILARITY_THRESHOLD, LOOKBACK_DAYS,
 * PROTECTION_WINDOW_DAYS, normalizeAddress, calculateSimilarity, findMatchingRegistry,
 * findOrphanedRegistry, findExpiredRegistry, deriveClusterKey, findBrokerSubmission,
 * computeThreadKey, findRecordByReplyHeaders, resolveLiveRecord). Do not rename or change
 * their parameters/return types.
 *
 * ═══ 🔴 THE PROTECTION WINDOW — ONE RECENCY RULE, THREE READS (added 2026-08-17) ═══
 * FSD tranche 3 item 1. Until this change the module answered "is this property already
 * claimed?" with three reads and TWO different recency policies:
 *
 *   read                                            | before      | after
 *   ------------------------------------------------|-------------|-----------
 *   findMatchingRegistry, EXACT key                  | NEVER expired | windowed
 *   findMatchingRegistry, FUZZY scan                 | 90 days     | unchanged
 *   findBrokerSubmission, REPEAT detection           | 90 days     | unchanged
 *
 * The consequence was a live defect: past day 90 the SAME property produced OPPOSITE
 * outcomes depending only on whether the second broker happened to word the address
 * identically to the first (exact hit -> incumbent keeps it for ever) or differently
 * (fuzzy miss -> new broker wins, and a SECOND registry row is minted for one building).
 * This is not "an expiry feature" bolted on; it is making the third read agree with the
 * two that already agreed with each other.
 *
 * 🔴 LOOKBACK_DAYS >= PROTECTION_WINDOW_DAYS IS AN INVARIANT, AND IT IS PINNED BY A TEST
 * RATHER THAN GUARANTEED BY CONSTRUCTION. If the protection window were ever set LONGER
 * than the fuzzy lookback, a claim in the gap would be protected on the exact path and
 * INVISIBLE on the fuzzy path — reintroducing exactly the asymmetry above, in a new place.
 * The two constants stay separate (they answer different questions and may legitimately
 * diverge upward on the lookback side) and are held together by
 * PropertyMatchingServiceTest, the same arrangement CallForOffersService uses for
 * CRITICAL_DAYS / APPROACHING_DAYS against ALERT_INTERVALS.
 *
 * ⚠ "90" IS HARDCODED IN FIVE PLACES AND FORMULAS CANNOT READ APEX CONSTANTS. The register,
 * so a future change moves all of them:
 *   1. PropertyMatchingService.LOOKBACK_DAYS            (this class)
 *   2. PropertyMatchingService.PROTECTION_WINDOW_DAYS   (this class)
 *   3. LeadFunnelController.BP_WINDOW_DAYS
 *   4. Lead.BP_Expiry__c                                (formula: First_Seen_Date + 90)
 *   5. Property_Registry__c.Protection_Expiry_Date__c   (formula; ADMIN item A1 — see the
 *      report note: not created by this change, and its absence does not affect behaviour,
 *      only visibility)
 * Sites 4 and 5 are DISPLAY ONLY. Nothing in the arbitration path reads either.
 *
 * ⚠ CONFIGURABILITY WAS CONSIDERED AND REFUSED (design §1.7). This is a claim-ARBITRATION
 * constant, so lowering it in Setup retroactively re-decides who owns properties that are
 * already claimed — every claim between the new and old value releases at once, and the
 * next email on any of them mints a new winner, with no deploy, no review and no audit.
 * That is a data migration wearing a checkbox. Change it by deploy.
 *
 * ✅ FUZZY DUAL-WINNER RACE — NOW CLOSED (W4). Previously race-safety was exact-string
 * only: the unique index on Property_Registry__c.Property_Key__c stopped two
 * BYTE-IDENTICAL claims, but two simultaneous DIFFERENTLY-worded-but-similar claims
 * could each read "no exact match", each pass the fuzzy check against rows predating the
 * other, and both insert distinct Property_Key__c rows — both "winning" the same
 * property. PropertyClaimService.claim() now SERIALISES same-property claims behind a
 * pessimistic FOR UPDATE row lock on Property_Claim_Lock__c before it decides a winner:
 * it derives a COARSE cluster key (deriveClusterKey), get-or-creates that cluster's lock
 * row, acquires a FOR UPDATE lock on it (blocking any concurrent same-cluster claim
 * until the first commits), and only THEN runs findMatchingRegistry + the insert. The
 * second claimant therefore sees the first's committed registry and correctly becomes a
 * duplicate — no dual winners — while the 60%-similarity fuzzy tolerance is preserved
 * unchanged (the inner fuzzy match still distinguishes genuinely different buildings that
 * happen to share a coarse cluster).
 *
 * ⚠ deriveClusterKey GAINED A SECOND JOB ON 2026-07-31 (D1 multi-property). It is still the
 * lock-partition key, but ExtractAddressQueueable now ALSO sorts a multi-property email's
 * work-list by it, so that concurrent jobs acquire shared locks in the same relative order
 * and cannot deadlock. Two consequences for anyone changing this method:
 *   • it must stay a PURE function of the normalized address — a key that varied with the
 *     LLM's array order, or with anything else per-transaction, would silently break the
 *     ordering guarantee while still looking correct;
 *   • the caller de-duplicates on the NORMALIZED ADDRESS, never on this key. Two genuinely
 *     different buildings sharing a coarse key is expected and safe (re-locking the same row
 *     inside one transaction is a no-op); collapsing on it would drop a real property.
 *
 * ⚠ RESIDUAL (bounded by design): the lock only serialises claims that derive the SAME
 * cluster key. Two addresses that are fuzzy-similar yet derive DIFFERENT cluster keys
 * would not serialise and could still both win. That is why deriveClusterKey is
 * deliberately COARSE (street number + first street-name token): coarseness maximises the
 * chance that fuzzy variants land in one bucket, and it can only ever cost extra lock
 * contention, never correctness (the inner fuzzy match is still the arbiter within a
 * bucket). The honest tradeoff is: coarser key = fewer missed serialisations but more
 * contention; a full-normalized-string key would put every fuzzy variant in its own
 * bucket and reopen exactly the race this closes.
 *
 * @see PropertyRegistrySelector.cls (all reads route here)
 * @see PropertyClaimLockSelector.cls (the FOR UPDATE lock query used to serialise claims)
 * @see PropertyClaimService.cls (the write side that consumes these decisions + holds the lock)
 */
public with sharing class PropertyMatchingService {

    /** Minimum Jaccard score at which two normalized addresses are treated as the same
     *  property on the fuzzy path. */
    public static final Decimal SIMILARITY_THRESHOLD = 0.6;

    /** Fuzzy-match recency window (days): only registrations claimed within the last
     *  LOOKBACK_DAYS are considered candidates. */
    public static final Integer LOOKBACK_DAYS = 90;

    /**
     * Broker-protection window (days): a registration older than this RELEASES the
     * property, so a later broker can win it. Applies to the EXACT-key claim read; the
     * fuzzy leg is already bounded by LOOKBACK_DAYS.
     *
     * 🔴 A CONVERTED WINNER IS EXEMPT — its claim never expires. See
     * PropertyRegistrySelector.selectLiveByPropertyKey for why that is what makes the
     * adoption update admissible at all, and for the stated converted-then-dead residual.
     *
     * 🔴 MUST BE <= LOOKBACK_DAYS. Pinned by PropertyMatchingServiceTest, not by
     * construction; the class header explains what breaks if it is not.
     */
    public static final Integer PROTECTION_WINDOW_DAYS = 90;

    /**
     * The opening edge of the protection window, relative to now — the single place the
     * cutoff Datetime is derived, so the live read and the expired read can never be
     * computed from two different clocks or two different constants.
     *
     * @return `Datetime.now()` minus PROTECTION_WINDOW_DAYS.
     */
    private static Datetime protectionCutoff() {
        return Datetime.now().addDays(-PROTECTION_WINDOW_DAYS);
    }

    /**
     * Canonicalize a raw property address into the atomic claim key. Blank in → '' out.
     * Otherwise: lowercase, replace every non-alphanumeric, non-whitespace character
     * with a single space, collapse runs of whitespace to one space, and trim. The
     * result is what becomes Property_Key__c (the unique dedup key) and
     * Normalized_Address__c, so two addresses that differ only in punctuation / casing /
     * spacing map to the same key and collide on the unique index.
     *
     * @param raw The inbound property address text; null/blank returns ''.
     * @return The normalized address, or '' when `raw` is null/blank.
     * @example
     * String key = PropertyMatchingService.normalizeAddress('123 Main St., Suite #4');
     * // 'key' == '123 main st suite 4'
     */
    public static String normalizeAddress(String raw) {
        if (String.isBlank(raw)) {
            return '';
        }
        return raw.toLowerCase()
                  .replaceAll('[^a-z0-9\\s]', ' ')
                  .replaceAll('\\s+', ' ')
                  .trim();
    }

    /**
     * Derive the COARSE cluster-partition key for a normalized address — the bucket key
     * used to serialise concurrent same-property claims
     * (Property_Claim_Lock__c.Cluster_Key__c).
     *
     * The key is the street NUMBER plus the FIRST alphabetic street-name token, so fuzzy
     * variants collapse into one bucket: '123 main street', '123 main st' and
     * '123 main street unit 4' all derive '123 main'. This is intentionally coarser than the
     * exact Property_Key__c (the full normalized string): a coarse bucket is what co-locates
     * fuzzy variants under one FOR UPDATE lock, while the inner findMatchingRegistry fuzzy
     * match still distinguishes genuinely different buildings that happen to share a bucket —
     * so coarseness only ever affects lock CONTENTION, never correctness. Falls back to the
     * full normalized string when no number or no alphabetic token can be derived (e.g. a
     * name-only address), which is still a valid — if narrower — bucket.
     *
     * The input is expected to be already normalized (lowercased, punctuation-stripped,
     * single-spaced) by normalizeAddress; blank in -> '' out. The number need not be the
     * first token (an address like 'main street 123' still yields '123 main').
     *
     * @param normalized The normalized property address (from normalizeAddress); null/blank
     *                   returns ''.
     * @return The coarse cluster key ('<number> <firstAlphaToken>'), or the full normalized
     *         string when a number + token pair cannot be derived, or '' when blank.
     * @example
     * String bucket = PropertyMatchingService.deriveClusterKey('123 main street unit 4');
     * // bucket == '123 main'
     */
    public static String deriveClusterKey(String normalized) {
        if (String.isBlank(normalized)) {
            return '';
        }
        String streetNumber = null;
        String streetToken = null;
        for (String token : normalized.split('\\s+')) {
            if (String.isBlank(token)) {
                continue;
            }
            if (streetNumber == null && token.isNumeric()) {
                streetNumber = token;
            } else if (streetToken == null && isAlphaToken(token)) {
                streetToken = token;
            }
            if (streetNumber != null && streetToken != null) {
                break;
            }
        }
        return (streetNumber != null && streetToken != null)
            ? streetNumber + ' ' + streetToken
            : normalized;
    }

    /**
     * True when every character of `token` is a letter — a purely alphabetic street-name
     * token. A blank token is not alphabetic.
     *
     * @param token The token to test.
     * @return true when `token` is non-blank and all letters.
     */
    private static Boolean isAlphaToken(String token) {
        return String.isNotBlank(token) && token.isAlpha();
    }

    /**
     * Jaccard similarity of two addresses over their space-split word tokens:
     * |A ∩ B| / |A ∪ B|. Returns 0 when either input is blank or when the token union
     * is empty. Order-independent and duplicate-token-insensitive (tokens are Sets), so
     * '100 main st' and 'main st 100' score 1.0.
     *
     * @param a First address (typically already normalized); blank returns 0.
     * @param b Second address (typically already normalized); blank returns 0.
     * @return A Decimal in [0, 1]; 0 when either input is blank or the union is empty.
     * @example
     * Decimal s = PropertyMatchingService.calculateSimilarity('100 main st', '100 main street');
     * // s == 0.5  (2 shared of {100, main, st, street})
     */
    public static Decimal calculateSimilarity(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) {
            return 0;
        }
        Set<String> tokensA = toTokenSet(a);
        Set<String> tokensB = toTokenSet(b);

        Set<String> unionTokens = new Set<String>(tokensA);
        unionTokens.addAll(tokensB);
        if (unionTokens.isEmpty()) {
            return 0;
        }

        Set<String> intersectionTokens = new Set<String>(tokensA);
        intersectionTokens.retainAll(tokensB);

        Decimal intersectionSize = intersectionTokens.size();
        return intersectionSize / unionTokens.size();
    }

    /**
     * Find the existing WINNING registration for a normalized address, exact match
     * first then fuzzy. Blank in → null.
     *
     * ⚠ "EXISTING WINNING REGISTRATION" MEANS **LIVE**, NOT MERELY PRESENT (2026-08-17).
     * Both legs are now bounded by the same recency policy: the exact leg by
     * PROTECTION_WINDOW_DAYS and the fuzzy leg by LOOKBACK_DAYS (equal today, and pinned
     * that way). A registration older than the window with an UNCONVERTED winner is
     * reported here as NO WINNER, which is what releases the property — and is why
     * PropertyClaimService.registerWinner must be able to ADOPT the expired row rather
     * than insert over it (see findExpiredRegistry).
     *
     * 🔴 CHANGING THIS ONE FUNCTION FLIPS AN EXPIRED PROPERTY EVERYWHERE AT ONCE, AND THAT
     * IS THE DESIGN GOAL. ExtractAddressQueueable's branch (d) (competing) and branch (e)
     * (winner) both route off this call, and claim()'s in-lock authority calls it too — so
     * the pre-read and the in-lock decision cannot disagree about whether a claim has
     * expired. Nothing in ExtractAddressQueueable was touched to add the window.
     *
     * Exact: the WINDOWED unique Property_Key__c lookup
     * (PropertyRegistrySelector.selectLiveByPropertyKey); if any row comes back it
     * is the definitive winner and is returned immediately. Fuzzy: otherwise scan the
     * winners registered within the last LOOKBACK_DAYS
     * (PropertyRegistrySelector.selectRecentWithWinner) and return the single candidate
     * with the highest calculateSimilarity that is at least SIMILARITY_THRESHOLD; null
     * when none clear the bar. The selector already excludes null-winner rows, so no
     * winner re-check is done here.
     *
     * @param normalized The normalized property address (from normalizeAddress);
     *                   null/blank returns null.
     * @return The winning Property_Registry__c (exact or best fuzzy), or null when the
     *         property has no live winner.
     * @example
     * Property_Registry__c winner =
     *     PropertyMatchingService.findMatchingRegistry(normalized);
     */
    public static Property_Registry__c findMatchingRegistry(String normalized) {
        if (String.isBlank(normalized)) {
            return null;
        }

        List<Property_Registry__c> exact = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ normalized }, protectionCutoff());
        if (!exact.isEmpty()) {
            return exact[0];
        }

        Datetime cutoff = Datetime.now().addDays(-LOOKBACK_DAYS);
        Property_Registry__c best = null;
        Decimal bestScore = -1;
        for (Property_Registry__c candidate : PropertyRegistrySelector.selectRecentWithWinner(cutoff)) {
            Decimal score = calculateSimilarity(normalized, candidate.Normalized_Address__c);
            if (score >= SIMILARITY_THRESHOLD && score > bestScore) {
                best = candidate;
                bestScore = score;
            }
        }
        return best;
    }

    /**
     * Find the ORPHANED registration for a normalized address — a registry row whose
     * winner was later deleted (Winning_Lead__c SetNull to null), leaving the unique
     * Property_Key__c occupied but unclaimed. Blank in → null.
     *
     * This is the row PropertyClaimService adopts when a claim loses the insert race but
     * the previous winner has since vanished: without adoption the unique key would be
     * permanently unclaimable (a new insert on the same key still collides with the
     * orphan). Delegates to PropertyRegistrySelector.selectOrphanByPropertyKey and
     * returns its first row (the key is unique, so there is at most one).
     *
     * @param normalized The normalized property address; null/blank returns null.
     * @return The orphaned Property_Registry__c for that key, or null when there is
     *         none (unregistered key, or the key already has a winner).
     * @example
     * Property_Registry__c orphan =
     *     PropertyMatchingService.findOrphanedRegistry(normalized);
     */
    public static Property_Registry__c findOrphanedRegistry(String normalized) {
        if (String.isBlank(normalized)) {
            return null;
        }
        List<Property_Registry__c> orphans =
            PropertyRegistrySelector.selectOrphanByPropertyKey(normalized);
        return orphans.isEmpty() ? null : orphans[0];
    }

    /**
     * Find the EXPIRED registration for a normalized address — a registry row that still
     * names a winner, but whose protection window closed and whose winning Lead is NOT
     * converted. Blank in -> null. Deliberately shaped as findOrphanedRegistry's twin: one
     * selector call, first row or null, no fuzzy fallback (the key is exact and unique).
     *
     * 🔴 IT IS CALLED FROM EXACTLY ONE PLACE — PropertyClaimService.registerWinner's
     * DUPLICATE_VALUE catch — AND THAT IS WHY THE WINDOW COSTS ZERO EXTRA SOQL ON EVERY
     * ORDINARY PATH. The cutoff on the LIVE read is a bind variable on a query that
     * already ran; this second read only happens when a claim actually collided with an
     * expired key, which is rare by construction.
     *
     * ⚠ WITHOUT THIS READ, A DATE FILTER ALONE IS A SILENT, PERMANENT CLAIM SINK. The
     * expired row still occupies the unique Property_Key__c, so the new winner's insert
     * throws DUPLICATE_VALUE; the re-check finds no live winner; and the row is not an
     * ORPHAN because it has a winner — so the claim falls through to UNCLAIMED and the key
     * becomes unclaimable by anyone, for ever, with no error anywhere. Anyone
     * "simplifying" the expiry down to the WHERE clause reintroduces that.
     *
     * @param normalized The normalized property address; null/blank returns null.
     * @return The expired, unconverted-winner Property_Registry__c for that key, or null
     *         when there is none (unregistered, still inside the window, or the winner has
     *         converted so the claim does not expire).
     * @example
     * Property_Registry__c expired =
     *     PropertyMatchingService.findExpiredRegistry(normalized);
     */
    public static Property_Registry__c findExpiredRegistry(String normalized) {
        if (String.isBlank(normalized)) {
            return null;
        }
        List<Property_Registry__c> expired =
            PropertyRegistrySelector.selectExpiredByPropertyKey(normalized, protectionCutoff());
        return expired.isEmpty() ? null : expired[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STAGING-MODEL ROUTING READS — repeat detection + RFC reply threading.
    //
    // These four back branches (a) and (b) of ExtractAddressQueueable's routing tree,
    // which run BEFORE any Lead is created. They exist so the pipeline can recognise an
    // email it should NOT turn into a new Lead: a reply inside an existing conversation,
    // or a follow-up from a broker who already submitted the same property. Like the
    // methods above they are read-only — every write stays in PropertyClaimService.
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * REPEAT DETECTION — the earliest submission by `brokerEmail` for the same property as
     * `normalizedAddress`, or null. A hit means this broker has already submitted this
     * property, so the inbound email is a follow-up that belongs on an EXISTING record rather
     * than becoming a second Lead.
     *
     * WHICH record depends on which broker is repeating, and the caller resolves it from the
     * two lookups on the row returned here:
     *   • `Source_Lead__c` populated — the WINNER re-emailing about the property they claimed.
     *     Their follow-up belongs on their own Lead.
     *   • `Source_Lead__c` NULL — a COMPETING broker re-emailing. Since 2026-07-31 a competing
     *     broker receives no Lead of their own, so there is nothing of theirs to append to and
     *     the follow-up belongs on `Winning_Lead__c` — the Lead that actually holds the
     *     property — alongside their submission row.
     * Null-source rows are therefore MATCHED, not skipped. Both this method and
     * CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail used to exclude them; both
     * exclusions were removed together, because either one alone would have made a competing
     * broker's follow-up invisible to repeat detection and turned every re-send into a fresh
     * competing claim.
     *
     * MATCHING IS DONE IN MEMORY, NOT IN SOQL, and that is forced by the schema:
     * Competing_Broker_Submission__c stores only Property_Address_Raw__c — the address as
     * the broker typed it. There is no normalized key column on this object (Property_Key__c
     * lives on Property_Registry__c), so a SOQL equality filter would compare a normalized
     * key against raw text and match almost nothing. Each candidate is therefore normalized
     * here with the SAME normalizeAddress the claim path uses, and compared exact-first,
     * then Jaccard — which gives repeat detection identical fuzzy tolerance to
     * findMatchingRegistry rather than a stricter, inconsistent one.
     *
     * The candidate set is bounded by the selector: this broker's submissions only, within
     * LOOKBACK_DAYS, LIMIT 200 — one query, no SOQL in the loop.
     *
     * Ordering matters: the selector returns oldest-first, so the exact-match short circuit
     * returns the ORIGINAL submission (whose Source_Lead__c is the Lead to reuse) rather
     * than a later repeat. Failing an exact match, the highest-scoring candidate at or above
     * SIMILARITY_THRESHOLD wins; ties keep the oldest.
     *
     * @param brokerEmail       The broker's address (LLM-extracted, or the envelope From as
     *                          the caller's fallback); blank returns null.
     * @param normalizedAddress The normalized property address (from normalizeAddress);
     *                          blank returns null.
     * @return The matching Competing_Broker_Submission__c (Winning_Lead__c always populated;
     *         Source_Lead__c populated only for the winner's own submissions), or null when
     *         this broker has not submitted this property.
     * @example
     * Competing_Broker_Submission__c prior =
     *     PropertyMatchingService.findBrokerSubmission(brokerEmail, normalized);
     */
    public static Competing_Broker_Submission__c findBrokerSubmission(
            String brokerEmail, String normalizedAddress) {
        if (String.isBlank(brokerEmail) || String.isBlank(normalizedAddress)) {
            return null;
        }

        Datetime cutoff = Datetime.now().addDays(-LOOKBACK_DAYS);
        Competing_Broker_Submission__c best = null;
        Decimal bestScore = -1;

        for (Competing_Broker_Submission__c candidate
                : CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail(brokerEmail, cutoff)) {
            // NOTE: a null Source_Lead__c is NOT a skip condition. It is the normal shape of a
            // competing broker's submission, and matching it is what makes their follow-up a
            // Repeat instead of an endlessly-recurring new competing claim.
            String candidateKey = normalizeAddress(candidate.Property_Address_Raw__c);
            if (String.isBlank(candidateKey)) {
                continue;
            }
            if (candidateKey == normalizedAddress) {
                return candidate;
            }
            Decimal score = calculateSimilarity(normalizedAddress, candidateKey);
            if (score >= SIMILARITY_THRESHOLD && score > bestScore) {
                best = candidate;
                bestScore = score;
            }
        }
        return best;
    }

    /**
     * Derive the CONVERSATION ROOT Message-ID — the value stamped on every Task this
     * pipeline logs (Task.Thread_Key__c), and the key that lets a later reply find the
     * record its thread was routed to.
     *
     * RFC 5322 resolution order, and the reason for it: `References` accumulates the whole
     * ancestry of a conversation in order, so its FIRST entry is the root and is identical
     * on every message in the thread — including after a forward, because forwarding
     * preserves References. That stability is the whole point: a thread key derived from
     * the immediate parent would change with every reply. `In-Reply-To` (the immediate
     * parent) is the fallback when References is absent, and this message's own Message-ID
     * is the last resort — correct for the FIRST message in a thread, which is its own root.
     *
     * All three inputs may be blank (some forwarding paths strip headers entirely), in
     * which case this returns blank/null and the caller simply stores no thread key.
     *
     * @param messageId  This message's RFC Message-ID.
     * @param inReplyTo  RFC In-Reply-To header (the immediate parent).
     * @param references RFC References header (whitespace-delimited ancestry).
     * @return The root Message-ID with angle brackets stripped, or the message id itself,
     *         or null when nothing usable was supplied.
     * @example
     * String threadKey = PropertyMatchingService.computeThreadKey(
     *     messageId, inReplyTo, references);
     */
    public static String computeThreadKey(String messageId, String inReplyTo, String references) {
        String root = firstMessageId(references);
        if (String.isNotBlank(root)) {
            return root;
        }
        root = firstMessageId(inReplyTo);
        if (String.isNotBlank(root)) {
            return root;
        }
        return stripAngleBrackets(messageId);
    }

    /**
     * REPLY THREADING — the record a reply belongs to, found from the RFC headers it cites.
     * When an internal user replies to (or inside) a thread the pipeline has already logged,
     * this returns the record that thread was routed to so the reply is filed there instead
     * of manufacturing a new Lead.
     *
     * Both `In-Reply-To` and `References` are mined for Message-IDs, because the two headers
     * carry different slices of the same ancestry and mail clients are inconsistent about
     * which they populate: In-Reply-To is the immediate parent, References is the full chain.
     * Every id found is probed against BOTH Task threading fields (Thread_Key__c and
     * Inbound_Message_Id__c) in one query.
     *
     * WhatId is preferred over WhoId because it holds the "main" business record — the
     * Opportunity or custom object — whereas WhoId holds the person (Lead / Contact). When a
     * Lead has been converted, the Task on the resulting Opportunity carries WhatId, and that
     * deal is the right home for the reply.
     *
     * @param inReplyTo  RFC In-Reply-To header from the inbound email; may be blank.
     * @param references RFC References header from the inbound email; may be blank.
     * @return The WhatId (preferred) or WhoId of the newest Task in that thread, or null
     *         when the email cites nothing or cites a thread this pipeline never logged.
     * @example
     * Id priorRecord =
     *     PropertyMatchingService.findRecordByReplyHeaders(inReplyTo, references);
     */
    public static Id findRecordByReplyHeaders(String inReplyTo, String references) {
        Set<String> cited = new Set<String>();
        collectMessageIds(cited, inReplyTo);
        collectMessageIds(cited, references);
        if (cited.isEmpty()) {
            return null;
        }

        List<Task> prior = TaskSelector.selectLatestByThreadOrMessageIds(cited);
        if (prior.isEmpty()) {
            return null;
        }
        Task match = prior[0];
        return (match.WhatId != null) ? match.WhatId : match.WhoId;
    }

    /**
     * Follow a converted Lead to the LIVE record it became, so an activity lands on the
     * record people actually work rather than the husk Lead conversion leaves behind.
     *
     * Non-Lead ids are returned unchanged — the method is safe to call on any routing
     * result, which is why the caller never has to type-check first. An unconverted Lead is
     * also returned unchanged. A converted Lead resolves to its Opportunity when there is
     * one (the deal is the useful record), else its Contact, else itself: conversion can
     * legitimately produce no Opportunity ("Don't create an opportunity"), and the original
     * Id is always a valid fallback.
     *
     * @param recordId Any record Id; null returns null.
     * @return ConvertedOpportunityId, else ConvertedContactId, else `recordId` unchanged.
     * @example
     * Id liveRecord = PropertyMatchingService.resolveLiveRecord(foundRecordId);
     */
    public static Id resolveLiveRecord(Id recordId) {
        if (recordId == null) {
            return null;
        }
        if (recordId.getSObjectType() != Lead.SObjectType) {
            return recordId;
        }

        List<Lead> rows = LeadSelector.selectConversionById(recordId);
        if (rows.isEmpty() || rows[0].IsConverted != true) {
            return recordId;
        }
        Lead converted = rows[0];
        if (converted.ConvertedOpportunityId != null) {
            return converted.ConvertedOpportunityId;
        }
        return (converted.ConvertedContactId != null) ? converted.ConvertedContactId : recordId;
    }

    /**
     * The FIRST Message-ID in a whitespace-delimited RFC header value, angle brackets
     * stripped. `References` is defined as a space-separated list in ancestry order, so its
     * first token is the conversation root.
     *
     * @param headerValue A raw In-Reply-To / References header value; blank returns null.
     * @return The first token with '&lt;' / '&gt;' removed, or null when there is none.
     */
    private static String firstMessageId(String headerValue) {
        if (String.isBlank(headerValue)) {
            return null;
        }
        for (String token : headerValue.trim().split('\\s+')) {
            String cleaned = stripAngleBrackets(token);
            if (String.isNotBlank(cleaned)) {
                return cleaned;
            }
        }
        return null;
    }

    /**
     * Add every Message-ID in a whitespace-delimited RFC header value to `target`, angle
     * brackets stripped. Used to build the full set of ids a reply cites across both
     * In-Reply-To and References.
     *
     * @param target      The accumulating Set to add to (mutated in place).
     * @param headerValue A raw In-Reply-To / References header value; blank adds nothing.
     */
    private static void collectMessageIds(Set<String> target, String headerValue) {
        if (String.isBlank(headerValue)) {
            return;
        }
        for (String token : headerValue.trim().split('\\s+')) {
            String cleaned = stripAngleBrackets(token);
            if (String.isNotBlank(cleaned)) {
                target.add(cleaned);
            }
        }
    }

    /**
     * Remove the angle brackets RFC 5322 wraps a Message-ID in ('&lt;id@host&gt;' -&gt;
     * 'id@host') and trim. Stripping is what makes the two threading fields comparable: the
     * same id can arrive bracketed in References and bare elsewhere, and an unstripped value
     * would silently fail every equality match.
     *
     * @param raw A Message-ID token, bracketed or bare; null returns null.
     * @return The bare id, trimmed; null when `raw` is null.
     */
    private static String stripAngleBrackets(String raw) {
        return (raw == null) ? null : raw.replaceAll('[<>]', '').trim();
    }

    /**
     * Split an address into its non-blank, space-delimited word tokens as a Set (so the
     * Jaccard math is order- and duplicate-insensitive).
     *
     * @param value The address string to tokenize.
     * @return The Set of non-blank whitespace-split tokens.
     */
    private static Set<String> toTokenSet(String value) {
        Set<String> tokens = new Set<String>();
        for (String token : value.split('\\s+')) {
            if (String.isNotBlank(token)) {
                tokens.add(token);
            }
        }
        return tokens;
    }
}
