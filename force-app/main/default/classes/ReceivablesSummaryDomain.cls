/**
 * Maps normalized feed DTOs onto `Receivables_Summary__c` mirror rows.
 *
 * LAYER - Domain. ZERO SOQL, ZERO DML. Every lookup it needs is passed in as a resolved Map, which
 * is what keeps `ReceivablesSyncService` responsible for the queries and this class provable without
 * a database.
 *
 * === NULL IS NOT ZERO, AND THAT RULE IS ENFORCED HERE OR NOWHERE ===
 * A feed that omits a value has said nothing; substituting 0 makes the mirror ASSERT something the
 * source never claimed. Two places where that matters concretely:
 *   - `Monthly_Rent__c` is the `Months_Outstanding__c` denominator. A 0 does not blank the metric,
 *     it corrupts the whole section 6.5 "worst by months of rent" ranking.
 *   - `Total_Outstanding_Amount__c` at 0 reads as "the tenant paid up", which auto-closes a live
 *     Case. A null must never become that.
 * So every assignment below copies the DTO value through verbatim, including null.
 *
 * === THE ONE PLACE A FALLBACK IS APPLIED, AND WHY ===
 * `Monthly_Rent__c` falls back to the matched `Unit__c.Current_Monthly_Rent__c` when the feed omits
 * it (OQ-3). This is a fallback to ANOTHER SOURCE OF THE SAME FACT, not an invented default: the
 * Unit mirror is itself the Yardi rent roll. When neither source has it, the field stays null and
 * `Months_Outstanding__c` stays blank - correctly, because there is no denominator.
 *
 * === `Yardi_Last_Synced_DateTime__c` CARRIES THE FEED'S CLOCK, NOT SALESFORCE'S ===
 * FSD section 4 requires last-synced to be visible on screen. Stamping `System.now()` would make
 * every row look fresh the instant it was written even when the feed behind it was three days old -
 * which is the exact deception the health check exists to prevent, reproduced on the UI. The feed's
 * own `feedAsOf` goes here instead, so a stale feed LOOKS stale to a human as well as to the job.
 *
 * @see ReceivablesFeedDTO.cls     (the source shape, and its null contract)
 * @see ReceivablesSyncService.cls (resolves the lookups and performs the upsert)
 */
