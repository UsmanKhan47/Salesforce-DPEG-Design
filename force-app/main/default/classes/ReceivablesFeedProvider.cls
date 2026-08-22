/**
 * THE ONE SWAP POINT. Everything about where receivables data comes from lives behind this
 * interface, and nothing downstream of `ReceivablesSyncService.ingest` can see through it.
 *
 * Implementations are selected AT RUNTIME from `Receivables_Sync_Config__c.Provider_Class_Name__c`
 * via `Type.forName(...).newInstance()`, so switching from the static-resource fixture to the live
 * ASB feed is a Setup edit - no deploy, no code change, no downstream change.
 *
 * === THE `Type.forName` HAZARD, AND THE TWO THINGS THAT CONTAIN IT ===
 * An implementation reached ONLY by a config string can be deleted, renamed or made abstract
 * without a single compile error anywhere. Both mitigations must survive review:
 *   1. `ReceivablesFeedProviderTest.everyShippedProviderNameResolves` asserts each shipped class
 *      name still resolves to a non-null instance of THIS interface.
 *   2. `ReceivablesIngestQueueable` HALTS on an unresolvable name
 *      (`Sync_Run__c.Halt_Reason__c = 'Config Missing'`, `Lifecycle_Ran__c = false`) and NEVER
 *      falls back to the stub. A silent stub fallback in production would publish fixture balances
 *      as if they were Yardi's, open Cases against them, and email principals about them.
 *
 * === CONTRACT FOR IMPLEMENTERS ===
 * - `fetch` MUST NOT throw for an ordinary remote failure. Return a result whose `rows` is empty
 *   and whose `feedAsOf` is null; the health check then halts the run with a recorded reason. Only
 *   a genuinely unexpected condition should escape, and the queueable records that as
 *   `Halt_Reason__c = 'Callout Failure'` or `'Parse Failure'`.
 * - `fetch` MUST populate `feedAsOf` from THE SOURCE's clock, never `System.now()`. See
 *   `ReceivablesFeedResult`.
 * - `sourceLabel()` MUST return a value present in the `Sync_Run__c.Source__c` picklist
 *   ('Stub' or 'ASB' today). It is RESTRICTED, and a restricted picklist IS enforced at DML on
 *   this project (measured four times) - a new provider needs its picklist value deployed BEFORE
 *   it can run, or the audit-row insert fails and takes the run with it.
 */
public interface ReceivablesFeedProvider {

    /**
     * Retrieve one receivables feed.
     *
     * @param request Fetch parameters; never null (the queueable always builds one).
     * @return The feed, already normalized. Never null.
     */
    ReceivablesFeedResult fetch(ReceivablesFeedRequest request);

    /**
     * @return The `Sync_Run__c.Source__c` picklist value this provider records.
     */
    String sourceLabel();
}
