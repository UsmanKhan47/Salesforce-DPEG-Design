/**
 * Selector for Property_Registry__c. Encapsulates ALL SOQL against
 * Property_Registry__c per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * Broker Protection module (CHUNK 1). Property_Registry__c is the first-broker-wins
 * ledger: one row per registered property (Property_Key__c is the unique dedup key)
 * pointing at the Winning_Lead__c that claimed it. Consumers land in CHUNK 2/3
 * (the registration / competing-submission services). Every query here returns the
 * same field set (Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
 * Registered_DateTime__c) so a caller can rely on a stable shape. The two
 * PROTECTION-WINDOW methods added 2026-08-17 extend that shape by exactly one
 * spanning field, `Winning_Lead__r.IsConverted`, and nothing else.
 *
 * ═══ THE PROTECTION WINDOW (added 2026-08-17, FSD tranche 3 item 1) ═══
 * Until this change the module answered "is this property already claimed?" with THREE
 * reads that did not agree with each other. Two were already windowed at
 * `PropertyMatchingService.LOOKBACK_DAYS` (90) — the FUZZY registry scan
 * (`selectRecentWithWinner`) and repeat detection
 * (`CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail`) — while the EXACT-key
 * read below, `selectByPropertyKeyWithWinner`, had no date filter at all.
 *
 * 🔴 THE CONSEQUENCE WAS A LIVE DEFECT, NOT A MISSING FEATURE: on day 91 the outcome
 * depended on HOW THE BROKER TYPED THE ADDRESS. An identically-worded resubmission hit
 * the exact read and the incumbent kept the property for ever; a differently-worded one
 * hit the fuzzy read, matched nothing, and the NEW broker won outright — minting a
 * second registry row on a different `Property_Key__c` for the same building. Two
 * brokers, same property, same day, opposite answers.
 *
 * `selectLiveByPropertyKey` is the windowed exact read that closes it.
 * `selectExpiredByPropertyKey` is its complement — the row an expired key must be
 * ADOPTED from, without which the key becomes permanently unclaimable (see that
 * method, and PropertyClaimService.registerWinner's third leg).
 *
 * MODE — every query uses `WITH USER_MODE` (API 67), the two new ones included.
 * Property_Registry__c is a custom object; P3 proved the custom-field FLS gap is 0, so
 * USER_MODE is safe and enforces the running user's sharing + FLS. There is no guest
 * path here, so no SYSTEM_MODE appears. ⚠ The two windowed methods span to
 * `Winning_Lead__r.IsConverted`, which adds a Lead read to a USER_MODE query — that is
 * NOT new exposure on this path: `LeadSelector.selectConversionById` already reads
 * `IsConverted` under USER_MODE for the same pipeline, and both are reached from the
 * same principals.
 *
 * SIGNATURE CONTRACT — the public methods are STATIC, matching the repo
 * selector norm (BovSubmissionSelector, CounterOfferSelector, ContactSelector,
 * LeadSelector all expose `public static` query methods). The original three keep the
 * exact signatures the Broker-Protection chunk plan fixed; CHUNK 2/3 bind to them by
 * name (`PropertyRegistrySelector.selectByPropertyKeyWithWinner(...)`). Do not rename or
 * change their parameters/return types — that would break the cross-chunk callers.
 * 🔴 THE PROTECTION WINDOW WAS THEREFORE ADDED, NEVER RETROFITTED ONTO AN EXISTING
 * SIGNATURE.
 *
 * NOT-FOUND CONTRACT — every method returns its natural empty List, never null: a
 * property that has never been registered, or a window with no recent winners, is
 * normal, not an error.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see CompetingBrokerSubmissionSelector.cls (sibling Broker-Protection selector)
 */
