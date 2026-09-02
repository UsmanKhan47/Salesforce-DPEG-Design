/**
 * Tests for `ChecklistController` — the `@AuraEnabled` boundary the three Phase 3 LWCs call.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * THE TWO DISPLAY SELECTOR METHODS ARE TESTED HERE, DELIBERATELY, AND NOT IN THE SELECTOR SUITES.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `ChecklistSelector.selectForDisplayByTransactionIds` and
 * `ChecklistItemSelector.selectForDisplayByTransactionIds` were added in Phase 3 and exist for
 * exactly one caller: `getChecklist`. Co-locating their tests with that caller means one file to
 * open when the checklist screen breaks, and it keeps the ordering / empty-list / field-population
 * contracts next to the code that depends on them. `ChecklistSelectorTest` covers the Phase 2
 * automation-path methods and is untouched.
 *
 * ── WHY EVERY TEST BUILDS ITS OWN FIXTURE RATHER THAN USING @TestSetup ──────────────────────
 * Several tests need `Checklist__c.Items_Complete__c` to hold a value that DISAGREES with the
 * items underneath it, which is only stable if nothing else in the transaction touches those items
 * afterwards. A shared `@TestSetup` deal would make that fragile in a way that is invisible until
 * someone adds a test.
 *
 * ⚠ There is no `ChecklistTrigger` — only `ChecklistItemTrigger` — so a direct update of
 * `Checklist__c.Items_Complete__c` is NOT recalculated behind the test's back. That is what makes
 * the "counts come from the items, not the stored fields" test possible at all.
 *
 * ⚠ THE `AuraHandledException` MESSAGE ASSERTIONS BELOW ONLY WORK BECAUSE THE CONTROLLER CALLS
 * `setMessage()`. Constructing `new AuraHandledException(msg)` alone leaves `getMessage()`
 * returning "Script-thrown exception" — both in a test and, more importantly, in the browser. So a
 * refactor that drops `setMessage` from `ChecklistController.ahe` turns every verbatim refusal into
 * that string for real users, and these tests are what catches it.
 *
 * @see force-app/main/default/classes/ChecklistController.cls
 * @see force-app/main/default/classes/ChecklistItemServiceTest.cls (the service below this one)
 */
@isTest
private class ChecklistControllerTest {

    private static Transaction__c newDeal() {
        return TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
    }

    /**
     * Two groups on one deal: `B` (Open Contract, three items) and `I` (Closing Prep, one item).
     * Returns the deal.
     */
    private static Transaction__c dealWithTwoGroups() {
        Transaction__c deal = newDeal();

        List<Checklist__c> groups = TestDataFactory.createChecklists(2, deal.Id, false);
        groups[0].Group_Letter__c = 'B';
        groups[0].Group_Name__c = 'Earnest Money & Wires';
        groups[0].Stage__c = 'Open Contract';
        groups[0].Sequence__c = 2;
        groups[1].Group_Letter__c = 'I';
        groups[1].Group_Name__c = 'Closing';
        groups[1].Stage__c = 'Closing Prep';
        groups[1].Sequence__c = 9;
        insert groups;

        List<Checklist_Item__c> bItems = TestDataFactory.createChecklistItems(3, groups[0].Id, false);
        // 🔴 THE CANARY. A subject carrying NEITHER marker, on an item whose booleans say it is both
        // critical and a wire step. A controller that derived either fact from the subject text
        // renders this row plain and the assertions on it fail. Mirrors the Jest suite and
        // ChecklistRollupServiceTest.
        bItems[0].Subject__c = 'Confirm wiring instructions verbally with the escrow officer';
        bItems[0].Is_Critical__c = true;
        bItems[0].Is_Wire_Verification__c = true;
        // 🔴 THE CONVERSE CANARY. Carries "(anti-fraud)" in the subject, booleans false.
        bItems[1].Subject__c = 'Order the ALTA survey (anti-fraud)';
        bItems[1].Is_Critical__c = false;
        bItems[1].Is_Wire_Verification__c = false;
        bItems[2].Subject__c = 'Fully execute PSA';
        bItems[2].Flag__c = 'Completed';
        insert bItems;

        List<Checklist_Item__c> iItems = TestDataFactory.createChecklistItems(1, groups[1].Id, false);
        iItems[0].Subject__c = 'Send closing wire to title company';
        iItems[0].Stage__c = 'Closing Prep';
        insert iItems;

        return deal;
    }

    private static Map<String, ChecklistController.ChecklistRow> byLetter(
        List<ChecklistController.ChecklistRow> rows
    ) {
        Map<String, ChecklistController.ChecklistRow> out =
            new Map<String, ChecklistController.ChecklistRow>();
        for (ChecklistController.ChecklistRow row : rows) {
            out.put(row.letter, row);
        }
        return out;
    }

