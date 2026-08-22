/**
 * Selector for `Utility_Bill__c` - encapsulates ALL SOQL against the monthly utility bill
 * per ARCHITECTURE.md section 2 and `.claude/rules/apex-layering-rule.md`.
 *
 * FSD 5.10.5. One bill per meter per billing month; `Meter__c` is its master-detail parent,
 * so a bill inherits the meter's Private sharing.
 *
 * === MODE - MIXED, PER METHOD ===
 * ARCHITECTURE.md section 2: "The mode is a property of the METHOD, never of the class."
 *
 *   USER_MODE   - selectDetailById, selectRecentByMeterIds. User-requested reads behind an LWC.
 *   SYSTEM_MODE - selectChainByMeterIds (trigger path) and queryVarianceSweep (batch path).
 *                 Both justified at their own declarations.
 *
 * === SHARING - ONE METHOD ESCAPES IT AND IT IS NOT THE OBVIOUS ONE ===
 * The class is `with sharing`. `SYSTEM_MODE` lifts CRUD/FLS and NEVER sharing, so those are
 * two separate decisions and are taken separately here:
 *
 *   selectChainByMeterIds  - `with sharing` (inherited). Runs inside the bill's own trigger,
 *                            as the user saving that bill. Master-detail guarantees that user
 *                            can already see the meter and therefore its sibling bills.
 *   queryVarianceSweep     - runs inside `private without sharing class VarianceSweep`, and
 *                            that is a SEPARATE, SEPARATELY JUSTIFIED decision. See its own
 *                            header.
 *
 * @see MeterSelector
 * @see UtilityVarianceAlertBatch
 */
