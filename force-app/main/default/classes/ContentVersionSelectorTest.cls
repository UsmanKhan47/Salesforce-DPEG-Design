/**
 * Test class for ContentVersionSelector — the first ContentVersion SOQL in the application
 * (2026-08-05, inbound broker-email attachment capture).
 *
 * Covers the single method: field population (Id, ContentDocumentId — the whole reason the
 * read exists is that ContentDocumentId is never populated on a freshly-inserted
 * ContentVersion sObject), the null/empty-input guards, the no-match case, and a bulk read.
 *
 * ═══ 🔴 BULK VOLUME IS 20, NOT 251 — DELIBERATE. DO NOT "RESTORE" IT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 for TRIGGERS, BATCH JOBS, SERVICES THAT DO
 * DML, and QUEUEABLES. Its stated reason is that 251 forces a SECOND trigger batch chunk and
 * so exposes SOQL/DML-in-a-loop bugs that 200 hides. **None of that applies to a selector
 * READ**: there is no loop, no chunking, no second firing, and no DML. `WHERE Id IN :ids` is
 * one statement whose behaviour at 251 is identical to its behaviour at 20 — so the larger
 * number buys no additional coverage and falsifies nothing extra.
 *
 * It is also NOT FREE, which is what turned this from a preference into a fix. Every
 * `ContentVersion` insert consumes a **ContentPublication**, capped org-wide at **2,500 per
 * 24 hours**. At 251 rows this one method consumed the overwhelming majority of the whole
 * suite's daily allowance, and a deploy that runs tests could fail on the cap alone —
 * converting a green codebase into a red deployment for a number that proves nothing.
 * Reduced to 20 on 2026-08-05 during code review. If you need volume confidence for the
 * consumer rather than the selector, note that `InboundEmailAttachmentService` already caps
 * retained files at `MAX_ATTACHMENTS = 10`, so 20 is already twice the reachable maximum.
 *
 * `WITH SYSTEM_MODE` is not independently probed here: it lifts FLS/CRUD only, never
 * sharing, and the running test user (System Administrator) has full access to ContentVersion
 * regardless of mode — so a mode-specific assertion would not be falsifiable in this test
 * context. The automation-path justification for SYSTEM_MODE is documented in the selector's
 * own class header and in ARCHITECTURE.md §2.
 *
 * @see ContentVersionSelector.cls
 * @author Unit Testing Agent
 */
@isTest
private class ContentVersionSelectorTest {

    /**
     * Bulk-read volume. See the BULK VOLUME note in the class header before changing this:
     * a selector read has no loop and no chunking, so 251 proves nothing 20 does not, and
     * every ContentVersion insert burns one of the org's 2,500 daily ContentPublications.
     */
    private static final Integer BULK_ROWS = 20;

    private static List<ContentVersion> insertContentVersions(Integer count) {
        List<ContentVersion> versions = new List<ContentVersion>();
        for (Integer i = 0; i < count; i++) {
            versions.add(new ContentVersion(
                Title = 'Selector Fixture ' + i, PathOnClient = 'selectorfixture' + i + '.pdf',
                VersionData = Blob.valueOf('selector fixture body ' + i)
            ));
        }
        insert versions;
        return versions;
    }

    @isTest
    static void selectByIds_returnsContentDocumentIdForEachVersion() {
        List<ContentVersion> versions = insertContentVersions(2);
        Set<Id> versionIds = new Set<Id>{ versions[0].Id, versions[1].Id };

        Test.startTest();
        List<ContentVersion> found = ContentVersionSelector.selectByIds(versionIds);
        Test.stopTest();

        Assert.areEqual(2, found.size(), 'Both inserted versions must be returned');
        for (ContentVersion cv : found) {
            Assert.isNotNull(cv.ContentDocumentId,
                'ContentDocumentId must be populated by the READ — this is the whole reason the '
                + 'selector exists, since the platform never returns it on the freshly-inserted sObject');
        }
    }

    @isTest
    static void selectByIds_nullInput_returnsEmptyListNotAQuery() {
        Test.startTest();
        List<ContentVersion> found = ContentVersionSelector.selectByIds(null);
        Test.stopTest();

        Assert.areEqual(0, found.size(), 'A null id set must short-circuit to an empty list');
    }

    @isTest
    static void selectByIds_emptySet_returnsEmptyList() {
        Test.startTest();
        List<ContentVersion> found = ContentVersionSelector.selectByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, found.size(), 'An empty id set must short-circuit to an empty list');
    }

    @isTest
    static void selectByIds_noMatchingRow_returnsEmptyList() {
        List<ContentVersion> versions = insertContentVersions(1);
        ContentVersion existing = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :versions[0].Id];
        delete [SELECT Id FROM ContentDocument WHERE Id = :existing.ContentDocumentId];

        Test.startTest();
        List<ContentVersion> found = ContentVersionSelector.selectByIds(new Set<Id>{ versions[0].Id });
        Test.stopTest();

        Assert.areEqual(0, found.size(), 'A ContentVersion Id with no matching row (deleted) must return an empty list, not throw');
    }

    /**
     * 🔴 DELIBERATELY 20 ROWS, NOT 251 — DO NOT "RESTORE" THE 251. See the BULK VOLUME note in
     * the class header for the full reasoning; the short version is that 251 proves nothing
     * here that 20 does not, and it is not free in this org.
     */
    @isTest
    static void selectByIds_bulk_readsAllInOneQuery() {
        List<ContentVersion> versions = insertContentVersions(BULK_ROWS);
        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion cv : versions) {
            versionIds.add(cv.Id);
        }

        Test.startTest();
        List<ContentVersion> found = ContentVersionSelector.selectByIds(versionIds);
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, found.size(),
            'All ' + BULK_ROWS + ' versions must be returned from ONE query — the exact contract '
            + 'InboundEmailAttachmentService.persist relies on regardless of file count');
    }
}