    private static ChecklistController.ItemRow itemBySubject(
        ChecklistController.ChecklistRow row,
        String fragment
    ) {
        for (ChecklistController.ItemRow item : row.items) {
            if (item.subject != null && item.subject.contains(fragment)) {
                return item;
            }
        }
        return null;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // getChecklist()
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void getChecklistReturnsGroupsInSequenceOrderWithTheirItems() {
        Transaction__c deal = dealWithTwoGroups();

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both groups returned');
        // Ordered by Checklist__c.Sequence__c (2 then 9), not by insert order or by Id.
        Assert.areEqual('B', rows[0].letter, 'Group sequence 2 comes first');
        Assert.areEqual('I', rows[1].letter, 'Group sequence 9 comes second');

        ChecklistController.ChecklistRow b = rows[0];
        Assert.areEqual('Earnest Money & Wires', b.name, 'Group name carried through');
        Assert.areEqual('Danish', b.ownerLabel, 'Owner label is the ROLE, carried from the group');
        Assert.areEqual('Open Contract', b.stage, 'Stage drives the LWC phase mapping');
        Assert.areEqual(3, b.items.size(), 'All three items on the group');
        Assert.areEqual(3, b.total, 'Total counted from the items');
        Assert.areEqual(1, b.complete, 'One item is Completed');
        Assert.areEqual(33, b.pct, '1 of 3 rounds to 33');
    }

    @isTest
    static void getChecklistDerivesCriticalAndWireFromTHEFIELDSNotTheSubject() {
        // 🔴 RISK 1 AT THE APEX BOUNDARY. Both directions, so an implementation that ORed the field
        // with a subject parse would still fail one of them.
        Transaction__c deal = dealWithTwoGroups();

        Test.startTest();
        Map<String, ChecklistController.ChecklistRow> rows =
            byLetter(ChecklistController.getChecklist(deal.Id));
        Test.stopTest();

        ChecklistController.ItemRow markerless = itemBySubject(rows.get('B'), 'escrow officer');
        Assert.isNotNull(markerless, 'The markerless canary item is present');
        Assert.isTrue(
            markerless.isCritical,
            'A MARKERLESS subject must still be critical — the flag is Is_Critical__c, not the text'
        );
        Assert.isTrue(
            markerless.isWireVerification,
            'A MARKERLESS subject must still be a wire step — the flag is Is_Wire_Verification__c'
        );

        ChecklistController.ItemRow marked = itemBySubject(rows.get('B'), 'ALTA survey');
        Assert.isNotNull(marked, 'The marked-but-false canary item is present');
        Assert.isFalse(
            marked.isCritical,
            'A subject containing "(anti-fraud)" must NOT be critical when Is_Critical__c is false'
        );
        Assert.isFalse(
            marked.isWireVerification,
            'A subject containing "(anti-fraud)" must NOT be a wire step when the flag is false'
        );

        // The subject is passed through VERBATIM, markers and all. Stripping is the LWC's job, and
        // keeping it server-side would put a second parser back into the pipeline.
        Assert.areEqual(
            'Order the ALTA survey (anti-fraud)',
            marked.subject,
            'The controller must not strip the marker — that is a presentation concern'
        );
    }

    @isTest
    static void getChecklistCountsFromTheITEMSNotFromTheStoredRollupFields() {
        // 🔴 THE DOCUMENTED DECISION, MADE FALSIFIABLE. Items_Total__c / Items_Complete__c are
        // Apex-written by ChecklistRollupService AFTER the item trigger fires, so between a
        // completion and its rollup they can lag. If the controller read them, one screen could
        // contradict itself — a header reading "3 of 10" above a list showing four ticked rows.
        // Here the stored fields are deliberately set to nonsense; the DTO must ignore them.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(4, checklistGroup.Id, false);
        items[0].Flag__c = 'Completed';
        items[1].Flag__c = 'Verified';
        insert items;

        // No ChecklistTrigger exists, so this stands: nothing recomputes it behind us.
        update new Checklist__c(Id = checklistGroup.Id, Items_Total__c = 99, Items_Complete__c = 0);

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        Assert.areEqual(4, rows[0].total, 'Total is the number of items actually returned, not 99');
        Assert.areEqual(
            2,
            rows[0].complete,
            'Complete counts Completed AND Verified from the items, not the stored 0'
        );
        Assert.areEqual(50, rows[0].pct, '2 of 4');
    }

    @isTest
    static void getChecklistTreatsVerifiedAsDone() {
        // Flag__c is a lossy picklist: DONE means Completed OR Verified. A count written against
        // Completed alone silently undercounts every verified wire item.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, false);
        items[0].Flag__c = 'Verified';
        insert items;

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        Assert.areEqual(1, rows[0].complete, 'A Verified item counts as done');
        Boolean sawDone = false;
        for (ChecklistController.ItemRow item : rows[0].items) {
            if (item.flag == 'Verified') {
                sawDone = item.done;
            }
        }
        Assert.isTrue(sawDone, 'ItemRow.done is true for a Verified item');
    }

    @isTest
    static void getChecklistFlagsAnItemWithAnUnmetPrerequisiteAsBlocked() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, true);
        TestDataFactory.linkPrerequisite(items[1], items[0], true);

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        Map<Id, ChecklistController.ItemRow> byId = new Map<Id, ChecklistController.ItemRow>();
        for (ChecklistController.ItemRow item : rows[0].items) {
            byId.put(item.id, item);
        }
        Assert.isTrue(byId.get(items[1].Id).blocked, 'The dependent item is blocked');
        Assert.isFalse(byId.get(items[0].Id).blocked, 'The prerequisite itself is not blocked');
    }

    @isTest
    static void getChecklistDropsAGroupWithNoItems() {
        // An empty conditional group (F on a no-loan deal) would otherwise render a 0 / 0 shell
        // that reads as broken. Matches the legacy twin's behaviour.
        Transaction__c deal = newDeal();
        List<Checklist__c> groups = TestDataFactory.createChecklists(2, deal.Id, true);
        TestDataFactory.createChecklistItems(2, groups[0].Id, true);

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the group that has items is returned');
        Assert.areEqual(2, rows[0].total, 'And it carries its items');
    }

    @isTest
    static void getChecklistReturnsAnEmptyListForADealWithNoChecklistAndForNull() {
        // Both are MEANINGFUL, not exceptional: the LWC renders an explicit empty state.
        Transaction__c deal = newDeal();

        Test.startTest();
        List<ChecklistController.ChecklistRow> none = ChecklistController.getChecklist(deal.Id);
        List<ChecklistController.ChecklistRow> nullId = ChecklistController.getChecklist(null);
        Test.stopTest();

        Assert.isNotNull(none, 'Never null — an empty list');
        Assert.areEqual(0, none.size(), 'A deal with no checklist returns nothing, without throwing');
        Assert.isNotNull(nullId, 'Never null for a null id either');
        Assert.areEqual(0, nullId.size(), 'A null transactionId is a no-op, not an exception');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // The two Phase 3 display selectors
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void displaySelectorsHonourTheEmptyListContract() {
        // 🔴 A LIST SELECTOR MUST RETURN AN EMPTY LIST, NEVER NULL, FOR EVERY DEGENERATE INPUT.
        // The controller iterates the result without a null guard; a null here is a screen-wide
        // NullPointerException surfaced to the user as the generic "could not be loaded".
        Test.startTest();
        List<Checklist__c> nullGroups = ChecklistSelector.selectForDisplayByTransactionIds(null);
        List<Checklist__c> emptyGroups =
            ChecklistSelector.selectForDisplayByTransactionIds(new Set<Id>());
        List<Checklist_Item__c> nullItems =
            ChecklistItemSelector.selectForDisplayByTransactionIds(null);
        List<Checklist_Item__c> emptyItems =
            ChecklistItemSelector.selectForDisplayByTransactionIds(new Set<Id>());
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.isNotNull(nullGroups, 'Checklist selector: null input');
        Assert.areEqual(0, nullGroups.size(), 'Checklist selector: null input returns empty');
        Assert.isNotNull(emptyGroups, 'Checklist selector: empty input');
        Assert.areEqual(0, emptyGroups.size(), 'Checklist selector: empty input returns empty');
        Assert.isNotNull(nullItems, 'Item selector: null input');
        Assert.areEqual(0, nullItems.size(), 'Item selector: null input returns empty');
        Assert.isNotNull(emptyItems, 'Item selector: empty input');
        Assert.areEqual(0, emptyItems.size(), 'Item selector: empty input returns empty');
        Assert.areEqual(
            0,
            queries,
            'A degenerate input must SHORT-CIRCUIT, not run a query that matches nothing — this is '
                + 'what keeps the guard clauses from being deleted as redundant'
        );
    }

    @isTest
    static void checklistDisplaySelectorReturnsOrderedGroupsWithTheDisplayFields() {
        Transaction__c deal = dealWithTwoGroups();

        Test.startTest();
        List<Checklist__c> groups =
            ChecklistSelector.selectForDisplayByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(2, groups.size(), 'Both groups on the deal');
        Assert.areEqual('B', groups[0].Group_Letter__c, 'Ordered by Sequence__c ascending');
        Assert.areEqual('I', groups[1].Group_Letter__c, 'Then the later group');
        // Every field the DTO reads must be in the SELECT — reading an unselected field is a
        // runtime SObjectException with no compile-time warning.
        Assert.areEqual('Earnest Money & Wires', groups[0].Group_Name__c, 'Group_Name__c selected');
        Assert.areEqual('Danish', groups[0].Owner_Label__c, 'Owner_Label__c selected');
        Assert.areEqual('Open Contract', groups[0].Stage__c, 'Stage__c selected');
        Assert.isFalse(groups[0].Is_Conditional__c, 'Is_Conditional__c selected');
        Assert.isNotNull(groups[0].Transaction__c, 'The master-detail parent is selected');
    }

    @isTest
    static void itemDisplaySelectorReturnsItemsOrderedByGroupThenSequence() {
        Transaction__c deal = dealWithTwoGroups();

        Test.startTest();
        // The group read supplies the letters. This is not a convenience: see the assertion note
        // below for why the item read deliberately cannot supply them itself.
        List<Checklist__c> groups =
            ChecklistSelector.selectForDisplayByTransactionIds(new Set<Id>{ deal.Id });
        List<Checklist_Item__c> items =
            ChecklistItemSelector.selectForDisplayByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Map<Id, String> letterByChecklistId = new Map<Id, String>();
        for (Checklist__c grp : groups) {
            letterByChecklistId.put(grp.Id, grp.Group_Letter__c);
        }

        Assert.areEqual(4, items.size(), 'Every item on the deal, across both groups');

        // ═══════════════════════════════════════════════════════════════════════════════════
        // ⚠ ASSERTED VIA THE `Checklist__c` ID FIELD, NOT VIA `Checklist__r.Group_Letter__c`.
        // ═══════════════════════════════════════════════════════════════════════════════════
        // The first version of this test read the spanning field, which the display selector does
        // NOT select - a `System.SObjectException` at runtime, and the test never ran because its
        // class had already been dropped from a deploy for an unrelated compile error.
        //
        // The fix is on the TEST side deliberately. Adding `Checklist__r.Group_Letter__c` to the
        // SELECT would have made this line pass, and would have violated that selector's own
        // stated rule: under `USER_MODE` every extra column is another FLS grant that must exist
        // or the whole query throws and the whole screen goes dark, so a field is selected only
        // when a consumer READS it. `ChecklistController` never dereferences this one - it takes
        // the letter from the `ChecklistSelector` result and joins items by the `Checklist__c` Id
        // field. Asserting the way production actually resolves the letter is both honest and a
        // closer test of the real code path.
        //
        // ⚠ `ORDER BY Checklist__r.Sequence__c` is unaffected: Apex permits ordering on an
        // unselected field. Only the READ throws.
        Assert.areEqual('B', letterByChecklistId.get(items[0].Checklist__c), 'Group B first');
        Assert.areEqual('B', letterByChecklistId.get(items[1].Checklist__c), 'Still group B');
        Assert.areEqual('B', letterByChecklistId.get(items[2].Checklist__c), 'Still group B');
        Assert.areEqual('I', letterByChecklistId.get(items[3].Checklist__c), 'Group I last');
        Assert.isTrue(
            items[0].Sequence__c < items[1].Sequence__c,
            'Within a group, ordered by item Sequence__c'
        );
        // The spanning read the DTO DOES depend on, and which IS selected.
        Assert.isNotNull(items[0].Checklist__r.Transaction__c, 'Grandparent deal traversed');
    }

    @isTest
    static void itemDisplaySelectorPopulatesTheCompletedByNameSpanningRead() {
        // Completed_By__r.Name is what retires the LastModifiedBy approximation. If the spanning
        // read is dropped from the SELECT the DTO silently renders a blank completer on every
        // finished row, which looks like missing data rather than a bug.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        Test.startTest();
        ChecklistItemService.complete(new List<ChecklistItemService.CompletionRequest>{
            new ChecklistItemService.CompletionRequest(item.Id, null)
        });
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        ChecklistController.ItemRow completed = rows[0].items[0];
        Assert.isTrue(completed.done, 'The item completed');
        Assert.areEqual(
            UserInfo.getName(),
            completed.completedByName,
            'The REAL completer resolves through the Completed_By__r spanning read'
        );
        Assert.isNotNull(completed.completedDateTime, 'And the completion timestamp comes through');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Write boundary — AuraHandledException mapping
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completeItemDelegatesAndPersists() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);

        Test.startTest();
        ChecklistController.completeItem(item.Id, 'done via the controller');
        Test.stopTest();

        Checklist_Item__c saved = [
            SELECT Flag__c, Comment__c FROM Checklist_Item__c WHERE Id = :item.Id
        ];
        Assert.areEqual('Completed', saved.Flag__c, 'The controller delegated the write');
        Assert.areEqual('done via the controller', saved.Comment__c, 'And carried the comment');
    }

    @isTest
    static void completeItemSurfacesAWireRefusalVERBATIMNotTheGenericMessage() {
        // 🔴 The generic message tells the user to "refresh the page and try again", which can never
        // work here. The specific one names the dialog they actually need.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        String message;
        Test.startTest();
        try {
            ChecklistController.completeItem(item.Id, null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('Verify Wiring Instructions'),
            'The user-actionable refusal must be surfaced verbatim, not swallowed: ' + message
        );
        Assert.isFalse(
            message.contains('Refresh the page and try again'),
            'It must NOT be replaced by the generic write-failure message: ' + message
        );
    }

    @isTest
    static void completeItemSurfacesAPrerequisiteRefusalVERBATIM() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, true);
        TestDataFactory.linkPrerequisite(items[1], items[0], true);

        String message;
        Test.startTest();
        try {
            ChecklistController.completeItem(items[1].Id, null);
            Assert.fail('Expected an AuraHandledException from the prerequisite gate');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(message), 'The refusal carries a message');
        Assert.isFalse(
            message.contains('Refresh the page and try again'),
            'A wire-fraud prerequisite refusal must NOT be flattened into the generic message: '
                + message
        );
    }

    @isTest
    static void completeItemSurfacesANotFoundRefusalVERBATIM() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(checklistGroup.Id, true);
        Id goneId = item.Id;
        delete item;

        String message;
        Test.startTest();
        try {
            ChecklistController.completeItem(goneId, null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('no longer available'),
            'The not-found guidance reaches the user: ' + message
        );
    }

    @isTest
    static void recordWireVerificationDelegatesAndPersistsTheEvidence() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        Test.startTest();
        ChecklistController.recordWireVerification(item.Id, 'Jane Doe', '713-555-0142', 'called the published number');
        Test.stopTest();

        Checklist_Item__c saved = [
            SELECT Flag__c, Verified_By_Name__c, Verification_Phone__c,
                   Verbal_Verification_Completed__c, Comment__c
            FROM Checklist_Item__c WHERE Id = :item.Id
        ];
        Assert.areEqual('Verified', saved.Flag__c, 'Verified, not merely Completed');
        Assert.areEqual('Jane Doe', saved.Verified_By_Name__c, 'Confirmer recorded');
        Assert.areEqual('713-555-0142', saved.Verification_Phone__c, 'Number recorded');
        Assert.isTrue(saved.Verbal_Verification_Completed__c, 'Verbal verification recorded');
        Assert.isTrue(
            saved.Comment__c.contains('called the published number'),
            'The verifier comment is kept'
        );
    }

    @isTest
    static void recordWireVerificationSurfacesTheMissingEvidenceRuleVERBATIM() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        String message;
        Test.startTest();
        try {
            ChecklistController.recordWireVerification(item.Id, '  ', '713-555-0142', null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('required'),
            'The name/phone rule reaches the user verbatim: ' + message
        );
        Assert.isFalse(
            reload(item.Id).Verbal_Verification_Completed__c,
            'Nothing half-written'
        );
    }

    private static Checklist_Item__c reload(Id itemId) {
        return [
            SELECT Verbal_Verification_Completed__c, Flag__c
            FROM Checklist_Item__c WHERE Id = :itemId
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // The failure channels — every catch block in the controller
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void getChecklistShowsTheGENERICReadFailureWhenTheRUNNINGUSERHasNoGrants() {
        // ═══════════════════════════════════════════════════════════════════════════════════
        // 🔴 THIS IS THE DOCUMENTED DEPLOY-DAY FAILURE MODE, MADE EXECUTABLE.
        // ═══════════════════════════════════════════════════════════════════════════════════
        // Both display selectors are `WITH USER_MODE` deliberately, and a Metadata-API-deployed
        // custom object arrives with no object permissions and its fields with ZERO
        // FieldPermissions rows for anybody. So before the permission pass lands, this screen
        // errors for EVERYONE - loudly, which is correct. The class header says exactly that; this
        // test is what makes the claim more than a comment, and it covers `getChecklist`'s generic
        // catch, which no happy-path test reaches.
        //
        // ⚠ THE PERSONA IS `Minimum Access - Salesforce` WITH NO PERMISSION SETS AT ALL. That is
        // the honest shape of "the grant has not been made yet". A `Standard User` persona would
        // prove nothing here for a different reason than usual: for a CUSTOM object no profile
        // grants access implicitly, so either profile denies - but Minimum Access says what is
        // meant.
        Transaction__c deal = dealWithTwoGroups();

        User ungranted;
        // Setup objects (User) and non-setup objects cannot be mixed in one transaction; the
        // runAs isolation block is what separates them.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ungranted = buildUngrantedUser();
            insert ungranted;
        }

        String message;
        Test.startTest();
        System.runAs(ungranted) {
            try {
                ChecklistController.getChecklist(deal.Id);
                Assert.fail('Expected an AuraHandledException - a user with no grants cannot read '
                    + 'Checklist__c under USER_MODE');
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('could not be loaded'),
            'The user gets the fixed generic read-failure message: ' + message
        );
        // 🔴 NO PLATFORM DETAIL MAY REACH THE USER. A QueryException here reads
        // "No such column 'Flag__c' on entity 'Checklist_Item__c'" - an FLS denial wearing a
        // schema error, which leaks field API names and tells the user nothing they can act on.
        Assert.isFalse(
            message.containsIgnoreCase('No such column') || message.contains('__c'),
            'Platform detail must stay in the debug log, not the toast: ' + message
        );
    }

    @isTest
    static void recordWireVerificationMapsAPlatformFailureToTheGenericMessage() {
        // Covers the generic write catch. The failure is induced with a confirmer name longer than
        // Verified_By_Name__c's Text(120) - deterministic, no user fixture. See the twin test in
        // ChecklistItemServiceTest for why this branch matters.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;

        String message;
        Test.startTest();
        try {
            ChecklistController.recordWireVerification(item.Id, 'N'.repeat(200), '713-555-0142', null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('could not be updated'),
            'An unexpected platform failure gets the FIXED generic message: ' + message
        );
        Assert.isFalse(
            message.containsIgnoreCase('STRING_TOO_LONG')
                || message.contains('Verified_By_Name__c')
                || message.containsIgnoreCase('FIELD_INTEGRITY'),
            'Raw DmlException text leaks field API names and must never be concatenated in: '
                + message
        );
    }

    @isTest
    static void recordWireVerificationSurfacesANotFoundRefusalVERBATIM() {
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false)[0];
        item.Is_Wire_Verification__c = true;
        insert item;
        Id goneId = item.Id;
        delete item;

        String message;
        Test.startTest();
        try {
            ChecklistController.recordWireVerification(goneId, 'Jane Doe', '713-555-0142', null);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            message.contains('no longer available'),
            'The actionable not-found guidance reaches the user: ' + message
        );
    }

    @isTest
    static void recordWireVerificationSurfacesAPrerequisiteRefusalVERBATIM() {
        // A wire-verification item can itself be gated - nothing says the anti-fraud call is always
        // first in its group. This covers the prerequisite catch on the WIRE path, which the
        // completion path's twin test does not reach.
        Transaction__c deal = newDeal();
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, false);
        items[1].Is_Wire_Verification__c = true;
        insert items;
        TestDataFactory.linkPrerequisite(items[1], items[0], true);

        String message;
        Test.startTest();
        try {
            ChecklistController.recordWireVerification(items[1].Id, 'Jane Doe', '713-555-0142', null);
            Assert.fail('Expected an AuraHandledException from the prerequisite gate');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(message), 'The refusal carries a message');
        Assert.isFalse(
            message.contains('could not be updated'),
            'A wire-fraud prerequisite refusal must NOT be flattened into the generic message: '
                + message
        );
        Assert.isFalse(
            reload(items[1].Id).Verbal_Verification_Completed__c,
            'And no evidence was written on a refused save'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 PHASE 5 — the capture boundary.
    //
    // `getCaptureContext` PERFORMS DML (it provisions the `Loan__c` / `Insurance_Binder__c`) and
    // carries three catch arms; `linkCaptureDocuments` carries two; `completeItem` gained two more
    // verbatim-surfacing arms; and `ItemRow.hasCapture` is a new wire-contract member. This block
    // covers all four, to the standard the four existing verbatim-surfacing tests above set.
    //
    // ⚠ CONTENT COST: 1 `ContentVersion` row in this whole block, in
    // `linkCaptureDocumentsFilesTheDocumentAgainstTheItem`. Every insert consumes one of the org's
    // 2,500-per-rolling-24-hours `ContentPublication` allowance and TEST ROLLBACK DOES NOT REFUND
    // IT (`.claude/rules/content-publication-rule.md`). The idempotency, multi-file and
    // deal-vs-item facts are proven in `ChecklistCaptureServiceTest`, which budgets 5 rows; this
    // class only needs to prove the CONTROLLER passes the ids through, which one row does.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /** One item at an exact coordinate, under a group re-pointed to `letter`. */
    private static Checklist_Item__c itemAtCoordinate(Id dealId, String letter, Integer sequence) {
        Checklist__c checklistGroup = TestDataFactory.createChecklist(dealId, false);
        checklistGroup.Group_Letter__c = letter;
        insert checklistGroup;
        return TestDataFactory.createChecklistItems(sequence, checklistGroup.Id, true)[sequence - 1];
    }

    @isTest
    static void getChecklistMarksOnlyCaptureItemsWithHasCapture() {
        // 🔴 `hasCapture` IS A WIRE-CONTRACT MEMBER. The LWC routes the click on it, so a controller
        // that stopped populating it would send every capture item to the plain confirm dialog and
        // the whole feature would silently disappear with no error anywhere.
        Transaction__c deal = newDeal();
        Checklist__c groupF = TestDataFactory.createChecklist(deal.Id, false);
        groupF.Group_Letter__c = 'F';
        insert groupF;
        // F1..F9: F5, F6 and F9 capture; the other six do not. Both halves in ONE group, so a
        // component that flagged everything and one that flagged nothing both fail.
        TestDataFactory.createChecklistItems(9, groupF.Id, true);

        Test.startTest();
        List<ChecklistController.ChecklistRow> rows = ChecklistController.getChecklist(deal.Id);
        Test.stopTest();

        // ⚠ KEYED BY Integer, NOT Decimal. `Sequence__c` is a Number(3,0) and comes back as a
        // Decimal whose SCALE is not guaranteed; `Map<Decimal, ...>` hashes on the decimal
        // representation, so a key stored as `5.0` would not be found by a lookup of `5` and this
        // test would fail against perfectly correct code. `intValue()` is the same normalisation
        // `ChecklistCaptureDefProvider.forCoordinate` applies.
        Map<Integer, Boolean> captureBySequence = new Map<Integer, Boolean>();
        for (ChecklistController.ItemRow item : rows[0].items) {
            captureBySequence.put(item.sequence.intValue(), item.hasCapture);
        }
        Assert.areEqual(true, captureBySequence.get(5), 'F5 selects the lender');
        Assert.areEqual(true, captureBySequence.get(6), 'F6 records the term sheet');
        Assert.areEqual(true, captureBySequence.get(9), 'F9 records the bank account type');
        Assert.areEqual(false, captureBySequence.get(7),
            'F7 forms the deal entity and has no Loan__c field behind it');
        Assert.areEqual(false, captureBySequence.get(8),
            'F8 opens the account; F9 records its TYPE. Flagging F8 would open an empty dialog');
        Assert.areEqual(false, captureBySequence.get(1), 'F1 builds the loan package - no capture');
    }

    @isTest
    static void getCaptureContextProvisionsTheTargetAndReturnsItsShape() {
        Transaction__c deal = newDeal();
        Checklist_Item__c f9 = itemAtCoordinate(deal.Id, 'F', 9);
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c],
            'Control: nothing exists until the dialog is opened');

        Test.startTest();
        ChecklistController.CaptureRow row = ChecklistController.getCaptureContext(f9.Id);
        Test.stopTest();

        Assert.isNotNull(row, 'F9 records something, so a context comes back');
        // ⚠ THE MODE IS A STRING ON THE WIRE. An Apex enum does not marshal to JavaScript as
        // anything the LWC can compare against, so the controller stringifies it once. The LWC
        // compares against these exact literals.
        Assert.areEqual('TARGET_FIELDS', row.captureMode, 'Stringified enum, not an enum');
        Assert.areEqual('Loan__c', row.objectApiName, 'and it names the object for the form');
        Assert.areEqual(1, [SELECT COUNT() FROM Loan__c], 'Opening the dialog PROVISIONED the loan');
        Assert.areEqual([SELECT Id FROM Loan__c LIMIT 1].Id, row.targetRecordId,
            'and the form binds to that record. A null here makes lightning-record-edit-form a '
                + 'CREATE form, which would make a second Loan__c on every open');
        Assert.areEqual(new List<String>{ 'Bank_Account_Type__c' }, row.captureFields,
            'offering exactly the field the step is about');
        Assert.areEqual(false, row.satisfied, 'which is blank, so the requirement is not met');
    }

    @isTest
    static void getCaptureContextReturnsNullForAnItemThatRecordsNothing() {
        // Null is the NORMAL answer for 64 of the 82 items, and the LWC reads it as "use the plain
        // confirm dialog". It must not be an exception.
        Transaction__c deal = newDeal();
        Checklist_Item__c ordinary = itemAtCoordinate(deal.Id, 'D', 3);

        Test.startTest();
        ChecklistController.CaptureRow row = ChecklistController.getCaptureContext(ordinary.Id);
        Test.stopTest();

        Assert.isNull(row, 'An item with no capture returns null rather than an empty context');
    }

    @isTest
    static void getCaptureContextSurfacesTheNotFoundMessageVerbatim() {
        // The `ItemNotFoundException` arm, reached DETERMINISTICALLY: the item is created and then
        // deleted, so `selectForCompletion` resolves nothing and the controller raises its own
        // not-found rather than dereferencing an empty map.
        // ⚠ NOT reached via `runAs` on purpose. An ungranted principal fails EARLIER, inside the
        // USER_MODE query, with `QueryException: No such column` — which lands in the generic catch,
        // not this arm. A runAs test would therefore assert on the wrong branch while looking like
        // it asserted on this one; that case is covered separately below.
        Transaction__c deal = newDeal();
        Checklist_Item__c f9 = itemAtCoordinate(deal.Id, 'F', 9);
        Id vanishedId = f9.Id;
        delete f9;

        String message;
        Test.startTest();
        try {
            ChecklistController.getCaptureContext(vanishedId);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'An item that no longer resolves must be refused, not served');
        Assert.isTrue(message.containsIgnoreCase('refresh'),
            'and "refresh the page" IS the fix here, so it must reach the user, was: ' + message);
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c],
            'and a failed context build provisions nothing');
    }

    @isTest
    static void getCaptureContextNeverLeaksPlatformTextToAnUngrantedPrincipal() {
        // 🔴 THE PROPERTY THAT MATTERS FOR THIS PRINCIPAL IS NON-LEAKAGE, NOT THE EXACT MESSAGE.
        // An ungranted principal fails inside the USER_MODE query with
        // `QueryException: No such column ...` — an FLS denial wearing a schema error — which the
        // generic catch maps to a fixed message. Asserting a specific sentence here would be
        // asserting on whichever branch happened to fire; asserting that no field API name, no
        // SOQL and no exception type reaches the client is the real contract, and it is what stops
        // a provisioning gap becoming an information disclosure.
        Transaction__c deal = newDeal();
        Checklist_Item__c f9 = itemAtCoordinate(deal.Id, 'F', 9);
        User ungranted = buildUngrantedUser();
        insert ungranted;

        String message;
        Test.startTest();
        System.runAs(ungranted) {
            try {
                ChecklistController.getCaptureContext(f9.Id);
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNotNull(message, 'A principal with no grants must be refused, not served');
        for (String leak : new List<String>{
            'No such column', 'SELECT', 'Loan__c', 'Checklist_Item__c', 'QueryException',
            'INSUFFICIENT_ACCESS'
        }) {
            Assert.isFalse(message.contains(leak),
                'The message must not carry platform text (' + leak + '), was: ' + message);
        }
    }

    @isTest
    static void completeItemSurfacesACaptureRefusalVerbatim() {
        // 🔴 THE ARM THAT MATTERS MOST. "Record the selected lender before completing this item"
        // is actionable; the generic "refresh the page and try again" can NEVER put a lender name
        // on a Loan__c, so mapping this to the generic message would make an ENFORCED control look
        // like a BROKEN PAGE - the exact defect the prerequisite arm above was written to prevent.
        Transaction__c deal = newDeal();
        Checklist_Item__c f5 = itemAtCoordinate(deal.Id, 'F', 5);

        String message;
        Test.startTest();
        try {
            ChecklistController.completeItem(f5.Id, null);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'The completion is refused');
        Assert.isTrue(message.containsIgnoreCase('lender'),
            'and the refusal names the missing output, was: ' + message);
        Assert.isFalse(message.containsIgnoreCase('contact your administrator'),
            'It must NOT be the generic write-failure message - that is advice nobody can act on');
    }

    @isTest
    static void linkCaptureDocumentsFilesTheDocumentAgainstTheItem() {
        // CONTENT COST: 1 ContentVersion row. See the block header.
        Transaction__c deal = newDeal();
        Checklist_Item__c c7 = itemAtCoordinate(deal.Id, 'C', 7);
        ContentVersion version = new ContentVersion(
            Title = 'PCR',
            PathOnClient = 'PCR.pdf',
            VersionData = Blob.valueOf('test document body')
        );
        insert version;
        Id documentId =
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;

        Test.startTest();
        Integer created = ChecklistController.linkCaptureDocuments(c7.Id, new List<Id>{ documentId });
        Test.stopTest();

        Assert.areEqual(1, created, 'The controller passes the ids through to the service');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :c7.Id],
            'and the link lands on the ITEM, which is what makes the document guard mean something');
    }

    @isTest
    static void linkCaptureDocumentsSurfacesAMissingItemVerbatim() {
        String message;
        Test.startTest();
        try {
            ChecklistController.linkCaptureDocuments(null, new List<Id>());
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'A null item id is refused rather than silently ignored');
        Assert.isTrue(message.containsIgnoreCase('refresh'), 'with actionable advice, was: ' + message);
    }

    /**
     * Builds (but does not insert) a `Minimum Access - Salesforce` user holding NO permission sets.
     *
     * For a CUSTOM object no profile grants access implicitly, so this persona genuinely cannot
     * read `Checklist__c` / `Checklist_Item__c` - which is the state the org is in between
     * deploying the schema and running the permission pass.
     */
    private static User buildUngrantedUser() {
        Profile minimumAccess = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = 'chklst' + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'No',
            LastName = 'Grants',
            Alias = 'nogrant',
            Email = 'no.grants.checklist@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