public with sharing class UtilityBillSelector {

    /**
     * The full chain of bills for the given meters, oldest read first.
     *
     * === `WITH SYSTEM_MODE`, JUSTIFIED HERE (ARCHITECTURE.md section 2) ===
     * Automation-path read. Called from the `Utility_Bill__c` trigger on the saving user's
     * BEHALF - to work out this bill's consumption and to re-link the prior-bill chain - and
     * not because the user asked to see other bills. `USER_MODE` throws rather than degrades,
     * and every field below is Metadata-API-deployed, so a persona missing one FLS grant
     * would have its own perfectly legitimate save rolled back with
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`.
     *
     * === ROW ARITHMETIC - READ BEFORE RAISING THE TRIGGER'S BULK CEILING ===
     * This deliberately loads EVERY bill for each affected meter rather than a window around
     * the changed read dates, because a full re-link is the only formulation that is
     * provably correct under all four chain-breaking events at once (back-dated insert,
     * read-date edit, middle delete, undelete). The cost is:
     *
     *     rows = (meters in this trigger chunk) x (lifetime bills per meter)
     *
     * A trigger chunk is at most 200 records, so at most 200 meters. At 12 monthly bills a
     * year that is 2,400 rows after one year and 12,000 after five - comfortably inside the
     * 50,000-row query limit. IF a meter ever accumulates more than ~250 bills AND a single
     * import touches 200 distinct meters, this must become a windowed query. Nothing else in
     * this feature has to change when it does.
     *
     * @param meterIds Meter Ids whose chains are needed; null/empty returns an empty list.
     * @return Bills ordered by meter, then Read_Date__c ASC (nulls last), then Id - a total
     *         order, so the chain is deterministic even for two bills read the same day.
     *         Never null.
     */
    public static List<Utility_Bill__c> selectChainByMeterIds(Set<Id> meterIds) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new List<Utility_Bill__c>();
        }
        return [
            SELECT Id, Meter__c, Bill_Date__c, Read_Date__c, Previous_Reading__c,
                   Current_Reading__c, Consumption__c, Prior_Utility_Bill__c
            FROM Utility_Bill__c
            WHERE Meter__c IN :meterIds
            WITH SYSTEM_MODE
            ORDER BY Meter__c ASC, Read_Date__c ASC NULLS LAST, Id ASC
        ];
    }

    /**
     * One bill with everything the record-page detail component renders, including the
     * prior bill's totals so the variance can be explained rather than merely stated.
     *
     * USER_MODE: this is the record the user opened.
     *
     * NOT-FOUND CONTRACT: returns null rather than throwing, because the controller turns a
     * missing/inaccessible bill into the same user-safe message as any other read failure
     * and there is nothing a QueryException would add.
     *
     * @param billId The bill; null returns null.
     * @return The bill, or null when it does not exist or is not visible.
     */
    public static Utility_Bill__c selectDetailById(Id billId) {
        if (billId == null) {
            return null;
        }
        List<Utility_Bill__c> rows = [
            SELECT Id, Name, Meter__c, Meter__r.Name, Meter__r.Meter_Number__c,
                   Meter__r.Utility_Type__c, Meter__r.Service_Identifier__c,
                   Meter__r.Register_Modulus__c, Meter__r.Property_Asset__c,
                   Meter__r.Property_Asset__r.Property_Name__c, Meter__r.Unit__c,
                   Meter__r.Unit__r.Suite_Number__c,
                   Bill_Date__c, Read_Date__c, Previous_Reading__c, Current_Reading__c,
                   Consumption__c, Total_Charges_Amount__c, Rate_Per_Unit__c,
                   Prior_Utility_Bill__c, Prior_Utility_Bill__r.Name,
                   Prior_Utility_Bill__r.Read_Date__c,
                   Prior_Utility_Bill__r.Consumption__c,
                   Prior_Utility_Bill__r.Total_Charges_Amount__c,
                   Usage_Variance_Amount__c, Rate_Variance_Amount__c,
                   Total_Variance_Amount__c
            FROM Utility_Bill__c
            WHERE Id = :billId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recent bills for the given meters, newest read first.
     *
     * USER_MODE: backs the billing-history list a user opened.
     *
     * @param meterIds  Meter Ids; null/empty returns an empty list.
     * @param rowLimit  Maximum rows; coerced into 1..2000.
     * @return Bills newest first; never null.
     */
    public static List<Utility_Bill__c> selectRecentByMeterIds(Set<Id> meterIds, Integer rowLimit) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new List<Utility_Bill__c>();
        }
        Integer cap = boundedLimit(rowLimit);
        return [
            SELECT Id, Name, Meter__c, Meter__r.Meter_Number__c, Meter__r.Utility_Type__c,
                   Bill_Date__c, Read_Date__c, Consumption__c, Total_Charges_Amount__c,
                   Rate_Per_Unit__c, Prior_Utility_Bill__c,
                   Prior_Utility_Bill__r.Total_Charges_Amount__c,
                   Usage_Variance_Amount__c, Rate_Variance_Amount__c, Total_Variance_Amount__c
            FROM Utility_Bill__c
            WHERE Meter__c IN :meterIds
            WITH USER_MODE
            ORDER BY Read_Date__c DESC NULLS LAST, Id DESC
            LIMIT :cap
        ];
    }

    /**
     * Batch locator for the variance sweep: every bill that HAS a prior bill and was touched
     * since the given cutoff.
     *
     * The threshold itself is applied in Apex, not here, deliberately: the variance fields
     * are cross-object FORMULAS, so a WHERE clause on them is non-selective and would force
     * a full scan on every run. `LastModifiedDate` is indexed, and "touched since the last
     * run" is also the natural idempotency window - see UtilityVarianceAlertBatch's header
     * for why this feature has no idempotency MARKER FIELD.
     *
     * @param cutoff Only bills modified at or after this instant; null means everything.
     * @return A `Database.QueryLocator` over the candidate bills.
     */
    public static Database.QueryLocator queryVarianceSweep(Datetime cutoff) {
        return new VarianceSweep().locator(cutoff);
    }

    /**
     * === `without sharing`, NARROW AND SEPARATELY JUSTIFIED (ARCHITECTURE.md section 2) ===
     * This inner class holds ONE query and nothing else, which is the shape the architecture
     * mandates instead of `without sharing` on a whole selector.
     *
     * WHY IT IS NEEDED, AND WHY SYSTEM_MODE ALONE IS NOT ENOUGH. `SYSTEM_MODE` bypasses
     * CRUD/FLS ONLY - it does NOT bypass sharing. `Meter__c` is Private OWD and
     * `Utility_Bill__c` is ControlledByParent, so a bill is visible only to someone who can
     * see its meter. `UtilityVarianceAlertBatch` runs as whoever SCHEDULED it. A scheduling
     * principal who owns no meters would get an empty locator and `finish()` would log an
     * all-zeros summary that is indistinguishable from a quiet month - a monitoring alert
     * that silently monitors nothing. That is the exact failure this project has already
     * measured once on an approval write, so it is fixed here rather than left to the
     * scheduling step.
     *
     * The escape is safe because nothing here is returned to a user: the locator feeds a
     * batch that sends a notification to a fixed public group and writes no records.
     */
    private without sharing class VarianceSweep {
        Database.QueryLocator locator(Datetime cutoff) {
            Datetime since = (cutoff == null) ? Datetime.newInstance(1970, 1, 1) : cutoff;
            return Database.getQueryLocator([
                SELECT Id, Name, Meter__c, Meter__r.Meter_Number__c, Meter__r.Utility_Type__c,
                       Meter__r.Property_Asset__c, Meter__r.Property_Asset__r.Property_Name__c,
                       Bill_Date__c, Read_Date__c, Consumption__c, Total_Charges_Amount__c,
                       Prior_Utility_Bill__c, Prior_Utility_Bill__r.Total_Charges_Amount__c,
                       Usage_Variance_Amount__c, Rate_Variance_Amount__c,
                       Total_Variance_Amount__c
                FROM Utility_Bill__c
                WHERE Prior_Utility_Bill__c != NULL
                  AND LastModifiedDate >= :since
                WITH SYSTEM_MODE
                ORDER BY Id ASC
            ]);
        }
    }

    /** Coerces a caller-supplied row limit into 1..2000. Null becomes 200. */
    private static Integer boundedLimit(Integer requested) {
        if (requested == null) {
            return 200;
        }
        if (requested < 1) {
            return 1;
        }
        return requested > 2000 ? 2000 : requested;
    }
}
