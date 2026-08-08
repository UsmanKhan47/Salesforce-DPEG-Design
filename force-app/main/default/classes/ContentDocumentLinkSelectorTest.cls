/**
 * Tests for ContentDocumentLinkSelector (P4, Module B2 — Property Management).
 *
 * Covers the single relocated query:
 *   - selectByLinkedEntityId : field population (ContentDocumentId + LinkedEntityId),
 *     the null-input guard, the no-links empty result, and a bulk read against one
 *     entity.
 *
 * CONTENT FIXTURES: the factory has no ContentDocumentLink helper, so these build
 * minimal valid fixtures directly — a ContentNote (whose Id IS its ContentDocument
 * Id) linked to a standard Account. This mirrors exactly what
 * BrokerAssignmentController.addNote inserts. All DML is non-setup, so no
 * MIXED_DML/runAs isolation is needed; ContentDocumentLink is a content/system
 * object queried under USER_MODE for file-sharing enforcement, so no Standard-User
 * FLS proof applies (design §3 #21).
 *
 * ═══ 🔴 BULK VOLUME IS 20, NOT 251 — DELIBERATE. DO NOT "RESTORE" IT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 for TRIGGERS, BATCH JOBS, SERVICES
 * THAT DO DML, and QUEUEABLES, because 251 forces a SECOND trigger batch chunk and
 * so exposes SOQL/DML-in-a-loop bugs that 200 hides. **None of that applies to a
 * selector READ**: `selectByLinkedEntityId` is one `WHERE LinkedEntityId = :id`
 * statement with no loop and no chunking, so its behaviour at 251 rows is identical
 * to its behaviour at 20 — the larger number proves nothing extra. See
 * `.claude/rules/content-publication-rule.md`.
 *
 * It is also NOT FREE: every `ContentNote` insert consumes a **ContentPublication**,
 * capped org-wide at **2,500 per rolling 24 hours**, and — unlike the ContentNote
 * ROW itself — that consumption survives test rollback. At 251 rows this one method
 * was, alongside the sibling `ContentNoteSelectorTest` bulk test, the single largest
 * consumer in the whole suite. Reduced to 20 on 2026-08-06 (ContentPublication
 * quota incident — see `EmailToLeadHandler` class header for the production outage
 * this traces back to).
 *
 * @see agent-output/p4-selector-design.md (§3 #21, §5)
 */
@isTest
private class ContentDocumentLinkSelectorTest {

    /**
     * Bulk-read volume. See the BULK VOLUME note in the class header before changing
     * this: a selector read has no loop and no chunking, so 251 proves nothing 20
     * does not, and every ContentNote insert burns one of the org's 2,500 daily
     * ContentPublications.
     */
    private static final Integer BULK_ROWS = 20;

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

    /**
     * 🔴 DELIBERATELY 20 ROWS, NOT 251 — DO NOT "RESTORE" THE 251. See the BULK
     * VOLUME note in the class header for the full reasoning; the short version is
     * that 251 proves nothing here that 20 does not, and it is not free in this org.
     */
    @isTest
    static void selectByLinkedEntityId_bulk_readsAll() {
        Account entity = TestDataFactory.createAccount(true);

        List<ContentNote> notes = new List<ContentNote>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
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

        Assert.areEqual(BULK_ROWS, found.size(), 'All ' + BULK_ROWS + ' links to the entity are returned at bulk volume');
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
