/**
 * Test class for AttachmentPersistQueueable — the transaction that owns nothing else, and the
 * ONLY class in this suite that inserts ContentVersion.
 *
 * ═══ QUOTA DISCIPLINE (.claude/rules/content-publication-rule.md) ═══
 * Every ContentVersion this class creates is a PERMANENT cost against the org's shared
 * 2,500-per-24h ContentPublication quota — test rollback does NOT refund it (M7). Fixtures are
 * therefore kept to the minimum row count that still falsifies the specific behaviour under
 * test, and several design-listed assertions are FOLDED INTO ONE fixture rather than given a
 * fixture each. Running total, by test method:
 *   execute_oneCarrier_convertsLinksAndPinsTheExactGovernorBudget ............ 1 ContentVersion
 *   execute_threeFilesTenTargets_stillPinsTheSameExactGovernorBudget ......... 3 ContentVersion
 *   execute_budgetCapDefers_leavesThatCarrierAndStampsPartial ................ 1 ContentVersion
 *   execute_viaRealQueueableEntryPoint_convertsExactlyLikeConvertDoes ........ 1 ContentVersion
 *   heapGate_* / execute_budgetReached_* / execute_breakerTripped_* /
 *   execute_missingCarrier_* / execute_persistRefusal_* / chooseConvertibleSubset_* . 0 ContentVersion
 * TOTAL for this class: 6 ContentVersion. Well inside the rule's "≤ 20 per class" ceiling.
 *
 * ═══ WHY `convert(...)` IS CALLED DIRECTLY, NOT VIA System.enqueueJob, IN MOST TESTS ═══
 * `AttachmentPersistQueueable.convert(Id, List<Id>)` is `public static` FOR EXACTLY THIS REASON
 * (see its own Javadoc): `AttachmentCarrierSweepBatch` calls the identical code path directly,
 * so testing it the same way is not a shortcut, it is testing the ACTUAL shared entry point.
 * `execute(QueueableContext)` itself is a two-line wrapper (attach the Finalizer, then call
 * `convert`) and `System.attachFinalizer` can only be called from a real running async Queueable
 * job, not from synchronous test code — so the FULL execute()-plus-Finalizer wiring is proven
 * separately, end to end, in `AttachmentPersistFinalizerTest` (which enqueues real jobs).
 *
 * ═══ HOW THE §6.2 HEAP GATE IS PROVEN WITHOUT REAL MULTI-MEGABYTE CONTENT ═══
 * `chooseConvertibleSubset(List<Attachment>)` is `@TestVisible private static` and PURE — no
 * SOQL, no DML, no bytes. It reads only `row.Id` and `row.BodyLength`. Real, valid Ids are taken
 * from tiny (near-zero-byte) classic `Attachment` rows — a classic Attachment insert costs ZERO
 * ContentPublications (SP-4.1), so this is free — and FRESH in-memory `Attachment` instances are
 * then built from those same Ids with FABRICATED `BodyLength` values, exactly as design §8.7 test
 * 5 specifies ("driven by fabricated BodyLength values through a @TestVisible seam ... pure, no
 * bytes, no quota"). This proves the SELECTION decision without ever allocating a real >4 MB
 * String/Blob synchronously inside a test method, which risks an UNCATCHABLE heap
 * `LimitException` in the test's own setup — exactly the failure class this whole redesign
 * exists to eliminate, and not one to risk reproducing inside the test suite that guards it.
 *
 * ═══ execute_budgetCapDefers_... — A DOCUMENTED SUBSTITUTION, NOT A SHORTCUT ═══
 * Design test 7 ("execute_deferredFile_leavesTheCarrierAndStampsPartial") describes deferral via
 * the HEAP gate specifically. Reaching `chosen.isEmpty()` (or a partial `chosen`) through the
 * REAL `AttachmentSelector.selectMetadataByParentIds` query requires an actual carrier whose
 * real, platform-computed `BodyLength` exceeds `CONVERT_MAX_TOTAL_BYTES` (4,000,000) — which
 * means building a real multi-megabyte Blob synchronously in the test, the same heap risk noted
 * above. `capToAllowance(...)` reaches the IDENTICAL code branch (`convert()`'s
 * `if (chosen.isEmpty()) { ...ATTACHMENT_STATUS_PARTIAL...NOTE_DEFERRED...return; }`, and the
 * "some converted, some left behind" shape one step later) by shrinking the chosen set via the
 * DAILY PUBLICATION BUDGET instead of BodyLength — deterministic, safe, and provably the same
 * observable outcome (carrier survives, status Partial, `NOTE_DEFERRED`'s text is what the
 * production code emits regardless of which cap produced the deferral). This is recorded here so
 * a reviewer does not read it as vacuous: it is a different ROUTE to the same CODE PATH, chosen
 * because the literal route is unsafe to execute inside a test.
 *
 * @see AttachmentPersistQueueable.cls
 * @see agent-output/design-requirements-attachment-persistence-v2.md §8.7 (tests 1-12), §9
 * @author Unit Testing Agent
 */