public with sharing class PropertyRegistrySelector {

    /**
     * Registered properties for a set of dedup keys that already have a winning
     * lead — backs the "has this property already been claimed?" lookup. Filters
     * out orphan (unclaimed) rows so a caller only sees settled registrations.
     *
     * @param keys Property_Key__c values to match (the unique registration keys);
     *             null / empty returns an empty list.
     * @return Property_Registry__c rows with a non-null Winning_Lead__c whose
     *         Property_Key__c is in `keys`; empty when the input is null/empty or
     *         nothing matches.
     * ⚠ THIS IS THE UN-WINDOWED READ, AND SINCE 2026-08-17 THAT IS ITS DISTINGUISHING
     * PROPERTY RATHER THAN AN INCIDENTAL ONE. It returns a winner however old the claim
     * is. The claim pipeline no longer uses it — `PropertyMatchingService`'s exact leg
     * moved to `selectLiveByPropertyKey`, which applies the protection window — so this
     * method survives for callers that genuinely want "has this key EVER been
     * registered?", and for the tests that pin the difference. Do NOT reintroduce it into
     * an arbitration path: doing so restores the exact/fuzzy asymmetry described in the
     * class header, where the same property is claimed or released depending only on how
     * the broker spelled the address.
     *
     * @example
     * List<Property_Registry__c> claimed =
     *     PropertyRegistrySelector.selectByPropertyKeyWithWinner(keys);
     */
    public static List<Property_Registry__c> selectByPropertyKeyWithWinner(Set<String> keys) {
        if (keys == null || keys.isEmpty()) {
            return new List<Property_Registry__c>();
        }
        return [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                   Registered_DateTime__c
            FROM Property_Registry__c
            WHERE Property_Key__c IN :keys AND Winning_Lead__c != null
            WITH USER_MODE
        ];
    }

    /**
     * Recently-registered properties (on or after `cutoff`) that already have a
     * winning lead, newest first — backs the recent-registrations view / recency
     * dedup window. Capped at 200 rows.
     *
     * `cutoff` is bound as a Datetime because Registered_DateTime__c is a DateTime
     * field; binding a Date would silently truncate the comparison to midnight and
     * skew the window.
     *
     * @param cutoff Inclusive lower bound for Registered_DateTime__c (a Datetime);
     *               null returns an empty list.
     * @return Up to 200 Property_Registry__c rows registered at/after `cutoff` with
     *         a non-null Winning_Lead__c, ordered by Registered_DateTime__c DESC;
     *         empty when `cutoff` is null or nothing matches.
     * @example
     * List<Property_Registry__c> recent =
     *     PropertyRegistrySelector.selectRecentWithWinner(Datetime.now().addDays(-30));
     */
    public static List<Property_Registry__c> selectRecentWithWinner(Datetime cutoff) {
        if (cutoff == null) {
            return new List<Property_Registry__c>();
        }
        return [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                   Registered_DateTime__c
            FROM Property_Registry__c
            WHERE Registered_DateTime__c >= :cutoff AND Winning_Lead__c != null
            WITH USER_MODE
            ORDER BY Registered_DateTime__c DESC
            LIMIT 200
        ];
    }

    /**
     * The single ORPHAN registration for one dedup key — a registered property that
     * exists but has no winning lead yet (Winning_Lead__c = null). Backs the
     * claim-an-orphan path: a competing submission can adopt an unclaimed row rather
     * than create a duplicate. LIMIT 1 because Property_Key__c is unique.
     *
     * @param key Property_Key__c value to match; null/blank returns an empty list.
     * @return At most one unclaimed Property_Registry__c row for that key; empty when
     *         `key` is null/blank, the key is unregistered, or its row already has a
     *         winner.
     * @example
     * List<Property_Registry__c> orphan =
     *     PropertyRegistrySelector.selectOrphanByPropertyKey(key);
     */
    public static List<Property_Registry__c> selectOrphanByPropertyKey(String key) {
        if (String.isBlank(key)) {
            return new List<Property_Registry__c>();
        }
        return [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                   Registered_DateTime__c
            FROM Property_Registry__c
            WHERE Property_Key__c = :key AND Winning_Lead__c = null
            WITH USER_MODE
            LIMIT 1
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PROTECTION WINDOW (added 2026-08-17) — the exact-key reads that respect
    // PropertyMatchingService.PROTECTION_WINDOW_DAYS. See the class header for why the
    // un-windowed exact read was a defect rather than a design.
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * LIVE registrations for a set of dedup keys — the windowed replacement for
     * `selectByPropertyKeyWithWinner` on the claim-arbitration path. A registration is
     * LIVE when it still holds a winner AND either
     *   (a) it was registered on or after `cutoff` — i.e. inside the protection window; or
     *   (b) 🔴 its winning Lead has been CONVERTED, in which case the claim NEVER expires.
     *
     * ═══ 🔴 WHY (b) IS NOT A COURTESY TO LIVE DEALS — IT IS WHAT MAKES THE WHOLE
     *     FEATURE ADMISSIBLE ═══
     * `PropertyClaimService`'s class header carries a written PROHIBITION on adding a
     * third DML statement against `Property_Registry__c`, because such an update would be
     * re-pointing a row whose `Winning_Lead__c` may hold a CONVERTED Lead — and the
     * platform rejects a Lead lookup SET to a converted Lead (a production incident,
     * staging row a0aiw000000OCckAAG). Expiry NEEDS that third statement (adoption).
     * Excluding converted winners from expiry is the ONLY reading under which the
     * adoption update can never touch a prohibited row, so it discharges the prohibition
     * STRUCTURALLY rather than by a runtime guard that a future edit could drop.
     * It is also the stronger business answer: a converted winner is a live deal DPEG is
     * transacting, which is precisely where commission adjudication is sharpest.
     *
     * ⚠ STATED RESIDUAL — A CONVERTED-THEN-DEAD DEAL PROTECTS ITS PROPERTY FOR EVER. A
     * Lead converted into an Opportunity that later went `Dead/Pass` still reads
     * `IsConverted = true`, so its claim never releases. The remedy needs no new code and
     * is already tested: DELETE the registry row by hand. `Winning_Lead__c` is SetNull, so
     * the key immediately becomes an ORPHAN and the existing orphan-adoption path
     * (`selectOrphanByPropertyKey` -> `PropertyClaimService.registerWinner`) re-opens it
     * to the next broker.
     *
     * MODE / SHARING — `WITH USER_MODE` on this `with sharing` class, and neither half of
     * ARCHITECTURE.md §2's automation-path exception arises here. MODE: this is a read the
     * running pipeline principal already performs today (the un-windowed twin is
     * USER_MODE and has been since the module shipped), it selects no newly-deployed
     * custom field, and the added spanning field `Winning_Lead__r.IsConverted` is a
     * standard Lead field already read under USER_MODE by
     * `LeadSelector.selectConversionById` on the same pipeline. SHARING:
     * `Property_Registry__c` is `sharingModel = ReadWrite` (verified in
     * `Property_Registry__c.object-meta.xml`), so `with sharing` filters nothing and a
     * `without sharing` inner class would be an unargued widening.
     *
     * @param keys   Property_Key__c values to match; null/empty returns an empty list.
     * @param cutoff Inclusive lower bound on Registered_DateTime__c (the protection
     *               window's opening edge). ⚠ NULL MEANS "NO WINDOW" — every live winner
     *               matches — and that is the deliberate FAIL-SAFE direction: a missing
     *               cutoff must leave incumbents PROTECTED, never silently release every
     *               claim in the org. Bound as a Datetime because Registered_DateTime__c
     *               is a DateTime; binding a Date would truncate to midnight.
     * @return Property_Registry__c rows (plus Winning_Lead__r.IsConverted) that are live
     *         for those keys; empty when the input is null/empty or nothing matches.
     * @example
     * List<Property_Registry__c> live = PropertyRegistrySelector.selectLiveByPropertyKey(
     *     new Set<String>{ normalized },
     *     Datetime.now().addDays(-PropertyMatchingService.PROTECTION_WINDOW_DAYS));
     */
    public static List<Property_Registry__c> selectLiveByPropertyKey(Set<String> keys, Datetime cutoff) {
        if (keys == null || keys.isEmpty()) {
            return new List<Property_Registry__c>();
        }
        if (cutoff == null) {
            // FAIL SAFE: no window supplied => nothing has expired. Identical to the
            // pre-2026-08-17 behaviour, which protects incumbents rather than releasing them.
            return [
                SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                       Registered_DateTime__c, Winning_Lead__r.IsConverted
                FROM Property_Registry__c
                WHERE Property_Key__c IN :keys AND Winning_Lead__c != null
                WITH USER_MODE
            ];
        }
        return [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                   Registered_DateTime__c, Winning_Lead__r.IsConverted
            FROM Property_Registry__c
            WHERE Property_Key__c IN :keys
              AND Winning_Lead__c != null
              AND (Registered_DateTime__c >= :cutoff OR Winning_Lead__r.IsConverted = true)
            WITH USER_MODE
        ];
    }

    /**
     * The single EXPIRED registration for one dedup key — a row that still holds a winner
     * but whose protection window has closed and whose winning Lead is NOT converted.
     * `LIMIT 1` because Property_Key__c is unique.
     *
     * 🔴 THIS METHOD EXISTS BECAUSE A DATE FILTER ALONE MAKES A PROPERTY PERMANENTLY
     * UNCLAIMABLE BY ANYONE. Trace it: `findMatchingRegistry` returns null (expired), so
     * the claim is not a lost race, so `registerWinner` INSERTS — and collides with the
     * expired row's still-unique `Property_Key__c`, throwing DUPLICATE_VALUE. The catch
     * re-runs `findMatchingRegistry` (still null) and then `findOrphanedRegistry`, which
     * filters `Winning_Lead__c = null` — and the expired row HAS a winner, so it is not an
     * orphan. Control falls through to the logged `UNCLAIMED` return: the new broker gets
     * a Lead with no claim, and the key can never be claimed by anybody again. This is the
     * read that lets `registerWinner` ADOPT the expired row instead.
     *
     * ⚠ `Winning_Lead__r.IsConverted = false` IS THE LOAD-BEARING FILTER, NOT A REFINEMENT
     * OF THE DATE ONE. Every row this method returns is a row whose `Winning_Lead__c`
     * holds an OPEN Lead, which is exactly what makes the caller's `update` safe against
     * the converted-Lead rejection that `PropertyClaimService`'s prohibition paragraph is
     * about. Removing it does not merely widen expiry — it re-opens a production defect
     * class that no Apex test in this org can reproduce (test context does not enforce the
     * restriction; see
     * PropertyClaimServiceTest.platform_lookupToAConvertedLead_isNotEnforcedInTestContext).
     *
     * MODE / SHARING — identical reasoning to `selectLiveByPropertyKey`; see that method.
     *
     * @param key    Property_Key__c value to match; null/blank returns an empty list.
     * @param cutoff Exclusive upper bound on Registered_DateTime__c. ⚠ NULL RETURNS EMPTY
     *               — with no window nothing has expired, so nothing is adoptable. Same
     *               fail-safe direction as `selectLiveByPropertyKey`: both degrade toward
     *               "the incumbent keeps the property".
     * @return At most one expired, unconverted-winner Property_Registry__c row for that
     *         key; empty when `key`/`cutoff` is null, the key is unregistered, the claim is
     *         still inside the window, or its winner has converted.
     * @example
     * List<Property_Registry__c> expired =
     *     PropertyRegistrySelector.selectExpiredByPropertyKey(normalized, cutoff);
     */
    public static List<Property_Registry__c> selectExpiredByPropertyKey(String key, Datetime cutoff) {
        if (String.isBlank(key) || cutoff == null) {
            return new List<Property_Registry__c>();
        }
        return [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c,
                   Registered_DateTime__c, Winning_Lead__r.IsConverted
            FROM Property_Registry__c
            WHERE Property_Key__c = :key
              AND Winning_Lead__c != null
              AND Registered_DateTime__c < :cutoff
              AND Winning_Lead__r.IsConverted = false
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
