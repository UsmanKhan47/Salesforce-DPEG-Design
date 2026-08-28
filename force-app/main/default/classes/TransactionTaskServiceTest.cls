/**
 * Tests TransactionTaskService (extracted from TransactionTaskController in P6). Proves the
 * checklist write behaviour is preserved end-to-end at the service layer: the status toggle,
 * the notes-preserving completion, and the wire-verification close (including its
 * name/phone gate, which the service now raises as a typed WireVerificationException rather
 * than an AuraHandledException — the AuraHandledException boundary moved to the controller).
 *
 * These are single-record operations (one Task update per method), so — like the
 * CounterOfferService precedent — there is no collection DML to bulk-test and no Savepoint
 * to force a rollback on. The controller-level tests separately cover the AuraHandledException
 * mapping.
 *
 * ── 🔴 2026-08-28: THE PERMISSION GATE + SYSTEM_MODE TESTS ───────────────────
 * The six original tests above all run as the TEST-RUNNING USER, who is a System
 * Administrator. THAT IS EXACTLY WHY THIS DEFECT SHIPPED: "Modify All Data" implies Task
 * CRUD, so an admin-run test passes against code no real user can execute. The tests in the
 * PERSONA section at the bottom of this class run as a `Minimum Access - Salesforce` user —
 * the profile Danish Rehman, Junior Dhanani and Nikhil Dhanani are all on (measured live on
 * usman-dpeg, 2026-08-28).
 *
 * ⚠ THE SIX ORIGINAL TESTS ARE NOW ALSO THE ADMIN-BYPASS PIN. They call the gated methods as
 * an administrator holding no `Transaction_Task_Actions` grant; if the "Modify All Data"
 * bypass were ever dropped from TransactionActionPermissionService.computeTaskActionAccess,
 * all six turn red. That is deliberate — dropping the bypass would take checklist completion
 * away from every administrator.
 *
 * ── ⚠ ONE TEST HERE CANNOT PASS UNTIL THE ADMIN HALF DEPLOYS ─────────────────
 * `grantHolder_withoutTaskEditCrud_completesAllThreeWritePaths` needs the
 * `Transaction_Task_Actions` CustomPermission to EXIST in the target org — measured
 * 2026-08-28, it does not yet (`SELECT DeveloperName FROM CustomPermission WHERE
 * DeveloperName LIKE 'Transaction%'` returns only `Transaction_Stage_Actions`).
 * `FeatureManagement.checkPermission` returns false for an undeployed permission rather than
 * throwing, so without that assert-the-premise guard the test would fail with a confusing
 * "access denied" and read as a code defect. It asserts the premise FIRST and names the cause.
 * This is the deploy-order coupling made loud on purpose: the Apex and the permission belong
 * in the same deploy.
 *
 * ⚠ AND IT IS WHY THE DENIAL TESTS ARE, TODAY, PARTLY VACUOUS. While the permission does not
 * exist, EVERY non-admin is denied — so a denial test passes even if the token string were
 * misspelled. The grant-holder test above is the control that makes the denials attributable;
 * read the two together, and treat a green denial suite with a red control as proving nothing.
 */
@isTest
private class TransactionTaskServiceTest {

