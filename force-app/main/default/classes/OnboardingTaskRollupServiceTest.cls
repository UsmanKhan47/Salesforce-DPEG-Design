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

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE 2026-09-02 DAY-0 ROLLUP SHARING FIX — ITEM 4' (the MIRROR IMAGE of the Transaction
    // rollup's fix). See agent-output/design-rollup-sharing-fix.md §3 and
    // OnboardingTaskRollupService's class header for the full argument.
    //
    // Here the WRITE (RollupWrites) has been `private without sharing` since 2026-08-22 and was
    // NEVER the problem. The READ (TaskSelector.selectByOnboardingIds -> OnboardingRollupReads)
    // was the one still sharing-filtered until 2026-09-02, and an ALWAYS-SUCCEEDING write paired
    // with a FILTERED read does not throw — it silently writes ZERO total / 0% complete. THAT is
    // the state this test proves is closed, and — same rule as the Transaction rollup's control —
    // "no exception" would not have caught it, because nothing ever threw.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE NON-OWNER CONTROL. `Onboarding__c` and its checklist Tasks are OWNED by a separate
     * `ownerUser`; the recompute is driven by `driverUser`, who holds record-level EDIT on the
     * Onboarding but has NO visibility into `ownerUser`'s Tasks (`Activity` stays Private, no
     * Activity/Task sharing rule exists anywhere in this repo, and these checklist Tasks attach
     * through the custom `Task.Onboarding__c` lookup — NOT `WhatId` — so no parent share can
     * cascade to them either). This is the REACHABLE production shape from
     * `OnboardingTaskRollupService`'s own header: a PM persona holds Edit on an `Onboarding__c`
     * while seeing only their OWN Tasks.
     *
     * ┌─────────────────────────────────────────────────────────────────────────────────────┐
     * │ 🔴 WHY THE EDIT GRANT IS AN EXPLICIT `Onboarding__Share`, NOT A GROUP MEMBERSHIP.    │
     * └─────────────────────────────────────────────────────────────────────────────────────┘
     * This fixture originally inserted a `GroupMember` into `DPEG_Property_Mgmt_Team` and leaned
     * on the criteria-based sharing rule `Onboarding_PM_All_RW` (criteria `Status__c != ''`) to
     * produce the Edit. It failed the guard below and rolled back deploy 0Afiw000000VkPxCAK on
     * 2026-09-02, for THREE independent reasons, any one of which is disqualifying for a test:
     *   1. Sharing recalculation triggered by a group-membership change is ASYNCHRONOUS. An
     *      in-test `GroupMember` insert is not reliably reflected in criteria-rule sharing inside
     *      the same transaction, so the guard races the platform and loses.
     *   2. `DPEG_Property_Mgmt_Team` has ZERO members in production — a known open go-live gate.
     *      `Onboarding_PM_All_RW` currently grants nobody anything, so the mechanism the fixture
     *      was reproducing is not actually live.
     *   3. Sharing rules are exposed to NEITHER SOQL NOR THE TOOLING API. There is no way for
     *      this test — or for DevOps — to confirm `Onboarding_PM_All_RW` is even deployed; the
     *      only route is a `retrieve`. A test must never depend on org config it cannot verify.
     * A manual `Onboarding__Share` is DETERMINISTIC and SYNCHRONOUS, needs no group membership,
     * and does not care whether `Onboarding_PM_All_RW` exists — while reproducing the identical
     * ACCESS SHAPE (record-level Edit on the parent, zero visibility into the Tasks), which is
     * the only property any assertion below actually depends on. `Onboarding__c` is
     * `sharingModel = Private` (see `Onboarding__c.object-meta.xml`), so `Onboarding__Share`
     * exists and accepts `RowCause = Manual`.
     * ⚠ THE SHARE IS THE LOAD-BEARING GRANT. The `DPEG_PropertyMgmt_Edit` assignment below is
     * NOT: that set is `viewAllRecords=true` / `modifyAllRecords=false`, so it supplies the
     * OBJECT-level Edit CRUD a PM really carries but CANNOT confer record-level Edit on a
     * Private-OWD record it does not own — proven by `TaskRollupServiceTest`'s twin, which
     * asserts `HasEditAccess == false` for a driver holding exactly that `allowEdit=true` shape.
     * It therefore cannot make the guard vacuous, and because
     * `TestDataFactory.assignPermissionSets` silently no-ops on a missing set it cannot make the
     * test fail either. It also grants NOTHING on Task/Activity (that set has no Activity object
     * or field entries at all), so it cannot leak Task visibility.
     *
     * HOW THIS GOES RED WITHOUT ITEM 4': revert `TaskSelector.OnboardingRollupReads` to
     * `with sharing` (leave `RollupWrites` alone — it was already `without sharing` and is
     * unrelated to this fix) -> `recalc` does NOT throw, and `Tasks_Total__c` /
     * `Completion_Pct__c` both silently come back 0, because `driverUser`'s Task read returns
     * zero rows. That is exactly the failure a "no exception" test cannot see.
     */
    @isTest static void recalc_nonOwnerDriver_countersNonZero_pinsItem4Prime() {
        User ownerUser = TestDataFactory.createStandardUserNoFls('onbShrOwn');
        User driverUser = TestDataFactory.createStandardUserNoFls('onbShrDrv');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // User and PermissionSetAssignment are SETUP objects — isolated in this runAs block
            // per the house pattern. NOTE: no GroupMember here any more; see the header above.
            insert new List<User>{ ownerUser, driverUser };
            TestDataFactory.assignPermissionSets(
                driverUser.Id, new Set<String>{ 'DPEG_PropertyMgmt_Edit' });
        }

        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.OwnerId = ownerUser.Id;
        insert o;
        Id onboardingId = o.Id;

        // 🔴 THE EDIT GRANT — explicit, synchronous, Apex-managed. Inserted by the default
        // test-running admin (a non-setup DML, so it must sit OUTSIDE the runAs block above).
        insert new Onboarding__Share(
            ParentId = onboardingId,
            UserOrGroupId = driverUser.Id,
            AccessLevel = 'Edit',
            RowCause = Schema.Onboarding__Share.RowCause.Manual
        );

        // 🔴 FIXTURE GUARD.
        System.runAs(driverUser) {
            UserRecordAccess access = [
                SELECT RecordId, HasReadAccess, HasEditAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :onboardingId
            ];
            Assert.isTrue(access.HasEditAccess,
                'FIXTURE PRECONDITION: driverUser must hold EDIT on the Onboarding via the '
                + 'explicit Onboarding__Share inserted immediately above (AccessLevel = Edit, '
                + 'RowCause = Manual) — that is the reachable production shape this test '
                + 'reproduces. If false, the manual share did not take: check that '
                + 'Onboarding__c is still sharingModel=Private (a switch to Public Read/Write '
                + 'or ControlledByParent removes Onboarding__Share entirely).');
        }

        List<Task> tasks = TestDataFactory.createOnboardingTasks(4, onboardingId, false);
        tasks[0].Onboarding_Status__c = 'Complete';
        tasks[1].Onboarding_Status__c = 'In Progress';
        tasks[2].Onboarding_Status__c = 'Not Started';
        tasks[3].Onboarding_Status__c = 'Blocked';
        for (Task t : tasks) {
            t.OwnerId = ownerUser.Id; // NOT driverUser — this is the whole point
        }
        insert tasks;

        Test.startTest();
        System.runAs(driverUser) {
            // Exactly what OnboardingService.completeTask does on the PM's behalf.
            OnboardingTaskRollupService.recalc(new Set<Id>{ onboardingId });
        }
        Test.stopTest();

        Onboarding__c r = [
            SELECT Tasks_Total__c, Tasks_Complete__c, Completion_Pct__c
            FROM Onboarding__c WHERE Id = :onboardingId
        ];
        Assert.areEqual(4, r.Tasks_Total__c,
            '0 here means the READ stayed sharing-filtered while the WRITE stayed escalated — the '
            + 'exact silent-zero state Item 4\' exists to close. driverUser owns none of these '
            + 'Tasks, so a filtered read sees none of them.');
        Assert.areEqual(1, r.Tasks_Complete__c, 'The one Complete Task is counted.');
        Assert.areEqual(25, r.Completion_Pct__c,
            '1 of 4 = 25%, not 0% — the silently-wrong-dashboard-percentage failure this fix closes.');
    }

    /**
     * 🔴 PROMOTED 2026-09-02 to `TestDataFactory.createStandardUserNoFls` — see
     * `TaskRollupServiceTest`'s identical delegation for the rationale (this class carried the
     * byte-identical twin that triggered the promotion).
     */
    private static User buildTaskCapableNoFlsUser(String tag) {
        return TestDataFactory.createStandardUserNoFls(tag);
    }

    /**
     * 🔴 PROMOTED 2026-09-02 to `TestDataFactory.assignPermissionSets` — thin delegation, same
     * reason as `buildTaskCapableNoFlsUser` above.
     */
    private static void assignPermissionSets(Id userId, Set<String> permissionSetNames) {
        TestDataFactory.assignPermissionSets(userId, permissionSetNames);
    }
}
