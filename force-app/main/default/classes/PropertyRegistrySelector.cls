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
 * Registered_DateTime__c) so a caller can rely on a stable shape.
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Property_Registry__c is a custom
 * object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and enforces
 * the running user's sharing + FLS. There is no guest path here, so no SYSTEM_MODE
 * appears.
 *
 * SIGNATURE CONTRACT — the three public methods are STATIC, matching the repo
 * selector norm (BovSubmissionSelector, CounterOfferSelector, ContactSelector,
 * LeadSelector all expose `public static` query methods). They keep the exact
 * signatures the Broker-Protection chunk plan fixed; CHUNK 2/3 bind to them by name
 * (`PropertyRegistrySelector.selectByPropertyKeyWithWinner(...)`). Do not rename or
 * change their parameters/return types — that would break the cross-chunk callers.
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
}
