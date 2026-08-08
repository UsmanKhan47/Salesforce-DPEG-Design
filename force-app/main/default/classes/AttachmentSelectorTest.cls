/**
 * Test class for AttachmentSelector — the first Attachment SOQL in the application, and the
 * two-method split that makes the §6.2 conversion heap gate a PRE-check rather than a hope.
 *
 * ═══ ZERO ContentPublication COST ═══
 * Every fixture here is a classic `Attachment` (SP-4.1, definitive: an Attachment insert
 * consumes ZERO ContentPublications). This class inserts no ContentVersion at all, so it costs
 * nothing against `.claude/rules/content-publication-rule.md`'s ceiling.
 *
 * COVERS: selectMetadataByParentIds never selects Body (the load-bearing property the whole
 * heap gate depends on), its null/empty short-circuit and ascending-BodyLength order;
 * selectBodiesByIds' null/empty short-circuit and that it returns exactly the requested subset
 * with Body populated.
 *
 * @see AttachmentSelector.cls
 * @see agent-output/design-requirements-attachment-persistence-v2.md §8.7 (tests 40-42)
 * @author Unit Testing Agent
 */
@isTest
private class AttachmentSelectorTest {

    private static Id insertStaging(String suffix) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Attachment selector fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-attachment-selector-' + suffix + '@example.invalid'
        );
        insert staging;
        return staging.Id;
    }

    private static Id insertCarrier(Id stagingId, String name, String content) {
        Attachment att = new Attachment(
            ParentId = stagingId,
            Name = name,
            ContentType = 'application/pdf',
            Body = Blob.valueOf(content)
        );
        insert att;
        return att.Id;
    }

    // ── selectMetadataByParentIds ─────────────────────────────────────────────

    @isTest
    static void selectMetadataByParentIds_neverSelectsBody() {
        // 🔴 THE LOAD-BEARING ASSERTION. If Body were ever added to this SELECT, referencing
        // row.Body on the returned row would compile fine (Attachment.Body is a real field) but
        // would silently allocate BodyLength bytes of heap per row the instant it is READ — and
        // AttachmentPersistQueueable never reads it here, so the only observable proof available
        // from outside the class is that touching .Body throws SObjectException for an UNQUERIED
        // field. That exception IS the pin: it can only be thrown if Body was excluded.
        Id stagingId = insertStaging('meta-1');
        insertCarrier(stagingId, 'om.pdf', 'PDF CONTENT');

        Test.startTest();
        List<Attachment> rows = AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Precondition: the carrier must be found');
        Boolean threwForUnqueriedBody = false;
        try {
            Blob unused = rows[0].Body;
        } catch (System.SObjectException e) {
            threwForUnqueriedBody = true;
        }
        Assert.isTrue(threwForUnqueriedBody,
            'Body must NOT be in the SELECT — reading it must throw SObjectException, proving the '
            + 'query never allocated the file bytes. If this ever stops throwing, someone added '
            + 'Body to selectMetadataByParentIds and reopened the heap risk SP-4.5 measured.');
        Assert.isNotNull(rows[0].BodyLength, 'BodyLength IS selected — this is what makes the gate a PRE-check');
    }

    @isTest
    static void selectMetadataByParentIds_ordersAscendingByBodyLength() {
        Id stagingId = insertStaging('meta-2');
        insertCarrier(stagingId, 'large.pdf', ''.rightPad(500, 'L'));
        insertCarrier(stagingId, 'small.pdf', 'S');
        insertCarrier(stagingId, 'medium.pdf', ''.rightPad(100, 'M'));

        Test.startTest();
        List<Attachment> rows = AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
        Test.stopTest();

        Assert.areEqual(3, rows.size(), '');
        Assert.areEqual('small.pdf', rows[0].Name, 'Ascending BodyLength: smallest first, so the heap gate defers deterministically');
        Assert.areEqual('medium.pdf', rows[1].Name, '');
        Assert.areEqual('large.pdf', rows[2].Name, '');
    }

    @isTest
    static void selectMetadataByParentIds_nullOrEmpty_shortCircuitsWithoutAQuery() {
        Test.startTest();
        List<Attachment> fromNull = AttachmentSelector.selectMetadataByParentIds(null);
        List<Attachment> fromEmpty = AttachmentSelector.selectMetadataByParentIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null parentIds set must return an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty parentIds set must return an empty list');
    }

    @isTest
    static void selectMetadataByParentIds_noMatch_returnsEmptyList() {
        Id stagingId = insertStaging('meta-3');
        // Deliberately no carrier inserted.

        Test.startTest();
        List<Attachment> rows = AttachmentSelector.selectMetadataByParentIds(new Set<Id>{ stagingId });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A staging row with no carrier must return an empty list, not throw');
    }

    // ── selectBodiesByIds ──────────────────────────────────────────────────────

    @isTest
    static void selectBodiesByIds_returnsOnlyTheRequestedSubsetWithBodyPopulated() {
        Id stagingId = insertStaging('bodies-1');
        Id wantedId = insertCarrier(stagingId, 'wanted.pdf', 'WANTED CONTENT');
        Id excludedId = insertCarrier(stagingId, 'excluded.pdf', 'EXCLUDED CONTENT');

        Test.startTest();
        List<Attachment> rows = AttachmentSelector.selectBodiesByIds(new Set<Id>{ wantedId });
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'Only the REQUESTED subset must be returned — never every carrier on the parent row, '
            + 'which is exactly the difference between a pre-check and a heap blow-out');
        Assert.areEqual(wantedId, rows[0].Id, '');
        Assert.areEqual('WANTED CONTENT', rows[0].Body.toString(), 'Body must be populated by this method');
    }

    @isTest
    static void selectBodiesByIds_nullOrEmpty_shortCircuitsWithoutAQuery() {
        Test.startTest();
        List<Attachment> fromNull = AttachmentSelector.selectBodiesByIds(null);
        List<Attachment> fromEmpty = AttachmentSelector.selectBodiesByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null ids set must return an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty ids set must return an empty list');
    }

    @isTest
    static void selectBodiesByIds_noMatch_returnsEmptyList() {
        Id stagingId = insertStaging('bodies-2');
        Id carrierId = insertCarrier(stagingId, 'gone.pdf', 'CONTENT');
        delete new Attachment(Id = carrierId);

        Test.startTest();
        List<Attachment> rows = AttachmentSelector.selectBodiesByIds(new Set<Id>{ carrierId });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A deleted carrier Id must return an empty list, not throw');
    }
}
