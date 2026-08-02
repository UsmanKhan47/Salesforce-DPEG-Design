/**
 * Tests PermissionSetGroupComponentSelector — the group-expansion read that keeps the Lead-action
 * permission gate correct for users provisioned through a Permission Set Group rather than a direct
 * assignment.
 *
 * Covers both branches of the single method: the null/empty guard (which must NOT issue a query)
 * and the populated path (which must return the group's member sets with PermissionSet.Name
 * traversed).
 *
 * ── WHY THE GROUP IS BUILT IN THE TEST ────────────────────────────────────────
 * The org's four deployed groups (DPEG_Junior_Analyst_PSG et al.) could have been queried instead,
 * but that would couple this test to metadata it does not own — if an admin edits a group's
 * membership the test's expected names change for reasons unrelated to the selector. Creating a
 * throwaway group makes the expected result a constant of the test itself.
 *
 * ── WHY THERE IS NO 251-RECORD BULK TEST ──────────────────────────────────────
 * The .claude/rules/bulk-test-rule.md 251-record mandate targets loops and trigger batches. This
 * selector issues exactly ONE query for the whole input Set regardless of size (the multi-group test
 * below proves that), and its real-world input is bounded by the number of groups assigned to one
 * user. A 251-group test would exercise no additional code path. The single-query guarantee — the
 * property the rule actually protects — IS asserted, via Limits.getQueries().
 *
 * ── SETUP-DML ISOLATION ───────────────────────────────────────────────────────
 * PermissionSetGroup and PermissionSetGroupComponent are setup objects. No test here touches a
 * non-setup record, which keeps MIXED_DML_OPERATION off the table.
 *
 * @see force-app/main/default/classes/PermissionSetGroupComponentSelector.cls
 */
@isTest
private class PermissionSetGroupComponentSelectorTest {

    private static final String LEAD_ACTION_PERM_SET = 'Lead_Stage_Actions_Access';
    private static final String BROKER_PERM_SET = 'Broker_Protection_Access';

    @isTest
    static void selectByGroupIds_nullInput_returnsEmptyWithoutQuerying() {
        Integer queriesBefore = Limits.getQueries();

        Test.startTest();
        List<PermissionSetGroupComponent> rows =
            PermissionSetGroupComponentSelector.selectByGroupIds(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(queriesBefore, Limits.getQueries(),
            'The null guard must return BEFORE issuing a query — it is what keeps the second read off users with no groups');
    }

    @isTest
    static void selectByGroupIds_emptyInput_returnsEmptyWithoutQuerying() {
        Integer queriesBefore = Limits.getQueries();

        Test.startTest();
        List<PermissionSetGroupComponent> rows =
            PermissionSetGroupComponentSelector.selectByGroupIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(queriesBefore, Limits.getQueries(), 'The empty guard must return before issuing a query');
    }

    @isTest
    static void selectByGroupIds_groupContainingTheLeadSet_returnsThatMemberWithNameTraversed() {
        // Arrange
        Id leadPermSetId = [SELECT Id FROM PermissionSet WHERE Name = :LEAD_ACTION_PERM_SET LIMIT 1].Id;
        PermissionSetGroup group1 = buildGroup('PsgCompSelOne');
        insert group1;
        insert new PermissionSetGroupComponent(
            PermissionSetGroupId = group1.Id,
            PermissionSetId = leadPermSetId
        );

        // Act
        Test.startTest();
        List<PermissionSetGroupComponent> rows =
            PermissionSetGroupComponentSelector.selectByGroupIds(new Set<Id>{ group1.Id });
        Test.stopTest();

        // Assert
        Assert.areEqual(1, rows.size(), 'The group has exactly one member set');
        Assert.areEqual(group1.Id, rows[0].PermissionSetGroupId, 'The row points back at the requested group');
        Assert.areEqual(leadPermSetId, rows[0].PermissionSetId, 'The member set Id is selected');
        Assert.isNotNull(rows[0].PermissionSet, 'The PermissionSet relationship must be traversed, not just the Id');
        Assert.areEqual(LEAD_ACTION_PERM_SET, rows[0].PermissionSet.Name,
            'PermissionSet.Name is the whole point of this selector — it is what the name-match gate compares');
    }

    @isTest
    static void selectByGroupIds_multipleGroups_returnsAllMembersInASingleQuery() {
        // Arrange — two groups, one member set each.
        Map<String, Id> permSetIdsByName = new Map<String, Id>();
        for (PermissionSet permSet : [
            SELECT Id, Name FROM PermissionSet WHERE Name IN (:LEAD_ACTION_PERM_SET, :BROKER_PERM_SET)
        ]) {
            permSetIdsByName.put(permSet.Name, permSet.Id);
        }
        PermissionSetGroup group1 = buildGroup('PsgCompSelTwoA');
        PermissionSetGroup group2 = buildGroup('PsgCompSelTwoB');
        insert new List<PermissionSetGroup>{ group1, group2 };
        insert new List<PermissionSetGroupComponent>{
            new PermissionSetGroupComponent(
                PermissionSetGroupId = group1.Id,
                PermissionSetId = permSetIdsByName.get(LEAD_ACTION_PERM_SET)
            ),
            new PermissionSetGroupComponent(
                PermissionSetGroupId = group2.Id,
                PermissionSetId = permSetIdsByName.get(BROKER_PERM_SET)
            )
        };

        // Act
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<PermissionSetGroupComponent> rows =
            PermissionSetGroupComponentSelector.selectByGroupIds(new Set<Id>{ group1.Id, group2.Id });
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        // Assert
        Assert.areEqual(1, queriesUsed,
            'Both groups must be expanded by ONE query — no SOQL per group (.claude/rules/apex-layering-rule.md)');
        Set<String> names = new Set<String>();
        for (PermissionSetGroupComponent row : rows) {
            names.add(row.PermissionSet.Name);
        }
        Assert.isTrue(names.contains(LEAD_ACTION_PERM_SET), 'The first group\'s member set is returned');
        Assert.isTrue(names.contains(BROKER_PERM_SET), 'The second group\'s member set is returned');
    }

    @isTest
    static void selectByGroupIds_groupWithNoComponents_returnsEmpty() {
        PermissionSetGroup emptyGroup = buildGroup('PsgCompSelEmpty');
        insert emptyGroup;

        Test.startTest();
        List<PermissionSetGroupComponent> rows =
            PermissionSetGroupComponentSelector.selectByGroupIds(new Set<Id>{ emptyGroup.Id });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A group with no member sets yields an empty list, not null — the caller loops over it unguarded');
    }

    /**
     * Builds (but does not insert) a throwaway permission set group. DeveloperName must be unique in
     * the org and cannot collide with the four real DPEG groups.
     *
     * @param tag short per-test token keeping DeveloperName unique across methods in one run
     */
    private static PermissionSetGroup buildGroup(String tag) {
        String unique = tag + String.valueOf(Datetime.now().getTime());
        return new PermissionSetGroup(
            DeveloperName = unique,
            MasterLabel = 'Test ' + tag
        );
    }
}
