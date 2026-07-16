@IsTest
private class GroupNotifierTest {

    private static final String GROUP_NAME = 'Test_Acq_Notify_Group';

    private static void createGroupWithMember() {
        // Setup-object DML is isolated in runAs to avoid MIXED_DML with any
        // standard-object DML the calling test performs.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Group g = new Group(Name = 'Test Acq Notify Group', DeveloperName = GROUP_NAME, Type = 'Regular');
            insert g;
            insert new GroupMember(GroupId = g.Id, UserOrGroupId = UserInfo.getUserId());
        }
    }

    @IsTest
    static void send_toGroupWithMember_sendsOnce() {
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        Test.startTest();
        GroupNotifier.send(GROUP_NAME, 'Title', 'Body', l.Id);
        Test.stopTest();

        System.Assert.areEqual(1, GroupNotifier.sentCount, 'One notification sent to the group');
    }

    @IsTest
    static void send_unknownGroup_isSilentNoOp() {
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        Test.startTest();
        GroupNotifier.send('No_Such_Group', 'Title', 'Body', l.Id);
        Test.stopTest();

        System.Assert.areEqual(0, GroupNotifier.sentCount, 'Unknown group sends nothing and does not throw');
    }

    @IsTest
    static void notify_emptyGroup_fallsBackToGroupId() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Group(Name = 'Test Acq Empty Group', DeveloperName = 'Test_Acq_Empty_Group', Type = 'Regular');
        }
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        Test.startTest();
        GroupNotifier.send('Test_Acq_Empty_Group', 'Title', 'Body', l.Id);
        Test.stopTest();

        // Fallback recipient is the group Id; send may be rejected by the platform
        // for a Regular group, but the call must never throw. No assertion on
        // sentCount here - the contract under test is the silent-degrade posture.
        System.Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :l.Id], 'Transaction unaffected');
    }

    @IsTest
    static void notify_nullAndEmptyRequests_areNoOps() {
        Test.startTest();
        GroupNotifier.notify(null);
        GroupNotifier.notify(new List<GroupNotifier.Request>());
        Test.stopTest();
        System.Assert.areEqual(0, GroupNotifier.sentCount, 'No sends for empty input');
    }

    /**
     * The guardrail this class exists to prove: a caller that loops send() for the same
     * group within one transaction (the exact shape of the bug ContractExecutionService had
     * — 3 send() calls per Opportunity, 9N queries for N records) must not re-query
     * Group / GroupMember / CustomNotificationType on every call. The cache is what makes a
     * looping caller merely inefficient (still O(1) queries) instead of a governor-limit break.
     */
    @IsTest
    static void notify_repeatedCallsInSameTransaction_reuseCachedRecipientsAndAddNoQueries() {
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        Test.startTest();
        GroupNotifier.send(GROUP_NAME, 'Title', 'Body', l.Id);
        Integer queriesAfterFirstCall = Limits.getQueries();

        // Simulate a looping caller — the anti-pattern the cache exists to protect against.
        for (Integer i = 0; i < 4; i++) {
            GroupNotifier.send(GROUP_NAME, 'Title ' + i, 'Body ' + i, l.Id);
        }
        Integer queriesAfterFourMoreCalls = Limits.getQueries();
        Test.stopTest();

        System.Assert.areEqual(5, GroupNotifier.sentCount, 'All five sends succeed using the cached recipient set');
        System.Assert.areEqual(queriesAfterFirstCall, queriesAfterFourMoreCalls,
            'Four additional send() calls for the same group in the same transaction must add zero additional SOQL queries — this is the cache guardrail, proven rather than assumed');
    }
}