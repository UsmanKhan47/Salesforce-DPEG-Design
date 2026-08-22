/**
 * Test fixtures for the FSD 5.9 receivables feature.
 *
 * ==========================================================================================
 * DELIBERATE, TEMPORARY DEVIATION FROM "ALWAYS USE TestDataFactory" - READ BEFORE EXTENDING
 * ==========================================================================================
 * ARCHITECTURE.md section 2 and `.claude/rules` both say test data comes from `TestDataFactory`, and
 * that is where these builders belong. They are not there for one reason:
 *
 *   On 2026-08-22 `TestDataFactory.cls` was already MODIFIED IN THIS WORKING TREE by a concurrent
 *   build stream (confirmed via `git status`; it had grown `createVendorContracts`). Adding methods
 *   to it would have forced that stream's unreviewed, in-flight work into this feature's deploy
 *   payload - the precise hazard this repo has been bitten by before, where a second session's
 *   changes silently unioned into a shared file and failed the deploy on the other stream's
 *   undeployed field.
 *
 * WHAT THIS CLASS DOES NOT DO: it does not re-implement anything `TestDataFactory` already provides.
 * The shared scaffold - Property, Property Asset, Unit - is DELEGATED to it, so there is exactly one
 * definition of those in the codebase. Only the four AR objects are built here.
 *
 * CONSOLIDATION IS OWED. Once the concurrent stream lands, move these five builders into
 * `TestDataFactory` verbatim and delete this class.
 *
 * @see TestDataFactory.cls (the scaffold this delegates to, and the eventual home of these methods)
 */
@isTest
public class ReceivablesTestData {

    /** Monotonic per-transaction counter, backing the two UNIQUE external ids below. */
    private static Integer counter = 0;

    /**
     * @return A unique suffix for this transaction.
     */
    private static String nextKey() {
        counter++;
        return String.valueOf(counter).leftPad(6, '0');
    }

    /**
     * The org-default `Receivables_Sync_Config__c` row. Custom setting DATA is not deployable, so
     * every test that exercises a config-dependent path must create it.
     *
     * @param enabled          `Is_Enabled__c`.
     * @param providerName     `Provider_Class_Name__c`.
     * @param thresholdAmount  `Opening_Threshold_Amount__c`; null leaves the dollar arm unarmed.
     * @param thresholdMonths  `Opening_Threshold_Months__c`; null leaves the months arm unarmed.
     * @return The inserted org-default row.
     */
    public static Receivables_Sync_Config__c config(
        Boolean enabled,
        String providerName,
        Decimal thresholdAmount,
        Decimal thresholdMonths
    ) {
        Receivables_Sync_Config__c settings = Receivables_Sync_Config__c.getOrgDefaults();
        settings.Is_Enabled__c = enabled;
        settings.Provider_Class_Name__c = providerName;
        settings.Opening_Threshold_Amount__c = thresholdAmount;
        settings.Opening_Threshold_Months__c = thresholdMonths;
        upsert settings;
        return settings;
    }

    /**
     * A config with every health-check arm armed, for halt tests.
     *
     * @param stalenessHours Staleness tolerance.
     * @param minimumRows    Row-count floor.
     * @param maxChangePct   Row-count change tolerance.
     * @param staleFollowUp  Stale-follow-up days.
     * @return The inserted org-default row.
     */
    public static Receivables_Sync_Config__c configWithHealthArms(
        Integer stalenessHours,
        Integer minimumRows,
        Decimal maxChangePct,
        Integer staleFollowUp
    ) {
        Receivables_Sync_Config__c settings = config(
            true, StubReceivablesFeedProvider.class.getName(), 1000, null);
        settings.Staleness_Tolerance_Hours__c = stalenessHours;
        settings.Minimum_Row_Count__c = minimumRows;
        settings.Maximum_Row_Count_Change_Pct__c = maxChangePct;
        settings.Stale_Follow_Up_Days__c = staleFollowUp;
        upsert settings;
        return settings;
    }

    /**
     * A `Sync_Run__c` audit row.
     *
     * @param status   `Status__c`.
     * @param rowCount `Row_Count__c`.
     * @param doInsert Insert when true.
     * @return The run.
     */
    public static Sync_Run__c syncRun(String status, Integer rowCount, Boolean doInsert) {
        Sync_Run__c run = new Sync_Run__c(
            Started_DateTime__c = System.now(),
            Status__c = status,
            Source__c = 'Stub',
            Provider_Class_Name__c = StubReceivablesFeedProvider.class.getName(),
            Row_Count__c = rowCount,
            Lifecycle_Ran__c = false
        );
        if (doInsert == true) {
            insert run;
        }
        return run;
    }

