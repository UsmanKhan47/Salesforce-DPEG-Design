/**
 * Selector for `Receivables_Summary__c`, the read-only Yardi receivables mirror.
 *
 * MODE - every method is `WITH SYSTEM_MODE`. All three are automation-path reads performed inside a
 * queueable or a batch on the scheduling principal's behalf, never at a human's request. The 24
 * mirror fields were deployed by the Metadata API, which grants FLS to NOBODY - System Administrator
 * included - so a `USER_MODE` read would raise `System.QueryException: No such column` on the very
 * first run.
 *
 * SHARING - ESCAPED via `SyncReads`, and load-bearing for the same structural reason as
 * `SyncRunSelector`: `Receivables_Summary__c` OWD is Private (verified 2026-08-22 via
 * `EntityDefinition`) and every mirror row is OWNED BY WHICHEVER PRINCIPAL FIRST INSERTED IT. The
 * moment the job is re-scheduled by a different admin, a sharing-filtered read stops seeing the
 * previous principal's rows - and the upsert then treats them as NEW. Because `Yardi_AR_Id__c` is a
 * UNIQUE external id the insert would be refused, and with `allOrNone = false` that refusal lands
 * silently in a `SaveResult` nobody reads. The mirror would simply stop updating, showing balances
 * frozen at whatever they were the day the scheduler changed, with a green run every night.
 *
 * @see ReceivablesSyncService.cls (the upsert)
 * @see ReceivablesSyncBatch.cls   (the lifecycle locator)
 */
public with sharing class ReceivablesSummarySelector {

    /**
     * Locator for the nightly lifecycle: every mirror row written by THIS run.
     *
     * SCOPED TO THE RUN ON PURPOSE, and the residual is stated rather than hidden. A tenant who
     * DISAPPEARS from the feed keeps their old `Sync_Run__c` and so is not selected - meaning their
     * open Case is not auto-closed. That is the safe direction and it is deliberate: absence of a row
     * is not evidence of payment, and FSD 5.9.2 says a partial sync must never destroy follow-up
     * history. RESIDUAL: such a Case stays open until the tenant reappears with a cleared balance or
     * a human closes it. The date-driven alerts still reach it, because those run off
     * `CaseSelector`, not off this locator.
     *
     * @param syncRunId The run whose rows to process; required.
     * @return A locator ordered by Id for deterministic chunking.
     */
    public static Database.QueryLocator queryLifecycleLocator(Id syncRunId) {
        return new SyncReads().lifecycleLocator(syncRunId);
    }

    /**
     * Mirror rows by Yardi AR key - used by the upsert path to learn which keys already exist, and
     * by tests.
     *
     * @param arKeys `Yardi_AR_Id__c` values; null/empty safe.
     * @return Matching rows; never null.
     */
    public static List<Receivables_Summary__c> selectByYardiArIds(Set<String> arKeys) {
        if (arKeys == null || arKeys.isEmpty()) {
            return new List<Receivables_Summary__c>();
        }
        return new SyncReads().byYardiArIds(arKeys);
    }

    /**
     * Mirror rows by Id.
     *
     * @param summaryIds Record Ids; null/empty safe.
     * @return Matching rows; never null.
     */
    public static List<Receivables_Summary__c> selectByIds(Set<Id> summaryIds) {
        if (summaryIds == null || summaryIds.isEmpty()) {
            return new List<Receivables_Summary__c>();
        }
        return new SyncReads().byIds(summaryIds);
    }

    /**
     * The sharing escape, confined to the three sync reads. See the class header: a sharing-filtered
     * mirror read does not error, it silently freezes the mirror after a change of scheduling
     * principal.
     */
    private without sharing class SyncReads {

        private Database.QueryLocator lifecycleLocator(Id syncRunId) {
            return Database.getQueryLocator([
                SELECT Id, Yardi_AR_Id__c, Unit__c, Property_Asset__c, Tenant_Name__c,
                       Monthly_Rent__c, Total_Outstanding_Amount__c, Days_Past_Due__c,
                       Months_Outstanding__c, Aging_Bucket__c, Has_Open_Delinquency_Case__c,
                       Responsible_Property_Manager__c, Yardi_Last_Synced_DateTime__c, Sync_Run__c
                FROM Receivables_Summary__c
                WHERE Sync_Run__c = :syncRunId
                WITH SYSTEM_MODE
                ORDER BY Id ASC
            ]);
        }

        private List<Receivables_Summary__c> byYardiArIds(Set<String> arKeys) {
            return [
                SELECT Id, Yardi_AR_Id__c, Unit__c, Property_Asset__c, Tenant_Name__c,
                       Monthly_Rent__c, Total_Outstanding_Amount__c, Days_Past_Due__c,
                       Months_Outstanding__c, Has_Open_Delinquency_Case__c,
                       Responsible_Property_Manager__c, Sync_Run__c
                FROM Receivables_Summary__c
                WHERE Yardi_AR_Id__c IN :arKeys
                WITH SYSTEM_MODE
                ORDER BY Id ASC
            ];
        }

        private List<Receivables_Summary__c> byIds(Set<Id> summaryIds) {
            return [
                SELECT Id, Yardi_AR_Id__c, Unit__c, Property_Asset__c, Tenant_Name__c,
                       Monthly_Rent__c, Total_Outstanding_Amount__c, Days_Past_Due__c,
                       Months_Outstanding__c, Has_Open_Delinquency_Case__c,
                       Responsible_Property_Manager__c, Sync_Run__c
                FROM Receivables_Summary__c
                WHERE Id IN :summaryIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
