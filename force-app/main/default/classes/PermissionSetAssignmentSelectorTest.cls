/**
 * Tests PermissionSetAssignmentSelector — the running-user permission-assignment read behind the
 * Lead stage quick actions' permission gate.
 *
 * The selector has one method and no branches, so the tests prove its CONTRACT rather than its
 * control flow:
 *   1. it returns the RUNNING user's rows (and switches when the running user switches),
 *   2. every field the service depends on is actually populated,
 *   3. it never returns another user's assignments.
 *
 * (2) is the assertion that matters most. The service reads PermissionSet.Name,
 * PermissionSet.PermissionsModifyAllData and PermissionSetGroupId off these rows; dropping any of
 * them from the SELECT would compile fine and silently make the permission gate wrong, so each is
 * asserted explicitly.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * The .claude/rules/bulk-test-rule.md 251-record mandate does not apply: the selector is filtered to
 * a single fixed Id (the running user) and takes no collection parameter, so there is no
 * collection-shaped behavior to bulk-test and no loop that a second batch could expose. This is the
 * per-transaction-singleton shape the rule already exempts. Documented here per the same precedent
 * as LeadConvertActionControllerTest.
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * Every test here does ONLY setup-object DML (User, PermissionSetAssignment). No test creates a
 * non-setup record, which is what keeps MIXED_DML_OPERATION off the table.
 *
 * @see force-app/main/default/classes/PermissionSetAssignmentSelector.cls
 */
@isTest
private class PermissionSetAssignmentSelectorTest {

    private static final String LEAD_ACTION_PERM_SET = 'Lead_Stage_Actions_Access';

    @isTest
    static void selectForCurrentUser_runningUser_returnsRowsWithEveryFieldTheServiceReads() {
        // Act
        Test.startTest();
        List<PermissionSetAssignment> rows = PermissionSetAssignmentSelector.selectForCurrentUser();
        Test.stopTest();

        // Assert — every user is assigned their profile's implicit permission set, so this is never
        // empty for a real running user.
        Assert.isFalse(rows.isEmpty(),
            'Every user holds at least their profile\'s implicit permission set, so the selector must return rows');

        Boolean sawProfileOwnedSet = false;
        for (PermissionSetAssignment row : rows) {
            Assert.isNotNull(row.PermissionSetId, 'PermissionSetId must be selected');
            Assert.isNotNull(row.PermissionSet, 'The PermissionSet relationship must be traversed, not just the Id');
            Assert.isNotNull(row.PermissionSet.Name, 'PermissionSet.Name backs the whole name-match gate');
            // Reading these two is itself the assertion: an unselected field throws
            // SObjectException("SObject row was retrieved via SOQL without querying the requested
            // field"), so a regression that drops either from the SELECT fails here rather than
            // silently mis-answering the permission gate in production.
            Assert.isNotNull(row.PermissionSet.PermissionsModifyAllData,
                'PermissionsModifyAllData must be selected — it backs the admin bypass');
            Assert.isNotNull(row.AssigneeId, 'AssigneeId must be selected so the row is self-describing');
            Object groupIdIsSelected = row.PermissionSetGroupId;   // null for a direct assignment; must not throw
            Assert.areEqual(row.PermissionSetGroupId, groupIdIsSelected,
                'PermissionSetGroupId must be selected — group expansion depends on it');
            if (row.PermissionSet.IsOwnedByProfile == true) {
                sawProfileOwnedSet = true;
            }
        }
        Assert.isTrue(sawProfileOwnedSet,
            'The running user\'s PROFILE surfaces here as an IsOwnedByProfile permission set — that row is what makes the admin bypass work');
    }

    /**
     * The selector is scoped to the RUNNING user, not to a fixed user. Proving it re-scopes under
     * System.runAs is what guarantees one user can never read another's permissions through it.
     */
    @isTest
    static void selectForCurrentUser_underRunAs_returnsThatUsersRowsOnly() {
        // Arrange — a bare Standard User with a single extra permission set assignment.
        User standardUser = buildStandardUser('psaselA');
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;
        insert standardUser;
        insert new PermissionSetAssignment(
            AssigneeId = standardUser.Id,
            PermissionSetId = permSetId
        );

        // Act
        Test.startTest();
        List<PermissionSetAssignment> rows;
        System.runAs(standardUser) {
            rows = PermissionSetAssignmentSelector.selectForCurrentUser();
        }
        Test.stopTest();

        // Assert — the rows belong to the impersonated user, and include the set just granted.
        Assert.isFalse(rows.isEmpty(), 'The impersonated user has assignments of their own');
        Set<String> names = new Set<String>();
        for (PermissionSetAssignment row : rows) {
            Assert.areEqual(standardUser.Id, row.AssigneeId,
                'Every row must belong to the RUNNING user — the selector must never leak another user\'s assignments');
            names.add(row.PermissionSet.Name);
        }
        Assert.isTrue(names.contains(LEAD_ACTION_PERM_SET),
            'The permission set assigned in Arrange must come back for the user it was assigned to');
    }

    /**
     * The negative half of the scoping guarantee: a set granted to ANOTHER user must not appear in
     * the running user's rows.
     */
    @isTest
    static void selectForCurrentUser_grantToAnotherUser_isNotVisibleToTheRunningUser() {
        // Arrange — user A holds the Lead set; user B holds nothing extra.
        User grantedUser = buildStandardUser('psaselB');
        User bareUser = buildStandardUser('psaselC');
        insert new List<User>{ grantedUser, bareUser };
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = grantedUser.Id, PermissionSetId = permSetId);

        // Act — read as the user who was NOT granted it.
        Test.startTest();
        List<PermissionSetAssignment> rows;
        System.runAs(bareUser) {
            rows = PermissionSetAssignmentSelector.selectForCurrentUser();
        }
        Test.stopTest();

        // Assert
        for (PermissionSetAssignment row : rows) {
            Assert.areNotEqual(LEAD_ACTION_PERM_SET, row.PermissionSet.Name,
                'A grant made to a different user must not appear in the running user\'s assignments');
            Assert.areEqual(bareUser.Id, row.AssigneeId, 'Only the running user\'s rows are returned');
        }
    }

    /**
     * Builds (but does not insert) a bare Standard User. Mirrors the repo's existing helper in
     * ContactSelectorTest / OpportunitySelectorTest.
     *
     * @param tag short per-test token keeping Username unique across methods in one run
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime()) + String.valueOf(Crypto.getRandomInteger()).right(4);
        return new User(
            FirstName = 'Std',
            LastName = 'PsaSel',
            Alias = 'psasel',
            Email = 'std.psasel@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
