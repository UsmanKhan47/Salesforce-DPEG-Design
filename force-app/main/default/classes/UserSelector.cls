/**
 * Selector for `User`. Holds one automation read: resolving a feed-supplied username to a live
 * Salesforce user so the receivables mirror can carry a Responsible Property Manager (FSD 5.9.4,
 * OQ-4) and the auto-created delinquency Case can be OWNED by them.
 *
 * MODE - `WITH SYSTEM_MODE` on `selectActiveByUsernames`. Automation path: the nightly job performs
 * this read on the scheduling principal's behalf, not at a human's request. `USER_MODE` would THROW
 * on any field the principal cannot see rather than degrading, and `User` field visibility varies by
 * profile in ways nobody controls per-field - so a `USER_MODE` read here would make the whole run's
 * survival depend on an unrelated profile setting.
 *
 * SHARING - `with sharing`, not escaped. `User` visibility is governed by the org-wide user
 * visibility setting rather than record sharing, and this read returns only Id and Username -
 * nothing an authenticated user cannot already see in a lookup. There is no duplicate-maker hazard
 * of the kind `CaseSelector` documents, so no `without sharing` inner class is warranted.
 *
 * @see ReceivablesSummaryDomain.cls (maps the resolved ids onto the mirror rows)
 */
public with sharing class UserSelector {

    /**
     * Active users, keyed by LOWERCASED username.
     *
     * Keys are lowercased because Salesforce usernames are case-insensitive for login but are stored
     * and returned in whatever case they were created in - so a feed emitting `Isha@dpeg.com`
     * against a stored `isha@dpeg.com` would silently fail to match and every Case would land
     * unowned. Callers must lowercase their lookup key too.
     *
     * @param usernames Usernames to resolve; null/empty safe. Matching is case-insensitive.
     * @return Map of lowercased username to User Id. Never null. A missing username is simply absent,
     *         which callers must treat as "leave the lookup null" rather than guessing an owner.
     * @example
     * Map&lt;String, Id&gt; ids = UserSelector.selectActiveByUsernames(new Set&lt;String&gt;{ 'pm@dpeg.com' });
     */
    public static Map<String, Id> selectActiveByUsernames(Set<String> usernames) {
        Map<String, Id> idsByUsername = new Map<String, Id>();
        if (usernames == null || usernames.isEmpty()) {
            return idsByUsername;
        }
        Set<String> normalized = new Set<String>();
        for (String username : usernames) {
            if (String.isNotBlank(username)) {
                normalized.add(username.toLowerCase());
            }
        }
        if (normalized.isEmpty()) {
            return idsByUsername;
        }
        for (User activeUser : [
            SELECT Id, Username
            FROM User
            WHERE Username IN :normalized
              AND IsActive = TRUE
            WITH SYSTEM_MODE
        ]) {
            idsByUsername.put(activeUser.Username.toLowerCase(), activeUser.Id);
        }
        return idsByUsername;
    }
}
