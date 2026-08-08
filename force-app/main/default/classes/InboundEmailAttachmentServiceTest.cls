/**
 * Test class for InboundEmailAttachmentService — the only class that writes ContentVersion
 * or ContentDocumentLink for the Broker-Protection inbound-email pipeline (2026-08-05).
 *
 * COVERS classify() (PURE — no SOQL/DML), persist() and linkTo() (both DML, both MUST NOT
 * THROW), and the two small public helpers (isImageAttachment, describeDrop) that
 * EmailToLeadHandler reuses directly.
 *
 * ═══ WHY classify() TESTS DO NOT ALLOCATE REAL MEGABYTE-SIZED BLOBS ═══
 * classify() reads `AttachmentRequest.byteSize` — an Integer the CALLER supplies — never
 * `att.body.size()`. So a boundary case (ATTACHMENT_MAX_BYTES, IMAGE_MIN_BYTES) can be
 * pinned exactly by setting `byteSize` to the desired value on a tiny placeholder Blob,
 * with zero heap risk. This is deliberate and mirrors production: EmailToLeadHandler's
 * marshalAttachments() derives byteSize from the REAL Blob before classify() ever runs, so
 * classify() itself never needs to re-measure it. Where a test genuinely needs the platform
 * to derive byteSize from a real Blob (the persist() DML tests), small real content is used
 * instead — see the persist() section.
 *
 * ═══ WHY forcePersistFailure IS THE ACCEPTANCE-CRITERION SEAM, NOT THE ONLY BOUNDARY TEST ═══
 * This class pins that persist() itself never propagates a forced failure and records it on
 * the staging row. The END-TO-END proof that a persistence failure still produces a
 * SUCCESSFUL, COMPLETE email routing — the single most important test in this suite, per the
 * task brief — lives in EmailToLeadHandlerTest
 * (handleInboundEmail_forcedPersistFailure_stillSucceedsAndRoutesNormally), because only the
 * handler owns the `result.success` contract this feature must never break.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in this
 * exact module (PropertyClaimServiceTest, PropertyMatchingServiceTest, ExtractAddressQueueableTest).
 *
 * @see InboundEmailAttachmentService.cls
 * @see agent-output/design-requirements-email-attachments.md §2 A/C/D/E, §4.1, §4.9
 * @author Unit Testing Agent
 */
@isTest
private class InboundEmailAttachmentServiceTest {

    // ── fixture helpers ───────────────────────────────────────────────────────

    private static InboundEmailAttachmentService.AttachmentRequest binaryAttachment(
            String fileName, String mimeSubType, Integer byteSize) {
        InboundEmailAttachmentService.AttachmentRequest att =
            new InboundEmailAttachmentService.AttachmentRequest();
        att.fileName = fileName;
        att.mimeSubType = mimeSubType;
        // A tiny placeholder body — classify() reads byteSize, never body.size(). See the
        // class header for why this is deliberate, not an oversight.
        att.body = Blob.valueOf('x');
        att.byteSize = byteSize;
        return att;
    }

    private static InboundEmailAttachmentService.AttachmentRequest binaryAttachmentWithRealBody(
            String fileName, String mimeSubType, String content) {
        InboundEmailAttachmentService.AttachmentRequest att =
            new InboundEmailAttachmentService.AttachmentRequest();
        att.fileName = fileName;
        att.mimeSubType = mimeSubType;
        att.body = Blob.valueOf(content);
        att.byteSize = content.length();
        return att;
    }

    private static InboundEmailAttachmentService.AttachmentRequest textAttachment(
            String fileName, String mimeSubType, String textBody) {
        InboundEmailAttachmentService.AttachmentRequest att =
            new InboundEmailAttachmentService.AttachmentRequest();
        att.fileName = fileName;
        att.mimeSubType = mimeSubType;
        att.textBody = textBody;
        att.byteSize = (textBody == null) ? 0 : textBody.length();
        return att;
    }

