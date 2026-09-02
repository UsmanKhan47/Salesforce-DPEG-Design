/**
 * Tests for `ChecklistCaptureService` — context resolution and provisioning, the completion guard,
 * and per-item document filing.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 CONTENT VOLUME IS 5 ROWS IN THE WHOLE CLASS, NOT 251 — DELIBERATE, AND NOT NEGOTIABLE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `.claude/rules/content-publication-rule.md` caps a DML-path content test at 1-3 rows per method
 * and targets 30 per class, and it overrides `.claude/rules/bulk-test-rule.md`'s 251 mandate for
 * `ContentVersion` / `ContentNote` / `ContentDocument` specifically. Every `ContentVersion` insert
 * consumes one of the org's 2,500-per-rolling-24-hours `ContentPublication` allowance; TEST
 * ROLLBACK DOES NOT REFUND IT; `Limits` cannot see it; and an overrun throws a
 * `System.UnexpectedException` that has been measured here to escape `catch (Exception)` and to be
 * ignored by `Database.insert(records, false)`, aborting the whole transaction. It caused a
 * production outage on 2026-08-06.
 *
 * The five rows are spent as follows, one fact each:
 *   1 — a linked document satisfies the C7/G6 guard;
 *   1 — the guard refuses when the document is linked to the DEAL but not to the ITEM;
 *   1 — re-linking the same document is idempotent rather than DUPLICATE_VALUE;
 *   2 — an upload event carrying TWO documents links both, which one row cannot prove.
 * Nothing here needs a sixth. ⚠ Do not add rows "for volume": a guard that reads links behaves
 * identically at 5 rows and at 251, and the cost of the extra 246 is real, shared and permanent.
 *
 * ✅ THE BULK PROOF FOR THIS CLASS IS DONE ON `Checklist_Item__c`, WHICH IS FREE. The 251-row
 * volume and cost-constancy tests below use 251 CHECKLIST ITEMS with zero content rows, which is
 * exactly where the guard's scaling risk lives (a read moved inside the item loop).
 */
@isTest
private class ChecklistCaptureServiceTest {

