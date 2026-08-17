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
    // ═══ 🔴 REWRITTEN 2026-08-17. THE PREVIOUS "ROUTE B" WAS STRUCTURALLY IMPOSSIBLE ══════════
    // These two tests had been red since at least 2026-08-12 (committed PARKED, see commit
    // ebd700e). Two compounding causes, both measured against usman-dpeg on 2026-08-17 rather
    // than reasoned about. The full write-up is in TaskRollupServiceTest's matching note — the
    // two classes were broken by ONE pair of causes and are fixed by ONE design; read them
    // together and change them together.
    //
    // CAUSE 1 — the persona could not create a Task, and no permission set could ever fix it.
    // The old fixture ran on `Minimum Access - Salesforce` and assigned Broker_Protection_Access
    // for "Task object CRUD (Create/Read/Edit)". That was read off the permission set FILE, which
    // does declare <object>Task</object> with allowCreate=true. It is not what the org has:
    // `SELECT SobjectType, COUNT(Id) FROM ObjectPermissions ... GROUP BY SobjectType` returns
    // Lead 53, Transaction__c 8, and Task/Event ABSENT — zero rows anywhere in the org, on any
    // permission set OR profile. Activity CRUD is not permission-set-grantable here; it lives on
    // the PROFILE (`PermissionsEditTask`: Minimum Access = false, Standard User = true). The
    // assignment was inert and the tests failed `System.TypeException: DML operation INSERT not
    // allowed on Task`. The persona now runs on `Standard User`; Broker_Protection_Access is
    // dropped rather than left in place with a comment explaining its non-existent purpose.
    //
    // CAUSE 2 — 🔴 AND THIS IS THE ONE THAT KILLS ROUTE B OUTRIGHT. With CRUD fixed the insert
    // then failed `System.DmlException: Operation failed due to fields being inaccessible on
    // Sobject Task`: ordinary DML on Task is FLS-enforced in this org, and createOnboardingTasks
    // writes Onboarding__c and Onboarding_Status__c — the exact two fields this test must
    // WITHHOLD. FLS edit implies read, so no grant satisfies both halves. "Have the restricted
    // principal insert the checklist Task itself" is not an under-permissioned fixture, it is a
    // self-contradiction.
    //
    // THE FIX — the fixture is built in the DEFAULT full-access context and OWNED BY the persona;
    // the persona performs ONLY the recalc() call. Nothing about the property under test is lost,
    // and here even less than on the Transaction side: recalc() is NOT trigger-driven (it is
    // called directly by OnboardingService.completeTask), so the persona was never required to
    // author the Tasks — only to invoke the recompute, which is exactly what it still does. This
    // is TaskSelectorTest's Route A applied one layer up, at the service instead of the selector.
    // ⚠ OWNERSHIP IS LOAD-BEARING ON BOTH RECORDS. Activity is `sharingModel Private` here, so
    // admin-owned Tasks would be invisible and every rollup would compute ZERO — passing or
    // failing for reasons having nothing to do with FLS. And DPEG_PropertyMgmt_Edit grants
    // Onboarding__c viewAllRecords = true but modifyAllRecords = FALSE (measured), so recalc's own
    // `update upd.values()` only succeeds on a record the persona owns.
    //
    // DISCRIMINATION — the property the whole test exists for, verified rather than assumed:
    //     SELECT Parent.Name, Parent.IsOwnedByProfile FROM FieldPermissions
    //     WHERE Field IN ('Task.Onboarding__c','Task.Onboarding_Status__c')
    //       -> only DPEG_Transaction_Team / DPEG_Junior_Analyst_PSG / DPEG_TaskChecklist_View /
    //          DPEG_Task_Edit / sfdc_slack, ALL IsOwnedByProfile = false. Re-running that query
    //          filtered to IsOwnedByProfile = true returns ZERO rows: NO PROFILE grants either
    //          field, `Standard User` included, and none of those sets is assigned below.
    // Restore `WITH USER_MODE` on TaskSelector.selectByOnboardingIds and the recalc() call below
    // throws `No such column 'Onboarding__c' on entity 'Task'` again, exactly as designed — there
    // is no try/catch, so that throw fails the method outright and IS the pin. ⚠ If a future admin
    // grants either field at the PROFILE level these tests silently stop discriminating; re-run
    // the query above before trusting a green result.
    //
    // ⚠ RENAMED in the same pass, so the names stop asserting a profile that is no longer used:
    //   recalc_minimumAccessUserNoFLS_succeeds_pinsTheSameLatentDefectAsTransactionRollup
    //     -> recalc_noFlsUser_succeeds_pinsTheSameLatentDefectAsTransactionRollup
    //   recalc_minimumAccessUserNoFLS_bulk251_succeeds -> recalc_noFlsUser_bulk251_succeeds
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Deliberately no try/catch: on the OLD code, this call throws a System.QueryException
    // directly (there is no trigger wrapping it here), which fails the test method outright —
    // that failure IS the regression pin.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 REGRESSION PIN for the pre-emptive fix — a principal who can work with Onboarding__c but
     * has NO FLS grant on Onboarding__c/Onboarding_Status__c (the Task's fields) must be able to
     * call recalc() without it throwing.
     */
    @isTest static void recalc_noFlsUser_succeeds_pinsTheSameLatentDefectAsTransactionRollup() {
        User noFlsUser = buildTaskCapableNoFlsUser('onbFlsA');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert noFlsUser;
            assignPermissionSets(noFlsUser.Id, new Set<String>{ 'DPEG_PropertyMgmt_Edit' });
        }

        // Fixture in the DEFAULT full-access context, OWNED BY the persona: writing
        // Onboarding__c / Onboarding_Status__c onto a Task needs edit FLS this persona must NOT
        // have, and Activity is Private here so admin-owned Tasks would be invisible and every
        // rollup would compute zero. Ownership of the Onboarding__c matters too —
        // DPEG_PropertyMgmt_Edit grants View All but NOT Modify All, so recalc's own update only
        // succeeds on a record the persona owns. See the design note above.
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.OwnerId = noFlsUser.Id;
        insert o;
        Id onboardingId = o.Id;

        List<Task> tasks = TestDataFactory.createOnboardingTasks(4, o.Id, false);
        tasks[0].Onboarding_Status__c = 'Complete';
        tasks[1].Onboarding_Status__c = 'In Progress';
        tasks[2].Onboarding_Status__c = 'Not Started';
        tasks[3].Onboarding_Status__c = 'Blocked';
        for (Task t : tasks) {
            t.OwnerId = noFlsUser.Id;
        }
        insert tasks;

        Test.startTest();
        System.runAs(noFlsUser) {
            // The ONLY thing the persona does — exactly what OnboardingService.completeTask does
            // on their behalf. recalc() reads Task through the SYSTEM_MODE selector and writes
            // back to Onboarding__c. No try/catch by design: under a reverted WITH USER_MODE the
            // read throws `No such column 'Onboarding__c' on entity 'Task'` and fails the method.
            OnboardingTaskRollupService.recalc(new Set<Id>{ onboardingId });
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
    @isTest static void recalc_noFlsUser_bulk251_succeeds() {
        User noFlsUser = buildTaskCapableNoFlsUser('onbFlsB');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert noFlsUser;
            assignPermissionSets(noFlsUser.Id, new Set<String>{ 'DPEG_PropertyMgmt_Edit' });
        }

        // Same fixture shape and same two ownership reasons as the sibling test above.
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.OwnerId = noFlsUser.Id;
        insert o;
        Id onboardingId = o.Id;

        List<Task> tasks = TestDataFactory.createOnboardingTasks(251, o.Id, false);
        for (Task t : tasks) {
            t.OwnerId = noFlsUser.Id;
        }
        insert tasks;

        Test.startTest();
        System.runAs(noFlsUser) {
            // 251 rows read in ONE SOQL statement by a principal with no FLS on either field.
            OnboardingTaskRollupService.recalc(new Set<Id>{ onboardingId });
        }
        Test.stopTest();

        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Not_Started__c FROM Onboarding__c WHERE Id = :onboardingId];
        System.assertEquals(251, r.Tasks_Total__c, 'All 251 checklist Tasks are counted for this principal');
        System.assertEquals(251, r.Tasks_Not_Started__c, 'createOnboardingTasks defaults every Task to Not Started');
    }

    /**
     * Builds (but does not insert) a user on the `Standard User` profile — the LEAST-privileged
     * profile in this org that can create a Task at all (`PermissionsEditTask = true`, measured;
     * `Minimum Access - Salesforce` is `false`, and no permission set can supply it because Task
     * has zero ObjectPermissions rows org-wide — see the design note above this section).
     *
     * 🔴 What the profile does NOT give is the point: it grants NO FLS on any Metadata-API-
     * deployed custom field, so this persona still cannot read Task.Onboarding__c or
     * Task.Onboarding_Status__c. That is the single fact the regression pin depends on. Each test
     * assigns, via assignPermissionSets below, only the custom-OBJECT CRUD it needs — never a set
     * declaring the withheld Task fields (DPEG_Task_Edit / DPEG_TaskChecklist_View /
     * DPEG_Transaction_Team must never be assigned here).
     */
    private static User buildTaskCapableNoFlsUser(String tag) {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
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