    private static Inbound_Email_Staging__c insertStaging(String suffix) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'FW: Attachment fixture',
            Raw_Body__c = 'body',
            Forwarded_By__c = 'forwarder@example.invalid',
            Message_Id__c = 'msg-attachment-fixture-' + suffix + '@example.invalid'
        );
        insert staging;
        return staging;
    }

    // ── classify() — content-based drops (evaluated BEFORE the slot-based caps) ──

    @isTest
    static void classify_pdfBinaryAttachment_isRetained() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('om.pdf', 'pdf', 100000)
            });

        Assert.areEqual(1, result.retainedCount, 'A plain PDF must be retained');
        Assert.areEqual(100000, result.retainedBytes, 'retainedBytes sums the retained files\' byteSize');
        Assert.areEqual(1, result.retained.size(), 'retained must carry the same file');
        Assert.isNull(result.droppedNotes, 'Nothing was dropped, so droppedNotes must be null, not an empty string');
    }

    @isTest
    static void classify_octetStreamWithPdfExtension_isRetainedViaTheUnionRule() {
        // G1 — a forwarded attachment routinely arrives as application/octet-stream. A
        // MIME-only filter would drop the offering memorandum; the filename extension must
        // rescue it.
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('offering-memo.pdf', 'octet-stream', 200000)
            });

        Assert.areEqual(1, result.retainedCount,
            'application/octet-stream must still be kept when the FILENAME extension is allowed (G1 union)');
    }

    @isTest
    static void classify_xlsxAttachment_isRetained() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('rentroll.xlsx', 'vnd.openxmlformats-officedocument.spreadsheetml.sheet', 50000)
            });

        Assert.areEqual(1, result.retainedCount, 'An Excel rent roll must be retained');
    }

    @isTest
    static void classify_csvTextAttachment_isRetained() {
        // G3 — the ONE textAttachment type kept. A CSV rent roll is real deal data.
        String csvBody = 'unit,rent\n101,1200\n102,1350';
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                textAttachment('rentroll.csv', 'csv', csvBody)
            });

        Assert.areEqual(1, result.retainedCount, 'A .csv text attachment must be retained (G3)');
        Assert.areEqual(csvBody.length(), result.retainedBytes, 'retainedBytes uses the character count for text attachments');
    }

    @isTest
    static void classify_vcfTextAttachment_isDroppedNotCsv() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                textAttachment('contact.vcf', 'x-vcard', 'BEGIN:VCARD...')
            });

        Assert.areEqual(0, result.retainedCount, 'A vCard is not a CSV and must be dropped (G3)');
        Assert.isNotNull(result.droppedNotes, 'The drop must be recorded, never silent');
        Assert.isTrue(result.droppedNotes.contains('contact.vcf'), 'The drop line must name the file. Actual: ' + result.droppedNotes);
    }

    @isTest
    static void classify_icsCalendarInviteTextAttachment_isDroppedNotCsv() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                textAttachment('invite.ics', 'calendar', 'BEGIN:VCALENDAR...')
            });

        Assert.areEqual(0, result.retainedCount, 'A calendar invite is not a CSV and must be dropped (G3)');
    }

    @isTest
    static void classify_disallowedBinaryType_isDroppedWithTypeNotAllowedReason() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('installer.exe', 'x-msdownload', 10000)
            });

        Assert.areEqual(0, result.retainedCount, 'An executable must never be retained');
        Assert.isTrue(result.droppedNotes.contains('installer.exe'), 'Actual: ' + result.droppedNotes);
    }

    @isTest
    static void classify_noContentAttachment_isDroppedWithNoContentReason() {
        InboundEmailAttachmentService.AttachmentRequest empty =
            new InboundEmailAttachmentService.AttachmentRequest();
        empty.fileName = 'ghost.pdf';
        empty.mimeSubType = 'pdf';
        // Deliberately no body AND no textBody.

        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{ empty });

        Assert.areEqual(0, result.retainedCount, 'A candidate with neither a Blob body nor text content must be dropped');
        Assert.isTrue(result.droppedNotes.contains('ghost.pdf'), 'Actual: ' + result.droppedNotes);
    }

    // ── classify() — the image floor (G2) ─────────────────────────────────────

    @isTest
    static void classify_pngUnder20KB_isDroppedAsLikelySignatureLogo() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('logo.png', 'png', InboundEmailAttachmentService.IMAGE_MIN_BYTES - 1)
            });

        Assert.areEqual(0, result.retainedCount, 'A sub-floor PNG must be dropped (G2)');
        Assert.isTrue(result.droppedNotes.contains('logo.png'), 'Actual: ' + result.droppedNotes);
    }

    @isTest
    static void classify_pngAtExactlyTheImageFloor_isRetained() {
        // The check is `bytes < IMAGE_MIN_BYTES`, so a file AT the floor must survive.
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('photo.png', 'png', InboundEmailAttachmentService.IMAGE_MIN_BYTES)
            });

        Assert.areEqual(1, result.retainedCount, 'A PNG exactly AT IMAGE_MIN_BYTES must be retained, not dropped');
    }

    @isTest
    static void classify_pngAboveTheImageFloor_isRetained() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('photo.png', 'png', InboundEmailAttachmentService.IMAGE_MIN_BYTES + 1000)
            });

        Assert.areEqual(1, result.retainedCount, 'A PNG above IMAGE_MIN_BYTES must be retained');
    }

    @isTest
    static void classify_nonImageUnderTwentyKB_isNotSubjectToTheImageFloor() {
        // The floor is IMAGES ONLY (G2). A small PDF is legitimate and must not be dropped
        // by a rule that exists to catch signature logos.
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('short-loi.pdf', 'pdf', InboundEmailAttachmentService.IMAGE_MIN_BYTES - 1)
            });

        Assert.areEqual(1, result.retainedCount, 'IMAGE_MIN_BYTES must apply to images only, never to a non-image type');
    }

    // ── classify() — the per-file size ceiling ────────────────────────────────

    @isTest
    static void classify_fileOverAttachmentMaxBytes_isDropped() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('huge.pdf', 'pdf', InboundEmailAttachmentService.ATTACHMENT_MAX_BYTES + 1)
            });

        Assert.areEqual(0, result.retainedCount, 'A file over ATTACHMENT_MAX_BYTES must be dropped');
        Assert.isTrue(result.droppedNotes.contains('huge.pdf'), 'Actual: ' + result.droppedNotes);
    }

    @isTest
    static void classify_fileAtExactlyAttachmentMaxBytes_isRetained() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('exactly-max.pdf', 'pdf', InboundEmailAttachmentService.ATTACHMENT_MAX_BYTES)
            });

        Assert.areEqual(1, result.retainedCount, 'A file exactly AT the ceiling must be retained, not dropped (the check is strictly greater-than)');
    }

    // ── classify() — TEXT_MAX_BYTES, the HEAP bound on the one allocating path ─

    /**
     * 🔴 THE HEAP-SAFETY BOUNDARY, ADDED IN CODE REVIEW 2026-08-05. This is the highest-stakes
     * assertion in this class, so it is worth stating what it protects.
     *
     * A retained TEXT attachment is converted with `Blob.valueOf(att.textBody)` in persist(),
     * and at that instant heap holds the source String AND an equal-sized Blob — 2x the file.
     * A BINARY attachment costs ~0 by comparison, because the platform already holds its Blob
     * before our first line runs. Under the original single `ATTACHMENT_MAX_BYTES = 5000000`
     * ceiling a 3.5 MB CSV rent roll was RETAINED (HEAP_HEADROOM_FLOOR saw only ~3.6 MB, under
     * its 4,000,000 floor) and then added ~3.5 MB in persist for ~7.1 MB against the 6 MB
     * SYNCHRONOUS limit. `System.LimitException` is UNCATCHABLE, so EmailToLeadHandler's catch
     * would never run, `result.success` would never be set, the staging insert would roll back,
     * and the Email Service would DISCARD the message — destroying the Lead, the registry
     * claim, the Task and the audit trail with no row anywhere recording the email existed.
     *
     * If this test is ever "simplified" to reuse ATTACHMENT_MAX_BYTES, that failure returns.
     *
     * THE "AND THE EMAIL STILL ROUTES" HALF IS ALREADY PINNED, at the handler level, by
     * `EmailToLeadHandlerTest.handleInboundEmail_vCardTextAttachment_isDroppedAndRecorded`:
     * a dropped TEXT attachment takes the IDENTICAL post-drop path regardless of WHICH rule
     * dropped it (staging row still created, zero ContentVersions, no throw, routing
     * unaffected). Only the recorded REASON differs, and that is what is asserted below.
     * Duplicating it here would require materializing a >1 MB String in the test itself —
     * heap-risky in a 6 MB synchronous context, and it would prove nothing new.
     */
    @isTest
    static void classify_textAttachmentOverTextMaxBytes_isDroppedWithTheReasonRecorded() {
        // byteSize is what classify() reads (see the class header), so the boundary is
        // expressed without allocating a megabyte of throwaway String in the test itself.
        InboundEmailAttachmentService.AttachmentRequest huge =
            textAttachment('giant-rentroll.csv', 'csv', 'unit,rent\n101,1200');
        huge.byteSize = InboundEmailAttachmentService.TEXT_MAX_BYTES + 1;

        InboundEmailAttachmentService.ClassificationResult result =
            InboundEmailAttachmentService.classify(
                new List<InboundEmailAttachmentService.AttachmentRequest>{ huge });

        Assert.areEqual(0, result.retainedCount,
            'A text attachment over TEXT_MAX_BYTES must be DROPPED — retaining it would allocate '
            + 'a second copy in heap and could kill the whole email with an uncatchable LimitException');
        Assert.isNotNull(result.droppedNotes, 'The drop must be RECORDED, never silent');
        Assert.isTrue(result.droppedNotes.contains('giant-rentroll.csv'),
            'The dropped note must name the file. Actual: ' + result.droppedNotes);
        Assert.isTrue(result.droppedNotes.contains('TEXT_MAX_BYTES'),
            'The dropped note must give the HEAP reason, not a generic size reason, so an operator '
            + 'can tell this apart from an ordinary oversize drop. Actual: ' + result.droppedNotes);
    }

    @isTest
    static void classify_textAttachmentAtExactlyTextMaxBytes_isRetained() {
        InboundEmailAttachmentService.AttachmentRequest atLimit =
            textAttachment('rentroll-at-limit.csv', 'csv', 'unit,rent\n101,1200');
        atLimit.byteSize = InboundEmailAttachmentService.TEXT_MAX_BYTES;

        InboundEmailAttachmentService.ClassificationResult result =
            InboundEmailAttachmentService.classify(
                new List<InboundEmailAttachmentService.AttachmentRequest>{ atLimit });

        Assert.areEqual(1, result.retainedCount,
            'A text attachment exactly AT the ceiling must be retained — the check is strictly '
            + 'greater-than, matching every other cap in this class');
    }

    @isTest
    static void classify_binaryAttachmentAboveTextMaxBytes_isStillRetained() {
        // The two ceilings are SEPARATE on purpose. A 2 MB PDF is fine (its Blob is already
        // resident); a 2 MB CSV is not (it would be copied). If someone ever collapses the two
        // constants, this test and the one above cannot both pass.
        InboundEmailAttachmentService.ClassificationResult result =
            InboundEmailAttachmentService.classify(
                new List<InboundEmailAttachmentService.AttachmentRequest>{
                    binaryAttachment('big-om.pdf', 'pdf',
                        InboundEmailAttachmentService.TEXT_MAX_BYTES + 1)
                });

        Assert.areEqual(1, result.retainedCount,
            'TEXT_MAX_BYTES must apply to TEXT attachments ONLY — a binary file of the same size '
            + 'costs ~0 additional heap and must still be retained');
    }

    // ── classify() — MAX_ATTACHMENTS, the slot-based cap (3 since 2026-08-06) ─

    @isTest
    static void classify_fourFiles_thirdRetainedFourthDroppedByCountCap() {
        // 🔴 RE-PINNED 2026-08-06: MAX_ATTACHMENTS is 3, not 10 (user decision, design §2.1).
        // This test used to send 11 files expecting a cap at 10; it is rewritten, not merely
        // re-valued, because the OLD shape (11 candidates) would now drop 8 of them and the old
        // "9th survives, 10th does not" boundary assertions would be meaningless at this cap.
        List<InboundEmailAttachmentService.AttachmentRequest> candidates =
            new List<InboundEmailAttachmentService.AttachmentRequest>();
        for (Integer i = 0; i < 4; i++) {
            candidates.add(binaryAttachment('file' + i + '.pdf', 'pdf', 1000));
        }

        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(candidates);

        Assert.areEqual(3, result.retainedCount, 'Only MAX_ATTACHMENTS (3) may be retained');
        Assert.areEqual(3, InboundEmailAttachmentService.MAX_ATTACHMENTS, 'Precondition: pins the constant itself, so this test goes red the moment the cap value changes again');
        Assert.isTrue(result.droppedNotes.contains('file3.pdf'),
            'The 4th (zero-indexed file3) must be the one dropped, since content-based checks run before the count cap. Actual: '
            + result.droppedNotes);
        Assert.isTrue(result.droppedNotes.contains(InboundEmailAttachmentService.REASON_COUNT_CAP),
            'The overflow must be dropped WITH THE COUNT-CAP REASON, visibly — never silent. Actual: ' + result.droppedNotes);
        Assert.isFalse(result.droppedNotes.contains('file2.pdf'),
            'The 3rd file (file2, zero-indexed) fits inside the cap and must NOT be dropped');
    }

    @isTest
    static void classify_ineligibleFileDoesNotConsumeARetentionSlot() {
        // The order of checks is deliberate (see classify()'s header comment): content-based
        // rejections run BEFORE the slot-based cap, so an ineligible file never masks an
        // eligible one. Three eligible PDFs plus ONE ineligible .exe (4 candidates total) must
        // still retain all three PDFs — the .exe must not "use up" the 3rd slot.
        List<InboundEmailAttachmentService.AttachmentRequest> candidates =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachment('ignored.exe', 'x-msdownload', 1000)
            };
        for (Integer i = 0; i < 3; i++) {
            candidates.add(binaryAttachment('file' + i + '.pdf', 'pdf', 1000));
        }

        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(candidates);

        Assert.areEqual(3, result.retainedCount, 'All 3 eligible PDFs must survive despite the ineligible 4th candidate');
    }

    // ── classify() — the dynamic heap guard ───────────────────────────────────

    @isTest
    static void classify_heapAboveHeadroomFloor_dropsEveryRemainingCandidate() {
        InboundEmailAttachmentService.heapSizeOverride =
            InboundEmailAttachmentService.HEAP_HEADROOM_FLOOR + 1;
        try {
            InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
                new List<InboundEmailAttachmentService.AttachmentRequest>{
                    binaryAttachment('one.pdf', 'pdf', 1000),
                    binaryAttachment('two.pdf', 'pdf', 1000)
                });

            Assert.areEqual(0, result.retainedCount, 'Once the heap floor is exceeded, nothing further may be retained');
            Assert.isTrue(result.droppedNotes.contains('one.pdf') && result.droppedNotes.contains('two.pdf'),
                'BOTH candidates must be dropped for heap headroom — the guard is sticky within one classify() call. Actual: '
                + result.droppedNotes);
        } finally {
            InboundEmailAttachmentService.heapSizeOverride = null;
        }
    }

    @isTest
    static void classify_heapBelowHeadroomFloor_retainsNormally() {
        InboundEmailAttachmentService.heapSizeOverride = 100;
        try {
            InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
                new List<InboundEmailAttachmentService.AttachmentRequest>{
                    binaryAttachment('fine.pdf', 'pdf', 1000)
                });

            Assert.areEqual(1, result.retainedCount, 'Heap comfortably below the floor must not affect retention');
        } finally {
            InboundEmailAttachmentService.heapSizeOverride = null;
        }
    }

    // ── classify() — null / empty inputs ──────────────────────────────────────

    @isTest
    static void classify_nullCandidates_returnsEmptyZeroValuedResultNotException() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(null);

        Assert.isNotNull(result, 'Must never return null');
        Assert.areEqual(0, result.retainedCount, '');
        Assert.areEqual(0, result.retainedBytes, '');
        Assert.isNull(result.droppedNotes, '');
        Assert.areEqual(0, result.retained.size(), '');
    }

    @isTest
    static void classify_emptyCandidates_returnsEmptyResult() {
        InboundEmailAttachmentService.ClassificationResult result =
            InboundEmailAttachmentService.classify(new List<InboundEmailAttachmentService.AttachmentRequest>());

        Assert.areEqual(0, result.retainedCount, 'An empty candidate list yields nothing retained');
    }

    @isTest
    static void classify_nullEntryInList_isSkippedDefensively() {
        InboundEmailAttachmentService.ClassificationResult result = InboundEmailAttachmentService.classify(
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                null, binaryAttachment('real.pdf', 'pdf', 1000)
            });

        Assert.areEqual(1, result.retainedCount, 'A null entry must be skipped without throwing, and must not affect a real one alongside it');
    }

    // ── stageBytes() — NEW 2026-08-06, THE BYTE CARRIER ───────────────────────
    //
    // Zero ContentPublication cost: stageBytes writes classic `Attachment` rows only. See
    // design tests 19-21.

    @isTest
    static void stageBytes_twoRetainedFiles_writesOneBulkAttachmentInsert() {
        Inbound_Email_Staging__c staging = insertStaging('stagebytes-bulk');
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('om.pdf', 'pdf', 'OM CONTENT'),
                binaryAttachmentWithRealBody('rentroll.xlsx',
                    'vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'RENT ROLL CONTENT')
            };

        Test.startTest();
        List<Id> carrierIds = InboundEmailAttachmentService.stageBytes(staging.Id, retained);
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(2, carrierIds.size(), 'Both retained files must be staged as carriers');
        Assert.areEqual(2, [SELECT COUNT() FROM Attachment WHERE ParentId = :staging.Id], '');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion],
            'stageBytes must NEVER insert a ContentVersion — it is the ONE file-related call left '
            + 'inside the transaction that owns the email');
        Assert.areEqual(1, dmlUsed,
            'GOVERNOR BUDGET: ONE bulk Database.insert(attachments, false) regardless of file count');
    }

    @isTest
    static void stageBytes_csvTextAttachment_convertsToBlobUnderTextMaxBytes() {
        // The relocated TEXT_MAX_BYTES guard (design §2.1): the Blob.valueOf(textBody)
        // allocation now happens HERE, synchronously, not in persist().
        Inbound_Email_Staging__c staging = insertStaging('stagebytes-csv');
        String csvBody = 'unit,rent\n101,1200\n102,1350';
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                textAttachment('rentroll.csv', 'csv', csvBody)
            };

        Test.startTest();
        List<Id> carrierIds = InboundEmailAttachmentService.stageBytes(staging.Id, retained);
        Test.stopTest();

        Assert.areEqual(1, carrierIds.size(), 'The CSV text attachment must be staged as a carrier');
        Attachment carrier = [SELECT Body, Name FROM Attachment WHERE Id = :carrierIds[0]];
        Assert.areEqual(csvBody, carrier.Body.toString(),
            'The text body must be converted to a Blob via Blob.valueOf and stored byte-identically');
        Assert.areEqual('rentroll.csv', carrier.Name, '');
    }

    @isTest
    static void stageBytes_nullOrEmptyRetained_returnsEmptyListWithNoDml() {
        Inbound_Email_Staging__c staging = insertStaging('stagebytes-empty');

        Test.startTest();
        List<Id> fromNull = InboundEmailAttachmentService.stageBytes(staging.Id, null);
        List<Id> fromEmpty = InboundEmailAttachmentService.stageBytes(
            staging.Id, new List<InboundEmailAttachmentService.AttachmentRequest>());
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), '');
        Assert.areEqual(0, fromEmpty.size(), '');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment WHERE ParentId = :staging.Id],
            'Nothing retained must mean zero carrier DML — the feature is provably zero-cost on an ordinary email');
    }

    @isTest
    static void stageBytes_nullStagingId_isANoOp() {
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('orphan.pdf', 'pdf', 'ORPHAN CONTENT')
            };

        Test.startTest();
        List<Id> carrierIds = InboundEmailAttachmentService.stageBytes(null, retained);
        Test.stopTest();

        Assert.areEqual(0, carrierIds.size(), 'A null stagingId must short-circuit to an empty list, never throw');
        Assert.areEqual(0, [SELECT COUNT() FROM Attachment], '');
    }

    @isTest
    static void stageBytes_carrierInsertRefused_isRecordedAsTerminalNotSavedAndDoesNotThrow() {
        // A deterministic, genuine DML refusal (not a seam): the staging row is hard-deleted
        // between createStaging and stageBytes, so ParentId points at a row that no longer
        // exists. stageBytes must never throw, and — because a carrier that was never written
        // can never be retried — the terminal Not_Saved status is the correct outcome (design §7:
        // one of only three TERMINAL modes).
        Inbound_Email_Staging__c staging = insertStaging('stagebytes-refused');
        Id deletedStagingId = staging.Id;
        delete staging;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ staging });

        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('doomed.pdf', 'pdf', 'DOOMED CONTENT')
            };

        Boolean threw = false;
        List<Id> carrierIds;
        try {
            Test.startTest();
            carrierIds = InboundEmailAttachmentService.stageBytes(deletedStagingId, retained);
            Test.stopTest();
        } catch (Exception e) {
            threw = true;
        }

        Assert.isFalse(threw, 'stageBytes MUST NOT THROW under any input — it is the one file-related call left at the boundary');
        Assert.areEqual(0, carrierIds.size(), 'A refused carrier insert must never be reported as stored');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'No ContentVersion may exist — this path never reaches persist()');
    }

    // ── persist() — DML, MUST NOT THROW ───────────────────────────────────────

    @isTest
    static void persist_retainedFiles_insertsContentVersionsAndLinksToStaging() {
        Inbound_Email_Staging__c staging = insertStaging('persist-happy');
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('om.pdf', 'pdf', 'PDF FILE CONTENT ONE'),
                binaryAttachmentWithRealBody('rentroll.xlsx',
                    'vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'XLSX FILE CONTENT TWO')
            };

        Test.startTest();
        List<Id> documentIds = InboundEmailAttachmentService.persist(staging.Id, retained);
        Test.stopTest();

        Assert.areEqual(2, documentIds.size(), 'Both retained files must be persisted and their ContentDocumentIds returned');
        Assert.areEqual(2, [SELECT COUNT() FROM ContentVersion WHERE Title IN ('om.pdf', 'rentroll.xlsx')],
            'Exactly one ContentVersion per retained file');

        List<ContentDocumentLink> stagingLinks = [
            SELECT ContentDocumentId, ShareType, Visibility FROM ContentDocumentLink
            WHERE LinkedEntityId = :staging.Id
        ];
        Assert.areEqual(2, stagingLinks.size(), 'Both files must be linked to the staging row synchronously');
        for (ContentDocumentLink link : stagingLinks) {
            Assert.areEqual('V', link.ShareType, 'Decision C2: the STAGING link uses Viewer, never Inferred');
            Assert.areEqual('AllUsers', link.Visibility, '');
        }

        Assert.isTrue(InboundEmailAttachmentService.lastRunPersistFailures.isEmpty(),
            'A clean persist must record no failures');
    }

    @isTest
    static void persist_nullRetained_returnsEmptyListWithNoDml() {
        Inbound_Email_Staging__c staging = insertStaging('persist-null');

        Test.startTest();
        List<Id> documentIds = InboundEmailAttachmentService.persist(staging.Id, null);
        Test.stopTest();

        Assert.areEqual(0, documentIds.size(), 'null retained must short-circuit to an empty list');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'No ContentVersion may be inserted when nothing was retained');
    }

    @isTest
    static void persist_emptyRetained_returnsEmptyListWithNoDml() {
        Inbound_Email_Staging__c staging = insertStaging('persist-empty');

        Test.startTest();
        List<Id> documentIds = InboundEmailAttachmentService.persist(
            staging.Id, new List<InboundEmailAttachmentService.AttachmentRequest>());
        Test.stopTest();

        Assert.areEqual(0, documentIds.size(), 'An empty retained list must short-circuit to an empty list');
    }

    @isTest
    static void persist_nullStagingId_stillPersistsFilesWithoutAStagingLink() {
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('orphan.pdf', 'pdf', 'ORPHAN FILE CONTENT')
            };

        Test.startTest();
        List<Id> documentIds = InboundEmailAttachmentService.persist(null, retained);
        Test.stopTest();

        Assert.areEqual(1, documentIds.size(), 'A null stagingId must not stop the FILE itself from being saved');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'orphan.pdf'], '');
    }

    @isTest
    static void persist_forcePersistFailureSeam_neverThrowsAndRecordsTheFailureOnStaging() {
        Inbound_Email_Staging__c staging = insertStaging('persist-forced-failure');
        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('doomed.pdf', 'pdf', 'DOOMED FILE CONTENT')
            };

        InboundEmailAttachmentService.forcePersistFailure = true;
        List<Id> documentIds;
        try {
            Test.startTest();
            documentIds = InboundEmailAttachmentService.persist(staging.Id, retained);
            Test.stopTest();
        } finally {
            InboundEmailAttachmentService.forcePersistFailure = false;
        }

        Assert.areEqual(0, documentIds.size(), 'A forced failure must degrade to an empty list, never throw');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'Nothing was actually saved once the forced failure fired before any DML');
        Assert.isFalse(InboundEmailAttachmentService.lastRunPersistFailures.isEmpty(),
            'The failure must be captured in the in-transaction telemetry');

        Inbound_Email_Staging__c updated = [
            SELECT Dropped_Attachment_Notes__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.isNotNull(updated.Dropped_Attachment_Notes__c,
            'THE R1 LESSON: the failure must be RECORDED on the staging row (durable), never merely a System.debug');
        Assert.isTrue(updated.Dropped_Attachment_Notes__c.contains('attachment persistence failed'),
            'Actual: ' + updated.Dropped_Attachment_Notes__c);
    }

    @isTest
    static void persist_stagingRowNoLongerExists_savesTheFileAndRecordsTheLinkRefusal() {
        // A deterministic, genuine DML refusal (not a seam): the staging row is hard-deleted
        // between createStaging and persist(), so the staging ContentDocumentLink insert is
        // refused with INVALID_CROSS_REFERENCE_KEY. persist() must still save the file itself
        // and must not throw.
        Inbound_Email_Staging__c staging = insertStaging('persist-deleted-staging');
        Id deletedStagingId = staging.Id;
        delete staging;
        Database.emptyRecycleBin(new List<Inbound_Email_Staging__c>{ staging });

        List<InboundEmailAttachmentService.AttachmentRequest> retained =
            new List<InboundEmailAttachmentService.AttachmentRequest>{
                binaryAttachmentWithRealBody('survivor.pdf', 'pdf', 'SURVIVOR FILE CONTENT')
            };

        Test.startTest();
        List<Id> documentIds = InboundEmailAttachmentService.persist(deletedStagingId, retained);
        Test.stopTest();

        Assert.areEqual(1, documentIds.size(), 'The FILE itself must still be saved even though its staging link is refused');
        Assert.isFalse(InboundEmailAttachmentService.lastRunPersistFailures.isEmpty(),
            'The refused staging link must be recorded in the in-transaction telemetry');
        Boolean anyMentionsLinkRefused = false;
        for (String failure : InboundEmailAttachmentService.lastRunPersistFailures) {
            if (failure.contains('link refused')) {
                anyMentionsLinkRefused = true;
            }
        }
        Assert.isTrue(anyMentionsLinkRefused, 'Actual: ' + InboundEmailAttachmentService.lastRunPersistFailures);
    }

    // ── linkTo() — DML, MUST NOT THROW ────────────────────────────────────────

    @isTest
    static void linkTo_twoDocumentsAndTwoTargets_createsTheFullCrossProduct() {
        List<Id> documentIds = new List<Id>();
        for (ContentVersion cv : insertContentVersions(2)) {
            documentIds.add(cv.Id);
        }
        Set<Id> versionIds = new Set<Id>(documentIds);
        List<Id> contentDocumentIds = new List<Id>();
        for (ContentVersion cv : [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :versionIds]) {
            contentDocumentIds.add(cv.ContentDocumentId);
        }
        Lead leadOne = TestDataFactory.createLead(true);
        Lead leadTwo = TestDataFactory.createLead(true);

        Test.startTest();
        Integer created = InboundEmailAttachmentService.linkTo(
            contentDocumentIds, new List<Id>{ leadOne.Id, leadTwo.Id });
        Test.stopTest();

        Assert.areEqual(4, created, 'linkTo() creates the FULL N x F cross product: 2 files x 2 targets = 4 links, from ONE bulk statement');
        Assert.areEqual(4, [
            SELECT COUNT() FROM ContentDocumentLink
            WHERE ContentDocumentId IN :contentDocumentIds AND LinkedEntityId IN :new List<Id>{ leadOne.Id, leadTwo.Id }
        ], '');
        for (ContentDocumentLink link : [
            SELECT ShareType, Visibility FROM ContentDocumentLink
            WHERE ContentDocumentId IN :contentDocumentIds AND LinkedEntityId IN :new List<Id>{ leadOne.Id, leadTwo.Id }
        ]) {
            Assert.areEqual('I', link.ShareType, 'Decision C2: ROUTED-record links use Inferred, matching the platform\'s own lead-conversion carry-over links');
        }
    }

    @isTest
    static void linkTo_duplicateDocumentAndTargetIds_deduplicatesBeforeInserting() {
        List<Id> contentDocumentIds = contentDocumentIdsFor(1);
        Lead lead = TestDataFactory.createLead(true);

        Test.startTest();
        // Deliberately repeated Ids on both axes.
        Integer created = InboundEmailAttachmentService.linkTo(
            new List<Id>{ contentDocumentIds[0], contentDocumentIds[0] },
            new List<Id>{ lead.Id, lead.Id });
        Test.stopTest();

        Assert.areEqual(1, created, 'One document x one DISTINCT target must produce exactly ONE link, never a DUPLICATE_VALUE-triggering repeat');
    }

    @isTest
    static void linkTo_nullOrEmptyInputs_isANoOpReturningZero() {
        List<Id> contentDocumentIds = contentDocumentIdsFor(1);
        Lead lead = TestDataFactory.createLead(true);

        Test.startTest();
        Integer fromNullDocs = InboundEmailAttachmentService.linkTo(null, new List<Id>{ lead.Id });
        Integer fromEmptyDocs = InboundEmailAttachmentService.linkTo(new List<Id>(), new List<Id>{ lead.Id });
        Integer fromNullTargets = InboundEmailAttachmentService.linkTo(contentDocumentIds, null);
        Integer fromEmptyTargets = InboundEmailAttachmentService.linkTo(contentDocumentIds, new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, fromNullDocs, '');
        Assert.areEqual(0, fromEmptyDocs, '');
        Assert.areEqual(0, fromNullTargets, '');
        Assert.areEqual(0, fromEmptyTargets, '');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :lead.Id],
            'None of the four no-op calls may have inserted a link');
    }

    @isTest
    static void linkTo_oneInvalidDocumentId_recordsRefusalButStillLinksTheValidOne() {
        // A deterministic DML refusal: a real Lead Id assigned where a ContentDocumentId is
        // expected fails INVALID_CROSS_REFERENCE_KEY at DML time — not a seam, a genuine
        // platform rejection, exercising the exact shape decision C point 3 describes.
        List<Id> validDocumentIds = contentDocumentIdsFor(1);
        Lead wrongTypeId = TestDataFactory.createLead(true);
        Lead target = TestDataFactory.createLead(true);

        Test.startTest();
        Integer created = InboundEmailAttachmentService.linkTo(
            new List<Id>{ validDocumentIds[0], wrongTypeId.Id }, new List<Id>{ target.Id });
        Test.stopTest();

        Assert.areEqual(1, created, 'The VALID document must still link — one refusal must not cost the other link in the same bulk statement');
        Assert.isFalse(InboundEmailAttachmentService.lastLinkFailures().isEmpty(),
            'The refusal must be captured in the in-transaction telemetry');
        Assert.isTrue(InboundEmailAttachmentService.lastLinkFailures()[0].contains('link refused'),
            'Actual: ' + InboundEmailAttachmentService.lastLinkFailures());
    }

    @isTest
    static void lastLinkFailures_afterACleanRun_isEmptyNeverNull() {
        List<Id> contentDocumentIds = contentDocumentIdsFor(1);
        Lead lead = TestDataFactory.createLead(true);

        Test.startTest();
        InboundEmailAttachmentService.linkTo(contentDocumentIds, new List<Id>{ lead.Id });
        Test.stopTest();

        Assert.isNotNull(InboundEmailAttachmentService.lastLinkFailures(), 'Must never return null');
        Assert.isTrue(InboundEmailAttachmentService.lastLinkFailures().isEmpty(), 'A clean run must have no refusals');
    }

    // ── isImageAttachment() ────────────────────────────────────────────────────

    @isTest
    static void isImageAttachment_byMimeSubtype_isTrue() {
        Assert.isTrue(InboundEmailAttachmentService.isImageAttachment('png', null), '');
        Assert.isTrue(InboundEmailAttachmentService.isImageAttachment('image/jpeg', null), 'A qualified MIME subtype must also match');
    }

    @isTest
    static void isImageAttachment_byExtensionOnlyWhenMimeIsUnreliable_isTrue() {
        Assert.isTrue(InboundEmailAttachmentService.isImageAttachment('octet-stream', 'photo.jpg'),
            'G1 union: the filename extension alone must be enough when the MIME subtype is not image-shaped');
    }

    @isTest
    static void isImageAttachment_neitherSignalMatches_isFalse() {
        Assert.isFalse(InboundEmailAttachmentService.isImageAttachment('pdf', 'document.pdf'), '');
        Assert.isFalse(InboundEmailAttachmentService.isImageAttachment(null, null), '');
    }

    // ── describeDrop() ──────────────────────────────────────────────────────────

    @isTest
    static void describeDrop_normalAttachment_formatsThePipeDelimitedLine() {
        InboundEmailAttachmentService.AttachmentRequest att = binaryAttachment('doc.pdf', 'pdf', 12345);

        String line = InboundEmailAttachmentService.describeDrop(att, 'test reason');

        Assert.areEqual('doc.pdf | pdf | 12345 | test reason', line, '');
    }

    @isTest
    static void describeDrop_nullAttachment_returnsUnknownPlaceholderLine() {
        String line = InboundEmailAttachmentService.describeDrop(null, 'test reason');

        Assert.areEqual('unknown | unknown | 0 | test reason', line, '');
    }

    @isTest
    static void describeDrop_blankFileNameAndMime_usesPlaceholders() {
        InboundEmailAttachmentService.AttachmentRequest att =
            new InboundEmailAttachmentService.AttachmentRequest();
        att.byteSize = 500;

        String line = InboundEmailAttachmentService.describeDrop(att, 'test reason');

        Assert.areEqual('(no filename) | (no mime) | 500 | test reason', line, '');
    }

    // ── shared content fixtures ────────────────────────────────────────────────

    private static List<ContentVersion> insertContentVersions(Integer count) {
        List<ContentVersion> versions = new List<ContentVersion>();
        for (Integer i = 0; i < count; i++) {
            versions.add(new ContentVersion(
                Title = 'Fixture ' + i, PathOnClient = 'fixture' + i + '.pdf',
                VersionData = Blob.valueOf('fixture body ' + i)
            ));
        }
        insert versions;
        return versions;
    }

    private static List<Id> contentDocumentIdsFor(Integer count) {
        List<ContentVersion> versions = insertContentVersions(count);
        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion cv : versions) {
            versionIds.add(cv.Id);
        }
        List<Id> documentIds = new List<Id>();
        for (ContentVersion cv : [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :versionIds]) {
            documentIds.add(cv.ContentDocumentId);
        }
        return documentIds;
    }
}
