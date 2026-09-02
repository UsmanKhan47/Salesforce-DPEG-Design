/**
 * Tests for `ChecklistItemService` — the Phase 3 completion service behind the Transaction
 * checklist LWCs.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * BULK VOLUME IS 251, PER `.claude/rules/bulk-test-rule.md`. NO EXEMPTION IS CLAIMED.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `complete` and `recordWireVerification` are collection-shaped service methods that perform DML,
 * which is the rule's 251 case. The per-transaction-singleton carve-out was considered and does
 * NOT apply: although the CONTROLLER passes a singleton (the LWC acts on one row at a time),
 * nothing about these methods is shaped around that, they loop, and a Flow or a future batch could
 * call either with any number of rows. Testing them at 1 and calling it done is exactly how a
 * SOQL-in-a-loop survives review.
 *
 * 🔴 THE BULKIFICATION PROOF DOES NOT ASSERT A MAGIC QUERY COUNT. It runs the SAME method twice in
 * one transaction — once with 1 row, once with 200 — and asserts the query and DML counts are
 * IDENTICAL. That is the actual invariant ("cost does not scale with row count"); it cannot go
 * stale when the trigger's own cost changes underneath it, and unlike a hardcoded budget it cannot
 * be silently "fixed" by bumping a number.
 *
 * ⚠ THE COMPARISON IS 1 vs 200, NOT 1 vs 251, AND THE REASON MATTERS. Salesforce fires a trigger
 * once per 200-row chunk, so a 251-row DML runs `ChecklistItemTriggerHandler` TWICE and legitimately
 * costs roughly twice the trigger-side queries. An "identical cost at 251" assertion would therefore
 * be measuring platform chunking rather than this service, and would go red against correct code —
 * the first draft of this class did exactly that. 200 is the largest single-chunk size, which
 * isolates the service's own cost precisely. The 251 VOLUME requirement is met separately, by the
 * two tests that complete 251 rows and assert every one of them landed — which is what forces the
 * second chunk to fire at all, and is the reason the rule prefers 251 over 200.
 *
 * ⚠ Counters are captured IMMEDIATELY around the service call, not around the whole test — the
 * fixture's own inserts and the assertions' own SELECTs would otherwise be measured too.
 *
 * ⚠ `Test.startTest()` resets the governor counters, so every measurement here is taken inside the
 * start/stop window.
 *
 * ── WHAT THE TRIGGER DOES DURING THESE TESTS ────────────────────────────────────────────────
 * `ChecklistItemTrigger` is live and deliberately NOT suppressed: `ChecklistItemDomain.stampCompletion`
 * writes `Completed_By__c` / `Completed_DateTime__c` in before-update, and
 * `ChecklistItemPrerequisiteService.enforceOnUpdate` is the gate whose refusal this class must
 * re-type. Suppressing either would make the happy-path tests prove less than they appear to.
 *
 * ⚠ `group` IS A RESERVED WORD IN APEX (GROUP BY), so the checklist parent is `checklistGroup`
 * throughout. The first draft of this class used `group` and produced three cascading compile
 * errors per site, none of which named the identifier. Same family as `update`, `from` and `bulk`.
 *
 * @see force-app/main/default/classes/ChecklistItemService.cls
 * @see force-app/main/default/classes/ChecklistControllerTest.cls (the boundary above this one)
 * @see .claude/rules/bulk-test-rule.md
 */
@isTest
private class ChecklistItemServiceTest {

    private static final String WIRE_SUBJECT = 'Call title company to verbally verify wiring instructions';

    /** A deal with the LEGACY fan-out guard pre-set, so the Task-model flow cannot interfere. */
    private static Transaction__c newDeal() {
        return TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
    }

    /**
     * A checklist group at a letter that carries NO Phase 5 capture coordinate.
     *
     * 🔴 THE FIXTURE MATTERS AS SOON AS A GROUP HAS MORE THAN FOUR ITEMS. `TestDataFactory
     * .createChecklist` always produces letter `A`, and `createChecklistItems` sequences from 1 -
     * so a 200- or 251-item group is `A1 … A251`, which CONTAINS `A5`. `A5` is a real Phase 5
     * coordinate ("Log critical dates into Salesforce deal record"), so completing that batch fires
     * `CriticalDateService.ensureFor` and spends 2 extra SOQL and 1 extra DML that a one-item batch
     * does not. The bulkification invariant below would then fail for a reason that has nothing to
     * do with bulkification.
     *
     * ⚠ THIS IS NOT HIDING THE COST - IT IS ISOLATING IT. The outcome pass's own 1-vs-200 cost
     * equality, measured WITH a derived coordinate present in both calls, is asserted by
     * `ChecklistOutcomeServiceTest.outcomeCostAt200RowsMatchesCostAtOne`. This helper exists so the
     * two properties are measured separately instead of one masking the other.
     *
     * Capture-free letters today are D, E, H, H2 and I. A, B, C, F, G and J all carry at least one.
     *
     * @param dealId the parent deal.
     * @param letter a capture-free group letter.
     * @return the inserted checklist.
     */
    private static Checklist__c captureFreeChecklist(Id dealId, String letter) {
        return checklistAtLetter(dealId, letter);
    }

