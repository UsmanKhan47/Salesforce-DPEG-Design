@isTest
private class OnboardingTaskRollupServiceTest {
    @isTest static void recalcComputesRollups() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Unit & Tenant Setup'; o.Status__c = 'In Progress';
        insert o;
        Date td = Date.today();
        List<Task> tasks = TestDataFactory.createOnboardingTasks(4, o.Id, false);
        tasks[0].Subject='a'; tasks[0].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[0].Onboarding_Status__c='Complete'; tasks[0].Status='Completed'; tasks[0].ActivityDate=td.addDays(-30);

        tasks[1].Subject='b'; tasks[1].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[1].Onboarding_Status__c='In Progress'; tasks[1].Status='Open'; tasks[1].ActivityDate=td.addDays(3);

        tasks[2].Subject='c'; tasks[2].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[2].Onboarding_Status__c='Blocked'; tasks[2].Status='Open'; tasks[2].ActivityDate=td.addDays(-5);

        tasks[3].Subject='d'; tasks[3].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[3].Onboarding_Status__c='Not Applicable'; tasks[3].Status='Open'; tasks[3].ActivityDate=null;
        insert tasks;

        Test.startTest();
        OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        Test.stopTest();
        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_NA__c, Tasks_Open__c,
                                  Tasks_Overdue__c, Tasks_Blocked_Now__c, Completion_Pct__c
                           FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(4, r.Tasks_Total__c);
        System.assertEquals(1, r.Tasks_Complete__c);
        System.assertEquals(1, r.Tasks_NA__c);
        System.assertEquals(2, r.Tasks_Open__c, 'in-progress + blocked');
        System.assertEquals(1, r.Tasks_Overdue__c, 'only the open, past-due blocked task (−5d); complete excluded, in-progress is future, N/A has no date');
        System.assertEquals(1, r.Tasks_Blocked_Now__c);
        System.assertEquals(25, r.Completion_Pct__c, '1 of 4 = 25%');
    }

    /**
     * Bulk scenario per .claude/rules/bulk-test-rule.md: 251 Tasks under one
     * Onboarding__c, forcing a second 200-record batch chunk through recalc's
     * single SOQL-then-single-DML shape (no SOQL/DML growth per task).
     */
    @isTest static void recalcHandlesBulk251Tasks() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        List<Task> tasks = TestDataFactory.createOnboardingTasks(251, o.Id, false);
        TestDataFactory.applyOverrides(tasks, new Map<String, Object>{
            'Onboarding_Status__c' => 'Not Started',
            'ActivityDate' => Date.today().addDays(7)
        });
        insert tasks;

        Test.startTest();
        OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        Test.stopTest();

        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Not_Started__c, Tasks_Open__c,
                                  Tasks_Complete__c, Completion_Pct__c
                           FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(251, r.Tasks_Total__c, 'all 251 tasks counted across the second batch chunk');
        System.assertEquals(251, r.Tasks_Not_Started__c);
        System.assertEquals(251, r.Tasks_Open__c);
        System.assertEquals(0, r.Tasks_Complete__c);
        System.assertEquals(0, r.Completion_Pct__c, '0 of 251 complete = 0%');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WITH SYSTEM_MODE regression coverage (2026-08-05). TaskSelector.selectByOnboardingIds moved
    // from WITH USER_MODE to WITH SYSTEM_MODE in the SAME change as selectByTransactionDealIds's
    // fix for a REPRODUCED production failure (see TaskSelector's Javadoc). This method has no
    // reproduced incident of its own — recalc() is invoked directly from
    // OnboardingService.completeTask rather than from a trigger — but it read the identical
    // custom fields (Onboarding__c, Onboarding_Status__c) under the identical WITH USER_MODE
    // call, so it carried the same latent defect and was fixed pre-emptively in the same change.
    //
    // ⚠ ROUTE B, REVISED 2026-08-05 after a failed deploy (job 0Afiw000000FALdCAO). recalc() both
    // READS Task (via TaskSelector, WITH SYSTEM_MODE) and WRITES BACK to Onboarding__c
    // (`update upd.values()`), and the checklist Task must be inserted by the restricted principal
    // to reach recalc() at all — none of that has a read-only escape hatch. (Unlike
    // TaskSelectorTest's selector-level pins, a zero-permission-set user cannot be used here: the
    // Onboarding__c update and the Task insert are both plain, unenforced DML, and object-level
    // CRUD — Edit on Onboarding__c, Create on Task — IS enforced by the platform for ordinary DML
    // even without any WITH clause.) The first version of this test built a zero-permission-set
    // user and threw `System.SecurityException: Access to entity 'Onboarding__c' denied` before
    // the Task-FLS behavior under test was ever reached.
    //
    // The fix assigns exactly two permission sets, verified by reading both files' metadata
    // directly rather than assumed:
    //   - DPEG_PropertyMgmt_Edit   -> Onboarding__c (and 12 other PM objects') object CRUD + FLS
    //     on Onboarding__c's OWN fields (needed for recalc's `update Onboarding__c`). Declares NO
    //     Task field permissions at all.
    //   - Broker_Protection_Access -> Task object CRUD (Create/Read/Edit — needed for the
    //     checklist Task insert). Its Task field grants are ActivityDate/Description/WhatId —
    //     NONE of Transaction_Deal__c, Onboarding__c, or Onboarding_Status__c. Cross-module
    //     borrow purely for this object-CRUD grant, for the same reason given in
    //     TaskRollupServiceTest: it is the only permission set in the repo granting Task CRUD
    //     without ALSO granting the checklist FLS (DPEG_Task_Edit / DPEG_TaskChecklist_View, the
    //     only two sets that declare Task.Onboarding__c / Task.Onboarding_Status__c, are
    //     deliberately NOT assigned).
    //
    // Deliberately no try/catch: on the OLD code, this call throws a System.QueryException
    // directly (there is no trigger wrapping it here), which fails the test method outright —
    // that failure IS the regression pin.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 REGRESSION PIN for the pre-emptive fix — a principal who can work with Onboarding__c but
     * has NO FLS grant on Onboarding__c/Onboarding_Status__c (the Task's fields) must be able to
     * call recalc() without it throwing.
     */
    @isTest static void recalc_minimumAccessUserNoFLS_succeeds_pinsTheSameLatentDefectAsTransactionRollup() {
        User minAccessUser = buildMinimumAccessUser('onbFlsA');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
            assignPermissionSets(minAccessUser.Id, new Set<String>{ 'DPEG_PropertyMgmt_Edit', 'Broker_Protection_Access' });
        }

        Id onboardingId;
        Test.startTest();
        System.runAs(minAccessUser) {
            Onboarding__c o = TestDataFactory.createOnboarding(null, false);
            insert o; // Create CRUD on Onboarding__c comes from DPEG_PropertyMgmt_Edit
            onboardingId = o.Id;

            List<Task> tasks = TestDataFactory.createOnboardingTasks(4, o.Id, false);
            tasks[0].Onboarding_Status__c = 'Complete';
            tasks[1].Onboarding_Status__c = 'In Progress';
            tasks[2].Onboarding_Status__c = 'Not Started';
            tasks[3].Onboarding_Status__c = 'Blocked';
            insert tasks; // Create CRUD on Task comes from Broker_Protection_Access

            OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id }); // no try/catch by design
        }
        Test.stopTest();

        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Blocked_Now__c
                           FROM Onboarding__c WHERE Id = :onboardingId];
        System.assertEquals(4, r.Tasks_Total__c,
            'recalc() succeeded for a principal who can work with Onboarding__c but has no FLS '
            + 'grant on Onboarding__c/Onboarding_Status__c');
        System.assertEquals(1, r.Tasks_Complete__c, 'The one Complete Task is counted');
        System.assertEquals(1, r.Tasks_Blocked_Now__c, 'The one Blocked Task is counted');
    }

    /**
     * Bulk companion (.claude/rules/bulk-test-rule.md — 251+ for a service method with DML).
     * OnboardingTaskRollupService.recalc is not trigger-driven, so this does not cross a second
     * trigger batch chunk the way the Transaction rollup's bulk test does — it instead proves the
     * WITH SYSTEM_MODE fix holds when the single SOQL statement reads 251 rows at once for this
     * persona, not just a handful.
     */
    @isTest static void recalc_minimumAccessUserNoFLS_bulk251_succeeds() {
        User minAccessUser = buildMinimumAccessUser('onbFlsB');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
            assignPermissionSets(minAccessUser.Id, new Set<String>{ 'DPEG_PropertyMgmt_Edit', 'Broker_Protection_Access' });
        }

        Id onboardingId;
        Test.startTest();
        System.runAs(minAccessUser) {
            Onboarding__c o = TestDataFactory.createOnboarding(null, false);
            insert o;
            onboardingId = o.Id;

            List<Task> tasks = TestDataFactory.createOnboardingTasks(251, o.Id, false);
            insert tasks;

            OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        }
        Test.stopTest();

        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Not_Started__c FROM Onboarding__c WHERE Id = :onboardingId];
        System.assertEquals(251, r.Tasks_Total__c, 'All 251 checklist Tasks are counted for this principal');
        System.assertEquals(251, r.Tasks_Not_Started__c, 'createOnboardingTasks defaults every Task to Not Started');
    }

    /**
     * Builds (but does not insert) a user on the 'Minimum Access - Salesforce' profile. By itself
     * this profile grants NO object CRUD on any custom object and NO FLS on any custom field.
     * Each test assigns exactly the permission sets it needs via assignPermissionSets below — see
     * the design note above this section for which, and why.
     */
    private static User buildMinimumAccessUser(String tag) {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Min',
            LastName = 'Access',
            Alias = 'minonb',
            Email = 'min.access.onboarding@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /**
     * Assigns the named permission sets to an already-inserted user. See TaskRollupServiceTest's
     * identical helper for the MIXED_DML_OPERATION rationale.
     */
    private static void assignPermissionSets(Id userId, Set<String> permissionSetNames) {
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id));
        }
        insert assignments;
    }
}
