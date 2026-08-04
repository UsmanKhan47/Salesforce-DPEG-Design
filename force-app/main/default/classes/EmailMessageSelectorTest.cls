/**
 * Tests for EmailMessageSelector — the EAC Thread Guard read of captured emails.
 *
 * The guard behaviour that consumes these rows is covered by
 * EmailThreadGuardServiceTest; this class proves the selector contract that class
 * depends on, in particular that ActivityId is returned. A selector that silently
 * stopped returning ActivityId would not fail any behavioural test with the test seam
 * engaged — it would simply stop deleting companion Tasks in production.
 *
 * `Incoming` (added 2026-08-04 for guard 5 / timeline dedup) gets the same treatment:
 * it is the FIRST term of `EmailThreadGuardService.isExactPipelineDuplicate`, and a
 * selector that silently stopped returning it would make every capture read as
 * direction-null, which the guard treats as "not inbound" — the dedup rule would
 * stop deleting anything, silently, rather than fail loudly.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 */
@isTest
private class EmailMessageSelectorTest {

    @isTest
    static void selectByIds_returnsIdentifiersAndTheCompanionActivityId() {
        EmailMessage capture = new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = 'sel-root@example.invalid',
            MessageIdentifier = 'sel-msg-1@example.invalid',
            FromAddress = 'junior@example.invalid',
            ToAddress = 'broker@example.invalid'
        );
        insert capture;
        // ⚠ THE RELATION IS WHAT CREATES THE COMPANION TASK. Measured in `usman-dpeg`
        // 2026-08-02: a capture associated with NO record has a NULL ActivityId — Enhanced
        // Email stamps it only when the message is related to something, because the
        // companion Task IS the activity on that record. Without this the ActivityId
        // assertion below fails, and it fails for a reason that has nothing to do with the
        // selector under test.
        Lead broker = TestDataFactory.createLead(true);
        insert new EmailMessageRelation(
            EmailMessageId = capture.Id, RelationId = broker.Id, RelationType = 'ToAddress');

        Test.startTest();
        List<EmailMessage> rows = EmailMessageSelector.selectByIds(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The captured email should be returned');
        Assert.areEqual('sel-root@example.invalid', rows[0].ThreadIdentifier,
            'ThreadIdentifier is the primary match key against Task.Thread_Key__c');
        Assert.areEqual('sel-msg-1@example.invalid', rows[0].MessageIdentifier,
            'MessageIdentifier is the secondary match key against Task.Inbound_Message_Id__c');
        Assert.isNotNull(rows[0].ActivityId,
            'ActivityId must be selected AND populated: it is the only handle the guard has on a '
            + 'companion Task. A null here means Enhanced Email is disabled in this org, which '
            + 'disarms the EAC fingerprint entirely');
    }

    /**
     * Pins the field added 2026-08-04: `Incoming` must be selected AND its value
     * returned faithfully. It is the first term of the guard's timeline-dedup
     * predicate — a selector that silently dropped it would make the predicate read
     * every capture as "not inbound" and the dedup rule would stop deleting anything,
     * silently, rather than fail loudly.
     */
    @isTest
    static void selectByIds_returnsIncoming() {
        EmailMessage capture = new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = true,
            ThreadIdentifier = 'sel-incoming-root@example.invalid',
            MessageIdentifier = 'sel-incoming-msg@example.invalid',
            FromAddress = 'broker@example.invalid',
            ToAddress = 'coordinator@example.invalid'
        );
        insert capture;

        Test.startTest();
        List<EmailMessage> rows = EmailMessageSelector.selectByIds(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The captured email should be returned');
        Assert.isTrue(rows[0].Incoming,
            'Incoming must be selected AND populated: it is the first term of the guard\'s '
            + 'timeline-dedup predicate (isExactPipelineDuplicate)');
    }

    @isTest
    static void selectByIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<EmailMessage> forNull = EmailMessageSelector.selectByIds(null);
        List<EmailMessage> forEmpty = EmailMessageSelector.selectByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Id set short-circuits to empty without querying');
        Assert.areEqual(0, forEmpty.size(), 'An empty Id set short-circuits to empty without querying');
    }
}
