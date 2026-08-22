/**
 * Typed accessor over the `Receivables_Sync_Config__c` hierarchy custom setting. Modelled on
 * `SharePointConfig` and `ContentPublicationBudget`, the two in-repo precedents.
 *
 * LAYER - utility/config. No SOQL, no DML. `getOrgDefaults()` is a PLATFORM CACHE READ AND COSTS
 * ZERO SOQL, which is the whole reason a hierarchy custom setting was chosen over Custom Metadata
 * (design GATE-4, user decision D-AR-6): this is consulted inside a queueable and inside a batch,
 * where a query per run would be a real cost paid every night for a value that changes twice a year.
 *
 * WARNING - ONLY THE ORG DEFAULT IS EVER READ (`getOrgDefaults()`, never `getInstance()`). A
 * per-user override on a nightly job would mean the feed behaves differently depending on WHO
 * scheduled it, which is exactly the class of bug that makes a scheduled job impossible to reason
 * about after the scheduling principal leaves.
 *
 * === THERE ARE NO HARDCODED FALLBACKS AND THERE MUST NEVER BE ANY ===
 * `getOrgDefaults()` returns an EMPTY INSTANCE rather than null when no row has ever been written,
 * so every accessor below can return null and every caller must handle it. That is deliberate: a
 * hardcoded default threshold would silently open Cases against a number nobody agreed to, and the
 * FSD references the opening threshold five times without ever quantifying it (OQ-1). An unset
 * config is a HALT (`Halt_Reason__c = 'Config Missing'`), which is visible, auditable and fixable in
 * Setup in thirty seconds. A hardcoded 5000 is none of those things.
 *
 * POST-DEPLOY GATE: custom setting DATA is not deployable. Somebody must create the org-default row
 * in Setup with `Is_Enabled__c = true` and a provider class name, or every run halts as
 * 'Config Missing'. That is by design and it LOOKS like a bug - which is why the halt reason is a
 * distinct picklist value and not a generic failure.
 *
 * @see SharePointConfig.cls           (the precedent, including the zero-SOQL assertion in its test)
 * @see ReceivablesIngestQueueable.cls (the only consumer of `isReady()` / `unavailableReason()`)
 */
public with sharing class ReceivablesSyncConfig {

    /**
     * True only when the feature is switched on AND has everything it needs to do useful work.
     *
     * "Useful work" deliberately includes AT LEAST ONE opening threshold. A run with neither
     * threshold set can never open a Case, so it would upsert the mirror, run the whole lifecycle
     * and open nothing - a job that looks healthy in every counter while the feature is inert. That
     * is the failure mode this method exists to make impossible.
     *
     * @return True when enabled, a provider is named, and at least one opening threshold is set.
     */
    public static Boolean isReady() {
        Receivables_Sync_Config__c config = settings();
        return config.Is_Enabled__c == true
            && String.isNotBlank(config.Provider_Class_Name__c)
            && (config.Opening_Threshold_Amount__c != null || config.Opening_Threshold_Months__c != null);
    }

    /**
     * Why `isReady()` is false, as a `Sync_Run__c.Halt_Reason__c` picklist value.
     *
     * The two answers are NOT interchangeable and separating them is the point: `'Disabled'` means
     * a human deliberately switched the feature off and the nightly no-op is correct; `'Config
     * Missing'` means somebody INTENDED it to run and it cannot. Collapsing them would make a
     * forgotten post-deploy gate indistinguishable from a deliberate pause.
     *
     * @return `'Disabled'`, `'Config Missing'`, or `'None'` when the config is in fact ready.
     */
    public static String unavailableReason() {
        Receivables_Sync_Config__c config = settings();
        if (config.Is_Enabled__c != true) {
            return 'Disabled';
        }
        if (String.isBlank(config.Provider_Class_Name__c)
                || (config.Opening_Threshold_Amount__c == null && config.Opening_Threshold_Months__c == null)) {
            return 'Config Missing';
        }
        return 'None';
    }

    /** @return The configured provider class name, or null when unset. */
    public static String providerClassName() {
        return settings().Provider_Class_Name__c;
    }

    /**
     * @return Dollar opening threshold, or null when the business chose to key opening on months of
     *         rent alone.
     */
    public static Decimal openingThresholdAmount() {
        return settings().Opening_Threshold_Amount__c;
    }

    /**
     * @return Months-of-rent opening threshold, or null when the business chose to key opening on
     *         dollars alone. FSD 5.9.1 records that the team reasons in months of rent, which is why
     *         this exists alongside the dollar figure rather than instead of it.
     */
    public static Decimal openingThresholdMonths() {
        return settings().Opening_Threshold_Months__c;
    }

    /**
     * @return Staleness tolerance in hours, or null. NULL DISABLES THE STALENESS ARM of the health
     *         check - it does not default to some safe number. See `ReceivablesHealthCheckDomain`.
     */
    public static Integer stalenessToleranceHours() {
        return toInteger(settings().Staleness_Tolerance_Hours__c);
    }

    /** @return Minimum expected row count, or null (arm disabled). */
    public static Integer minimumRowCount() {
        return toInteger(settings().Minimum_Row_Count__c);
    }

    /**
     * @return Maximum tolerated percentage change in row count versus the previous COMPLETED run,
     *         or null (arm disabled). Catches a feed that DOUBLED, which a lower bound alone cannot.
     */
    public static Decimal maximumRowCountChangePct() {
        return settings().Maximum_Row_Count_Change_Pct__c;
    }

    /**
     * @return Days without a follow-up before a reminder fires, or null. Null disables the
     *         stale-follow-up alert entirely rather than defaulting to the FSD's 7 - see the class
     *         header on why there are no hardcoded fallbacks.
     */
    public static Integer staleFollowUpDays() {
        return toInteger(settings().Stale_Follow_Up_Days__c);
    }

    /**
     * The org-default custom-setting row.
     *
     * `getOrgDefaults()` returns an EMPTY INSTANCE rather than null when no row has ever been
     * written - which is why `isReady()` tests field values and not the reference. This method never
     * upserts: creating an empty, disabled row would add a DML statement to a read path to record a
     * state that is already the default answer.
     *
     * @return The org-default settings row; never queried, always cache-read (0 SOQL).
     */
    private static Receivables_Sync_Config__c settings() {
        Receivables_Sync_Config__c config = Receivables_Sync_Config__c.getOrgDefaults();
        return (config == null) ? new Receivables_Sync_Config__c() : config;
    }

    /**
     * Number(x,0) custom-setting fields arrive as `Decimal`, not `Integer` - the same trap
     * `NdaExpiryAlertBatch` and `CallForOffersAlertBatch` both document. Cast once, here, so no
     * caller has to remember.
     *
     * @param value The raw decimal.
     * @return The integer value, or null when the input is null.
     */
    private static Integer toInteger(Decimal value) {
        return (value == null) ? null : value.intValue();
    }
}
