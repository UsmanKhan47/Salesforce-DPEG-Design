/**
 * Tests for ContentNoteSelector (P4, Module B2 — Property Management).
 *
 * Covers the single relocated query:
 *   - selectByIdsOrderedByCreatedDateDesc : field population (Title selected,
 *     CreatedBy.Name populated, TextPreview accessible), ORDER BY CreatedDate DESC
 *     (proven with Test.setCreatedDate — same-transaction notes share CreatedDate),
 *     the null/empty guards, and a 251-note bulk read (bulk-test-rule).
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
 * @see agent-output/p4-selector-design.md (§3 #22, §5)
 */
@isTest
private class ContentNoteSelectorTest {

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

    @isTest
    static void selectByIdsOrderedByCreatedDateDesc_bulk251_readsAll() {
        List<ContentNote> notes = new List<ContentNote>();
        for (Integer i = 0; i < 251; i++) {
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

        Assert.areEqual(251, rows.size(), 'All 251 notes are returned for their 251 Ids at bulk volume');
    }
}