    /** An Active Transaction with the fan-out Flow suppressed (no Contract_Executed_Date__c). */
    private static Transaction__c newSuppressedTransaction() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
        return t;
    }

    @isTest
    static void setTaskStatusToggles() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1, Status = 'Not Started');
        insert tsk;

        Test.startTest();
        TransactionTaskService.setTaskStatus(tsk.Id, true);
        Assert.areEqual('Completed', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status, 'done=true marks Completed');
        TransactionTaskService.setTaskStatus(tsk.Id, false);
        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status, 'done=false reverts to Not Started');
        Test.stopTest();
    }

    @isTest
    static void completeTaskWithNotesTrimsAndSaves() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1, Status = 'Not Started');
        insert tsk;

        Test.startTest();
        TransactionTaskService.completeTask(tsk.Id, '  Called the seller to confirm.  ');
        Test.stopTest();

        Task r = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        Assert.areEqual('Completed', r.Status, 'Task closed');
        Assert.areEqual('Called the seller to confirm.', r.Description, 'Notes trimmed and saved');
    }

    @isTest
    static void completeTaskBlankNotesLeavesDescriptionUntouched() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Status = 'Not Started', Description = 'Pre-existing comment');
        insert tsk;

        Test.startTest();
        TransactionTaskService.completeTask(tsk.Id, '   ');
        Test.stopTest();

        Task r = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        Assert.areEqual('Completed', r.Status, 'Task closed even with no new notes');
        Assert.areEqual('Pre-existing comment', r.Description, 'Blank notes must not overwrite existing comments');
    }

    @isTest
    static void completeWireVerificationStampsAndLogs() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100', null);
        Test.stopTest();

        Task r = [
            SELECT Status, Verbal_Verification_Completed__c, Verified_By__c,
                   Verification_Phone__c, Verified_At__c, Description
            FROM Task WHERE Id = :wire.Id
        ];
        Assert.areEqual('Completed', r.Status, 'Task closed after verification');
        Assert.areEqual(true, r.Verbal_Verification_Completed__c, 'Verification flag set');
        Assert.areEqual('Jane Doe', r.Verified_By__c, 'Confirmer name stamped');
        Assert.areEqual('713-555-0100', r.Verification_Phone__c, 'Phone stamped');
        Assert.isNotNull(r.Verified_At__c, 'Timestamp stamped');
        Assert.isTrue(r.Description != null && r.Description.contains('Verified by phone with Jane Doe'),
            'Standard verification note logged to comments');
    }

    @isTest
    static void completeWireVerificationWithCommentsAndExistingDescriptionAppendsInOrder() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2,
            Description = 'Prior note from earlier in the deal.');
        insert wire;

        Test.startTest();
        TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100',
            'Called title company twice to confirm.');
        Test.stopTest();

        Task r = [SELECT Description FROM Task WHERE Id = :wire.Id];
        Assert.isTrue(r.Description.startsWith('Prior note from earlier in the deal.'),
            'Existing Description preserved, not overwritten');
        Assert.isTrue(r.Description.contains('Called title company twice to confirm.'),
            'Verifier comments appended');
        Assert.isTrue(r.Description.contains('Verified by phone with Jane Doe'),
            'Standard note appended after the comments');
    }

    @isTest
    static void completeWireVerificationBlankNamePhoneThrowsTypedException() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        // The service raises a TYPED exception (not AuraHandledException) — the boundary moved
        // to the controller. Blank name and blank phone both trip the gate.
        try {
            TransactionTaskService.completeWireVerification(wire.Id, '', '', null);
            Assert.fail('Blank name/phone must raise WireVerificationException');
        } catch (TransactionTaskService.WireVerificationException e) {
            Assert.isNotNull(e.getMessage(), 'gate raises a typed WireVerificationException');
        }
        // Blank phone only (name present) also trips it.
        try {
            TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '', null);
            Assert.fail('Blank phone must raise WireVerificationException');
        } catch (TransactionTaskService.WireVerificationException e) {
            Assert.isNotNull(e.getMessage(), 'blank phone raises a typed WireVerificationException');
        }
        Test.stopTest();

        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :wire.Id].Status,
            'Task stays open when the gate blocks closure');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PERSONA SECTION (2026-08-28) — `Minimum Access - Salesforce`, the profile
    // EVERY real non-admin user in this org is on. Read the class header first.
    // ═════════════════════════════════════════════════════════════════════════

    private static final String TASK_ACTION_CUSTOM_PERMISSION = 'Transaction_Task_Actions';
    private static final String TRANSACTION_TEAM_GROUP = 'DPEG_Transaction_Team';
    private static final String MINIMUM_ACCESS_PROFILE = 'Minimum Access - Salesforce';
    private static final String NO_PERMISSION_MESSAGE =
        'You don\'t have permission to perform this action.';

    /**
     * 🔴 THE PREMISE PIN. Everything else in this section rests on two platform facts, and
     * neither is inferred — this test measures both, live, inside System.runAs:
     *
     *   1. a `Minimum Access - Salesforce` user CANNOT update a Task in user mode, even one
     *      they OWN and can READ (so the failure is object CRUD, not sharing and not FLS);
     *   2. the SAME write succeeds through `AccessLevel.SYSTEM_MODE` — the exact statement
     *      TransactionTaskService now runs.
     *
     * If fact 1 ever turns false (a profile change, a platform change), this test goes red and
     * the whole SYSTEM_MODE exemption should be re-argued rather than kept out of habit. If
     * fact 2 turns false, the fix does not work at all.
     *
     * ⚠ It calls Database.update DIRECTLY, NOT through the service, on purpose: it is a
     * statement about the PLATFORM, and it must stay verifiable while the
     * `Transaction_Task_Actions` custom permission is still undeployed and the service's gate
     * therefore refuses everyone.
     */
    @isTest
    static void premise_minimumAccessUserCannotWriteTaskInUserMode_butCanInSystemMode() {
        User persona = provisionedPersona('ttsA');
        Transaction__c t = suppressedTransactionOwnedBy(persona.Id);
        Task tsk = checklistTaskOwnedBy(t, persona.Id, 'A1', 'A. Contract Execution & Title Opening');

        Boolean taskUpdateable;
        Boolean taskReadable;
        Boolean plainUpdateThrew = false;
        String plainUpdateError = '(no exception)';

        Test.startTest();
        System.runAs(persona) {
            taskUpdateable = Schema.sObjectType.Task.isUpdateable();
            taskReadable = Schema.sObjectType.Task.isAccessible();
            try {
                update new Task(Id = tsk.Id, Status = 'Completed');
            } catch (Exception e) {
                plainUpdateThrew = true;
                plainUpdateError = e.getTypeName() + ': ' + e.getMessage();
            }
            Database.update(new Task(Id = tsk.Id, Status = 'Completed'), true, AccessLevel.SYSTEM_MODE);
        }
        Test.stopTest();

        Assert.isFalse(taskUpdateable,
            'PREMISE 1: a Minimum Access - Salesforce user must NOT have Task object Edit. If this '
            + 'is true, the CRUD gap this whole change works around no longer exists and the '
            + 'SYSTEM_MODE exemption in TransactionTaskService should be re-argued.');
        Assert.isTrue(taskReadable,
            'The same persona MUST still be able to READ Task — the checklist renders for them and '
            + 'TaskSelector.selectRequiredById is deliberately left WITH USER_MODE on that basis.');
        Assert.isTrue(plainUpdateThrew,
            'PREMISE 2: plain user-mode DML must FAIL for this persona — that failure IS the '
            + 'reported defect ("This task could not be updated"). Actual: ' + plainUpdateError);
        Assert.areEqual('Completed', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status,
            'PREMISE 3: the same write through AccessLevel.SYSTEM_MODE must succeed for the same '
            + 'persona on the same record — this is the mechanism the fix depends on');
    }

    /**
     * 🔴 THE ACCEPTANCE TEST — the scenario that shipped broken, covering ALL THREE write paths.
     * A user with NO Task object CRUD, who holds `Transaction_Task_Actions`, completes tasks.
     *
     * ⚠ REQUIRES THE ADMIN HALF OF THIS CHANGE TO BE DEPLOYED. The first assertion states that
     * premise explicitly so a red here reads as "the custom permission is missing from this org",
     * never as "the service is broken". See the class header.
     */
    @isTest
    static void grantHolder_withoutTaskEditCrud_completesAllThreeWritePaths() {
        Assert.isFalse(
            [SELECT Id FROM CustomPermission WHERE DeveloperName = :TASK_ACTION_CUSTOM_PERMISSION].isEmpty(),
            'PREMISE: the CustomPermission "' + TASK_ACTION_CUSTOM_PERMISSION + '" must exist in '
            + 'this org before this test can mean anything. FeatureManagement.checkPermission '
            + 'returns FALSE (it never throws) for an undeployed permission, so without this guard '
            + 'a missing admin half would look exactly like a broken gate. Deploy '
            + 'customPermissions/Transaction_Task_Actions + the DPEG_Task_Edit grant WITH this Apex.');

        User persona = provisionedPersona('ttsB');
        Transaction__c t = suppressedTransactionOwnedBy(persona.Id);
        Task toggle = checklistTaskOwnedBy(t, persona.Id, 'A1', 'A. Contract Execution & Title Opening');
        Task noted = checklistTaskOwnedBy(t, persona.Id, 'A2', 'A. Contract Execution & Title Opening');
        Task wire = checklistTaskOwnedBy(t, persona.Id,
            'Verify wiring instructions by phone (anti-fraud)', 'B. Earnest Money Wire');

        Boolean holdsGrant;
        Boolean taskUpdateable;

        Test.startTest();
        System.runAs(persona) {
            TransactionActionPermissionService.clearCache();
            holdsGrant = TransactionActionPermissionService.hasTaskActionAccess();
            taskUpdateable = Schema.sObjectType.Task.isUpdateable();
            TransactionTaskService.setTaskStatus(toggle.Id, true);
            TransactionTaskService.completeTask(noted.Id, '  Called the seller to confirm.  ');
            TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100', null);
        }
        Test.stopTest();

        Assert.isTrue(holdsGrant,
            'The persona holds Transaction_Task_Actions through DPEG_Task_Edit inside '
            + 'DPEG_Transaction_Team — the exact provisioning every real Transactions user has');
        Assert.isFalse(taskUpdateable,
            'AND STILL HAS NO Task OBJECT EDIT. This is the whole point: the custom permission '
            + 'authorizes, the platform CRUD does not — an admin-run test proves nothing here.');

        Map<Id, Task> saved = new Map<Id, Task>([
            SELECT Id, Status, Description, Verbal_Verification_Completed__c, Verified_By__c,
                   Verification_Phone__c, Verified_At__c
            FROM Task WHERE Id IN (:toggle.Id, :noted.Id, :wire.Id)
        ]);
        Assert.areEqual('Completed', saved.get(toggle.Id).Status, 'setTaskStatus wrote as a non-admin');
        Assert.areEqual('Completed', saved.get(noted.Id).Status, 'completeTask wrote as a non-admin');
        Assert.areEqual('Called the seller to confirm.', saved.get(noted.Id).Description,
            'completeTask still trims and saves the notes');
        Assert.areEqual('Completed', saved.get(wire.Id).Status,
            'completeWireVerification wrote as a non-admin');
        Assert.areEqual(true, saved.get(wire.Id).Verbal_Verification_Completed__c,
            'the verification flag is set — a custom field whose FLS lives on DPEG_Task_Edit');
        Assert.areEqual('Jane Doe', saved.get(wire.Id).Verified_By__c, 'confirmer name stamped');
        Assert.areEqual('713-555-0100', saved.get(wire.Id).Verification_Phone__c, 'phone stamped');
        Assert.isNotNull(saved.get(wire.Id).Verified_At__c, 'timestamp stamped');
    }

    /**
     * A persona with no grant at all is refused by setTaskStatus, with the user-safe message and
     * the typed exception the controller boundary is supposed to be able to distinguish.
     */
    @isTest
    static void deniedPersona_setTaskStatus_isRefusedWithTheUserSafeMessage() {
        User persona = barePersona('ttsC');
        Transaction__c t = newSuppressedTransaction();
        Task tsk = checklistTaskOwnedBy(t, persona.Id, 'A1', 'A. Contract Execution & Title Opening');

        String message;
        Test.startTest();
        System.runAs(persona) {
            TransactionActionPermissionService.clearCache();
            try {
                TransactionTaskService.setTaskStatus(tsk.Id, true);
                Assert.fail('A user without Transaction_Task_Actions must be REFUSED, not written for');
            } catch (TransactionActionPermissionService.AccessDeniedException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.areEqual(NO_PERMISSION_MESSAGE, message,
            'The refusal must carry the shared, user-safe denial message — no platform detail, no '
            + 'field API names, and the same wording as the Lead/Opportunity/Disposition gates');
        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status,
            'A refused call must not have written. SYSTEM_MODE DML sits BEHIND the gate, never '
            + 'in front of it — if this row is Completed the assert has been reordered below the DML.');
    }

    /** Same refusal on the second write path. */
    @isTest
    static void deniedPersona_completeTask_isRefusedAndLeavesTheTaskOpen() {
        User persona = barePersona('ttsD');
        Transaction__c t = newSuppressedTransaction();
        Task tsk = checklistTaskOwnedBy(t, persona.Id, 'A2', 'A. Contract Execution & Title Opening');

        String message;
        Test.startTest();
        System.runAs(persona) {
            TransactionActionPermissionService.clearCache();
            try {
                TransactionTaskService.completeTask(tsk.Id, 'Notes that must not be saved.');
                Assert.fail('completeTask must be gated too — fixing only setTaskStatus moves the error');
            } catch (TransactionActionPermissionService.AccessDeniedException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.areEqual(NO_PERMISSION_MESSAGE, message, 'user-safe denial message');
        Task saved = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        Assert.areEqual('Not Started', saved.Status, 'Task stays open');
        Assert.isNull(saved.Description, 'and the refused notes were never persisted');
    }

    /**
     * Third write path, plus the ORDER pin: the permission gate runs BEFORE the name/phone rule.
     * Called with blank name AND blank phone — the input the WireVerificationException guard
     * exists for — an unauthorized caller must still get the ACCESS refusal, not coaching on a
     * business rule they may not act on. Swap the two statements in the service and this reds.
     */
    @isTest
    static void deniedPersona_completeWireVerification_refusesBeforeTheNamePhoneRule() {
        User persona = barePersona('ttsE');
        Transaction__c t = newSuppressedTransaction();
        Task wire = checklistTaskOwnedBy(t, persona.Id,
            'Verify wiring instructions by phone (anti-fraud)', 'B. Earnest Money Wire');

        String message;
        Boolean wrongExceptionType = false;
        Test.startTest();
        System.runAs(persona) {
            TransactionActionPermissionService.clearCache();
            try {
                TransactionTaskService.completeWireVerification(wire.Id, '', '', null);
                Assert.fail('completeWireVerification must be gated too');
            } catch (TransactionActionPermissionService.AccessDeniedException e) {
                message = e.getMessage();
            } catch (TransactionTaskService.WireVerificationException e) {
                wrongExceptionType = true;
            }
        }
        Test.stopTest();

        Assert.isFalse(wrongExceptionType,
            'The AUTHORIZATION check must precede the name/phone rule: an unauthorized caller who '
            + 'submits blank input must be told they lack permission, not told how to fill the form');
        Assert.areEqual(NO_PERMISSION_MESSAGE, message, 'user-safe denial message');
        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :wire.Id].Status,
            'Task stays open');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // persona helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A Minimum Access user provisioned EXACTLY as a real Transactions user is: assigned the
     * deployed `DPEG_Transaction_Team` permission set GROUP, which carries `DPEG_Task_Edit`
     * (and therefore, once deployed, the `Transaction_Task_Actions` custom permission) —
     * verified live on usman-dpeg 2026-08-28.
     *
     * ⚠ THE REAL GROUP, NOT A HAND-BUILT SET, DELIBERATELY. A fabricated permission set would
     * only prove the platform enforces a gate (never in doubt). Assigning the real group also
     * asserts that the grant still travels the path production relies on — if someone removes
     * DPEG_Task_Edit from the group, or the custom permission from that set, this reds.
     *
     * ⚠ Group membership ALSO grants Transaction__c edit, which this fixture needs for a
     * non-obvious reason: TaskRollupTrigger fires on every Task update and rolls counters up to
     * the parent Transaction__c. That write is SYSTEM_MODE but `with sharing`, so a persona who
     * cannot reach the parent record would fail there — AFTER passing this gate.
     */
    private static User provisionedPersona(String tag) {
        User u = buildMinimumAccessUser(tag);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            Id groupId = [
                SELECT Id FROM PermissionSetGroup
                WHERE DeveloperName = :TRANSACTION_TEAM_GROUP LIMIT 1
            ].Id;
            Test.calculatePermissionSetGroup(groupId);
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetGroupId = groupId);
        }
        return u;
    }

    /** A Minimum Access user with NO permission sets — the denial persona. */
    private static User barePersona(String tag) {
        User u = buildMinimumAccessUser(tag);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    /**
     * ⚠ `Minimum Access - Salesforce`, NOT `Standard User`. Task is a STANDARD object, and a
     * Standard User profile grants Task CRUD at the PROFILE level — which would silently hand
     * the denial persona the very permission this suite is proving they lack, making every
     * SYSTEM_MODE assertion vacuous. It is also the profile all three real non-admin users in
     * this org are actually on.
     *
     * ⚠ The insert is wrapped in System.runAs by the callers: User is a setup object and these
     * tests also perform Task/Transaction DML, which is MIXED_DML_OPERATION without it.
     */
    private static User buildMinimumAccessUser(String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = :MINIMUM_ACCESS_PROFILE LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Min',
            LastName = 'TxnTask',
            Alias = 'ttask',
            Email = 'min.txntask@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /**
     * An Active Transaction owned by the persona, fan-out Flow suppressed. Ownership matters:
     * TaskRollupTrigger writes counters back to this record on every checklist Task update, and
     * that write is SYSTEM_MODE but sharing-enforced. Production matches — all 82 checklist
     * Tasks and the one Transaction in usman-dpeg are owned by the user completing them.
     */
    private static Transaction__c suppressedTransactionOwnedBy(Id ownerId) {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        t.OwnerId = ownerId;
        insert t;
        return t;
    }

    /** A checklist Task on `t`, owned by the persona so record access is satisfied by ownership. */
    private static Task checklistTaskOwnedBy(Transaction__c t, Id ownerId, String subject, String groupName) {
        Task tsk = new Task(
            Transaction_Deal__c = t.Id,
            Subject = subject,
            Task_Group__c = groupName,
            Task_Sequence__c = 1,
            Status = 'Not Started',
            OwnerId = ownerId
        );
        insert tsk;
        return tsk;
    }
}