public with sharing class ReceivablesSummaryDomain {

    /**
     * Build mirror rows from feed rows.
     *
     * `Property_Asset__c` is DERIVED from the matched Unit's master rather than carried on the feed,
     * because `Property_Asset__c` has no external id in this org (measured 2026-08-22). An unmatched
     * `yardiUnitId` therefore leaves BOTH the Unit and the Property Asset null - the row still lands
     * and the lifecycle still runs, it simply is not navigable to a property. That is a data problem
     * to see in a report, not a reason to drop the row.
     *
     * @param rows              Normalized feed rows; null/empty safe.
     * @param unitsByYardiId    Units keyed by `Yardi_Unit_Id__c`; may be empty.
     * @param userIdsByUsername Active user Ids keyed by LOWERCASED username; may be empty.
     * @param syncRunId         The run stamped onto every row, making per-row staleness auditable.
     * @param feedAsOf          The feed's own clock, stamped as last-synced.
     * @return Mirror rows ready for upsert on `Yardi_AR_Id__c`. Never null.
     */
    public static List<Receivables_Summary__c> toRecords(
        List<ReceivablesFeedDTO> rows,
        Map<String, Unit__c> unitsByYardiId,
        Map<String, Id> userIdsByUsername,
        Id syncRunId,
        DateTime feedAsOf
    ) {
        List<Receivables_Summary__c> records = new List<Receivables_Summary__c>();
        if (rows == null || rows.isEmpty()) {
            return records;
        }
        Map<String, Unit__c> units = (unitsByYardiId == null) ? new Map<String, Unit__c>() : unitsByYardiId;
        Map<String, Id> users = (userIdsByUsername == null) ? new Map<String, Id>() : userIdsByUsername;

        for (ReceivablesFeedDTO row : rows) {
            Unit__c unit = (String.isBlank(row.yardiUnitId)) ? null : units.get(row.yardiUnitId);

            Receivables_Summary__c summary = new Receivables_Summary__c();
            summary.Yardi_AR_Id__c = row.yardiArId;
            summary.Unit__c = (unit == null) ? null : unit.Id;
            summary.Property_Asset__c = (unit == null) ? null : unit.Property_Asset__c;
            summary.Tenant_Name__c = resolveTenantName(row, unit);

            // The ONE fallback, and only to the other Yardi mirror of the same fact. Never to 0.
            summary.Monthly_Rent__c = (row.monthlyRent != null)
                ? row.monthlyRent
                : ((unit == null) ? null : unit.Current_Monthly_Rent__c);

            summary.Total_Outstanding_Amount__c = row.totalOutstanding;
            summary.Base_Rent_Outstanding_Amount__c = row.baseRentOutstanding;
            summary.NNN_CAM_Outstanding_Amount__c = row.nnnCamOutstanding;
            summary.Late_Fee_Outstanding_Amount__c = row.lateFeeOutstanding;
            summary.Other_Outstanding_Amount__c = row.otherOutstanding;

            summary.Current_Amount__c = row.currentAmount;
            summary.Aging_1_30_Amount__c = row.aging1To30;
            summary.Aging_31_60_Amount__c = row.aging31To60;
            summary.Aging_61_90_Amount__c = row.aging61To90;
            summary.Aging_90_Plus_Amount__c = row.aging90Plus;

            summary.Days_Past_Due__c = row.daysPastDue;

            if (String.isNotBlank(row.responsiblePropertyManagerUsername)) {
                summary.Responsible_Property_Manager__c =
                    users.get(row.responsiblePropertyManagerUsername.toLowerCase());
            }

            summary.Sync_Run__c = syncRunId;
            summary.Yardi_Last_Synced_DateTime__c = feedAsOf;
            records.add(summary);
        }
        return records;
    }

    /**
     * The distinct `Yardi_Unit_Id__c` values a feed refers to - the caller uses this to build its
     * single Unit query instead of querying per row.
     *
     * @param rows Feed rows; null/empty safe.
     * @return Distinct non-blank unit keys; never null.
     */
    public static Set<String> collectUnitKeys(List<ReceivablesFeedDTO> rows) {
        Set<String> keys = new Set<String>();
        if (rows == null) {
            return keys;
        }
        for (ReceivablesFeedDTO row : rows) {
            if (row != null && String.isNotBlank(row.yardiUnitId)) {
                keys.add(row.yardiUnitId);
            }
        }
        return keys;
    }

    /**
     * The distinct property-manager usernames a feed refers to.
     *
     * @param rows Feed rows; null/empty safe.
     * @return Distinct non-blank usernames; never null.
     */
    public static Set<String> collectManagerUsernames(List<ReceivablesFeedDTO> rows) {
        Set<String> usernames = new Set<String>();
        if (rows == null) {
            return usernames;
        }
        for (ReceivablesFeedDTO row : rows) {
            if (row != null && String.isNotBlank(row.responsiblePropertyManagerUsername)) {
                usernames.add(row.responsiblePropertyManagerUsername);
            }
        }
        return usernames;
    }

    /**
     * Tenant label: the feed's, else the matched Unit's. Tenant identity in this org is a STRING -
     * there is no `Tenant__c` object - so this denormalised label is what the section 6.5 rankings
     * group on, which is why it is worth falling back rather than leaving blank.
     *
     * @param row  The feed row.
     * @param unit The matched Unit, or null.
     * @return The tenant name, or null when neither source has one.
     */
    private static String resolveTenantName(ReceivablesFeedDTO row, Unit__c unit) {
        if (String.isNotBlank(row.tenantName)) {
            return row.tenantName;
        }
        return (unit == null) ? null : unit.Tenant_Name__c;
    }
}