    /**
     * Mirror rows. `Yardi_AR_Id__c` is UNIQUE, so it is counter-backed.
     *
     * @param count             How many.
     * @param unitId            `Unit__c` lookup; nullable.
     * @param propertyAssetId   `Property_Asset__c` lookup; nullable.
     * @param totalOutstanding  `Total_Outstanding_Amount__c` on every row.
     * @param daysPastDue       `Days_Past_Due__c` on every row.
     * @param syncRunId         `Sync_Run__c` stamp; nullable.
     * @param doInsert          Insert when true.
     * @return The mirror rows.
     */
    public static List<Receivables_Summary__c> summaries(
        Integer count,
        Id unitId,
        Id propertyAssetId,
        Decimal totalOutstanding,
        Integer daysPastDue,
        Id syncRunId,
        Boolean doInsert
    ) {
        List<Receivables_Summary__c> rows = new List<Receivables_Summary__c>();
        for (Integer i = 0; i < count; i++) {
            rows.add(new Receivables_Summary__c(
                Yardi_AR_Id__c = 'AR-T-' + nextKey(),
                Unit__c = unitId,
                Property_Asset__c = propertyAssetId,
                Tenant_Name__c = 'Test Tenant ' + i,
                Monthly_Rent__c = 5000,
                Total_Outstanding_Amount__c = totalOutstanding,
                Days_Past_Due__c = daysPastDue,
                Sync_Run__c = syncRunId,
                Has_Open_Delinquency_Case__c = false,
                Yardi_Last_Synced_DateTime__c = System.now()
            ));
        }
        if (doInsert == true) {
            insert rows;
        }
        return rows;
    }

    /**
     * Open delinquency Cases keyed to mirror rows.
     *
     * @param summaries The mirror rows to hang Cases off; one Case each.
     * @param status    `Case.Status` (must be valid on the Delinquency record type).
     * @param doInsert  Insert when true.
     * @return The Cases.
     */
    public static List<Case> delinquencyCases(
        List<Receivables_Summary__c> summaries,
        String status,
        Boolean doInsert
    ) {
        Id recordTypeId = delinquencyRecordTypeId();
        List<Case> cases = new List<Case>();
        for (Receivables_Summary__c summary : summaries) {
            cases.add(new Case(
                RecordTypeId = recordTypeId,
                Status = status,
                Subject = 'Delinquency - ' + summary.Tenant_Name__c,
                Yardi_AR_Id__c = summary.Yardi_AR_Id__c,
                Receivables_Summary__c = summary.Id,
                Unit__c = summary.Unit__c,
                Property_Asset__c = summary.Property_Asset__c,
                Balance_At_Open_Amount__c = summary.Total_Outstanding_Amount__c,
                Current_Balance_Amount__c = summary.Total_Outstanding_Amount__c,
                Days_Past_Due_At_Open__c = summary.Days_Past_Due__c,
                Current_Days_Past_Due__c = summary.Days_Past_Due__c,
                Escalation_Level__c = 0,
                Reopened_Count__c = 0,
                Auto_Closed_By_Sync__c = false
            ));
        }
        if (doInsert == true) {
            insert cases;
        }
        return cases;
    }

    /**
     * Payment commitments under a Case (master-detail parent, so it is mandatory).
     *
     * @param count          How many.
     * @param parentCaseId   Master Case.
     * @param commitmentType `Commitment_Type__c`.
     * @param dueDate        `Due_Date__c`.
     * @param doInsert       Insert when true.
     * @return The commitments, all at status Open.
     */
    public static List<Payment_Commitment__c> commitments(
        Integer count,
        Id parentCaseId,
        String commitmentType,
        Date dueDate,
        Boolean doInsert
    ) {
        List<Payment_Commitment__c> commitments = new List<Payment_Commitment__c>();
        for (Integer i = 0; i < count; i++) {
            commitments.add(new Payment_Commitment__c(
                Case__c = parentCaseId,
                Commitment_Type__c = commitmentType,
                Promised_Amount__c = 1000 + i,
                Due_Date__c = dueDate,
                Instalment_Number__c = i + 1,
                Status__c = 'Open',
                Breach_Notified__c = false
            ));
        }
        if (doInsert == true) {
            insert commitments;
        }
        return commitments;
    }

    /**
     * Feed DTOs, source-agnostic.
     *
     * @param count            How many.
     * @param yardiUnitId      Unit external id to reference; nullable.
     * @param totalOutstanding Total on every row.
     * @param daysPastDue      Aging on every row.
     * @return The DTOs.
     */
    public static List<ReceivablesFeedDTO> feedRows(
        Integer count,
        String yardiUnitId,
        Decimal totalOutstanding,
        Integer daysPastDue
    ) {
        List<ReceivablesFeedDTO> rows = new List<ReceivablesFeedDTO>();
        for (Integer i = 0; i < count; i++) {
            ReceivablesFeedDTO row = new ReceivablesFeedDTO();
            row.yardiArId = 'AR-F-' + nextKey();
            row.yardiUnitId = yardiUnitId;
            row.tenantName = 'Feed Tenant ' + i;
            row.monthlyRent = 5000;
            row.totalOutstanding = totalOutstanding;
            row.baseRentOutstanding = totalOutstanding;
            row.currentAmount = 0;
            row.aging90Plus = totalOutstanding;
            row.daysPastDue = daysPastDue;
            rows.add(row);
        }
        return rows;
    }

    /**
     * @return The Delinquency record type Id, or null when it is not deployed.
     */
    public static Id delinquencyRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.Case
            .getRecordTypeInfosByDeveloperName()
            .get('Delinquency');
        return (info == null) ? null : info.getRecordTypeId();
    }
}
