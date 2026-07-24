/**
 * Broker-Protection first-broker-wins matching (CHUNK 2). Pure address-normalization
 * and Jaccard similarity plus selector-backed lookups against the Property_Registry__c
 * ledger — it decides WHETHER an inbound property already has a winner, an orphaned
 * registration, or nothing. It never writes; PropertyClaimService owns all claim /
 * duplicate DML and calls back into these read helpers.
 *
 * LAYER — Service (read side). Per ARCHITECTURE.md §2 all SOQL stays in the selectors:
 * this class never queries an SObject itself, it delegates every read to
 * PropertyRegistrySelector (now static). No DML, no callouts. normalizeAddress,
 * calculateSimilarity and deriveClusterKey are pure functions with no platform
 * dependency, so CHUNK 2/3 tests can assert them directly.
 *
 * SIGNATURE CONTRACT — the constants and the five public static methods are the exact
 * bindings CHUNK 3 / the claim writer wire to (SIMILARITY_THRESHOLD, LOOKBACK_DAYS,
 * normalizeAddress, calculateSimilarity, findMatchingRegistry, findOrphanedRegistry,
 * deriveClusterKey). Do not rename or change their parameters/return types.
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
     * Exact: the unique Property_Key__c lookup
     * (PropertyRegistrySelector.selectByPropertyKeyWithWinner); if any row comes back it
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

        List<Property_Registry__c> exact =
            PropertyRegistrySelector.selectByPropertyKeyWithWinner(new Set<String>{ normalized });
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
