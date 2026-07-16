/**
 * Selector for Broker_Assignment__c. Encapsulates ALL SOQL against
 * Broker_Assignment__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * P4, Module B2 — Property Management (Broker + Content cluster). Two consumers:
 *   • BrokerAssignmentController (dashboard reads + replaceBroker fetch-for-update)
 *       - queryAll (6 AuraEnabled methods)        -> selectAllOrderedByCreatedDateDesc
 *       - replaceBroker snapshot fetch            -> selectRequiredById
 *   • BrokerCheckInReminderSchedulable (overdue reminder scan)
 *       - overdue-active scan                     -> selectActiveOverdueByCheckInDays
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Broker_Assignment__c is a
 * custom object; P3 proved the custom-field FLS gap is 0, so USER_MODE enforces
 * the running user's sharing + FLS without breaking these internal personas
 * (design §5). There is NO guest/automation path on Broker_Assignment__c, so no
 * `SYSTEM_MODE` appears here.
 *
 * NOT-FOUND CONTRACT is per-caller (pilot WireSelector pattern):
 *   - list reads (dashboard / overdue scan)  : missing rows are normal -> return
 *     an EMPTY List, never null.
 *   - fetch-for-update (selectRequiredById)   : replaceBroker passed a specific Id
 *     it expects to exist; a miss is an error -> single-row SOQL assignment lets
 *     the native System.QueryException fly (matches the old inline query).
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see agent-output/p4-selector-design.md (§3 #5, §4, §5)
 */
public with sharing class BrokerAssignmentSelector {

    /**
     * Every Broker_Assignment__c, newest first — backs the six dashboard reads on
     * BrokerAssignmentController (KPIs, assignments grid, portfolio, alerts,
     * scorecard, broker totals, detail/history) which all buffer this single query
     * in memory and derive their own aggregates. The field set and
     * `ORDER BY CreatedDate DESC` mirror the original inline queryAll exactly.
     *
     * @return All Broker_Assignment__c records ordered by CreatedDate DESC; an
     *         empty list when none exist (never null).
     * @example
     * List<Broker_Assignment__c> all = BrokerAssignmentSelector.selectAllOrderedByCreatedDateDesc();
     */
    public static List<Broker_Assignment__c> selectAllOrderedByCreatedDateDesc() {
        return [
            SELECT Id, Status__c, Listing_Start_Date__c, Listing_End_Date__c, Reason_Ended__c, Replacement_Notes__c,
                   Last_Check_In_Date__c, Days_Since_Check_In__c, Listing_Active_Days__c,
                   Leased_Area__c, Vacant_Area__c,
                   Property_Asset__c, Property_Display_Name__c, Property_Type_Display__c,
                   Address_Display__c, Gross_Sq_Ft__c,
                   Broker__c, Broker_Name__c, Broker_Firm__c, Broker_Email__c, Broker_Phone__c
            FROM Broker_Assignment__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Active listings whose check-in is more than `thresholdDays` days stale —
     * backs BrokerCheckInReminderSchedulable's overdue scan. Days_Since_Check_In__c
     * is a formula over Last_Check_In_Date__c; the WHERE mirrors the original inline
     * query (`Status__c = 'Active' AND Days_Since_Check_In__c > :threshold`).
     *
     * @param thresholdDays Minimum days-since-check-in (exclusive) to flag overdue;
     *                      a null threshold short-circuits to an empty list.
     * @return Matching Active assignments (Id, Property_Display_Name__c, Broker__c);
     *         an empty list when thresholdDays is null or none qualify (never null).
     * @example
     * List<Broker_Assignment__c> overdue =
     *     BrokerAssignmentSelector.selectActiveOverdueByCheckInDays(BrokerAssignmentController.OVERDUE_DAYS);
     */
    public static List<Broker_Assignment__c> selectActiveOverdueByCheckInDays(Integer thresholdDays) {
        if (thresholdDays == null) {
            return new List<Broker_Assignment__c>();
        }
        return [
            SELECT Id, Property_Display_Name__c, Broker__c
            FROM Broker_Assignment__c
            WHERE Status__c = 'Active' AND Days_Since_Check_In__c > :thresholdDays
            WITH USER_MODE
        ];
    }

    /**
     * Fetches exactly one Broker_Assignment__c by Id for the broker-replacement
     * update path (backs BrokerAssignmentController.replaceBroker). Uses a single-row
     * SOQL assignment with LIMIT 1: when the Id resolves to no row, Apex throws
     * System.QueryException ("List has no rows for assignment to SObject"),
     * preserving the caller contract that a missing target is an error.
     *
     * FIELD SET IS DELIBERATE: replaceBroker reads Property_Asset__c, Broker__c,
     * Listing_Start_Date__c and Last_Check_In_Date__c off the returned record to
     * snapshot the outgoing broker's stint; a narrower SELECT would reintroduce a
     * System.SObjectException on those accesses. Do not narrow this field list.
     *
     * @param assignmentId Broker_Assignment__c Id to load for update; must reference
     *                     an existing row.
     * @return The Broker_Assignment__c with the snapshot fields populated.
     * @throws System.QueryException when no Broker_Assignment__c matches the Id.
     */
    public static Broker_Assignment__c selectRequiredById(Id assignmentId) {
        return [
            SELECT Id, Property_Asset__c, Broker__c, Listing_Start_Date__c, Last_Check_In_Date__c
            FROM Broker_Assignment__c
            WHERE Id = :assignmentId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
