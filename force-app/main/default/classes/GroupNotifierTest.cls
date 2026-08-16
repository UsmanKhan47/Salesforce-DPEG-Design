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

    // ═══════════════════════════════════════════════════════════════════════
    // notifyWithOutcome — added 2026-08-14 for CallForOffersAlertBatch
    //
    // The existing `notify` swallows every failure by design, which is right for its original
    // callers and WRONG for a caller that writes an idempotency marker after sending: without an
    // outcome it must either lose alerts silently (stamp anyway) or repeat them daily (never
    // stamp). These tests pin the contract the new caller depends on.
    // ═══════════════════════════════════════════════════════════════════════

    @IsTest
    static void notifyWithOutcome_reportsTruePerSuccessfulSend() {
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
        for (Integer i = 0; i < 3; i++) {
            GroupNotifier.Request r = new GroupNotifier.Request();
            r.recipientGroup = GROUP_NAME;
            r.title = 'Title ' + i;
            r.body = 'Body ' + i;
            r.targetRecordId = l.Id;
            requests.add(r);
        }

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);
        Test.stopTest();

        System.Assert.areEqual(3, outcomes.size(), 'One outcome per request');
        for (Integer i = 0; i < outcomes.size(); i++) {
            System.Assert.isTrue(outcomes[i], 'Request ' + i + ' was sent');
        }
        System.Assert.areEqual(3, GroupNotifier.sentCount, 'and all three actually went out');
    }

    @IsTest
    static void notifyWithOutcome_reportsFalseForAGroupThatResolvesToNoRecipients() {
        // 🔴 THE BRANCH THE ALERT BATCH DEPENDS ON. `notify` swallows this and returns void, so a
        // caller could not tell it had happened. Here it must come back as an explicit false, or the
        // batch stamps a marker for an alert nobody received and the alert is lost for ever.
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = 'No_Such_Group_' + Math.abs(Crypto.getRandomInteger());
        r.title = 'Title';
        r.body = 'Body';
        r.targetRecordId = l.Id;

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(new List<GroupNotifier.Request>{ r });
        Test.stopTest();

        System.Assert.areEqual(1, outcomes.size(), 'The list stays index-aligned with the input');
        System.Assert.isFalse(outcomes[0], 'An unresolvable group must report false, not silence');
        System.Assert.areEqual(0, GroupNotifier.sentCount, 'and nothing was sent');
    }

    @IsTest
    static void notifyWithOutcome_staysIndexAlignedAcrossASkippedRequest() {
        // A short list would be the dangerous failure: a caller zipping outcomes against its own
        // pending-stamp list would stamp the WRONG records. The list is pre-filled with false, so a
        // skipped or malformed request occupies its own slot.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request good = new GroupNotifier.Request();
        good.recipientGroup = GROUP_NAME;
        good.title = 'Title';
        good.body = 'Body';
        good.targetRecordId = l.Id;

        GroupNotifier.Request noTarget = new GroupNotifier.Request();
        noTarget.recipientGroup = GROUP_NAME;
        noTarget.title = 'Title';
        noTarget.body = 'Body';
        // targetRecordId deliberately left null.

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(
            new List<GroupNotifier.Request>{ noTarget, good, null }
        );
        Test.stopTest();

        System.Assert.areEqual(3, outcomes.size(),
            'Every input request gets a slot, including the ones that were skipped');
        System.Assert.isFalse(outcomes[0], 'A request with no target record is false');
        System.Assert.isTrue(outcomes[1], 'The valid request in the middle still succeeds');
        System.Assert.isFalse(outcomes[2], 'A null request is false rather than shifting the list');
    }

    @IsTest
    static void notifyWithOutcome_nullAndEmptyInputReturnEmptyNotNull() {
        Test.startTest();
        System.Assert.areEqual(0, GroupNotifier.notifyWithOutcome(null).size(), 'Null input');
        System.Assert.areEqual(0,
            GroupNotifier.notifyWithOutcome(new List<GroupNotifier.Request>()).size(), 'Empty input');
        Test.stopTest();
    }

    @IsTest
    static void notify_stillReturnsVoidAndStillSends_soFlowIsUnaffected() {
        // `notify` now delegates to `notifyWithOutcome` and discards the answer. The @InvocableMethod
        // signature is untouched; this pins that the delegation did not change its behaviour.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = GROUP_NAME;
        r.title = 'Title';
        r.body = 'Body';
        r.targetRecordId = l.Id;

        Test.startTest();
        GroupNotifier.notify(new List<GroupNotifier.Request>{ r });
        Test.stopTest();

        System.Assert.areEqual(1, GroupNotifier.sentCount,
            'The Flow entry point still sends exactly as it did before the refactor');
    }
}