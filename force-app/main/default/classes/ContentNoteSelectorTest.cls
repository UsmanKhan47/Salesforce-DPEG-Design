/**
 * Tests for ContentNoteSelector (P4, Module B2 — Property Management).
 *
 * Covers the single relocated query:
 *   - selectByIdsOrderedByCreatedDateDesc : field population (Title selected,
 *     CreatedBy.Name populated, TextPreview accessible), ORDER BY CreatedDate DESC
 *     (proven with Test.setCreatedDate — same-transaction notes share CreatedDate),
 *     the null/empty guards, and a bulk read.
 *
 * CONTENT FIXTURES: the factory has no ContentNote helper, so these insert
 * ContentNotes directly (Title + Content Blob), matching
 * BrokerAssignmentController.addNote. No link is needed because this selector
 * queries ContentNote by Id directly. TextPreview is asserted only for
 * accessibility (it is derived and is typically blank in the same transaction as
 * insert — the controller already treats a blank preview as "fall back to Title").
 * ContentNote is a content/system object queried under USER_MODE for file-sharing
 * enforcement, so no Standard-User FLS proof applies (design §3 #22).
 *
 * ═══ 🔴 BULK VOLUME IS 20, NOT 251 — DELIBERATE. DO NOT "RESTORE" IT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 for TRIGGERS, BATCH JOBS, SERVICES
 * THAT DO DML, and QUEUEABLES, because 251 forces a SECOND trigger batch chunk and
 * so exposes SOQL/DML-in-a-loop bugs that 200 hides. **None of that applies to a
 * selector READ**: `selectByIdsOrderedByCreatedDateDesc` is one `WHERE Id IN :ids`
 * statement with no loop and no chunking, so its behaviour at 251 rows is identical
 * to its behaviour at 20 — the larger number proves nothing extra. See
 * `.claude/rules/content-publication-rule.md`.
 *
 * It is also NOT FREE: every `ContentNote` insert consumes a **ContentPublication**,
 * capped org-wide at **2,500 per rolling 24 hours**, and — unlike the ContentNote
 * ROW itself — that consumption survives test rollback. At 251 rows this one method
 * was, alongside the sibling `ContentDocumentLinkSelectorTest` bulk test, the single
 * largest consumer in the whole suite. Reduced to 20 on 2026-08-06 (ContentPublication
 * quota incident — see `EmailToLeadHandler` class header for the production outage
 * this traces back to).
 *
 * @see agent-output/p4-selector-design.md (§3 #22, §5)
 */
@isTest
private class ContentNoteSelectorTest {

    /**
     * Bulk-read volume. See the BULK VOLUME note in the class header before changing
     * this: a selector read has no loop and no chunking, so 251 proves nothing 20
     * does not, and every ContentNote insert burns one of the org's 2,500 daily
     * ContentPublications.
     */
    private static final Integer BULK_ROWS = 20;

    @isTest
    static void selectByIdsOrderedByCreatedDateDesc_populatesFields() {
        ContentNote note = new ContentNote(Title = 'Tour Friday', Content = Blob.valueOf('<p>Broker tour Friday.</p>'));
        insert note;

        Test.startTest();
        List<ContentNote> rows = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(new Set<Id>{ note.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The note is returned for its own Id');
        Assert.areEqual(note.Id, rows[0].Id, 'Id is selected and matches');
        Assert.areEqual('Tour Friday', rows[0].Title, 'Title is selected');
        Assert.areEqual(UserInfo.getName(), rows[0].CreatedBy.Name, 'CreatedBy.Name is selected and resolves to the creator');
        // Referencing TextPreview proves it is in the SELECT (it is derived and may be
        // blank in the same transaction as insert, so its value is not asserted — the
        // controller falls back to Title when preview is blank).
        Assert.isNotNull(rows[0].CreatedDate,
            'CreatedDate and TextPreview (=' + rows[0].TextPreview + ') are both selected');
    }

    @isTest
    static void selectByIdsOrderedByCreatedDateDesc_ordersByCreatedDateDesc() {
        ContentNote older = new ContentNote(Title = 'Older', Content = Blob.valueOf('<p>older</p>'));
        ContentNote newer = new ContentNote(Title = 'Newer', Content = Blob.valueOf('<p>newer</p>'));
        insert new List<ContentNote>{ older, newer };
        // Same-transaction inserts share CreatedDate, so force a deterministic order.
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));
        Test.setCreatedDate(newer.Id, Datetime.now());

        Test.startTest();
        List<ContentNote> rows = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(
            new Set<Id>{ older.Id, newer.Id });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both notes are returned');
        Assert.areEqual(newer.Id, rows[0].Id, 'ORDER BY CreatedDate DESC returns the newest note first');
        Assert.areEqual(older.Id, rows[1].Id, 'The older note sorts last');
    }

    @isTest
    static void selectByIdsOrderedByCreatedDateDesc_nullEmpty_returnsEmpty() {
        Test.startTest();
        List<ContentNote> forNull = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(null);
        List<ContentNote> forEmpty = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null id set short-circuits to an empty list, not a query');
        Assert.areEqual(0, forEmpty.size(), 'An empty id set short-circuits to an empty list, not a query');
    }

    /**
     * 🔴 DELIBERATELY 20 ROWS, NOT 251 — DO NOT "RESTORE" THE 251. See the BULK
     * VOLUME note in the class header for the full reasoning; the short version is
     * that 251 proves nothing here that 20 does not, and it is not free in this org.
     */
    @isTest
    static void selectByIdsOrderedByCreatedDateDesc_bulk_readsAll() {
        List<ContentNote> notes = new List<ContentNote>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            notes.add(new ContentNote(Title = 'Note ' + i, Content = Blob.valueOf('body ' + i)));
        }
        insert notes;
        Set<Id> ids = new Set<Id>();
        for (ContentNote note : notes) {
            ids.add(note.Id);
        }

        Test.startTest();
        List<ContentNote> rows = ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(ids);
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, rows.size(), 'All ' + BULK_ROWS + ' notes are returned for their Ids at bulk volume');
    }
}
