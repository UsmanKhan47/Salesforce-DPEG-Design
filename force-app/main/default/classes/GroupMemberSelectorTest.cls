/**
 * Tests for GroupMemberSelector (SYSTEM_MODE setup-object lookup backing
 * GroupNotifier's recipient resolution).
 *
 * TEST-DATA NOTE (guardrail): Group and GroupMember are SETUP objects. Their DML is
 * isolated inside System.runAs(currentUser) — the house pattern (see GroupNotifierTest)
 * that avoids MIXED_DML_OPERATION if a future edit mixes in non-setup DML. Public
 * groups (Type 'Regular') and GroupMember rows are insertable via Apex DML, so the
 * found paths are seeded directly; the current running user is used as the member
 * (a real 005 user Id) so no extra User provisioning is needed.
 *
 * @see force-app/main/default/classes/GroupMemberSelector.cls
 * @see .claude/rules/bulk-test-rule.md (251-record bulk method)
 */
@isTest
private class GroupMemberSelectorTest {

    private static final Integer BULK_N = 251;

    /**
     * Bulk: 251 groups, each with the running user as a member, selected in one
     * call by the full set of group Ids. Proves the selector resolves membership
     * across the 200-record boundary with a single query (no SOQL-in-loop).
     */
    @isTest
    static void selectByGroupIds_bulk_returnsAllMembers() {
        Set<Id> groupIds = new Set<Id>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<Group> groups = new List<Group>();
            for (Integer i = 0; i < BULK_N; i++) {
                groups.add(new Group(
                    Name = 'P4 GM Bulk ' + i,
                    DeveloperName = 'P4_GM_Bulk_' + i,
                    Type = 'Regular'
                ));
            }
            insert groups;

            List<GroupMember> members = new List<GroupMember>();
            for (Group g : groups) {
                groupIds.add(g.Id);
                members.add(new GroupMember(GroupId = g.Id, UserOrGroupId = UserInfo.getUserId()));
            }
            insert members;
        }

        Test.startTest();
        List<GroupMember> result = GroupMemberSelector.selectByGroupIds(groupIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'One member returned per group across all 251 groups');
        Assert.areEqual(UserInfo.getUserId(), result[0].UserOrGroupId, 'UserOrGroupId is populated (the notification recipient)');
        Assert.isTrue(groupIds.contains(result[0].GroupId), 'GroupId is populated and within the queried set');
    }

    /**
     * Filter proof: only members of the queried group Ids are returned; a member of
     * a group NOT in the set is excluded (WHERE GroupId IN).
     */
    @isTest
    static void selectByGroupIds_returnsOnlyMembersOfQueriedGroups() {
        Id queriedGroupId;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Group queried = new Group(Name = 'P4 GM Queried', DeveloperName = 'P4_GM_Queried', Type = 'Regular');
            Group other = new Group(Name = 'P4 GM Other', DeveloperName = 'P4_GM_Other', Type = 'Regular');
            insert new List<Group>{ queried, other };
            queriedGroupId = queried.Id;
            insert new List<GroupMember>{
                new GroupMember(GroupId = queried.Id, UserOrGroupId = UserInfo.getUserId()),
                new GroupMember(GroupId = other.Id, UserOrGroupId = UserInfo.getUserId())
            };
        }

        Test.startTest();
        List<GroupMember> result = GroupMemberSelector.selectByGroupIds(new Set<Id>{ queriedGroupId });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the queried group\'s member is returned');
        Assert.areEqual(queriedGroupId, result[0].GroupId, 'The excluded group\'s member is filtered out');
    }

    @isTest
    static void selectByGroupIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<GroupMember> nullResult = GroupMemberSelector.selectByGroupIds(null);
        List<GroupMember> emptyResult = GroupMemberSelector.selectByGroupIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
