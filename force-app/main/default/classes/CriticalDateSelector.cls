/**
 * Selector for `Critical_Date__c`. Encapsulates ALL SOQL against the object per ARCHITECTURE.md §2
 * and `.claude/rules/apex-layering-rule.md`.
 *
 * layer=selector. Sole consumer today: `CriticalDateService.ensureFor`, the idempotent
 * auto-create that lifts its rules verbatim from `scripts/seed-critical-dates.apex`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE ONE READ HERE ESCAPES **BOTH** CRUD/FLS **AND** SHARING, AND THOSE ARE TWO SEPARATE
 *    DECISIONS WITH TWO SEPARATE JUSTIFICATIONS. READ BOTH BEFORE CHANGING EITHER.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE.md §2 warns about exactly this shape: "`SYSTEM_MODE` bypasses CRUD/FLS ONLY — it
 * does NOT bypass sharing … check sharing as its own question whenever a SYSTEM_MODE automation
 * read hits a Private-OWD object whose rows are owned by someone other than the principal running
 * the automation — and **especially when the read backs an idempotency guard, where a
 * sharing-filtered read does not disable the feature, it inverts it into a duplicate-maker**."
 *
 * `Critical_Date__c` is `sharingModel=Private` and has NO owner-based sharing rule; rows are owned
 * by whoever created them, which for the seed script is the admin who ran it and for the service
 * is whichever user's save advanced the deal's stage. The read below IS the idempotency key
 * `(Transaction + Type)`. Under `with sharing` a second principal would see none of the first
 * principal's rows, conclude nothing exists, and insert a duplicate `Closing Date` on every deal —
 * silently, with no error anywhere, growing one row per stage change per principal.
 * `DPEG_Transaction_View` / `_Edit` do grant `viewAllRecords=true` on this object today, which
 * would mask the defect for the personas that hold them and expose it for everyone else
 * (a Queueable, a Flow-invoked path, a script run by an unassigned admin) — a bug that only
 * appears for the users nobody tests as. So the escape is structural, not a convenience.
 *
 * SCOPED AS NARROWLY AS APEX ALLOWS, exactly like the precedents this repo already established:
 * the class stays `with sharing`, and the elevated read lives alone in a `private without sharing`
 * inner class holding ONE method and ONE statement. It returns only the two fields the key is
 * built from — never a row, never a field the caller could surface — so it cannot leak anything a
 * principal could not otherwise see.
 * PRECEDENT: `OnboardingSelector.IdempotencyReads`, `PropertyAssetSelector.AssetCreationReads`,
 * `OnboardingTaskRollupService.RollupWrites`.
 *
 * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
 * `new IdempotencyReads()` at the call site.
 *
 * @see force-app/main/default/classes/CriticalDateService.cls
 * @see scripts/seed-critical-dates.apex (the rules this selector's consumer lifts)
 * @see agent-output/design-transaction-fsd-gaps.md §2.6, §5.5
 */
public with sharing class CriticalDateSelector {

    /**
     * The `(Transaction + Type)` keys that already exist for the supplied deals.
     *
     * 🔴 `WITH SYSTEM_MODE` — AUTOMATION PATH. ⚠ AMENDED 2026-09-01: this named
     * `TransactionTrigger`'s after-update context FIRST and the seed script as an aside. That arm
     * was REMOVED by user decision, so the ORDER IS NOW REVERSED — `CriticalDateService.ensureFor`
     * has exactly one production caller, `scripts/seed-critical-dates.apex`, and the trigger
     * consequence below is DORMANT rather than current. See `TransactionTriggerHandler.afterUpdate`
     * for what must be true before the arm returns.
     * The exemption is unchanged and is carried by the script path on its own: the read is performed
     * ON A PRINCIPAL'S BEHALF (a bulk projection, not a row the operator asked for), `USER_MODE`
     * THROWS rather than degrades, and `Type__c` and `Transaction__c` are both
     * Metadata-API-deployed custom fields — one ungranted field would abort the whole run.
     * When the arm returns, so does the sharper consequence: a throw inside an after-update trigger
     * rolls back the deal save that provoked it.
     * 🔴 AND `without sharing`, via the inner class — SEPARATELY JUSTIFIED IN THIS CLASS'S HEADER.
     * SYSTEM_MODE alone would leave this an idempotency guard that inverts into a duplicate-maker.
     *
     * NOT-FOUND CONTRACT: an empty set means "no Critical Dates exist for these deals", which is
     * the normal state for a new deal and must never be treated as an error. Never null.
     *
     * @param transactionIds Parent `Transaction__c` ids; null/empty-safe.
     * @return Keys of the form `<Transaction Id>|<Type__c>` for every existing row on those deals.
     * @example
     * Set<String> taken = CriticalDateSelector.selectExistingKeysByTransactionIds(dealIds);
     */
    public static Set<String> selectExistingKeysByTransactionIds(Set<Id> transactionIds) {
        Set<String> keys = new Set<String>();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return keys;
        }
        for (Critical_Date__c row : new IdempotencyReads().byTransactionIds(transactionIds)) {
            keys.add(String.valueOf(row.Transaction__c) + '|' + row.Type__c);
        }
        return keys;
    }

    /**
     * 🔴 THE IDEMPOTENCY READ, WHICH MUST RUN **WITHOUT SHARING**. The full argument is in this
     * class's header; the short version is that a sharing-filtered idempotency guard does not fail
     * safe, it duplicates. Inner classes do NOT inherit the outer class's sharing keyword, so it is
     * declared explicitly here and `CriticalDateSelector` itself STAYS `with sharing`.
     */
    private without sharing class IdempotencyReads {

        /**
         * @param transactionIds Parent deals to look under (non-empty by the caller's guard).
         * @return Existing Critical Dates with Transaction__c and Type__c populated.
         */
        private List<Critical_Date__c> byTransactionIds(Set<Id> transactionIds) {
            return [
                SELECT Transaction__c, Type__c
                FROM Critical_Date__c
                WHERE Transaction__c IN :transactionIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
