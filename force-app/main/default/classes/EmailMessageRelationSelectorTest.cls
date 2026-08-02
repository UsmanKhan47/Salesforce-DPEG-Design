/**
 * Tests for EmailMessageRelationSelector — the EAC Thread Guard read of "which Leads
 * did this captured email land on?".
 *
 * ⚠ THE POINT OF THIS CLASS CHANGED WITH REVIEW W1 (2026-08-02). This selector used to
 * filter `RelationObjectType = 'Lead'` in SOQL, and these tests pinned that filter.
 * They now pin the OPPOSITE contract: every relation type must come back, typed. The
 * reason is that the guard's remedy (deleting the EmailMessage) is org-wide even
 * though its trigger condition is Lead-scoped — so the service must be able to SEE a
 * Contact relation in order to protect it. Lead scoping moved into explicit Apex in
 * EmailThreadGuardService; the behavioural proof of the protection itself lives in
 * EmailThreadGuardServiceTest.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 */
@isTest
private class EmailMessageRelationSelectorTest {

    /**
     * W1: this selector must return EVERY relation type, not just Leads. The guard
     * cannot protect a Contact's timeline from a capture it cannot see the Contact
     * relation for, and the Lead scoping now happens explicitly in
     * EmailThreadGuardService. If this method is ever re-narrowed to
     * `RelationObjectType = 'Lead'`, W1 silently regresses.
     */
    @isTest
    static void selectByMessageIds_returnsEveryRelationTypeWithItsObjectType() {
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = buildCapture();
        insert capture;
        // The shape EAC produces: the same message matched to a Lead AND to a User.
        //
        // ⚠ THE USER RELATION MUST BE 'CcAddress'. Measured in `usman-dpeg` 2026-08-02:
        // with FromAddress populated the platform auto-creates a FromAddress-typed relation
        // for the sender, and a User relation on 'ToAddress' OR 'FromAddress' then throws
        // `LIMIT_EXCEEDED, An email can't have more than 1 sender`. 'CcAddress' inserts
        // cleanly and still derives RelationObjectType = 'User', which is the only field
        // the guard reads. Lead/Contact relations are unaffected and use 'ToAddress'.
        insert new List<EmailMessageRelation>{
            new EmailMessageRelation(EmailMessageId = capture.Id, RelationId = broker.Id,
                                     RelationType = 'ToAddress'),
            new EmailMessageRelation(EmailMessageId = capture.Id, RelationId = UserInfo.getUserId(),
                                     RelationType = 'CcAddress')
        };

        Test.startTest();
        List<EmailMessageRelation> rows =
            EmailMessageRelationSelector.selectByMessageIds(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'BOTH relations must be returned. Filtering to Lead in SOQL is what allowed a '
            + 'Contact-and-Lead capture to be deleted off the Contact (W1). The count is 2, not 3, '
            + 'because the platform auto-creates a third sender relation whose RelationId is NULL '
            + '(RelationObjectType null) and the selector RelationId != null filter excludes it — '
            + 'correctly: an unmatched address is evidence of no record at all');
        Map<String, Id> relationIdByObjectType = new Map<String, Id>();
        for (EmailMessageRelation row : rows) {
            Assert.areEqual(capture.Id, row.EmailMessageId, 'Keyed back to the message it belongs to');
            relationIdByObjectType.put(row.RelationObjectType, row.RelationId);
        }
        Assert.areEqual(broker.Id, relationIdByObjectType.get('Lead'),
            'The Lead relation is returned and typed, so the service can scope on it');
        Assert.areEqual(UserInfo.getUserId(), relationIdByObjectType.get('User'),
            'The User relation is returned and typed, so the service can EXCLUDE it from the '
            + '"lives elsewhere" test rather than guessing');
    }

    @isTest
    static void selectByMessageIds_messageWithNoRelations_returnsEmpty() {
        EmailMessage capture = buildCapture();
        insert capture;

        Test.startTest();
        List<EmailMessageRelation> rows =
            EmailMessageRelationSelector.selectByMessageIds(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A capture that landed on nothing returns empty — the guard reads this as "not my '
            + 'concern" and leaves the email alone');
    }

    @isTest
    static void selectByMessageIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<EmailMessageRelation> forNull =
            EmailMessageRelationSelector.selectByMessageIds(null);
        List<EmailMessageRelation> forEmpty =
            EmailMessageRelationSelector.selectByMessageIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Id set short-circuits to empty without querying');
        Assert.areEqual(0, forEmpty.size(), 'An empty Id set short-circuits to empty without querying');
    }

    /** @return An unsaved EmailMessage in the shape EAC materializes. */
    private static EmailMessage buildCapture() {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = 'rel-root@example.invalid',
            MessageIdentifier = 'rel-msg-1@example.invalid',
            FromAddress = 'junior@example.invalid',
            ToAddress = 'broker@example.invalid'
        );
    }
}
