/**
 * Selector for Work_Order__c — encapsulates ALL SOQL against Work_Order__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 Module B1 (Property Management — WorkOrder + Lease cluster). Relocates the
 * five Work_Order__c queries out of WorkOrderController.
 * Design: agent-output/p4-selector-design.md §3 #1, §4 Skeleton A, §5, §6.
 *
 * MODE — every query uses USER_MODE (API 67). Work_Order__c is a custom object;
 * P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and enforces the
 * running user's sharing + FLS. No guest path touches Work Orders → no SYSTEM_MODE.
 * Static SOQL uses the `WITH USER_MODE` clause; the three relocated dynamic queries
 * pass `AccessLevel.USER_MODE` as the Database.query argument (the WITH clause is
 * illegal inside a dynamic query string).
 *
 * DYNAMIC QUERIES ARE INJECTION-SAFE: the three widget methods build their SOQL
 * entirely from selector-owned constants (ROW_FIELDS + literal WHERE/ORDER tails).
 * No caller-supplied string is concatenated, so there is no injection surface —
 * which is why they take no clause parameter (a deliberate departure from the
 * design's illustrative selectByClause(String), chosen so no SOQL fragment leaks
 * into the controller). The *_DateTime__c ORDER BY fields (Reported_DateTime__c,
 * SLA_Due_DateTime__c) are the post-D3-migration field names; the old *_Date__c
 * fields are dropped and must not be reintroduced.
 *
 * NOT-FOUND CONTRACT: selectRequiredById uses a single-row SOQL assignment, so a
 * missing Id throws System.QueryException — preserving WorkOrderController.getActivity's
 * existing record-page behaviour (the Id always references a live record there).
 * This mirrors the WireSelector.selectRequiredById pilot precedent.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (pilot template)
 */
public with sharing class WorkOrderSelector {

    /**
     * Display field set shared by the three dynamic widget queries — the exact
     * columns WorkOrderController.toRows maps. Centralised so the queries stay DRY
     * (AccountSelector reference pattern).
     */
    private static final String ROW_FIELDS = String.join(new List<String>{
        'Id', 'Subject__c', 'Property_Display_Name__c', 'Unit_Label__c', 'Priority__c',
        'Status__c', 'SLA_Health__c', 'Hours_Open__c', 'SLA_Breached__c', 'Is_Untouched__c', 'Is_Open__c'
    }, ', ');

    /**
     * All Work Orders with the four SLA-rollup flags getHomeKpis aggregates in
     * Apex. Backs WorkOrderController.getHomeKpis.
     *
     * @return Every Work_Order__c with Is_Open__c, SLA_Breached__c, SLA_Health__c
     *         and Is_Untouched__c populated; empty list when none exist.
     */
    public static List<Work_Order__c> selectForKpis() {
        return [
            SELECT Is_Open__c, SLA_Breached__c, SLA_Health__c, Is_Untouched__c
            FROM Work_Order__c
            WITH USER_MODE
        ];
    }

    /**
     * The six most-recently-reported open Work Orders. Backs getRecentWorkOrders.
     *
     * @return Up to 6 open Work_Order__c, newest reported first
     *         (ORDER BY Reported_DateTime__c DESC LIMIT 6).
     */
    public static List<Work_Order__c> selectRecentOpen() {
        return Database.query(
            'SELECT ' + ROW_FIELDS + ' FROM Work_Order__c ' +
            'WHERE Is_Open__c = true ORDER BY Reported_DateTime__c DESC LIMIT 6',
            AccessLevel.USER_MODE
        );
    }

    /**
     * Breached, still-open Critical/High Work Orders, soonest SLA due first.
     * Backs getEscalations.
     *
     * @return Escalation Work_Order__c ordered by SLA_Due_DateTime__c ASC NULLS LAST;
     *         empty list when none qualify.
     */
    public static List<Work_Order__c> selectEscalations() {
        return Database.query(
            'SELECT ' + ROW_FIELDS + ' FROM Work_Order__c ' +
            'WHERE Is_Escalation__c = true ORDER BY SLA_Due_DateTime__c ASC NULLS LAST',
            AccessLevel.USER_MODE
        );
    }

    /**
     * Open Work Orders no one has touched, oldest reported first. Backs getUntouched.
     *
     * @return Untouched Work_Order__c ordered by Reported_DateTime__c ASC NULLS LAST;
     *         empty list when none qualify.
     */
    public static List<Work_Order__c> selectUntouched() {
        return Database.query(
            'SELECT ' + ROW_FIELDS + ' FROM Work_Order__c ' +
            'WHERE Is_Untouched__c = true ORDER BY Reported_DateTime__c ASC NULLS LAST',
            AccessLevel.USER_MODE
        );
    }

    /**
     * One Work Order by Id for the record-page activity view. Backs getActivity.
     * Single-row assignment: a missing Id throws System.QueryException, matching the
     * record-page contract that the Id always resolves to a live row.
     *
     * @param workOrderId Work_Order__c Id (record-page context).
     * @return The Work_Order__c with Id and Is_Untouched__c populated.
     * @throws System.QueryException when no Work_Order__c matches the Id.
     */
    public static Work_Order__c selectRequiredById(Id workOrderId) {
        return [
            SELECT Id, Is_Untouched__c
            FROM Work_Order__c
            WHERE Id = :workOrderId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