    /**
     * A checklist group at a CHOSEN letter. Neutral name, because the Phase 5 wiring tests below
     * deliberately use it for capture-BEARING letters (A, B, F) while the cost tests above use
     * `captureFreeChecklist` for capture-free ones. Same mechanism, opposite intent, so the two
     * names are worth keeping distinct.
     *
     * @param dealId the parent deal.
     * @param letter the `Group_Letter__c` to stamp.
     * @return the inserted checklist.
     */
    private static Checklist__c checklistAtLetter(Id dealId, String letter) {
        Checklist__c checklistGroup = TestDataFactory.createChecklist(dealId, false);
        checklistGroup.Group_Letter__c = letter;
        insert checklistGroup;
        return checklistGroup;
    }

    private static Checklist_Item__c reload(Id itemId) {
        return [
            SELECT Id, Flag__c, Comment__c, Completed_By__c, Completed_DateTime__c,
                   Verbal_Verification_Completed__c, Verified_By_Name__c, Verification_Phone__c,
                   Verified_DateTime__c, Is_Wire_Verification__c
            FROM Checklist_Item__c
            WHERE Id = :itemId
        ];
    }

    private static List<ChecklistItemService.CompletionRequest> one(Id itemId, String comment) {
        return new List<ChecklistItemService.CompletionRequest>{
            new ChecklistItemService.CompletionRequest(itemId, comment)
        };
    }

    /**
     * One item at an EXACT coordinate. Items 1..sequence are created under a group re-pointed to
     * `letter`, and the last one is returned. The coordinate is the whole point - Phase 5 keys on
     * `(Group_Letter__c, Sequence__c)` and never on `Subject__c`.
     */
    private static Checklist_Item__c itemAtCoordinate(Id dealId, String letter, Integer sequence) {
        Checklist__c checklistGroup = checklistAtLetter(dealId, letter);
        return TestDataFactory.createChecklistItems(sequence, checklistGroup.Id, true)[sequence - 1];
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 PHASE 5 WIRING — these three tests exist because DELETING THE TWO PHASE 5 CALLS FROM
    //    `complete()` LEFT THE ENTIRE APEX SUITE GREEN.
    //
    // `ChecklistCaptureService` and `ChecklistOutcomeService` are thoroughly tested DIRECTLY, in
    // their own classes. Nothing proved that `ChecklistItemService.complete` actually calls them,
    // so the one line joining the feature to the only path a human uses was unpinned. Each test
    // below goes through `complete()` and asserts an effect that ONLY the wiring can produce.
    //
    // ⚠ These are deliberately NOT in the cost/volume block above, which uses capture-free group
    // letters so it measures bulkification alone (see `captureFreeChecklist`). Separating the two
    // is what stops either property masking the other.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completeRefusesACaptureItemWhoseOutputIsNotOnFile() {
        // Pins the `assertCaptureSatisfied` call. F5 selects the lender; with no Loan__c at all
        // there is nothing on file, so the completion must be refused BEFORE any DML.
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAtCoordinate(deal.Id, 'F', 5);

        Test.startTest();
        String message;
        try {
            ChecklistItemService.complete(one(f5.Id, null));
        } catch (ChecklistCaptureService.CaptureRequiredException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message,
            'complete() must run the capture guard. If this passes with a null message the guard '
                + 'call has been removed from complete() and every capture item closes empty');
        Assert.isTrue(message.containsIgnoreCase('lender'),
            'and the refusal names the missing output, was: ' + message);
        Assert.areEqual('None', reload(f5.Id).Flag__c,
            'Nothing was written - the refusal is raised before the DML, not after it');
    }

    @isTest
    static void completeStampsEarnestMoneySentForB5() {
        // Pins the `applyForCompletedItems` call for the EARNEST_MONEY_SENT outcome.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAtCoordinate(deal.Id, 'B', 5);

        Test.startTest();
        ChecklistItemService.complete(one(b5.Id, null));
        Test.stopTest();

        Transaction__c after = [
            SELECT Earnest_Money_Sent__c, Earnest_Money_Sent_Date__c
            FROM Transaction__c WHERE Id = :deal.Id
        ];
        Assert.areEqual(true, after.Earnest_Money_Sent__c,
            'Completing B5 through complete() must stamp the deal. A false here means the outcome '
                + 'call has been removed and B5 records nothing again');
        Assert.areEqual(Date.today(), after.Earnest_Money_Sent_Date__c, 'and stamp its date');
    }