    private static final Integer BULK_ITEMS = 251;

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Context resolution and provisioning
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void contextForAFieldCaptureProvisionsTheTargetAndNamesItsFields() {
        Transaction__c deal = newDeal();
        Checklist_Item__c f9 = itemAt(deal.Id, 'F', 9);
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c],
            'Control: the Loan__c does not exist until a capture dialog is opened');

        Test.startTest();
        Map<Id, ChecklistCaptureService.CaptureContext> contexts = contextFor(f9.Id);
        Test.stopTest();

        ChecklistCaptureService.CaptureContext context = contexts.get(f9.Id);
        Assert.isNotNull(context, 'F9 records the bank account type and must return a context');
        Assert.areEqual(ChecklistCaptureDefProvider.CaptureMode.TARGET_FIELDS, context.captureMode,
            'F9 is a field capture');
        Assert.areEqual('Loan__c', context.targetObject, 'written onto the deal loan');
        Assert.areEqual(1, [SELECT COUNT() FROM Loan__c],
            'and opening the dialog PROVISIONED exactly one Loan__c');
        Assert.areEqual(
            [SELECT Id FROM Loan__c LIMIT 1].Id, context.targetRecordId,
            'The context points at that provisioned record, so the record-edit-form binds to it '
                + 'rather than silently becoming a CREATE form'
        );
        Assert.areEqual(new List<String>{ 'Bank_Account_Type__c' }, context.captureFields,
            'and offers exactly the field the step is about');
        Assert.areEqual(false, context.satisfied, 'which is blank, so the requirement is not met');
    }

    @isTest
    static void contextForAnInsuranceCaptureProvisionsABinder() {
        Transaction__c deal = newDeal();
        Checklist_Item__c g5 = itemAt(deal.Id, 'G', 5);

        Test.startTest();
        ChecklistCaptureService.CaptureContext context = contextFor(g5.Id).get(g5.Id);
        Test.stopTest();

        Assert.areEqual('Insurance_Binder__c', context.targetObject, 'G5 binds coverage');
        Assert.areEqual(1, [SELECT COUNT() FROM Insurance_Binder__c], 'and provisions the binder');
        Assert.areEqual('Bound_Date__c', context.requiredField,
            'The BOUND DATE is what must be recorded — Is_Bound__c is a formula over it and could '
                + 'never be entered by anyone');
        Assert.isFalse(context.captureFields.contains('Is_Bound__c'),
            'and the formula must not be offered in the form, which would fail the save');
    }

    @isTest
    static void contextForADocumentCapturePointsAtTheDealNotTheItem() {
        // "Upload PCR to deal document folder" — the FILE belongs to the deal. The per-item link is
        // added afterwards by `linkDocumentsToItems`, which is what gives the guard something
        // item-specific to check.
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAt(deal.Id, 'C', 7);

        Test.startTest();
        ChecklistCaptureService.CaptureContext context = contextFor(c7.Id).get(c7.Id);
        Test.stopTest();

        Assert.areEqual(ChecklistCaptureDefProvider.CaptureMode.DOCUMENT, context.captureMode,
            'C7 is a document capture');
        Assert.areEqual(deal.Id, context.targetRecordId,
            'and the upload targets the DEAL, which is what the deal document folder means');
        Assert.areEqual(false, context.satisfied, 'no document is on file yet');
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c],
            'A document capture must not provision a financing record as a side effect');
    }

    @isTest
    static void contextForADerivedItemProvisionsNothingAndIsAlwaysSatisfied() {
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAt(deal.Id, 'A', 5);

        Test.startTest();
        ChecklistCaptureService.CaptureContext context = contextFor(a5.Id).get(a5.Id);
        Test.stopTest();

        Assert.areEqual(ChecklistCaptureDefProvider.CaptureMode.DERIVED, context.captureMode,
            'A5 is derived — the server logs the dates, the user types nothing');
        Assert.isNull(context.targetRecordId, 'so there is no record for a form to bind to');
        Assert.areEqual(true, context.satisfied, 'and nothing for the user to satisfy');
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c], 'Nothing was provisioned');
    }

    @isTest
    static void contextForAnUnmappedItemIsAbsentRatherThanEmpty() {
        // Absent, not an empty context: the LWC reads a missing entry as "use the ordinary confirm
        // dialog", and an empty capture form would be a dead end with no fields and no upload.
        Transaction__c deal = newDeal();
        Checklist_Item__c ordinary = itemAt(deal.Id, 'D', 3);

        Test.startTest();
        Map<Id, ChecklistCaptureService.CaptureContext> contexts = contextFor(ordinary.Id);
        Test.stopTest();

        Assert.isTrue(contexts.isEmpty(), '64 of the 82 items record nothing, and that is normal');
    }

    @isTest
    static void contextForIsIdempotentAcrossTheFourLoanDialogs() {
        // F5, F6, F9 and F12 are four separate dialogs on one deal. All four must land on ONE
        // Loan__c, or the four captures scatter across four records and none of them is the deal.
        Transaction__c deal = newDeal();
        Checklist__c groupF = checklistFor(deal.Id, 'F');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(12, groupF.Id, true);

        Test.startTest();
        Set<Id> targets = new Set<Id>();
        for (Integer sequence : new List<Integer>{ 5, 6, 9, 12 }) {
            Checklist_Item__c item = items[sequence - 1];
            targets.add(contextFor(item.Id).get(item.Id).targetRecordId);
        }
        Test.stopTest();

        Assert.areEqual(1, targets.size(), 'All four dialogs bind to the SAME Loan__c');
        Assert.areEqual(1, [SELECT COUNT() FROM Loan__c], 'and only one row exists');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // The completion guard
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void guardRefusesAFieldCaptureWithNothingRecorded() {
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAt(deal.Id, 'F', 5);
        insert new Loan__c(Transaction__c = deal.Id);

        Test.startTest();
        String message = refusalFrom(f5.Id);
        Test.stopTest();

        Assert.isNotNull(message, 'F5 selects the lender and must not close without one');
        Assert.isTrue(message.containsIgnoreCase('lender'),
            'The refusal must NAME the missing output — a generic "try again" can never be acted '
                + 'on, and was actual: ' + message);
    }

    @isTest
    static void guardAcceptsAFieldCaptureOnceItIsRecorded() {
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAt(deal.Id, 'F', 5);
        insert new Loan__c(Transaction__c = deal.Id, Lender_Name__c = 'First Bank');

        Test.startTest();
        String message = refusalFrom(f5.Id);
        Test.stopTest();

        Assert.isNull(message, 'With the lender on file the completion is allowed, was: ' + message);
    }

    @isTest
    static void guardTreatsABlankStringAsNothingRecorded() {
        // ⚠ `lightning-record-edit-form` sends an emptied Text field as '' rather than null, so a
        // plain null check would accept a lender whose name was typed and then deleted. Whitespace
        // is the same case.
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAt(deal.Id, 'F', 5);
        insert new Loan__c(Transaction__c = deal.Id, Lender_Name__c = '   ');

        Test.startTest();
        String message = refusalFrom(f5.Id);
        Test.stopTest();

        Assert.isNotNull(message, 'A lender name of spaces is not a lender name');
    }

    @isTest
    static void guardRefusesWhenTheTargetRecordDoesNotExistAtAll() {
        // 🔴 FAIL CLOSED. `Loan__c` is Private OWD with an ordinary lookup, so unlike a checklist
        // item its visibility does NOT follow the deal. An unresolvable target must read as "the
        // value is not on file", never be waved through on the strength of a query that returned
        // nothing.
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAt(deal.Id, 'F', 5);

        Test.startTest();
        String message = refusalFrom(f5.Id);
        Test.stopTest();

        Assert.isNotNull(message, 'No Loan__c at all is not the same as a satisfied requirement');
    }

    @isTest
    static void guardAllowsAnOptionalCaptureWithNothingRecorded() {
        // F11 offers the commitment date but does not require it — the lender may not have issued
        // its commitment on the day the company agreement goes out. A requirement here would make
        // the item impossible to complete truthfully.
        Transaction__c deal = newDeal();
        Checklist_Item__c f11 = itemAt(deal.Id, 'F', 11);
        insert new Loan__c(Transaction__c = deal.Id);

        Test.startTest();
        String message = refusalFrom(f11.Id);
        Test.stopTest();

        Assert.isNull(message, 'F11 is an optional capture, was refused with: ' + message);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 PICKLIST COORDINATES — the satisfied/unsatisfied pair per coordinate.
    //
    // Until 2026-09-02 the guard was exercised only at F5 (Text), F11 (optional) and G5 (Date),
    // so NO picklist coordinate was tested at all — and that is precisely where it was broken.
    // `Auto_Payment_Status__c` defaults to `Not Set Up`, so the platform stamps a value at insert
    // and a "non-blank?" test passed on a loan nobody had touched. Every picklist coordinate now
    // carries both halves of the pair.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void guardRefusesF12OnAFreshlyProvisionedLoan() {
        // 🔴 THE REGRESSION TEST FOR THE VACUOUS GUARD. No hand-set field value anywhere in this
        // test: the loan is created exactly as `LoanService.ensureFor` creates it, so the platform
        // default is what is being asserted against.
        Transaction__c deal = newDeal();
        Checklist_Item__c f12 = itemAt(deal.Id, 'F', 12);
        LoanService.ensureFor(new Set<Id>{ deal.Id });
        Assert.areEqual('Not Set Up',
            [SELECT Auto_Payment_Status__c FROM Loan__c WHERE Transaction__c = :deal.Id LIMIT 1]
                .Auto_Payment_Status__c,
            'Fixture control: the PLATFORM stamped the default, nothing in this test did');

        Test.startTest();
        String message = refusalFrom(f12.Id);
        Test.stopTest();

        Assert.isNotNull(message,
            'Not Set Up is the state meaning the step did not happen. Accepting it made the two '
                + 'items the business calls most frequently missed permanently completable with '
                + 'nothing recorded, from the moment ANY other group F dialog was opened');
        Assert.isTrue(message.containsIgnoreCase('Active'),
            'and the refusal must name the value that WOULD satisfy it, was: ' + message);
    }

    @isTest
    static void guardRefusesEveryNonActiveAutoPaymentValue() {
        // Requested is a mandate asked for, not a mandate running - the exact "frequently missed"
        // gap. Failed is a recorded outcome, not a completed setup; closing the item over a bank
        // rejection is what leaving it unsatisfying prevents.
        for (String value : new List<String>{ 'Not Set Up', 'Requested', 'Failed' }) {
            Transaction__c deal = newDeal();
            Checklist_Item__c f12 = itemAt(deal.Id, 'F', 12);
            insert new Loan__c(Transaction__c = deal.Id, Auto_Payment_Status__c = value);

            Assert.isNotNull(refusalFrom(f12.Id),
                'Auto_Payment_Status__c = ' + value + ' means the payment is not running, so F12 '
                    + 'must not close');
        }
    }

    @isTest
    static void guardAcceptsF12OnceThePaymentIsActive() {
        // The positive half. Without it the pair above could pass on a guard that refused
        // EVERYTHING, which would be a different and equally broken control.
        Transaction__c deal = newDeal();
        Checklist_Item__c f12 = itemAt(deal.Id, 'F', 12);
        insert new Loan__c(Transaction__c = deal.Id, Auto_Payment_Status__c = 'Active');

        Test.startTest();
        String message = refusalFrom(f12.Id);
        Test.stopTest();

        Assert.isNull(message, 'Active is the one value that closes F12, was: ' + message);
    }

    @isTest
    static void j4CarriesTheSameNarrowingAsF12() {
        // J4 is the post-closing revisit of F12, writing the SAME field on the SAME Loan__c. A
        // narrowing applied to one and not the other would leave the post-closing half vacuous,
        // which is the half nobody watches.
        Transaction__c deal = newDeal();
        Checklist_Item__c j4 = itemAt(deal.Id, 'J', 4);
        insert new Loan__c(Transaction__c = deal.Id, Auto_Payment_Status__c = 'Requested');

        Test.startTest();
        String refused = refusalFrom(j4.Id);
        update new Loan__c(
            Id = [SELECT Id FROM Loan__c WHERE Transaction__c = :deal.Id LIMIT 1].Id,
            Auto_Payment_Status__c = 'Active'
        );
        String allowed = refusalFrom(j4.Id);
        Test.stopTest();

        Assert.isNotNull(refused, 'J4 refuses Requested exactly as F12 does');
        Assert.isNull(allowed, 'and accepts Active, was: ' + allowed);
    }

    @isTest
    static void contextForF12ReportsUnsatisfiedOnAFreshLoan() {
        // 🔴 THE DIALOG HALF OF THE SAME DEFECT. `satisfied` drives whether the screen presents the
        // requirement as already met, so a vacuous guard ALSO told the user there was nothing to do
        // before they had started.
        Transaction__c deal = newDeal();
        Checklist_Item__c f12 = itemAt(deal.Id, 'F', 12);

        Test.startTest();
        ChecklistCaptureService.CaptureContext context = contextFor(f12.Id).get(f12.Id);
        Test.stopTest();

        Assert.areEqual(false, context.satisfied,
            'Opening the F12 dialog provisions the Loan__c and the platform stamps Not Set Up - '
                + 'the dialog must not then report the requirement as already met');
    }

    @isTest
    static void bankAccountTypeAcceptsAnyValueBecauseItHasNoDefault() {
        // 🔴 THE CONTROL THAT KEEPS THE NARROWING HONEST. `Bank_Account_Type__c` carries no
        // `<default>true</default>`, so blank genuinely means "not selected" and every declared
        // value is a real answer. Narrowing it too would refuse a correct selection. The divergence
        // between these two picklists is what exposed the F12 defect in the first place.
        Transaction__c deal = newDeal();
        Checklist_Item__c f9 = itemAt(deal.Id, 'F', 9);
        insert new Loan__c(Transaction__c = deal.Id, Bank_Account_Type__c = 'Other');

        Test.startTest();
        String message = refusalFrom(f9.Id);
        Test.stopTest();

        Assert.isNull(message,
            'Other is a real bank account type and must close F9, was: ' + message);
    }

    @isTest
    static void guardNeverProvisionsATargetRecord() {
        // 🔴 A GUARD WITH A SIDE EFFECT would leave an empty Loan__c behind on every refused
        // completion — one per attempt, on the deals where the user is struggling most.
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAt(deal.Id, 'F', 5);

        Test.startTest();
        refusalFrom(f5.Id);
        refusalFrom(f5.Id);
        refusalFrom(f5.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c],
            'Three refused attempts must leave zero records behind');
    }

    @isTest
    static void guardCostsNothingWhenNoItemInTheBatchCaptures() {
        // 64 of the 82 items record nothing, so this is the common path and it must be free.
        Transaction__c deal = newDeal();
        Checklist__c groupD = checklistFor(deal.Id, 'D');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(5, groupD.Id, true);
        List<Checklist_Item__c> resolved = resolve(new Map<Id, Checklist_Item__c>(items).keySet());

        Test.startTest();
        Integer before = Limits.getQueries();
        ChecklistCaptureService.assertCaptureSatisfied(resolved);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, spent, 'A capture-free batch must not spend a single query');
    }

    @isTest
    static void guardCostAt251ItemsMatchesCostAtOne() {
        // `.claude/rules/bulk-test-rule.md` volume case, done on `Checklist_Item__c` — which is
        // free — rather than on content rows, which are not. A loan read moved inside the item loop
        // would still refuse and allow correctly; only this number would notice.
        Transaction__c bulkDeal = newDeal();
        Checklist__c bulkGroup = checklistFor(bulkDeal.Id, 'F');
        List<Checklist_Item__c> many =
            TestDataFactory.createChecklistItems(BULK_ITEMS, bulkGroup.Id, true);
        insert fullyRecordedLoan(bulkDeal.Id);

        Transaction__c singleDeal = newDeal();
        Checklist_Item__c one = itemAt(singleDeal.Id, 'F', 5);
        insert fullyRecordedLoan(singleDeal.Id);

        List<Checklist_Item__c> bulkRows = resolve(new Map<Id, Checklist_Item__c>(many).keySet());
        List<Checklist_Item__c> singleRow = resolve(new Set<Id>{ one.Id });

        Test.startTest();
        Integer q0 = Limits.getQueries();
        ChecklistCaptureService.assertCaptureSatisfied(singleRow);
        Integer singleQueries = Limits.getQueries() - q0;

        Integer q1 = Limits.getQueries();
        ChecklistCaptureService.assertCaptureSatisfied(bulkRows);
        Integer bulkQueries = Limits.getQueries() - q1;
        Test.stopTest();

        Assert.areEqual(singleQueries, bulkQueries,
            'Query count must not scale with row count (1 row cost ' + singleQueries
                + ', 251 rows cost ' + bulkQueries + ')');
        Assert.areEqual(1, bulkQueries,
            'and the constant is ONE loan read for the whole batch, not one per capture item');
    }

    @isTest
    static void guardIsNullAndEmptySafe() {
        Test.startTest();
        ChecklistCaptureService.assertCaptureSatisfied(null);
        ChecklistCaptureService.assertCaptureSatisfied(new List<Checklist_Item__c>());
        Map<Id, ChecklistCaptureService.CaptureContext> contexts =
            ChecklistCaptureService.contextFor(null);
        Test.stopTest();

        Assert.isTrue(contexts.isEmpty(), 'Null input returns an empty map, never null or a throw');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Documents — 5 ContentVersion rows in total across this section (1 + 1 + 1 + 2). The class
    // header carries the per-fact budget; these two numbers must always agree, because a wrong
    // figure in a QUOTA comment is the one that must not rot.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void aDocumentLinkedToTheItemSatisfiesTheGuard() {
        // CONTENT COST: 1 row.
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAt(deal.Id, 'C', 7);
        Id documentId = newDocument('PCR');

        Test.startTest();
        Integer created = ChecklistCaptureService.linkDocumentsToItems(
            c7.Id, new List<Id>{ documentId });
        String message = refusalFrom(c7.Id);
        Test.stopTest();

        Assert.areEqual(1, created, 'One link created');
        Assert.isNull(message, 'and the item may now close, was refused with: ' + message);
    }

    @isTest
    static void aDocumentOnTheDealAloneDoesNotSatisfyTheGuard() {
        // 🔴 THE VACUITY THIS PREVENTS. If the guard asked "does this DEAL have any file?", every
        // deal with a single unrelated attachment would satisfy every document item forever, and
        // the guard would be green and meaningless. It asks about the ITEM.
        // CONTENT COST: 1 row.
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAt(deal.Id, 'C', 7);
        Id documentId = newDocument('Unrelated');
        insert new ContentDocumentLink(
            ContentDocumentId = documentId,
            LinkedEntityId = deal.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );

        Test.startTest();
        String message = refusalFrom(c7.Id);
        Test.stopTest();

        Assert.isNotNull(message,
            'A file on the deal that was never filed against C7 must not satisfy C7');
    }

    @isTest
    static void reLinkingTheSameDocumentIsIdempotent() {
        // The LWC can fire `uploadfinished` twice for one file on a slow connection, and a second
        // link for the same pair raises DUPLICATE_VALUE.
        // CONTENT COST: 1 row.
        Transaction__c deal = newDeal();
        Checklist_Item__c g6 = itemAt(deal.Id, 'G', 6);
        Id documentId = newDocument('Binder');

        Test.startTest();
        Integer first = ChecklistCaptureService.linkDocumentsToItems(g6.Id, new List<Id>{ documentId });
        Integer second = ChecklistCaptureService.linkDocumentsToItems(g6.Id, new List<Id>{ documentId });
        Integer withDuplicateInOneCall = ChecklistCaptureService.linkDocumentsToItems(
            g6.Id, new List<Id>{ documentId, documentId });
        Test.stopTest();

        Assert.areEqual(1, first, 'The first call creates the link');
        Assert.areEqual(0, second, 'the second finds it already there');
        Assert.areEqual(0, withDuplicateInOneCall, 'and a duplicate within one call is collapsed');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :g6.Id],
            'exactly one link exists');
    }

    @isTest
    static void everyDocumentInOneUploadEventIsLinked() {
        // Proves the LOOP rather than a single-row shortcut, which is the one fact a one-row test
        // cannot establish. CONTENT COST: 2 rows, and it needs both — a `ContentDocumentLink` must
        // point at a REAL `ContentDocument`, so a fake second id would fail the insert rather than
        // exercising the loop.
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAt(deal.Id, 'C', 7);
        Id first = newDocument('PCR part 1');
        Id second = newDocument('PCR part 2');

        Test.startTest();
        Integer created = ChecklistCaptureService.linkDocumentsToItems(
            c7.Id, new List<Id>{ first, second });
        Test.stopTest();

        Assert.areEqual(2, created, 'Both documents in the event are linked, not just the first');
    }

    @isTest
    static void linkDocumentsIsNullSafeAndRefusesAMissingItem() {
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAt(deal.Id, 'C', 7);

        Test.startTest();
        Assert.areEqual(0, ChecklistCaptureService.linkDocumentsToItems(c7.Id, null),
            'A null document list is a no-op, not a throw');
        Assert.areEqual(0, ChecklistCaptureService.linkDocumentsToItems(c7.Id, new List<Id>()),
            'and so is an empty one');
        Boolean refused = false;
        try {
            ChecklistCaptureService.linkDocumentsToItems(null, new List<Id>{ c7.Id });
        } catch (ChecklistCaptureService.CaptureUnavailableException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A null item id is refused rather than silently ignored');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Fixtures
    // ═══════════════════════════════════════════════════════════════════════════════════════

    private static Transaction__c newDeal() {
        return TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
    }

    /** A checklist group at a CHOSEN letter — the coordinate is what Phase 5 keys on. */
    private static Checklist__c checklistFor(Id dealId, String letter) {
        Checklist__c checklistGroup = TestDataFactory.createChecklist(dealId, false);
        checklistGroup.Group_Letter__c = letter;
        insert checklistGroup;
        return checklistGroup;
    }

    private static Checklist_Item__c itemAt(Id dealId, String letter, Integer sequence) {
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(
            sequence, checklistFor(dealId, letter).Id, true);
        return items[sequence - 1];
    }

    /** Reads items exactly as `ChecklistItemService.complete` does, so the guard sees real rows. */
    private static List<Checklist_Item__c> resolve(Set<Id> itemIds) {
        return ChecklistItemSelector.selectForCompletion(itemIds).values();
    }

    private static Map<Id, ChecklistCaptureService.CaptureContext> contextFor(Id itemId) {
        return ChecklistCaptureService.contextFor(resolve(new Set<Id>{ itemId }));
    }

    /** Runs the guard for one item and returns the refusal message, or null when it passed. */
    private static String refusalFrom(Id itemId) {
        try {
            ChecklistCaptureService.assertCaptureSatisfied(resolve(new Set<Id>{ itemId }));
            return null;
        } catch (ChecklistCaptureService.CaptureRequiredException e) {
            return e.getMessage();
        }
    }

    /** A loan with every REQUIRED capture field populated, so a whole group F batch passes. */
    private static Loan__c fullyRecordedLoan(Id dealId) {
        return new Loan__c(
            Transaction__c = dealId,
            Lender_Name__c = 'First Bank',
            Loan_Amount__c = 5000000,
            Bank_Account_Type__c = 'Operating',
            Auto_Payment_Status__c = 'Active'
        );
    }

    /**
     * One `ContentVersion`, returning its `ContentDocumentId`.
     *
     * 🔴 EVERY CALL COSTS ONE `ContentPublication` AGAINST A NON-REFUNDABLE ORG-WIDE DAILY CAP,
     * AND TEST ROLLBACK DOES NOT GIVE IT BACK. Count the calls in this class before adding one —
     * the budget is documented in the class header.
     */
    private static Id newDocument(String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('test document body')
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id]
            .ContentDocumentId;
    }
}
