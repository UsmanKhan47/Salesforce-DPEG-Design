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
        List<Checklist_Item__c> items =
            ChecklistItemSelector.selectForDisplayByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(4, items.size(), 'Every item on the deal, across both groups');
        // ORDER BY Checklist__r.Sequence__c then Sequence__c: all of group B (seq 2) before the
        // single item of group I (seq 9). The controller relies on this and never re-sorts.
        Assert.areEqual('B', items[0].Checklist__r.Group_Letter__c, 'Group B first');
        Assert.areEqual('B', items[1].Checklist__r.Group_Letter__c, 'Still group B');
        Assert.areEqual('B', items[2].Checklist__r.Group_Letter__c, 'Still group B');
        Assert.areEqual('I', items[3].Checklist__r.Group_Letter__c, 'Group I last');
        Assert.isTrue(
            items[0].Sequence__c < items[1].Sequence__c,
            'Within a group, ordered by item Sequence__c'
        );
        // The spanning read the DTO depends on.
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
}