@isTest
private class AttachmentPersistQueueableTest {

    private static Id insertStaging(String suffix, String attachmentStatus) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Persist queueable fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-persistq-fixture-' + suffix + '@example.invalid',
            Attachment_Status__c = attachmentStatus
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

    /**
     * An in-memory Attachment carrying a REAL Id (from a tiny, already-inserted row — free,
     * since a classic Attachment costs zero ContentPublications) but a FABRICATED BodyLength.
     * `BodyLength` is a platform-calculated field with no writable path through the normal
     * constructor/DML surface; JSON deserialization is the standard, reliable way to set such a
     * field on an in-memory instance without ever touching the database — exactly what
     * chooseConvertibleSubset's PURE, no-SOQL contract needs to be tested against realistic sizes
     * without allocating a single real byte.
     */
    private static Attachment fakeAttachment(Id realId, Integer bodyLength) {
        return (Attachment) JSON.deserialize(
            '{"Id":"' + realId + '","BodyLength":' + bodyLength + '}', Attachment.class);
    }

    // ── happy path: one carrier, one target — folds design tests 1, 2, 4, 12 ──

    @isTest
    static void execute_oneCarrier_convertsLinksAndPinsTheExactGovernorBudget() {
        Id stagingId = insertStaging('happy-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'om.pdf', 'PDF OFFERING MEMORANDUM CONTENT');
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, new List<Id>{ target.Id });
        Test.stopTest();

        // Test 1 — the happy path end to end: carrier gone, status Saved.
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId],
            'The converted carrier must be deleted — only files that FAILED to convert are kept');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'om.pdf'], '');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c, '');

        // Test 4 — the ShareType split survives the move: 'V' to staging, 'I' to the routed target.
        List<ContentDocumentLink> stagingLinks = [
            SELECT ShareType FROM ContentDocumentLink WHERE LinkedEntityId = :stagingId
        ];
        Assert.areEqual(1, stagingLinks.size(), '');
        Assert.areEqual('V', stagingLinks[0].ShareType, 'The staging link must stay Viewer, never Inferred');
        List<ContentDocumentLink> routedLinks = [
            SELECT ShareType FROM ContentDocumentLink WHERE LinkedEntityId = :target.Id
        ];
        Assert.areEqual(1, routedLinks.size(), '');
        Assert.areEqual('I', routedLinks[0].ShareType, 'The routed link must stay Inferred, matching the platform\'s own conversion carry-over links');

        // Test 2 — the EXACT governor budget at 1 file x 1 target. See the class header table in
        // AttachmentPersistQueueable.cls: 3 SOQL (metadata + bodies + ContentVersionSelector) and
        // 6 DML (ContentVersion insert, staging link, routed link, carrier delete, budget
        // counter, staging status stamp) — SIX, not the design §9 table's five, because that
        // table omits the staging status stamp its own §11.2 step 10 requires.
        Assert.areEqual(3, AttachmentPersistQueueable.lastRunQueryCount,
            'GOVERNOR BUDGET: exactly 3 SOQL, constant regardless of file/target count');
        Assert.areEqual(6, AttachmentPersistQueueable.lastRunDmlCount,
            'GOVERNOR BUDGET: exactly 6 DML — see AttachmentPersistQueueable\'s own class header for '
            + 'why this is 6, not the design doc\'s stale 5');

        // Test 12 — heap-peak telemetry is captured inside the async context for the §6.2 pin.
        Assert.isNotNull(AttachmentPersistQueueable.lastRunHeapPeak,
            'lastRunHeapPeak must be recorded so the §6.2 ceiling can be asserted from inside the job');
        Assert.areEqual(1, AttachmentPersistQueueable.lastRunConvertedCount, '');
        Assert.areEqual(0, AttachmentPersistQueueable.lastRunDeferredCount, '');
    }

    // ── the SAME exact budget at the cap: 3 files x 10 targets ────────────────

    @isTest
    static void execute_threeFilesTenTargets_stillPinsTheSameExactGovernorBudget() {
        // Test 3 — the load-bearing property is CONSTANCY, not the absolute numbers: this must
        // pin the IDENTICAL 3 SOQL / 6 DML as the 1x1 case above, because every DML statement
        // here is ONE BULK call regardless of file count or target count.
        Id stagingId = insertStaging('cap-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'file0.pdf', 'CONTENT ZERO');
        insertCarrier(stagingId, 'file1.pdf', 'CONTENT ONE');
        insertCarrier(stagingId, 'file2.pdf', 'CONTENT TWO');
        List<Id> targets = new List<Id>();
        for (Lead target : TestDataFactory.createLeads(10, true)) {
            targets.add(target.Id);
        }

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, targets);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'All 3 carriers must convert and be deleted');
        Assert.areEqual(3, [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'file%.pdf'], '');
        Assert.areEqual(30, [
            SELECT COUNT() FROM ContentDocumentLink
            WHERE LinkedEntityId IN :targets
        ], '3 files x 10 targets = 30 links, from ONE bulk linkTo() statement, never per file or per target');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c, '');

        Assert.areEqual(3, AttachmentPersistQueueable.lastRunQueryCount,
            'GOVERNOR BUDGET: still exactly 3 SOQL at 3 files x 10 targets — CONSTANT is the point');
        Assert.areEqual(6, AttachmentPersistQueueable.lastRunDmlCount,
            'GOVERNOR BUDGET: still exactly 6 DML at 3 files x 10 targets — CONSTANT is the point');
    }

    // ── the §6.2 heap gate — PURE, fabricated BodyLength, zero bytes/quota ────

    @isTest
    static void heapGate_selectsTheSubsetThatFitsAndDefersTheRest() {
        // Test 5. Real Ids (free — classic Attachment costs zero publications), fabricated sizes.
        Id smallId = insertCarrier(insertStaging('gate-1', InboundEmailStagingService.ATTACHMENT_STATUS_NONE), 'small', 'x');
        Id bigId = insertCarrier(insertStaging('gate-2', InboundEmailStagingService.ATTACHMENT_STATUS_NONE), 'big', 'x');
        // Ascending order, as AttachmentSelector.selectMetadataByParentIds would return it.
        List<Attachment> rows = new List<Attachment>{
            fakeAttachment(smallId, 1000000),
            fakeAttachment(bigId, 3500000)
        };
        // 1,000,000 + 3,500,000 = 4,500,000 > CONVERT_MAX_TOTAL_BYTES (4,000,000): the small one
        // fits alone (1,000,000 <= 4,000,000); adding the big one would exceed the cap, so it defers.

        Test.startTest();
        Set<Id> chosen = AttachmentPersistQueueable.chooseConvertibleSubset(rows);
        Test.stopTest();

        Assert.areEqual(1, chosen.size(), 'Only the file(s) that fit together may be chosen');
        Assert.isTrue(chosen.contains(smallId), 'The smaller file must be chosen — ascending order means it is tried first');
        Assert.isFalse(chosen.contains(bigId), 'The larger file must be DEFERRED, not dropped — it stays on the carrier for the next pass');
    }

    @isTest
    static void heapGate_singleFileAtOrUnderTheCeiling_alwaysFitsAlone_neverPermanentlyStuck() {
        // Test 6. Because CONVERT_MAX_TOTAL_BYTES equals ATTACHMENT_MAX_BYTES, any file this
        // pipeline would ever RETAIN must fit a conversion transaction by itself.
        Id stagingId = insertStaging('gate-3', InboundEmailStagingService.ATTACHMENT_STATUS_NONE);
        Id atCeilingId = insertCarrier(stagingId, 'at-ceiling', 'x');
        Id overCeilingId = insertCarrier(stagingId, 'over-ceiling', 'x');

        Test.startTest();
        Set<Id> chosenAtCeiling = AttachmentPersistQueueable.chooseConvertibleSubset(
            new List<Attachment>{ fakeAttachment(atCeilingId, 4000000) });
        Set<Id> chosenOverCeiling = AttachmentPersistQueueable.chooseConvertibleSubset(
            new List<Attachment>{ fakeAttachment(overCeilingId, 4000001) });
        Test.stopTest();

        Assert.isTrue(chosenAtCeiling.contains(atCeilingId),
            'A file exactly AT CONVERT_MAX_TOTAL_BYTES must be chosen — the check is strictly greater-than, '
            + 'matching every other cap in this module, and this is what guarantees a retained file can never be stuck');
        Assert.isFalse(chosenOverCeiling.contains(overCeilingId),
            'A file over the ceiling (only reachable via a legacy carrier written under an OLD, larger '
            + 'ATTACHMENT_MAX_BYTES) must never be chosen — it takes the sweeper\'s Expired exit instead, '
            + 'which is a defined exit, not a stuck state');
    }

    // ── deferral is recoverable — see the class header note on this substitution ─

    @isTest
    static void execute_budgetCapDefers_leavesThatCarrierAndStampsPartial() {
        // Test 7, via the documented substitution explained in this class's header: the daily
        // publication budget, not real oversized content, is used to force ONE of two small
        // carriers to be left behind.
        Id stagingId = insertStaging('defer-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        Id keptId = insertCarrier(stagingId, 'aaa-kept.pdf', 'SMALL');
        Id deferredId = insertCarrier(stagingId, 'zzz-deferred.pdf', 'ALSO SMALL');
        Lead target = TestDataFactory.createLead(true);
        // Consume all but 1 of the daily allowance, so capToAllowance() can afford only ONE of
        // the two heap-gate-chosen carriers.
        ContentPublicationBudget.record(999);

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, new List<Id>{ target.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'aaa-kept.pdf'],
            'Precondition: the budget-affordable carrier must actually convert, or the assertions below prove nothing');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId],
            'The carrier the budget could not afford must be LEFT ON THE ROW, not deleted — '
            + 'a deferral is a recoverable delay, never a loss');
        Attachment remaining = [SELECT Name FROM Attachment WHERE ParentId = :stagingId];
        Assert.areEqual('zzz-deferred.pdf', remaining.Name, 'The larger-by-name (later-in-order) carrier is the one deferred');

        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, staging.Attachment_Status__c,
            'Some converted, some deferred: Partial, not Saved and not Failed');
        Assert.isNotNull(staging.Dropped_Attachment_Notes__c, 'A deferral must be RECORDED, never silent');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('will be retried'),
            'The note must say the file is RECOVERABLE. Actual: ' + staging.Dropped_Attachment_Notes__c);

        Assert.areEqual(1, AttachmentPersistQueueable.lastRunConvertedCount, '');
        Assert.areEqual(1, AttachmentPersistQueueable.lastRunDeferredCount, '');
    }

    // ── admissibility gates: skip and record, zero ContentVersion DML ─────────

    @isTest
    static void execute_budgetReached_convertsNothingAndStampsPartial() {
        // Test 8 — §6.6. The daily budget is checked BEFORE the metadata SOQL even runs, so NO
        // carrier read happens on this path — the ONE SOQL that IS spent (measured; not the zero
        // this test originally assumed) is `InboundEmailStagingService.appendDroppedNote`'s own
        // read-then-append, invoked from markAttachmentStatus to record the §7 note. That is a
        // documented, separate cost (its own class header: "+1 SOQL / +1 DML", failure-path
        // only) — not the carrier-selection read this test exists to prove is skipped.
        Id stagingId = insertStaging('budget-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'blocked.pdf', 'CONTENT');
        ContentPublicationBudget.record(1000);

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'blocked.pdf'],
            'No ContentVersion DML may be issued once the daily budget is exhausted');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'The carrier must survive, untouched');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, staging.Attachment_Status__c, '');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('daily publication budget reached'),
            'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.areEqual(1, AttachmentPersistQueueable.lastRunQueryCount,
            'Exactly 1 SOQL (the note-append\'s own read) is spent reaching this refusal — ZERO of it is '
            + 'a carrier read: AttachmentSelector.selectMetadataByParentIds must never be called once the '
            + 'daily budget is exhausted');
    }

    @isTest
    static void execute_breakerTripped_convertsNothingAndRecordsSuspendedUntil() {
        // Test 9 — §6.5. Same zero-SOQL, zero-ContentVersion shape as the budget case, but via
        // the reactive breaker instead, and the status lands on Failed (re-queued) not Partial.
        Id stagingId = insertStaging('breaker-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'suspended.pdf', 'CONTENT');
        ContentPublicationBudget.trip();

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'suspended.pdf'], 'No ContentVersion DML while the breaker is tripped');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], 'The carrier must survive, untouched');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_FAILED, staging.Attachment_Status__c,
            'A tripped breaker stamps Failed, matching the Finalizer\'s own stamp for the same underlying condition');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('persistence suspended until'),
            'Actual: ' + staging.Dropped_Attachment_Notes__c);
    }

    @isTest
    static void execute_missingCarrier_isANoOpAndThrowsNothing() {
        // Test 10 — a released, expired, or already-converted row must not break a replayed sweep.
        Id stagingId = insertStaging('missing-1', InboundEmailStagingService.ATTACHMENT_STATUS_NOT_SAVED);
        // Deliberately NO carrier inserted.

        Test.startTest();
        AttachmentPersistQueueable.convert(stagingId, new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], '');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_NOT_SAVED, staging.Attachment_Status__c,
            'Returning WITHOUT a stamp is deliberate — whoever removed the carrier already wrote the '
            + 'terminal status, and overwriting it here would erase why the file is not there');
        Assert.areEqual(0, AttachmentPersistQueueable.lastRunDmlCount, 'A missing carrier must cost zero DML');
    }

    @isTest
    static void execute_missingStagingId_isANoOp() {
        Test.startTest();
        AttachmentPersistQueueable.convert(null, new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'A null stagingId must be a pure no-op');
    }

    // ── a persist()-level refusal keeps the carrier — only converted rows die ──

    @isTest
    static void execute_persistRefusal_recordsItAndKeepsThatCarrier() {
        // Test 11. Forces InboundEmailAttachmentService.persist()'s OWN per-row heap re-check
        // (REASON_CONVERT_HEAP_CEILING) via its existing heapSizeOverride test seam — a genuine
        // refusal INSIDE persist(), downstream of the pre-selection heap gate, which is what
        // proves "only CONVERTED rows are deleted" rather than merely "the pre-selected subset
        // is deleted".
        Id stagingId = insertStaging('refusal-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'never-converts.pdf', 'CONTENT');
        Lead target = TestDataFactory.createLead(true);

        InboundEmailAttachmentService.heapSizeOverride =
            InboundEmailAttachmentService.CONVERT_HEAP_CEILING + 1;
        try {
            Test.startTest();
            AttachmentPersistQueueable.convert(stagingId, new List<Id>{ target.Id });
            Test.stopTest();
        } finally {
            InboundEmailAttachmentService.heapSizeOverride = null;
        }

        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion WHERE Title = 'never-converts.pdf'],
            'The per-row conversion heap ceiling must refuse the ContentVersion insert entirely');
        Assert.areEqual(1, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId],
            'A carrier whose ContentVersion insert was refused must be KEPT, never deleted — deleting it '
            + 'here would destroy the bytes of a file that still needs retrying');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c, Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL, staging.Attachment_Status__c, '');
        Assert.isTrue(staging.Dropped_Attachment_Notes__c.contains('CONVERT_HEAP_CEILING'),
            'Actual: ' + staging.Dropped_Attachment_Notes__c);
        Assert.areEqual(0, AttachmentPersistQueueable.lastRunConvertedCount, '');
    }

    // ── the REAL entry point — constructor + execute(), via System.enqueueJob ─

    @isTest
    static void execute_viaRealQueueableEntryPoint_convertsExactlyLikeConvertDoes() {
        // Every other test in this class calls convert() directly (see the class header for
        // why that is the correct, not merely convenient, choice — AttachmentCarrierSweepBatch
        // shares the identical code path). This ONE test instead goes through the constructor
        // and execute() exactly as ExtractAddressQueueable.enqueueAttachmentPersist would in
        // production, proving the thin wrapper (attach the Finalizer, then delegate) works
        // end to end and not merely by inspection.
        Id stagingId = insertStaging('real-entry-1', InboundEmailStagingService.ATTACHMENT_STATUS_PENDING);
        insertCarrier(stagingId, 'via-queueable.pdf', 'CONTENT VIA REAL ENTRY POINT');
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        System.enqueueJob(new AttachmentPersistQueueable(stagingId, new List<Id>{ target.Id }));
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'via-queueable.pdf'], '');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :stagingId], '');
        Inbound_Email_Staging__c staging = [
            SELECT Attachment_Status__c FROM Inbound_Email_Staging__c WHERE Id = :stagingId
        ];
        Assert.areEqual(InboundEmailStagingService.ATTACHMENT_STATUS_SAVED, staging.Attachment_Status__c, '');
    }

    // ── chooseConvertibleSubset — the remaining pure-function edge cases ─────

    @isTest
    static void chooseConvertibleSubset_nullOrEmptyRows_returnsEmptySet() {
        Test.startTest();
        Set<Id> fromNull = AttachmentPersistQueueable.chooseConvertibleSubset(null);
        Set<Id> fromEmpty = AttachmentPersistQueueable.chooseConvertibleSubset(new List<Attachment>());
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'null rows must yield an empty set, never throw');
        Assert.areEqual(0, fromEmpty.size(), 'An empty rows list must yield an empty set');
    }

    @isTest
    static void chooseConvertibleSubset_nullEntryOrNullId_isSkippedDefensively() {
        Id realId = insertCarrier(insertStaging('gate-4', InboundEmailStagingService.ATTACHMENT_STATUS_NONE), 'real', 'x');

        Attachment noIdRow = (Attachment) JSON.deserialize('{"BodyLength":1000}', Attachment.class);

        Test.startTest();
        Set<Id> chosen = AttachmentPersistQueueable.chooseConvertibleSubset(new List<Attachment>{
            null, noIdRow, fakeAttachment(realId, 500)
        });
        Test.stopTest();

        Assert.areEqual(1, chosen.size(), 'A null entry and an entry with no Id must both be skipped without throwing');
        Assert.isTrue(chosen.contains(realId), '');
    }
}