    @isTest
    static void reCompletingAnAlreadyDoneItemDoesNotReApplyItsOutcome() {
        // 🔴 PINS THAT `complete()` PASSES ITS PRE-DML READ AS THE PRIOR STATE. Without that
        // argument, an unrelated edit to an already-complete item re-enters the outcome path.
        //
        // THE DISCRIMINATOR IS THE DATE, NOT THE FLAG. `Earnest_Money_Sent__c` stays true from the
        // first completion, so re-application would be invisible on it. Nulling the DATE in between
        // gives the second call something to re-stamp if the gate is not armed: `buildDealWrites`
        // stamps `Earnest_Money_Sent_Date__c` whenever it is blank AND the item is in this batch's
        // earnest set. Gate armed -> B5 never enters that set -> the date stays null.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAtCoordinate(deal.Id, 'B', 5);

        Test.startTest();
        ChecklistItemService.complete(one(b5.Id, 'first pass'));
        Assert.areEqual(Date.today(),
            [SELECT Earnest_Money_Sent_Date__c FROM Transaction__c WHERE Id = :deal.Id]
                .Earnest_Money_Sent_Date__c,
            'Control: the first completion DID stamp, so this test is not vacuous');

        update new Transaction__c(Id = deal.Id, Earnest_Money_Sent_Date__c = null);
        // An ordinary edit to an already-complete item — the exact case the gate exists for.
        ChecklistItemService.complete(one(b5.Id, 'a later comment on a done item'));
        Test.stopTest();

        Transaction__c after = [
            SELECT Earnest_Money_Sent__c, Earnest_Money_Sent_Date__c
            FROM Transaction__c WHERE Id = :deal.Id
        ];
        Assert.isNull(after.Earnest_Money_Sent_Date__c,
            'The second call must NOT re-stamp. A date here means complete() stopped passing its '
                + 'prior-state map and every edit to a done item re-applies its outcomes');
        Assert.areEqual(true, after.Earnest_Money_Sent__c,
            'and the flag from the first completion is untouched - the gate skips re-application, '
                + 'it does not undo anything');
    }

    @isTest
    static void completeProjectsCriticalDatesForA5() {
        // Pins the `applyForCompletedItems` call for the CRITICAL_DATES outcome, which is the arm
        // that reaches `CriticalDateService` - the one Phase 5 side effect with a blast radius
        // outside this module (a projected date makes the deal undeletable).
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAtCoordinate(deal.Id, 'A', 5);
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'Control: no critical dates before A5 is completed');

        Test.startTest();
        ChecklistItemService.complete(one(a5.Id, null));
        Test.stopTest();

        Assert.isTrue(
            [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id] > 0,
            'Completing "Log critical dates into Salesforce deal record" through complete() must '
                + 'actually log them'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // complete()
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completeSetsTheDoneFlagAndPersistsTheComment() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        Test.startTest();
        ChecklistItemService.complete(one(item.Id, '  Signed copy filed.  '));
        Test.stopTest();

        Checklist_Item__c saved = reload(item.Id);
        Assert.areEqual(ChecklistItemDomain.FLAG_COMPLETED, saved.Flag__c, 'Flag__c should be Completed');
        Assert.areEqual('Signed copy filed.', saved.Comment__c, 'Comment is trimmed and persisted');
        // Written by the BEFORE-UPDATE trigger, not by the service. Asserted here because the
        // service deliberately does not set them, and a future "helpful" addition would create a
        // second competing writer of the same history.
        Assert.areEqual(UserInfo.getUserId(), saved.Completed_By__c, 'Trigger stamps the real completer');
        Assert.isNotNull(saved.Completed_DateTime__c, 'Trigger stamps the completion time');
    }

