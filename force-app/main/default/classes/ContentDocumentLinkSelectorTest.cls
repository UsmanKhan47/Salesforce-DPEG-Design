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

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // selectByLinkedEntityIds — the MANY-parent read, added 2026-09-02 for ChecklistCaptureService.
    //
    // 🔴 THIS METHOD HAD ZERO COVERAGE UNTIL NOW, AND THAT IS WHY IT MATTERS. The class carried
    // tests for `selectByLinkedEntityId` (singular) only, so a payload containing the selector
    // without this block would have sat at roughly 50% — a silent, zero-error coverage rollback,
    // which is a shape this org has produced repeatedly.
    //
    // 🔴 CONTENT COST: 3 `ContentNote` rows for this whole block, spent one fact each —
    //   2 — `spansEveryParentInOneQuery`: one document linked to TWO entities proves the read spans
    //       parents; a second document on the second entity proves the caller can still tell them
    //       apart. One row cannot establish either.
    //   1 — `unlinkedParentIsAbsentNotZero`: a single linked parent beside an unlinked one.
    //   0 — `nullAndEmptyShortCircuitWithoutQuerying`.
    // A selector read behaves identically at 3 rows and at 251, and
    // `.claude/rules/content-publication-rule.md` caps a read at 20 — so volume here would buy
    // nothing against a real, shared, non-refundable cost. ⚠ Count the `insertNoteLinkedTo` calls
    // before changing this figure; a wrong number in a QUOTA comment is the one that must not rot.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByLinkedEntityIds_spansEveryParentInOneQuery() {
        // 🔴 THE WHOLE REASON THE METHOD EXISTS. `ChecklistCaptureService` asks "does every C7/G6
        // item in this completion batch have a document on file?" and must answer it in ONE query
        // however many items the batch carries. A per-parent loop would still return the right
        // rows, and only the query count would notice.
        Account first = TestDataFactory.createAccount(true);
        Account second = TestDataFactory.createAccount(true);
        ContentNote shared = insertNoteLinkedTo(first.Id, 'Shared document');
        insert new ContentDocumentLink(
            ContentDocumentId = shared.Id, LinkedEntityId = second.Id,
            ShareType = 'V', Visibility = 'AllUsers');
        ContentNote secondOnly = insertNoteLinkedTo(second.Id, 'Second document');

        Test.startTest();
        Integer before = Limits.getQueries();
        List<ContentDocumentLink> links = ContentDocumentLinkSelector.selectByLinkedEntityIds(
            new Set<Id>{ first.Id, second.Id });
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(1, spent, 'ONE query for both parents, never one per parent');
        Assert.areEqual(3, links.size(), 'Both parents links come back in a single read');

        // Grouped by parent, which is exactly what the caller does with the result.
        Map<Id, Set<Id>> documentsByEntity = new Map<Id, Set<Id>>();
        for (ContentDocumentLink link : links) {
            if (!documentsByEntity.containsKey(link.LinkedEntityId)) {
                documentsByEntity.put(link.LinkedEntityId, new Set<Id>());
            }
            documentsByEntity.get(link.LinkedEntityId).add(link.ContentDocumentId);
        }
        Assert.areEqual(new Set<Id>{ shared.Id }, documentsByEntity.get(first.Id),
            'The first entity holds only the shared document');
        Assert.areEqual(new Set<Id>{ shared.Id, secondOnly.Id }, documentsByEntity.get(second.Id),
            'and the second holds both — so per-parent counts cannot cross-contaminate');
    }

    @isTest
    static void selectByLinkedEntityIds_unlinkedParentIsAbsentNotZero() {
        // 🔴 THE CONTRACT `ChecklistCaptureService.documentCountsByItem` RELIES ON. An unlinked
        // parent must be ABSENT from the result, so a missing key reads as "no document on file"
        // and the C7/G6 guard refuses. A row carrying a zero count would be a different contract.
        Account linked = TestDataFactory.createAccount(true);
        Account bare = TestDataFactory.createAccount(true);
        insertNoteLinkedTo(linked.Id, 'Only document');

        Test.startTest();
        List<ContentDocumentLink> links = ContentDocumentLinkSelector.selectByLinkedEntityIds(
            new Set<Id>{ linked.Id, bare.Id });
        Test.stopTest();

        Assert.areEqual(1, links.size(), 'Only the linked parent contributes a row');
        Assert.areEqual(linked.Id, links[0].LinkedEntityId, 'and it is the linked one');
    }

    @isTest
    static void selectByLinkedEntityIds_nullAndEmptyShortCircuitWithoutQuerying() {
        // `ChecklistCaptureService` calls this on EVERY completion batch, and most batches contain
        // no document item at all — so the empty case must not spend a query.
        Test.startTest();
        Integer before = Limits.getQueries();
        List<ContentDocumentLink> fromNull =
            ContentDocumentLinkSelector.selectByLinkedEntityIds(null);
        List<ContentDocumentLink> fromEmpty =
            ContentDocumentLinkSelector.selectByLinkedEntityIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'Null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'Empty input returns an empty list');
        Assert.areEqual(0, spent, 'and neither spends a query');
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
