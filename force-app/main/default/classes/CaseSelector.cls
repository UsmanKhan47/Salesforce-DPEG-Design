/**
 * Selector for `Case`. First Case selector in this repo - nothing queried Case before FSD 5.9.
 *
 * ==========================================================================================
 * THE DUPLICATE-CASE GUARD IS THE REASON THIS CLASS EXISTS, AND IT MUST BE SHARING-PROOF
 * ==========================================================================================
 * FSD 5.9.6 step 3 says the nightly sync must NEVER create a second open Case for a tenant who
 * already has one. That guarantee is implemented as ONE read - `selectOpenDelinquencyByArKeys` -
 * and the read is the whole guarantee. Everything about how it is written is load-bearing:
 *
 * 1. `Case` OWD in `usman-dpeg` is PRIVATE. Verified 2026-08-22 by querying
 *    `EntityDefinition.InternalSharingModel`. (The design document claimed `ReadWriteTransfer`;
 *    that claim was STALE and is corrected here. Do not restore it from the design doc.)
 *
 * 2. `WITH SYSTEM_MODE` lifts CRUD and FLS. IT DOES NOT LIFT SHARING. Ever. This is the single
 *    most-repeated correction in this repo's history and it is repeated here because the
 *    consequence is worse than usual.
 *
 * 3. A sharing-filtered guard read DOES NOT DISABLE THE FEATURE - IT INVERTS IT INTO A
 *    DUPLICATE-MAKER. Think through what a partial result means: the query returns the open Cases
 *    the running principal happens to own, and returns NOTHING for the ones owned by other property
 *    managers. The caller reads "no open Case exists" and OPENS ANOTHER ONE. Every night. For every
 *    tenant whose Case belongs to somebody else. The guard does not fail closed; it fails open, and
 *    it fails open exactly on the records it exists to protect.
 *
 * 4. AND THE FAILURE IS SILENT. The sync upserts with `allOrNone = false`, so nothing throws and
 *    nothing appears in any counter as an error. This repo has the incident on file: an approval's
 *    parent write failed for every approver who did not OWN the record, `SYSTEM_MODE` had been
 *    chosen specifically to fix it, and `allOrNone = false` swallowed the refusal. It worked in
 *    every test only because the test's approver was the owner - which is what every test does
 *    unless it is deliberately built not to.
 *
 * 5. So the query lives in `GuardReads`, a narrow `private without sharing` INNER class holding
 *    only that query. NOT `without sharing` on this whole selector: `selectStaleFollowUp` and
 *    `selectWriteOffAwaitingDecision` below are automation reads too, but they drive ALERTS, and an
 *    alert that under-fires is a missed reminder rather than a corrupted data set. The escape
 *    belongs to the statement whose correctness depends on it.
 *
 * REQUIRED TEST, AND WHY THE PROFILE MATTERS: `CaseSelectorTest` creates the open Case as user A and
 * runs the guard as user B on the MINIMUM ACCESS profile, asserting the Case is still found. A
 * `Standard User`-based test would prove nothing for a standard object - that profile already grants
 * Case read, so the test would pass with the escape removed.
 *
 * MODE - every method here is `WITH SYSTEM_MODE`, every one an automation-path read performed on the
 * nightly job's behalf. `USER_MODE` throws rather than degrading, and the ~22 Case custom fields were
 * deployed by the Metadata API, which grants FLS to nobody including System Administrator - so
 * `USER_MODE` would raise `No such column` on the first run and take the audit row with it.
 *
 * WARNING - `Case.Yardi_AR_Id__c` is an external id that is deliberately NOT UNIQUE. Closed Cases
 * accumulate per tenant over time; a unique index would refuse the second-ever Case for a tenant who
 * re-delinquents. That is why every query here filters on `IsClosed = false` rather than assuming
 * one row per key.
 *
 * @see DelinquencyCaseService.cls (the only caller)
 */
