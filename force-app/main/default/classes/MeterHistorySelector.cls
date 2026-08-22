/**
 * Selector for `Meter__History` - the platform-maintained field-history shadow of
 * `Meter__c`. All SOQL against it lives here, per ARCHITECTURE.md section 2 and
 * `.claude/rules/apex-layering-rule.md`.
 *
 * === WHY THIS OBJECT IS QUERIED AT ALL: TELLING A METER SWAP FROM A REGISTER ROLLOVER ===
 * A rollover (a 5-dial register passing 99,980 -> 20) and a physical meter swap (the old
 * device retired at 87,412, the replacement starting at 20) are ARITHMETICALLY IDENTICAL on
 * a utility bill: both present as `Current_Reading__c < Previous_Reading__c`. Applying
 * rollover arithmetic to a swap fabricates a register-sized consumption spike, which then
 * propagates into every variance formula and fires the alert. FSD 5.10.4's own
 * `Service_Identifier__c` ("durable service-point ID; survives meter swaps") is the FSD
 * telling us swaps are real and expected.
 *
 * `Meter__c.Meter_Number__c` carries `trackHistory=true`. A device swap on an existing
 * service point IS a change to that field, so the platform has already been recording the
 * evidence. This selector reads it. That is a POSITIVE swap signal that needs no new field,
 * no new checkbox and no user discipline.
 *
 * === THREE FACTS ABOUT `__History` THAT SHAPE EVERY CALLER ===
 * All three measured against `usman-dpeg` on 2026-08-22:
 *
 *  1. `Meter__History` IS queryable (`isAccessible = true`) and `Field` holds the field's
 *     full API name verbatim - `'Meter_Number__c'`, not `'MeterNumber'` and not a label.
 *  2. It is NOT createable (`isCreateable = false`). Apex cannot insert a history row, in a
 *     test or anywhere else. A unit test therefore CANNOT seed a swap through this object,
 *     which is why `UtilityBillService` exposes a `@TestVisible` injection seam instead of
 *     mocking a selector return.
 *  3. History rows are NOT visible in the transaction that created them - a query
 *     immediately after the `update` returns zero rows. That is not a defect for this
 *     feature: a bill is always saved in a LATER transaction than the swap it follows.
 *     It does mean an integration test cannot swap and bill in one go.
 *
 * MODE - SYSTEM_MODE, justified at the method. SHARING - see the method header.
 */
public with sharing class MeterHistorySelector {

    /** The one tracked field a device swap changes. Matched verbatim against `Field`. */
    private static final String METER_NUMBER_FIELD = 'Meter_Number__c';

    /**
     * Every recorded change to `Meter_Number__c` on the given meters at or after `since`.
     *
     * === `WITH SYSTEM_MODE`, JUSTIFIED HERE (ARCHITECTURE.md section 2) ===
     * Automation-path read, performed from the `Utility_Bill__c` before-trigger on the
     * saving user's behalf. It decides an arithmetic branch and is never shown to anyone.
     * `USER_MODE` throws rather than degrades, and a persona without history-object access
     * would have their own legitimate bill save rolled back with
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` - a swap check must never be able to do that.
     *
     * SHARING is inherited (`with sharing`) and that is correct here: the caller is saving a
     * bill whose master-detail parent IS one of these meters, so the running user can see
     * the meter by construction.
     *
     * @param meterIds Meter Ids to check; null/empty returns an empty list.
     * @param since    Earliest change instant of interest; null means no lower bound. The
     *                 caller passes the oldest prior-bill read date in the batch so the
     *                 query stays bounded rather than reading a meter's whole life.
     * @return Matching history rows carrying ParentId and CreatedDate, oldest first;
     *         never null.
     */
    public static List<Meter__History> selectMeterNumberChanges(Set<Id> meterIds, Datetime since) {
        if (meterIds == null || meterIds.isEmpty()) {
            return new List<Meter__History>();
        }
        Datetime lowerBound = (since == null) ? Datetime.newInstance(1970, 1, 1) : since;
        return [
            SELECT Id, ParentId, Field, OldValue, NewValue, CreatedDate
            FROM Meter__History
            WHERE ParentId IN :meterIds
              AND Field = :METER_NUMBER_FIELD
              AND CreatedDate >= :lowerBound
            WITH SYSTEM_MODE
            ORDER BY ParentId ASC, CreatedDate ASC
        ];
    }
}
