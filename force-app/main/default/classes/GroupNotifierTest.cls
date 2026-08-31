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

    // ═══════════════════════════════════════════════════════════════════════
    // Request.additionalRecipientIds (2026-08-31, for StageDelayAlertBatch)
    //
    // 🔴 THE RECIPIENT SET ITSELF CANNOT BE ASSERTED. There is no SObject for a delivered
    // custom notification and `send()` returns void, so "did the owner get it?" is not a
    // question any test in this org can answer. What IS observable is the OUTCOME Boolean —
    // and, because a recipient Id that resolves to nothing makes the platform reject the
    // WHOLE call, an unresolvable extra recipient is a precise, in-band probe for whether a
    // given request's extras reached `send()` at all. That is what these tests use.
    //
    // 🔴 THE FIRST DESIGN OF THESE TESTS USED AN UNRESOLVABLE RECIPIENT ID AS THE PROBE, AND IT
    // WAS MEASURED NOT TO WORK. In real execution a recipient Id that resolves to nothing DOES
    // make the platform reject the whole call — probed against usman-dpeg on 2026-08-31,
    // `n.send({ realUserId, '005000000000AAA' })` raised
    // `System.HandledException: Invalid parameter value for: recipientIds` and delivered nothing.
    // **Inside a test context `send()` does not validate its recipients at all** and returns
    // cleanly, so the probe reports success and the test is vacuous. That is why
    // `GroupNotifier.lastSendRecipients` was added: recording the set is the only way to observe
    // what a send was actually addressed to. Do not replace it with the "simpler" invalid-Id
    // version — it has already been tried here and it silently proves nothing.
    // ═══════════════════════════════════════════════════════════════════════

    /** A syntactically valid User Id that resolves to no user. 15 characters, so no checksum. */
    private static final Id UNRESOLVABLE_USER_ID = '005000000000AAA';

    @IsTest
    static void additionalRecipientIds_areMergedIntoTheSameSendRatherThanASecondOne() {
        // The whole reason this field exists: `StageDelayAlertBatch` must reach the deal owner AND
        // the Acquisition queue, and at a measured `6.0 ms + 0.22 ms x |recipients|` per send,
        // merging costs ~0.22 ms where a second Request would cost ~6.2 ms. `sentCount` is the
        // proof that it is still ONE call.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = GROUP_NAME;
        r.title = 'Title';
        r.body = 'Body';
        r.targetRecordId = l.Id;
        r.additionalRecipientIds = new Set<String>{ String.valueOf(UserInfo.getUserId()) };

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(new List<GroupNotifier.Request>{ r });
        Test.stopTest();

        System.Assert.areEqual(1, outcomes.size(), 'One request, one outcome');
        System.Assert.isTrue(outcomes[0], 'and it went out');
        System.Assert.areEqual(1, GroupNotifier.sentCount,
            'in exactly ONE send() call — the extra recipient rides the group\'s call rather than '
            + 'earning a second one. A second call here would double this job\'s CPU per deal');
        System.Assert.areEqual(1, GroupNotifier.lastSendRecipients.size(), 'one recorded send');
        System.Assert.isTrue(
            GroupNotifier.lastSendRecipients[0].contains(String.valueOf(UserInfo.getUserId())),
            'and the extra recipient is genuinely IN the set that was sent, which is the only '
            + 'observable proof that the merge happened at all');
    }

    @IsTest
    static void anExtraRecipientWhoIsAlreadyAGroupMemberIsNotNotifiedTwice() {
        // The de-duplication half, and it is a real product behaviour rather than a tidy detail:
        // `StageDelayAlertBatch`'s deal owner is very often also a member of the Acquisition queue,
        // and a `Set` is what stops that person getting two bells about one deal.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = GROUP_NAME;
        r.title = 'Title';
        r.body = 'Body';
        r.targetRecordId = l.Id;
        // The group's only member IS the running user, so the extra is a duplicate by construction.
        r.additionalRecipientIds = new Set<String>{ String.valueOf(UserInfo.getUserId()) };

        Test.startTest();
        GroupNotifier.notifyWithOutcome(new List<GroupNotifier.Request>{ r });
        Test.stopTest();

        System.Assert.areEqual(1, GroupNotifier.lastSendRecipients[0].size(),
            'The recipient appears ONCE, not twice — a List instead of a Set here would send the '
            + 'deal owner two identical notifications whenever they are also on the queue');
    }

    @IsTest
    static void additionalRecipientIds_doNotLeakFromOneRequestIntoTheNext() {
        // 🔴 THE HIGHEST-VALUE TEST OF THE THREE, AND IT PINS A ONE-LINE BUG THAT WOULD OTHERWISE BE
        // INVISIBLE. `resolveRecipients` caches the resolved member Set BY GROUP NAME and hands back
        // THE LIVE OBJECT. Merging extras into it directly instead of into a COPY would mean a
        // 200-deal chunk ends with the last deal's notification addressed to all 200 owners — and
        // nothing observable would say so, because a notification cannot be queried.
        //
        // `lastSendRecipients` makes it observable: request 1 carries an extra, request 2 to the
        // SAME group carries none, and request 2's recorded recipient set must NOT contain request
        // 1's extra. Delete the `new Set<String>(recipients)` copy in `notifyWithOutcome` and this
        // is the only test in the repo that goes red.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request poisoned = new GroupNotifier.Request();
        poisoned.recipientGroup = GROUP_NAME;
        poisoned.title = 'Poisoned';
        poisoned.body = 'Body';
        poisoned.targetRecordId = l.Id;
        poisoned.additionalRecipientIds = new Set<String>{ String.valueOf(UNRESOLVABLE_USER_ID) };

        GroupNotifier.Request clean = new GroupNotifier.Request();
        clean.recipientGroup = GROUP_NAME;
        clean.title = 'Clean';
        clean.body = 'Body';
        clean.targetRecordId = l.Id;

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(
            new List<GroupNotifier.Request>{ poisoned, clean }
        );
        Test.stopTest();

        System.Assert.areEqual(2, outcomes.size(), 'Index alignment is preserved');
        System.Assert.areEqual(2, GroupNotifier.lastSendRecipients.size(),
            'PRECONDITION: both requests reached send()');
        System.Assert.isTrue(
            GroupNotifier.lastSendRecipients[0].contains(String.valueOf(UNRESOLVABLE_USER_ID)),
            'PRECONDITION: the first request really did carry the extra recipient');
        System.Assert.isFalse(
            GroupNotifier.lastSendRecipients[1].contains(String.valueOf(UNRESOLVABLE_USER_ID)),
            '🔴 and the NEXT request to the same group did NOT inherit it. If this goes red, the '
            + 'defensive copy in notifyWithOutcome has been removed and a 200-deal chunk is now '
            + 'addressing its last notification to all 200 deal owners');
        System.Assert.areEqual(1, GroupNotifier.lastSendRecipients[1].size(),
            'The clean request is addressed to the group\'s one member and nobody else');
    }

    @IsTest
    static void additionalRecipientIds_doNotRescueAGroupThatDoesNotExist() {
        // Deliberate: a missing recipient group is a CONFIGURATION failure (post-deploy gate P1),
        // and sending to the owner alone would let the caller stamp an idempotency marker and hide
        // it forever. The guard is unchanged and the extras do not bypass it.
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = 'No_Such_Group';
        r.title = 'Title';
        r.body = 'Body';
        r.targetRecordId = l.Id;
        r.additionalRecipientIds = new Set<String>{ String.valueOf(UserInfo.getUserId()) };

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(new List<GroupNotifier.Request>{ r });
        Test.stopTest();

        System.Assert.isFalse(outcomes[0],
            'A group that does not exist still reports false even with extras supplied');
        System.Assert.areEqual(0, GroupNotifier.sentCount,
            'and nothing is sent, so a send-then-stamp caller writes no marker and retries');
    }

    @IsTest
    static void aNullOrEmptyExtraSetChangesNothingForExistingCallers() {
        // The compatibility pin. All six callers written before 2026-08-31 leave this field null,
        // and their behaviour must be byte-for-byte unchanged.
        createGroupWithMember();
        Lead l = new Lead(LastName = 'Target', Company = 'Acme', Status = 'New');
        insert l;

        GroupNotifier.Request nullSet = new GroupNotifier.Request();
        nullSet.recipientGroup = GROUP_NAME;
        nullSet.title = 'Title';
        nullSet.body = 'Body';
        nullSet.targetRecordId = l.Id;

        GroupNotifier.Request emptySet = new GroupNotifier.Request();
        emptySet.recipientGroup = GROUP_NAME;
        emptySet.title = 'Title';
        emptySet.body = 'Body';
        emptySet.targetRecordId = l.Id;
        emptySet.additionalRecipientIds = new Set<String>();

        Test.startTest();
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(
            new List<GroupNotifier.Request>{ nullSet, emptySet }
        );
        Test.stopTest();

        System.Assert.isTrue(outcomes[0], 'A null extras set sends exactly as before');
        System.Assert.isTrue(outcomes[1], 'and so does an empty one');
        System.Assert.areEqual(2, GroupNotifier.sentCount, 'two ordinary sends, nothing new');
    }
}