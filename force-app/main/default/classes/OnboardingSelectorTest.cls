/**
 * Tests for OnboardingSelector (P4, Onboarding + Task-rollup cleanup wave).
 *
 * Covers the single relocated query, selectActive():
 *   - field population across the wide dashboard field set,
 *   - the active/terminal split (Stage__c != 'Onboarding Complete'),
 *   - ORDER BY Target_Completion_Date__c NULLS LAST,
 *   - a 251-record bulk read (bulk-test-rule),
 *   - the empty-result contract when everything is terminal (never null).
 *
 * Onboarding__c is a CUSTOM object; design §5 measured the custom-field FLS gap = 0
 * and reserves the System.runAs(standardUser) USER_MODE proof for STANDARD-object
 * selectors, so no runAs test appears here (mirrors the WireSelector pilot's
 * custom-object stance). These tests run in the default (admin) context, which
 * has full FLS, so USER_MODE returns every row.
 *
 * @see force-app/main/default/classes/OnboardingSelector.cls
 * @see force-app/main/default/classes/TaskSelectorTest.cls (sibling, this wave)
 * @see agent-output/p4-selector-design.md (§2, §4, §5)
 */
@isTest
private class OnboardingSelectorTest {

    private static final String TERMINAL_STAGE = 'Onboarding Complete';

    @isTest
    static void selectActive_populatesSelectedFields() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Unit & Tenant Setup';
        o.Status__c = 'In Progress';
        o.Completion_Pct__c = 42;
        o.Tasks_Total__c = 20;
        o.Tasks_Complete__c = 8;
        o.Tasks_Overdue__c = 3;
        o.Days_To_Onboard__c = 25;
        o.Age_Days__c = 12;
        o.Oldest_Open_Days__c = 17;
        o.Past_Target__c = true;
        o.Start_Date__c = Date.newInstance(2026, 5, 1);
        o.Target_Completion_Date__c = Date.newInstance(2026, 7, 1);
        insert o;

        Test.startTest();
        List<Onboarding__c> rows = OnboardingSelector.selectActive();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The single active Onboarding is returned');
        Onboarding__c r = rows[0];
        Assert.areEqual('Unit & Tenant Setup', r.Stage__c, 'Stage__c is selected');
        Assert.areEqual('In Progress', r.Status__c, 'Status__c is selected');
        Assert.areEqual(42, r.Completion_Pct__c, 'Completion_Pct__c is selected');
        Assert.areEqual(20, r.Tasks_Total__c, 'Tasks_Total__c is selected');
        Assert.areEqual(8, r.Tasks_Complete__c, 'Tasks_Complete__c is selected');
        Assert.areEqual(3, r.Tasks_Overdue__c, 'Tasks_Overdue__c is selected');
        Assert.areEqual(25, r.Days_To_Onboard__c, 'Days_To_Onboard__c is selected');
        Assert.areEqual(12, r.Age_Days__c, 'Age_Days__c is selected');
        Assert.areEqual(17, r.Oldest_Open_Days__c, 'Oldest_Open_Days__c is selected');
        Assert.areEqual(true, r.Past_Target__c, 'Past_Target__c is selected');
        Assert.areEqual(Date.newInstance(2026, 5, 1), r.Start_Date__c, 'Start_Date__c is selected');
        Assert.areEqual(Date.newInstance(2026, 7, 1), r.Target_Completion_Date__c, 'Target_Completion_Date__c is selected');
    }

    @isTest
    static void selectActive_excludesTerminalStage() {
        List<Onboarding__c> obs = TestDataFactory.createOnboardings(2, null, false);
        obs[0].Stage__c = 'Property Set up';   // active
        obs[1].Stage__c = TERMINAL_STAGE;      // terminal — must be excluded
        insert obs;

        Test.startTest();
        List<Onboarding__c> rows = OnboardingSelector.selectActive();
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the active Onboarding is returned; the terminal-stage one is excluded');
        Assert.areEqual(obs[0].Id, rows[0].Id, 'The active-stage record is the one returned');
        Assert.areNotEqual(TERMINAL_STAGE, rows[0].Stage__c, 'A returned row is never in the terminal stage');
    }

    @isTest
    static void selectActive_ordersByTargetDateNullsLast() {
        List<Onboarding__c> obs = TestDataFactory.createOnboardings(3, null, false);
        obs[0].Stage__c = 'Property Set up'; obs[0].Target_Completion_Date__c = Date.newInstance(2026, 9, 1);
        obs[1].Stage__c = 'Property Set up'; obs[1].Target_Completion_Date__c = null;
        obs[2].Stage__c = 'Property Set up'; obs[2].Target_Completion_Date__c = Date.newInstance(2026, 6, 1);
        insert obs;

        Test.startTest();
        List<Onboarding__c> rows = OnboardingSelector.selectActive();
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'All three active Onboardings returned');
        Assert.areEqual(Date.newInstance(2026, 6, 1), rows[0].Target_Completion_Date__c, 'Earliest target date sorts first');
        Assert.areEqual(Date.newInstance(2026, 9, 1), rows[1].Target_Completion_Date__c, 'Later target date sorts second');
        Assert.areEqual(null, rows[2].Target_Completion_Date__c, 'The null target date sorts LAST (NULLS LAST)');
    }

    /**
     * 251 active Onboardings in one DML, crossing the 200-row boundary
     * (bulk-test-rule). selectActive is a single query with no per-record work, so
     * it must return every one.
     */
    @isTest
    static void selectActive_bulk251_returnsAllActive() {
        TestDataFactory.createOnboardings(251, null, true);   // default Stage__c = 'Property Set up' (active)

        Test.startTest();
        List<Onboarding__c> rows = OnboardingSelector.selectActive();
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'All 251 active Onboardings are returned at bulk volume');
    }

    @isTest
    static void selectActive_allTerminal_returnsEmpty() {
        List<Onboarding__c> obs = TestDataFactory.createOnboardings(2, null, false);
        for (Onboarding__c o : obs) {
            o.Stage__c = TERMINAL_STAGE;
        }
        insert obs;

        Test.startTest();
        List<Onboarding__c> rows = OnboardingSelector.selectActive();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'When every Onboarding is terminal, selectActive returns an empty list (never null)');
    }
}
