/**
 * Selector for Onboarding__c. Encapsulates ALL SOQL against Onboarding__c per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md
 * ("All SOQL must live in Selector classes. Nothing else queries that object.").
 *
 * P4 (Onboarding + Task-rollup cleanup wave). This closes single-selector
 * ownership of Onboarding__c: the one inline query previously lived in
 * OnboardingController.activeOnboardings() and fed all five dashboard readers
 * (getKpis / getOnboardings / getPortfolio / getRiskAlerts / getTimeSla). Those
 * five now share a single selector call.
 *
 * MODE — `WITH USER_MODE` (API 67). Onboarding__c is a custom object; P3 measured
 * the custom-field FLS gap = 0, so USER_MODE is safe and enforces the running
 * user's sharing + FLS. NOTE this is a deliberate behaviour change: the relocated
 * query ran in the default SYSTEM mode before (no WITH clause); moving SOQL into
 * the selector layer is the point at which USER_MODE is applied, per the P4 goal.
 * The internal PM dashboard personas that call these AuraEnabled controllers hold
 * the deployed Onboarding permsets, so USER_MODE returns rows. There is NO
 * guest/automation path on Onboarding__c, so NO `SYSTEM_MODE` appears here.
 *
 * ⚠ CLAUSE ORDER: `WITH USER_MODE` sits after the WHERE and BEFORE ORDER BY — the
 * order the P4 pilot flagged as a compile-breaker if reversed.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/WireSelector.cls (P4 pilot template)
 * @see force-app/main/default/classes/TaskSelector.cls (sibling selector, this wave)
 * @see agent-output/p4-selector-design.md (§2, §4, §5)
 */
public with sharing class OnboardingSelector {

    /**
     * Terminal onboarding stage. An Onboarding__c in this stage is complete and is
     * excluded from every "active" dashboard read. Held here (not in the caller)
     * because the active/terminal split is a property of the query shape this
     * selector owns.
     */
    private static final String DONE_STAGE = 'Onboarding Complete';

    /**
     * All in-flight (non-terminal) Onboarding__c records for the PM dashboard,
     * ordered by target completion date (nulls last). Backs
     * OnboardingController's getKpis / getOnboardings / getPortfolio /
     * getRiskAlerts / getTimeSla — every field selected is read by at least one of
     * those five, so the field list is the union they need and must not be
     * narrowed without checking all five consumers.
     *
     * @return Active Onboarding__c records (Stage__c != 'Onboarding Complete')
     *         ordered by Target_Completion_Date__c NULLS LAST; an empty list when
     *         none are active (never null).
     * @example
     * List<Onboarding__c> active = OnboardingSelector.selectActive();
     */
    public static List<Onboarding__c> selectActive() {
        return [
            SELECT Id, Name, Property_Name__c, Stage__c, Status__c,
                   Start_Date__c, Target_Completion_Date__c, Onboarding_Lead__c,
                   Completion_Pct__c, Tasks_Total__c, Tasks_Complete__c, Tasks_In_Progress__c,
                   Tasks_Not_Started__c, Tasks_Blocked__c, Tasks_NA__c, Tasks_Open__c,
                   Tasks_Overdue__c, Tasks_Blocked_Now__c, Tasks_Stalled__c, Tasks_Due_7d__c,
                   Days_To_Onboard__c, Age_Days__c, Oldest_Open_Days__c, Past_Target__c
            FROM Onboarding__c
            WHERE Stage__c != :DONE_STAGE
            WITH USER_MODE
            ORDER BY Target_Completion_Date__c NULLS LAST
        ];
    }
}
