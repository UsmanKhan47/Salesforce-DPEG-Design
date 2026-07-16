/**
 * Tests for ContentDocumentLinkSelector (P4, Module B2 — Property Management).
 *
 * Covers the single relocated query:
 *   - selectByLinkedEntityId : field population (ContentDocumentId + LinkedEntityId),
 *     the null-input guard, the no-links empty result, and a 251-link bulk read
 *     against one entity (bulk-test-rule).
 *
 * CONTENT FIXTURES: the factory has no ContentDocumentLink helper, so these build
 * minimal valid fixtures directly — a ContentNote (whose Id IS its ContentDocument
 * Id) linked to a standard Account. This mirrors exactly what
 * BrokerAssignmentController.addNote inserts. All DML is non-setup, so no
 * MIXED_DML/runAs isolation is needed; ContentDocumentLink is a content/system
 * object queried under USER_MODE for file-sharing enforcement, so no Standard-User
 * FLS proof applies (design §3 #21).
 *
 * @see agent-output/p4-selector-design.md (§3 #21, §5)
 */
@isTest
private class ContentDocumentLinkSelectorTest {

    @isTest
    static void selectByLinkedEntityId_returnsLinksForEntity() {
        Account entity = TestDataFactory.createAccount(true);
        ContentNote note = insertNoteLinkedTo(entity.Id, 'Signage confirmed');

        Test.startTest();
        List<ContentDocumentLink> links = ContentDocumentLinkSelector.selectByLinkedEntityId(entity.Id);
        Test.stopTest();

        Assert.areEqual(1, links.size(), 'The one document linked to the entity is returned');
        Assert.areEqual(note.Id, links[0].ContentDocumentId, 'ContentDocumentId is selected and matches the linked note/document');
        Assert.areEqual(entity.Id, links[0].LinkedEntityId, 'LinkedEntityId is selected and matches the queried entity');
    }

    @isTest
    static void selectByLinkedEntityId_nullInput_returnsEmpty() {
        Test.startTest();
        List<ContentDocumentLink> links = ContentDocumentLinkSelector.selectByLinkedEntityId(null);
        Test.stopTest();

        Assert.areEqual(0, links.size(), 'A null linkedEntityId short-circuits to an empty list, not a query');
    }

    @isTest
    static void selectByLinkedEntityId_noLinks_returnsEmpty() {
        Account entity = TestDataFactory.createAccount(true);

        Test.startTest();
        List<ContentDocumentLink> links = ContentDocumentLinkSelector.selectByLinkedEntityId(entity.Id);
        Test.stopTest();

        Assert.areEqual(0, links.size(), 'An entity with no linked documents returns an empty list');
    }

    @isTest
    static void selectByLinkedEntityId_bulk251_readsAll() {
        Account entity = TestDataFactory.createAccount(true);

        List<ContentNote> notes = new List<ContentNote>();
        for (Integer i = 0; i < 251; i++) {
            notes.add(new ContentNote(Title = 'Note ' + i, Content = Blob.valueOf('body ' + i)));
        }
        insert notes;
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentNote note : notes) {
            links.add(new ContentDocumentLink(
                ContentDocumentId = note.Id, LinkedEntityId = entity.Id,
                ShareType = 'V', Visibility = 'AllUsers'));
        }
        insert links;

        Test.startTest();
        List<ContentDocumentLink> found = ContentDocumentLinkSelector.selectByLinkedEntityId(entity.Id);
        Test.stopTest();

        Assert.areEqual(251, found.size(), 'All 251 links to the entity are returned at bulk volume');
    }

    /**
     * Inserts a ContentNote and links it to the supplied entity, matching
     * BrokerAssignmentController.addNote. Returns the note (its Id == its
     * ContentDocument Id).
     */
    private static ContentNote insertNoteLinkedTo(Id entityId, String title) {
        ContentNote note = new ContentNote(Title = title, Content = Blob.valueOf('<p>' + title + '</p>'));
        insert note;
        insert new ContentDocumentLink(
            ContentDocumentId = note.Id, LinkedEntityId = entityId,
            ShareType = 'V', Visibility = 'AllUsers');
        return note;
    }
}
