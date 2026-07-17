/**
 * Selector for Lease_Renewal__c — encapsulates ALL SOQL against Lease_Renewal__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module B1. Relocates the four Lease_Renewal__c queries out of
 * LeaseRenewalController. Design: agent-output/p4-selector-design.md §3 #3, §4, §6.
 *
 * MODE: USER_MODE (custom object, FLS gap 0 — P3). Static SOQL uses `WITH USER_MODE`;
 * the two relocated dynamic widget queries pass `AccessLevel.USER_MODE`. Both dynamic
 * strings are built only from selector-owned constants (ROW_FIELDS + literal
 * WHERE/ORDER tails) — no caller string is concatenated, so there is no injection
 * surface (which is why they take no clause parameter).
 *
 * NOT-FOUND CONTRACT: selectRequiredById uses a single-row SOQL assignment (a miss
 * throws System.QueryException), preserving LeaseRenewalController.getTimeline's
 * record-page behaviour and mirroring the WireSelector.selectRequiredById precedent.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (pilot template)
 */
public with sharing class LeaseRenewalSelector {

    /**
     * Display field set shared by the two dynamic widget queries — the exact
     * columns LeaseRenewalController.toRow maps.
     */
    private static final String ROW_FIELDS = String.join(new List<String>{
        'Id', 'Tenant_Name__c', 'Property_Display_Name__c', 'Unit_Label__c', 'Lease_End__c',
        'Days_To_Expiry__c', 'Stage__c', 'Status__c', 'Last_Contact_Date__c',
        'Days_Since_Contact__c', 'Is_Non_Responsive__c'
    }, ', ');

    /**
     * All renewals with the fields getHomeKpis aggregates in Apex. Backs
     * LeaseRenewalController.getHomeKpis.
     *
     * @return Every Lease_Renewal__c with Status__c, Days_To_Expiry__c,
     *         Is_Non_Responsive__c and Renewed_Date__c populated; empty list when none.
     */
    public static List<Lease_Renewal__c> selectForKpis() {
        return [
            SELECT Status__c, Days_To_Expiry__c, Is_Non_Responsive__c, Renewed_Date__c
            FROM Lease_Renewal__c
            WITH USER_MODE
        ];
    }

    /**
     * The six most-recently-created renewals. Backs getRecentRenewals.
     *
     * @return Up to 6 Lease_Renewal__c, newest created first
     *         (ORDER BY CreatedDate DESC LIMIT 6).
     */
    public static List<Lease_Renewal__c> selectRecent() {
        return Database.query(
            'SELECT ' + ROW_FIELDS + ' FROM Lease_Renewal__c ' +
            'ORDER BY CreatedDate DESC LIMIT 6',
            AccessLevel.USER_MODE
        );
    }

    /**
     * Active renewals needing attention — non-responsive, or expiring within 30
     * days — soonest lease-end first. Backs getAttention.
     *
     * @return Attention Lease_Renewal__c ordered by Lease_End__c ASC NULLS LAST;
     *         empty list when none qualify.
     */
    public static List<Lease_Renewal__c> selectAttention() {
        return Database.query(
            'SELECT ' + ROW_FIELDS + ' FROM Lease_Renewal__c ' +
            'WHERE Status__c = \'Active\' AND (Is_Non_Responsive__c = true OR Days_To_Expiry__c <= 30) ' +
            'ORDER BY Lease_End__c ASC NULLS LAST',
            AccessLevel.USER_MODE
        );
    }

    /**
     * One renewal by Id for the record-page timeline header. Backs getTimeline.
     * Single-row assignment: a missing Id throws System.QueryException.
     *
     * @param renewalId Lease_Renewal__c Id (record-page context).
     * @return The Lease_Renewal__c with Id, Stage__c, Status__c, Is_Non_Responsive__c
     *         and Days_Since_Contact__c populated.
     * @throws System.QueryException when no Lease_Renewal__c matches the Id.
     */
    public static Lease_Renewal__c selectRequiredById(Id renewalId) {
        return [
            SELECT Id, Stage__c, Status__c, Is_Non_Responsive__c, Days_Since_Contact__c
            FROM Lease_Renewal__c
            WHERE Id = :renewalId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