    @isTest
    static void completeWithABlankCommentLeavesTheExistingCommentIntact() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, false);
        item.Comment__c = 'Earlier note that must survive.';
        insert item;

        Test.startTest();
        ChecklistItemService.complete(one(item.Id, '   '));
        Test.stopTest();

        Checklist_Item__c saved = reload(item.Id);
        Assert.areEqual(ChecklistItemDomain.FLAG_COMPLETED, saved.Flag__c, 'Still completes');
        Assert.areEqual(
            'Earlier note that must survive.',
            saved.Comment__c,
            'A blank comment must LEAVE the existing one alone, not erase it'
        );
    }

    @isTest
    static void completeRefusesAnUnverifiedWireItemAndWritesNOTHING() {
        // The anti-fraud control. Ticking a wire step without recording who was called, and on what
        // number, destroys the only evidence the control produces.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, false);
        items[0].Is_Wire_Verification__c = true;
        items[0].Subject__c = WIRE_SUBJECT;
        insert items;

        String message;
        Test.startTest();
        try {
            // Both rows in ONE batch: the ordinary item is the control that proves the refusal is
            // ALL-OR-NOTHING rather than a per-row skip.
            ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
                new ChecklistItemService.CompletionRequest(items[1].Id, 'fine'),
                new ChecklistItemService.CompletionRequest(items[0].Id, 'sneaking it through')
            });
            Assert.fail('Expected WireVerificationException for an unverified wire item');
        } catch (ChecklistItemService.WireVerificationException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('Verify Wiring Instructions'),
            'The message must name the dialog the user has to use instead: ' + message
        );
        Assert.areEqual('None', reload(items[0].Id).Flag__c, 'The wire item must not have completed');
        Assert.areEqual(
            'None',
            reload(items[1].Id).Flag__c,
            'The ORDINARY item in the same batch must not have completed either — the refusal '
                + 'happens before any DML, so the whole batch is refused rather than partly applied'
        );
    }

    @isTest
    static void completeAllowsAWireItemThatALREADYHasItsVerbalVerification() {
        // The guard is "no evidence on file", not "is a wire item". Once the call has been recorded
        // the item completes like any other.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        item.Verbal_Verification_Completed__c = true;
        insert item;

        Test.startTest();
        ChecklistItemService.complete(one(item.Id, null));
        Test.stopTest();

        Assert.areEqual(
            ChecklistItemDomain.FLAG_COMPLETED,
            reload(item.Id).Flag__c,
            'A wire item with evidence on file completes normally'
        );
    }

    @isTest
    static void completeThrowsItemNotFoundForAnIdThatNoLongerResolves() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);
        Id goneId = item.Id;
        delete item;

        String message;
        Test.startTest();
        try {
            ChecklistItemService.complete(one(goneId, null));
            Assert.fail('Expected ItemNotFoundException');
        } catch (ChecklistItemService.ItemNotFoundException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(message.contains('Refresh'), 'The message must be actionable: ' + message);
        // ⚠ It must NOT distinguish "deleted" from "you cannot see it" — saying so would tell an
        // unauthorised caller that a record exists, which is what the sharing model is refusing.
        Assert.isFalse(
            message.containsIgnoreCase('deleted') || message.containsIgnoreCase('permission'),
            'The not-found message must not leak WHY the row did not resolve: ' + message
        );
    }

    @isTest
    static void completeReTypesTheWireFraudPrerequisiteRefusalSoTheUserSeesWhy() {
        // 🔴 The defect this prevents: the gate refuses with addError in a before-update trigger,
        // which reaches Apex as a plain DmlException and would be mapped to "refresh and try
        // again" — advice that can never work, because refreshing does not make the phone call.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, false);
        items[0].Is_Wire_Verification__c = true;
        items[0].Subject__c = WIRE_SUBJECT;
        insert items;
        // items[1] (the wire REQUEST) waits on items[0] (the verification call).
        TestDataFactory.linkPrerequisite(items[1], items[0], true);

        Boolean refused = false;
        String message;
        Test.startTest();
        try {
            ChecklistItemService.complete(one(items[1].Id, null));
        } catch (ChecklistItemPrerequisiteService.PrerequisiteNotMetException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The blocked item must be refused as a typed prerequisite failure, '
            + 'not as a raw DmlException');
        Assert.isTrue(String.isNotBlank(message), 'The refusal must carry the guidance text');
        Assert.areEqual('None', reload(items[1].Id).Flag__c, 'The blocked item did not complete');
    }

    @isTest
    static void completeIsANoOpForNullEmptyAndIdlessInput() {
        Test.startTest();
        ChecklistItemService.complete(null);
        ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>());
        ChecklistItemService.complete(one(null, 'ignored'));
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dml, 'None of the three degenerate inputs may issue DML');
    }

    @isTest
    static void completeToleratesTheSameItemTwiceInOneBatch() {
        // Two rows for one record in a single DML is DUPLICATE_VALUE. The first request wins.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        Test.startTest();
        ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
            new ChecklistItemService.CompletionRequest(item.Id, 'first'),
            new ChecklistItemService.CompletionRequest(item.Id, 'second')
        });
        Test.stopTest();

        Assert.areEqual('first', reload(item.Id).Comment__c, 'The first request wins; no DUPLICATE_VALUE');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // recordWireVerification()
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void recordWireVerificationWritesTheEvidenceAndAPPENDSToTheExistingComment() {
        // ═══════════════════════════════════════════════════════════════════════════════════
        // 🔴 THIS TEST IS THE GUARD ON `ChecklistItemSelector.selectForCompletion`'s FIELD LIST.
        // ═══════════════════════════════════════════════════════════════════════════════════
        // `recordWireVerification` reads `current.Comment__c` to append to it. If anyone trims that
        // LongTextArea out of the selector "for performance", the code still COMPILES and still
        // DEPLOYS — the failure is a runtime `System.SObjectException: SObject row was retrieved
        // via SOQL without querying the requested field`, on the anti-fraud write path, in
        // production. `ChecklistSelectorTest` cannot catch it (it asserts row counts), so the
        // pre-existing comment below is not decoration: it is what forces the read.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        item.Subject__c = WIRE_SUBJECT;
        item.Comment__c = 'PRIOR NOTE';
        insert item;

        Test.startTest();
        ChecklistItemService.recordWireVerification(
            new List<ChecklistItemService.WireVerificationRequest>{
                new ChecklistItemService.WireVerificationRequest(
                    item.Id, '  Jane Doe  ', '  713-555-0142  ', '  Called the published number.  '
                )
            }
        );
        Test.stopTest();

        Checklist_Item__c saved = reload(item.Id);
        Assert.areEqual(
            ChecklistItemDomain.FLAG_VERIFIED,
            saved.Flag__c,
            'Verified, NOT Completed — the flag is what says evidence is on file'
        );
        Assert.isTrue(saved.Verbal_Verification_Completed__c, 'Verbal verification recorded');
        Assert.areEqual('Jane Doe', saved.Verified_By_Name__c, 'Confirmer name is trimmed');
        Assert.areEqual('713-555-0142', saved.Verification_Phone__c, 'Phone is trimmed');
        Assert.isNotNull(saved.Verified_DateTime__c, 'Verification time is stamped');

        Assert.isTrue(
            saved.Comment__c.startsWith('PRIOR NOTE'),
            'The prior comment must SURVIVE — proving Comment__c was read before the write. Got: '
                + saved.Comment__c
        );
        Assert.isTrue(
            saved.Comment__c.contains('Called the published number.'),
            'The verifier\'s own comment is kept'
        );
        Assert.isTrue(
            saved.Comment__c.contains('Verified by phone with Jane Doe at 713-555-0142'),
            'The standard verification note is appended'
        );
    }

    @isTest
    static void recordWireVerificationRefusesBlankNameOrPhoneAndWritesNothing() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, false);
        for (Checklist_Item__c i : items) {
            i.Is_Wire_Verification__c = true;
            i.Subject__c = WIRE_SUBJECT;
        }
        insert items;

        Integer refusals = 0;
        Test.startTest();
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(items[0].Id, '   ', '713-555-0142', null)
                }
            );
        } catch (ChecklistItemService.WireVerificationException e) {
            refusals++;
        }
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(items[1].Id, 'Jane Doe', null, null)
                }
            );
        } catch (ChecklistItemService.WireVerificationException e) {
            refusals++;
        }
        Test.stopTest();

        Assert.areEqual(2, refusals, 'Blank name and blank phone are BOTH refused');
        Assert.isFalse(
            reload(items[0].Id).Verbal_Verification_Completed__c,
            'A refused verification must leave no half-written evidence'
        );
        Assert.areEqual('None', reload(items[1].Id).Flag__c, 'And must not close the item');
    }

    @isTest
    static void recordWireVerificationRefusesAnItemThatIsNotAWireStep() {
        // Stamping Verified and an anti-fraud note on an ordinary step puts evidence of a control
        // on a row that never had one — worse than useless in an audit.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        String message;
        Test.startTest();
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(item.Id, 'Jane Doe', '713-555-0142', null)
                }
            );
            Assert.fail('Expected WireVerificationException for a non-wire item');
        } catch (ChecklistItemService.WireVerificationException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('not a wire-verification step'),
            'The message must say why: ' + message
        );
        Assert.areEqual('None', reload(item.Id).Flag__c, 'Nothing written');
    }

    @isTest
    static void recordWireVerificationThrowsItemNotFoundForAnUnresolvableId() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);
        Id goneId = item.Id;
        delete item;

        Boolean thrown = false;
        Test.startTest();
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(goneId, 'Jane Doe', '713-555-0142', null)
                }
            );
        } catch (ChecklistItemService.ItemNotFoundException e) {
            thrown = true;
        }
        Test.stopTest();

        Assert.isTrue(thrown, 'An unresolvable id is refused before the name/phone rule is reached');
    }

    @isTest
    static void recordWireVerificationIsANoOpForNullAndEmptyInput() {
        Test.startTest();
        ChecklistItemService.recordWireVerification(null);
        ChecklistItemService.recordWireVerification(new List<ChecklistItemService.WireVerificationRequest>());
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dml, 'No DML for degenerate input');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // appendComment() — the 4,000-character LongTextArea boundary
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE OFF-BY-ONE WINDOW. `Comment__c` is a LongTextArea(4000) and `appendComment` keeps the
     * NEWEST content when the composed value overflows — the newest content on this path is the
     * line recording who was called and on what number.
     *
     * The obvious single-check implementation (`addition.length() >= keep` -> substring from
     * `length - MAX`) computes a NEGATIVE index for any addition between `keep` and `MAX`
     * characters and throws `System.StringException`. `keep` is 3,968 here, so the broken window is
     * 3,968–3,999 inclusive — 32 values wide, and reachable only by a verifier writing a very long
     * comment. It would have shipped.
     *
     * ⚠ THE BOUNDARIES ARE DERIVED FROM THE CONSTANTS, NOT HARDCODED, so a change to the marker
     * text moves the tested window with it instead of silently un-testing the boundary. The literal
     * 3,968 is asserted separately, once, so that a marker change is VISIBLE rather than absorbed.
     */
    @isTest
    static void appendCommentSurvivesEveryBoundaryAroundTheFieldLimit() {
        final Integer maxLen = ChecklistItemService.COMMENT_MAX_LENGTH;
        final Integer keep = maxLen - ChecklistItemService.COMMENT_TRUNCATION_MARKER.length();

        Assert.areEqual(4000, maxLen, 'Comment__c is a LongTextArea(4000)');
        Assert.areEqual(
            3968,
            keep,
            'The marker is 32 characters, so the fragile window is 3968-3999. If this fails the '
                + 'marker text changed — check that the boundary cases below still bracket it.'
        );

        String existing = 'x'.repeat(500);

        // The four boundaries the reviewer named, expressed against the constants.
        Map<String, Integer> cases = new Map<String, Integer>{
            'keep - 1 (3967) — marker branch'        => keep - 1,
            'keep (3968) — first negative-index case' => keep,
            'max - 1 (3999) — last negative-index case' => maxLen - 1,
            'max (4000) — tail-of-addition branch'   => maxLen,
            'max + 1 (4001) — overflowing addition'  => maxLen + 1
        };

        for (String caseLabel : cases.keySet()) {
            Integer additionLength = cases.get(caseLabel);
            String addition = 'a'.repeat(additionLength - 1) + 'Z'; // 'Z' marks the very newest char
            String result = ChecklistItemService.appendComment(existing, addition);

            Assert.isTrue(
                result.length() <= maxLen,
                caseLabel + ': result must fit the field, was ' + result.length()
            );
            Assert.isTrue(
                result.endsWith('Z'),
                caseLabel + ': the NEWEST character must survive — that is the whole point of dropping '
                    + 'from the front rather than the back'
            );
        }
    }

    @isTest
    static void appendCommentKeepsBothPartsWhenTheyFitAndMarksTheCutWhenTheyDoNot() {
        final Integer maxLen = ChecklistItemService.COMMENT_MAX_LENGTH;
        final String marker = ChecklistItemService.COMMENT_TRUNCATION_MARKER;

        // Comfortably inside the limit: nothing is dropped and nothing is marked.
        String small = ChecklistItemService.appendComment('OLD', 'NEW');
        Assert.areEqual('OLD\nNEW', small, 'Both parts kept, newline-joined');
        Assert.isFalse(small.contains(marker), 'No truncation marker when nothing was truncated');

        // Blank existing: the addition is the whole value.
        Assert.areEqual('NEW', ChecklistItemService.appendComment(null, 'NEW'), 'Null existing');
        Assert.areEqual('NEW', ChecklistItemService.appendComment('   ', 'NEW'), 'Blank existing');

        // Overflow with a short addition: history is cut from the FRONT and the cut is marked.
        String bigExisting = 'x'.repeat(maxLen);
        String cut = ChecklistItemService.appendComment(bigExisting, 'THE VERIFICATION NOTE');
        Assert.areEqual(maxLen, cut.length(), 'Trimmed to exactly the field limit');
        Assert.isTrue(cut.startsWith(marker), 'The dropped region is marked, not silently removed');
        Assert.isTrue(
            cut.endsWith('THE VERIFICATION NOTE'),
            'The newest content — the audit evidence — is what survives'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // BULK — 251 rows, per .claude/rules/bulk-test-rule.md
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completeAt200RowsCostsTheSameQueriesAndDmlAsAtOne() {
        // 🔴 THE BULKIFICATION INVARIANT. The SAME method, measured twice in one transaction, must
        // cost the same regardless of row count. A SOQL or DML statement moved inside the loop
        // breaks this immediately, and unlike a hardcoded budget it cannot be papered over by
        // bumping a number. 200 rows is the largest SINGLE trigger chunk, so this isolates the
        // service's own cost from the platform's per-chunk trigger firing (see the class header).
        Transaction__c deal = newDeal();
        // Capture-free letters, so neither call carries a Phase 5 coordinate — see
        // `captureFreeChecklist`. Without this the 200-row group contains A5 and the one-row group
        // does not, and the equality below fails on the outcome pass rather than on bulkification.
        Checklist__c smallGroup = captureFreeChecklist(deal.Id, 'D');
        Checklist__c largeGroup = captureFreeChecklist(deal.Id, 'E');
        Checklist_Item__c single = TestDataFactory.createChecklistItem(smallGroup.Id, true);
        List<Checklist_Item__c> many = TestDataFactory.createChecklistItems(200, largeGroup.Id, true);

        List<ChecklistItemService.CompletionRequest> bulkRequests =
            new List<ChecklistItemService.CompletionRequest>();
        for (Checklist_Item__c item : many) {
            bulkRequests.add(new ChecklistItemService.CompletionRequest(item.Id, 'bulk'));
        }

        Test.startTest();
        // Captured immediately around each call so the fixture's own inserts are not measured.
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        ChecklistItemService.complete(one(single.Id, 'single'));
        Integer singleQueries = Limits.getQueries() - q0;
        Integer singleDml = Limits.getDmlStatements() - d0;

        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        ChecklistItemService.complete(bulkRequests);
        Integer bulkQueries = Limits.getQueries() - q1;
        Integer bulkDml = Limits.getDmlStatements() - d1;
        Test.stopTest();

        Assert.areEqual(
            201,
            [
                SELECT COUNT()
                FROM Checklist_Item__c
                WHERE Checklist__r.Transaction__c = :deal.Id AND Flag__c = 'Completed'
            ],
            'Every row in both calls completed'
        );
        Assert.areEqual(
            singleQueries,
            bulkQueries,
            'Query count must not scale with row count (1 row cost ' + singleQueries
                + ', 200 rows cost ' + bulkQueries + ')'
        );
        Assert.areEqual(
            singleDml,
            bulkDml,
            'DML statement count must not scale with row count (1 row cost ' + singleDml
                + ', 200 rows cost ' + bulkDml + ')'
        );
    }

    @isTest
    static void completeLandsAll251RowsInOneCall() {
        // The `.claude/rules/bulk-test-rule.md` VOLUME case. 251 forces a SECOND trigger chunk,
        // which is the whole reason the rule picks that number over 200: a bug that only appears
        // when the trigger logic runs more than once per transaction surfaces here and nowhere else.
        Transaction__c deal = newDeal();
        // Capture-free letter: this test measures TRIGGER CHUNKING at 251, not the Phase 5 outcome
        // pass. `ChecklistOutcomeServiceTest` covers that separately. See `captureFreeChecklist`.
        Checklist__c checklistGroup = captureFreeChecklist(deal.Id, 'D');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(251, checklistGroup.Id, true);

        List<ChecklistItemService.CompletionRequest> requests =
            new List<ChecklistItemService.CompletionRequest>();
        for (Checklist_Item__c item : items) {
            requests.add(new ChecklistItemService.CompletionRequest(item.Id, 'bulk'));
        }

        Test.startTest();
        ChecklistItemService.complete(requests);
        Integer queriesUsed = Limits.getQueries();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(
            251,
            [
                SELECT COUNT()
                FROM Checklist_Item__c
                WHERE Checklist__r.Transaction__c = :deal.Id AND Flag__c = 'Completed'
            ],
            'All 251 items completed, across BOTH trigger chunks'
        );
        // Absolute ceilings, deliberately generous and deliberately NOT derived from a measurement
        // taken in this same test — a bound derived from the thing it bounds can never go red.
        // Their only job is to catch a catastrophic per-row query or DML; the precise invariant is
        // the 1-vs-200 equality above.
        Assert.isTrue(queriesUsed < 20, 'Query count should be a small constant, was ' + queriesUsed);
        Assert.isTrue(dmlUsed < 20, 'DML statement count should be a small constant, was ' + dmlUsed);
    }

    @isTest
    static void recordWireVerificationLandsAll251RowsInOneCall() {
        Transaction__c deal = newDeal();
        // Capture-free letter, same reason as the sibling 251 test above. Note that a VERIFIED item
        // is DONE (`ChecklistItemDomain.isDone` is a two-value test), so an A5 in this batch would
        // fire the Phase 5 outcome pass just as a completion does.
        Checklist__c checklistGroup = captureFreeChecklist(deal.Id, 'D');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(251, checklistGroup.Id, false);
        for (Checklist_Item__c item : items) {
            item.Is_Wire_Verification__c = true;
        }
        insert items;

        List<ChecklistItemService.WireVerificationRequest> requests =
            new List<ChecklistItemService.WireVerificationRequest>();
        for (Checklist_Item__c item : items) {
            requests.add(new ChecklistItemService.WireVerificationRequest(
                item.Id, 'Jane Doe', '713-555-0142', null
            ));
        }

        Test.startTest();
        ChecklistItemService.recordWireVerification(requests);
        Integer queriesUsed = Limits.getQueries();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(
            251,
            [
                SELECT COUNT()
                FROM Checklist_Item__c
                WHERE Checklist__r.Transaction__c = :deal.Id AND Flag__c = 'Verified'
            ],
            'All 251 wire items verified, across BOTH trigger chunks'
        );
        Assert.isTrue(queriesUsed < 20, 'Query count should be a small constant, was ' + queriesUsed);
        Assert.isTrue(dmlUsed < 20, 'DML statement count should be a small constant, was ' + dmlUsed);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Coverage of the paths a happy-path suite never reaches
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completeSkipsNullEntriesAndStillProcessesTheRest() {
        // A caller assembling requests in a loop can leave a null in the list. Skipping it is not
        // the same as refusing the batch, and the distinction is only visible at more than one row.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        Test.startTest();
        ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
            null,
            new ChecklistItemService.CompletionRequest(null, 'no id'),
            new ChecklistItemService.CompletionRequest(item.Id, 'real')
        });
        Test.stopTest();

        Checklist_Item__c saved = reload(item.Id);
        Assert.areEqual(ChecklistItemDomain.FLAG_COMPLETED, saved.Flag__c, 'The real request landed');
        Assert.areEqual('real', saved.Comment__c, 'With its comment');
    }

    @isTest
    static void recordWireVerificationSkipsNullEntriesAndDuplicates() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        Test.startTest();
        ChecklistItemService.recordWireVerification(
            new List<ChecklistItemService.WireVerificationRequest>{
                null,
                new ChecklistItemService.WireVerificationRequest(null, 'Jane Doe', '713-555-0142', null),
                new ChecklistItemService.WireVerificationRequest(item.Id, 'Jane Doe', '713-555-0142', 'first'),
                // Same id twice would be DUPLICATE_VALUE in one DML. First wins.
                new ChecklistItemService.WireVerificationRequest(item.Id, 'Someone Else', '000', 'second')
            }
        );
        Test.stopTest();

        Checklist_Item__c saved = reload(item.Id);
        Assert.areEqual(ChecklistItemDomain.FLAG_VERIFIED, saved.Flag__c, 'The real request landed');
        Assert.areEqual('Jane Doe', saved.Verified_By_Name__c, 'The FIRST request wins, not the last');
        Assert.isTrue(saved.Comment__c.contains('first'), 'And its comment');
        Assert.isFalse(saved.Comment__c.contains('second'), 'The duplicate was dropped entirely');
    }

    @isTest
    static void aPlatformDmlFailureIsRETHROWNUNTOUCHEDAndNotDisguisedAsARefusal() {
        // ═══════════════════════════════════════════════════════════════════════════════════
        // 🔴 THE OTHER HALF OF `refusalOrOriginal`. Its job is to re-type ONLY the wire-fraud
        // prerequisite refusal; everything else must escape UNCHANGED so the controller still maps
        // it to the fixed generic message. Without this test only the re-typing branch is covered,
        // and a broadened matcher — `asRefusal` returning non-null for any DmlException — would go
        // unnoticed while quietly routing raw platform text (field API names, validation-rule
        // internals) to the user.
        //
        // The failure is induced with a confirmer name longer than `Verified_By_Name__c`'s
        // Text(120): deterministic, needs no user fixture, and no sharing setup.
        //
        // ⚠ IT ALSO DOCUMENTS A REAL LIMIT. The service does NOT length-check that field, so an
        // over-long name is a platform error rather than a friendly refusal. That is acceptable
        // (the controller shows the generic message and leaks nothing) but it is a decision, not
        // an oversight — a UI that can submit 121 characters here would want a guard.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        Boolean caughtDml = false;
        Boolean caughtRefusal = false;
        Test.startTest();
        try {
            ChecklistItemService.recordWireVerification(
                new List<ChecklistItemService.WireVerificationRequest>{
                    new ChecklistItemService.WireVerificationRequest(
                        item.Id, 'N'.repeat(200), '713-555-0142', null
                    )
                }
            );
            Assert.fail('Expected the platform to reject a 200-character Verified_By_Name__c');
        } catch (ChecklistItemPrerequisiteService.PrerequisiteNotMetException e) {
            caughtRefusal = true;
        } catch (DmlException e) {
            caughtDml = true;
        }
        Test.stopTest();

        Assert.isTrue(caughtDml, 'An ordinary platform failure must surface as a DmlException');
        Assert.isFalse(
            caughtRefusal,
            'It must NOT be re-typed as a prerequisite refusal - that path is reserved for the '
                + 'wire-fraud gate, whose message is shown to the user verbatim'
        );
        Assert.areEqual('None', reload(item.Id).Flag__c, 'Nothing was written');
    }
}