public with sharing class CaseSelector {

    /** Record type developer name for the delinquency lifecycle. */
    @TestVisible
    private static final String RT_DELINQUENCY = 'Delinquency';

    /**
     * THE GUARD. Open delinquency Cases for a set of Yardi AR keys, read WITHOUT SHARING.
     *
     * @param arKeys `Case.Yardi_AR_Id__c` values to check; null/empty safe.
     * @return Every OPEN delinquency Case whose key is in the set, oldest first. Never null.
     *         Oldest-first ordering is deliberate: if data ever does contain two open Cases for one
     *         key, the caller keeps the FIRST (the one with the real follow-up history) rather than
     *         whichever the database happened to return first.
     * @example
     * List&lt;Case&gt; open = CaseSelector.selectOpenDelinquencyByArKeys(new Set&lt;String&gt;{ 'AR-1001' });
     */
    public static List<Case> selectOpenDelinquencyByArKeys(Set<String> arKeys) {
        if (arKeys == null || arKeys.isEmpty()) {
            return new List<Case>();
        }
        return new GuardReads().openDelinquencyByArKeys(arKeys);
    }

    /**
     * Open delinquency Cases whose follow-up has gone stale (FSD 5.9.7 row 6).
     *
     * Stale means EITHER the promised `Next_Follow_Up_Date__c` has passed, OR no follow-up has been
     * recorded within the configured window. Both arms are needed: the first catches a PM who set a
     * date and missed it, the second catches one who never set a date at all - and the second is the
     * more common failure, so keying only on `Next_Follow_Up_Date__c` would miss most of them.
     *
     * @param asOf      The date to measure against; passed in so the batch evaluates one whole run
     *                  against a single date rather than straddling midnight.
     * @param staleDays Days without a follow-up before a Case counts as stale.
     * @param maxRows   Hard row cap, so an unbounded backlog cannot blow the heap.
     * @return Stale open Cases; never null. Empty when `staleDays` is null (the alert is unconfigured
     *         and therefore disabled - see `ReceivablesSyncConfig` on why there are no defaults).
     */
    public static List<Case> selectStaleFollowUp(Date asOf, Integer staleDays, Integer maxRows) {
        if (asOf == null || staleDays == null) {
            return new List<Case>();
        }
        return new AlertReads().staleFollowUp(asOf, staleDays, (maxRows == null) ? 2000 : maxRows);
    }

    /**
     * Open delinquency Cases with a write-off requested and no decision recorded (FSD 5.9.7 row 7).
     *
     * @param maxRows Hard row cap.
     * @return Cases awaiting a principal's write-off decision; never null.
     */
    public static List<Case> selectWriteOffAwaitingDecision(Integer maxRows) {
        return new AlertReads().writeOffAwaitingDecision((maxRows == null) ? 2000 : maxRows);
    }

    /**
     * Delinquency Cases by Id, whatever their state - used when a breached payment commitment has to
     * REOPEN a Case that the sync already resolved (FSD 5.9.7 row 5).
     *
     * @param caseIds Case Ids; null/empty safe.
     * @return The matching Cases; never null.
     */
    public static List<Case> selectByIds(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) {
            return new List<Case>();
        }
        return new GuardReads().byIds(caseIds);
    }

    /**
     * THE SHARING ESCAPE. Holds ONLY the reads whose correctness depends on seeing rows the running
     * principal does not own. Read the class header before touching this - the guard read failing
     * open is the specific failure this class is built around.
     */
    private without sharing class GuardReads {

        private List<Case> openDelinquencyByArKeys(Set<String> arKeys) {
            String recordType = RT_DELINQUENCY;
            return [
                SELECT Id, CaseNumber, OwnerId, Status, Reason, IsClosed, CreatedDate,
                       Yardi_AR_Id__c, Receivables_Summary__c, Unit__c, Property_Asset__c,
                       Resolution_Path__c, Escalation_Level__c, Escalation_Basis_Days__c,
                       Escalated_DateTime__c, Balance_At_Open_Amount__c, Days_Past_Due_At_Open__c,
                       Current_Balance_Amount__c, Current_Days_Past_Due__c,
                       Last_Follow_Up_DateTime__c, Next_Follow_Up_Date__c,
                       Reopened_Count__c, Auto_Closed_By_Sync__c,
                       Write_Off_Requested__c, Write_Off_Decision__c
                FROM Case
                WHERE Yardi_AR_Id__c IN :arKeys
                  AND IsClosed = FALSE
                  AND RecordType.DeveloperName = :recordType
                WITH SYSTEM_MODE
                ORDER BY CreatedDate ASC, Id ASC
            ];
        }

        private List<Case> byIds(Set<Id> caseIds) {
            String recordType = RT_DELINQUENCY;
            return [
                SELECT Id, OwnerId, Status, IsClosed, Yardi_AR_Id__c, Receivables_Summary__c,
                       Escalation_Level__c, Escalation_Basis_Days__c, Reopened_Count__c,
                       Auto_Closed_By_Sync__c, Current_Balance_Amount__c
                FROM Case
                WHERE Id IN :caseIds
                  AND RecordType.DeveloperName = :recordType
                WITH SYSTEM_MODE
            ];
        }
    }

    /**
     * The alert-driving reads. Also `without sharing`, and for the same structural reason - a
     * delinquency Case is owned by ONE property manager while the nightly job runs as somebody else,
     * so a sharing-filtered read would alert on a subset of Cases and stay quiet about the rest.
     * Kept SEPARATE from `GuardReads` so the guard's exceptional status stays visible: under-firing
     * an alert is a missed reminder, under-firing the guard corrupts the data set.
     */
    private without sharing class AlertReads {

        private List<Case> staleFollowUp(Date asOf, Integer staleDays, Integer maxRows) {
            String recordType = RT_DELINQUENCY;
            DateTime staleBefore = DateTime.newInstance(asOf.addDays(-staleDays), Time.newInstance(0, 0, 0, 0));
            return [
                SELECT Id, CaseNumber, OwnerId, Status, Yardi_AR_Id__c, Receivables_Summary__c,
                       Last_Follow_Up_DateTime__c, Next_Follow_Up_Date__c, Current_Balance_Amount__c,
                       Current_Days_Past_Due__c
                FROM Case
                WHERE IsClosed = FALSE
                  AND RecordType.DeveloperName = :recordType
                  AND (
                        (Next_Follow_Up_Date__c != NULL AND Next_Follow_Up_Date__c < :asOf)
                        OR (Last_Follow_Up_DateTime__c != NULL AND Last_Follow_Up_DateTime__c < :staleBefore)
                      )
                WITH SYSTEM_MODE
                ORDER BY Last_Follow_Up_DateTime__c ASC NULLS FIRST, Id ASC
                LIMIT :maxRows
            ];
        }

        private List<Case> writeOffAwaitingDecision(Integer maxRows) {
            String recordType = RT_DELINQUENCY;
            String pending = 'Pending';
            return [
                SELECT Id, CaseNumber, OwnerId, Status, Yardi_AR_Id__c, Escalation_Level__c,
                       Write_Off_Requested__c, Write_Off_Requested_Amount__c, Write_Off_Decision__c
                FROM Case
                WHERE IsClosed = FALSE
                  AND RecordType.DeveloperName = :recordType
                  AND Write_Off_Requested__c = TRUE
                  AND (Write_Off_Decision__c = NULL OR Write_Off_Decision__c = :pending)
                WITH SYSTEM_MODE
                ORDER BY Id ASC
                LIMIT :maxRows
            ];
        }
    }
}
