/**
 * Tests for the wire-fraud prerequisite gate on the `Checklist_Item__c` model.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR PHASE 0 BYPASS SHAPES ARE EACH TESTED HERE, INCLUDING THE TWO THAT ARE DEAD BY
 *    CONSTRUCTION - BECAUSE "IT CANNOT HAPPEN" IS A CLAIM, AND AN UNTESTED CLAIM IS A COMMENT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   SHAPE 1 blank-and-complete   -> refusesBlankingTheLinkAndCompletingInOneSave (still reachable)
 *   SHAPE 2 repoint-at-a-done-item -> refusesRepointingTheLinkAtACompletedItem  (still reachable)
 *           and its cross-deal amplification -> refusesALinkPointingAtAnotherDeal
 *   SHAPE 3a re-parent the dependent -> reparentingAnItemIsRefusedByThePlatform (DEAD: the platform
 *           itself refuses it, which is what this test proves rather than assumes)
 *   SHAPE 3b renumber the prerequisite -> renumberingThePrerequisiteDoesNotBreakTheLink (DEAD: the
 *           link is an Id, so this test asserts the gate STILL REFUSES afterwards, which is the
 *           exact assertion Phase 0 could not make)
 *
 * 🔴 THE TEST RUNNER IS AN ADMINISTRATOR, AND THAT SILENTLY DISARMS BRANCH (B).
 * `TransactionActionPermissionService.hasPrereqOverrideAccess()` returns true for anyone with
 * "Modify All Data", which every test-running admin has. A disarm test written without forcing that
 * false passes VACUOUSLY - it proves the admin bypass works, not the narrowing it is named for.
 * Every disarm test below pins the cache to false through the `@TestVisible` seam first, and
 * `allowsAnOverrideHolderToRepairTheLink` pins it true to prove the escape hatch is reachable.
 *
 * BULK VOLUME IS 251, per `.claude/rules/bulk-test-rule.md`: the platform chunks before-update at
 * 200 rows, so 251 forces a SECOND firing and is what makes "exactly one query per chunk, never a
 * function of row count" falsifiable. The governor assertions read the service's own in-context
 * counters, NOT `Limits.getQueries()` after `Test.stopTest()` - stopTest restores the pre-test
 * counters and the obvious assertion passes vacuously.
 */
@isTest
private class ChecklistItemPrerequisiteServiceTest {

    private static final String FLAG_NONE = 'None';
    private static final String FLAG_COMPLETED = 'Completed';
    private static final String FLAG_VERIFIED = 'Verified';

    /**
     * The fixture group's name, overriding the factory's generic 'Test Group A'.
     *
     * 🔴 THIS IS WHAT MAKES `fixtureItems()` UNAMBIGUOUS, AND IT IS NOT DECORATION. Three tests
     * below build a SECOND deal and a second group mid-test, and the factory names every group it
     * creates 'Test Group A' - so neither a bare query nor one filtered on the factory's own group
     * name can tell the fixture apart from them. Filtering on a name only this class writes can. A
     * Day-0 fan-out group cannot collide either: those names come from
     * `Task_Group_Def__mdt.Group_Name__c`, which are business group names.
     */
    private static final String FIXTURE_GROUP = 'PREREQ FIXTURE GROUP';

    /**
     * 🔴 `createTransactionsOnChecklistModel`, NOT `createTransactions`. The plain factory populates
     * `Contract_Executed_Date__c`, the FIRST entry filter of `flows/Transaction_Task_Fanout`, which
     * was repointed onto `ChecklistFanoutService` on 2026-09-03. A plain fixture deal therefore
     * materialises ~96 EXTRA `Checklist_Item__c` rows, sequenced from 1, on the same deal - and
     * `fixtureItems()` sorts by `Sequence__c`, so `items[0]` and `items[1]` would stop being the
     * prerequisite and the dependent and nearly every test in this class would assert against the
     * wrong pair. The date is load-bearing for nothing here: no assertion reads it and none reads a
     * value derived from it - `Due_Date__c` is written explicitly by `createChecklistItems`, and the
     * gate itself never touches either field.
     */
    @TestSetup
    static void setupTestData() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, false);
        checklistGroup.Group_Name__c = FIXTURE_GROUP;
        insert checklistGroup;
        // Two items: [0] is the prerequisite (B2), [1] is the dependent (B3).
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, checklistGroup.Id, true);
        TestDataFactory.linkPrerequisite(items[1], items[0], true);
    }

    /**
     * @return The two fixture items, prerequisite first, dependent second.
     *
     * Qualified by `FIXTURE_GROUP` rather than reading every item in the transaction. Suppression in
     * `@TestSetup` is what removes the fan-out rows today; this filter is what keeps the pick
     * correct if that suppression is ever undone, and - independently of the fan-out - it stops the
     * second deal built by three of the tests below from ever being picked up here.
     */
    private static List<Checklist_Item__c> fixtureItems() {
        return [
            SELECT Id, Flag__c, Blocked_By__c, Is_Prerequisite_Met__c, Checklist__c, Sequence__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Group_Name__c = :FIXTURE_GROUP
            ORDER BY Sequence__c ASC
        ];
    }

    /** Forces the override gate to a known answer. Without this the admin runner always holds it. */
    private static void forceOverrideAccess(Boolean allowed) {
        TransactionActionPermissionService.cachedHasPrereqOverrideAccess = allowed;
    }

    @isTest
    static void shouldRefuseCompletion_WhenPrerequisiteIsOpen() {
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Completing an item whose prerequisite is open must be refused');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('wire-fraud verification'),
            'The refusal must name the blocking step: ' + result.getErrors()[0].getMessage());
    }

    @isTest
    static void shouldAllowCompletion_WhenPrerequisiteIsCompleted() {
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_COMPLETED);

        Test.startTest();
        update new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED);
        Test.stopTest();

        Checklist_Item__c dependent = [
            SELECT Flag__c, Is_Prerequisite_Met__c FROM Checklist_Item__c WHERE Id = :items[1].Id
        ];
        Assert.areEqual(FLAG_COMPLETED, dependent.Flag__c, 'The dependent should have completed');
        Assert.isTrue(dependent.Is_Prerequisite_Met__c,
            'The denormalised backstop must be stamped true once the prerequisite is done');
    }

    @isTest
    static void shouldAllowCompletion_WhenPrerequisiteIsVerified() {
        // 🔴 DONE MEANS Completed OR Verified. A gate testing `Completed` alone would refuse a
        // dependent whose wire verification was legitimately marked Verified - which is exactly the
        // value the two wire-verification items use.
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_VERIFIED);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'A Verified prerequisite is DONE and must satisfy the gate: '
                + (result.isSuccess() ? '' : result.getErrors()[0].getMessage()));
    }

    @isTest
    static void refusesBlankingTheLinkAndCompletingInOneSave() {
        // SHAPE 1 - STILL REACHABLE ON THE NEW MODEL. A lookup can be nulled exactly like the
        // Phase 0 Text key, so this is closed by DEFENCE (the surviving-link rule), not by schema.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(new Checklist_Item__c(
            Id = items[1].Id, Flag__c = FLAG_COMPLETED, Blocked_By__c = null), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Blanking the link in the same save must not disarm the gate - the STORED link wins '
                + 'while the row is open');
    }

    @isTest
    static void refusesRepointingTheLinkAtACompletedItem() {
        // SHAPE 2 - STILL REACHABLE. A third, already-complete item on the SAME deal is the
        // cheapest version of the Phase 0 `A|1` attack.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        Checklist_Item__c decoy = TestDataFactory.createChecklistItem(items[0].Checklist__c, false);
        decoy.Sequence__c = 99;
        insert decoy;
        update new Checklist_Item__c(Id = decoy.Id, Flag__c = FLAG_COMPLETED);

        Test.startTest();
        Database.SaveResult result = Database.update(new Checklist_Item__c(
            Id = items[1].Id, Flag__c = FLAG_COMPLETED, Blocked_By__c = decoy.Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Repointing the link at a completed item must not choose the gate its own examiner');
    }

    @isTest
    static void refusesALinkPointingAtAnotherDeal() {
        // SHAPE 2's AMPLIFICATION, WHICH HAS NO PHASE 0 COUNTERPART. The Text key could only ever
        // name a sibling under the same deal; a lookup accepts ANY item in the org.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        // Suppressed too: this deal exists only to be a FOREIGN parent, so a 96-row Day-0 fan-out
        // on it would be pure cost. Its date is read by nothing in this test.
        Transaction__c otherDeal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Checklist__c otherGroup = TestDataFactory.createChecklist(otherDeal.Id, true);
        Checklist_Item__c foreign = TestDataFactory.createChecklistItem(otherGroup.Id, true);
        update new Checklist_Item__c(Id = foreign.Id, Flag__c = FLAG_COMPLETED);

        Test.startTest();
        Database.SaveResult result = Database.update(new Checklist_Item__c(
            Id = items[1].Id, Blocked_By__c = foreign.Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A cross-deal prerequisite must be refused outright');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('same deal'),
            'The refusal must say why: ' + result.getErrors()[0].getMessage());
    }

    @isTest
    static void refusesALinkPointingAtItself() {
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(new Checklist_Item__c(
            Id = items[1].Id, Blocked_By__c = items[1].Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'A self-referencing prerequisite would make the item permanently uncompletable');
    }

    @isTest
    static void reparentingAnItemIsRefusedByThePlatform() {
        // SHAPE 3a - DEAD BY CONSTRUCTION. Phase 0's EXPLOIT A moved `Transaction_Deal__c` to
        // re-scope the sibling lookup. Here the parent is master-detail with
        // `reparentableMasterDetail=false`, so the PLATFORM refuses the write before any trigger
        // sees it. Asserted rather than assumed.
        List<Checklist_Item__c> items = fixtureItems();
        // Suppressed: a re-parent target only. Nothing here reads its contract execution date.
        Transaction__c otherDeal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Checklist__c otherGroup = TestDataFactory.createChecklist(otherDeal.Id, true);

        Test.startTest();
        Database.SaveResult result = Database.update(new Checklist_Item__c(
            Id = items[1].Id, Checklist__c = otherGroup.Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'A non-reparentable master-detail child must not be movable to another deal');
    }

    @isTest
    static void renumberingThePrerequisiteDoesNotBreakTheLink() {
        // SHAPE 3b - DEAD BY CONSTRUCTION, and this is the assertion Phase 0 could not make: its
        // residual 4b judged this un-closeable inside that budget. The link is an Id, so renumbering
        // the prerequisite changes nothing and the gate STILL REFUSES.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Sequence__c = 99);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Renumbering the prerequisite must not orphan the link - it is an Id, not a coordinate');
    }

    @isTest
    static void refusesDisarmingTheLinkOnAnOpenItem() {
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Blocked_By__c = null), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Removing the link while the prerequisite is open is the first save of the two-save '
                + 'bypass and must be refused on its own');
    }

    /**
     * 🔴 EXPLOIT C — REOPEN-AND-ERASE. Two saves, ordinary Edit access, NO override.
     *
     *     update {Flag__c = 'None',      Blocked_By__c = null};  // save 1
     *     update {Flag__c = 'Completed'};                        // save 2
     *
     * Save 1 slipped every branch while the guard was `!wasDone`: (A) declined because the row was
     * LEAVING done rather than entering it, and (B) declined because the row HAD been done. Save 2
     * then had no link on either side, so it was not a candidate at all. Found in the live Phase 0
     * gate and carried here, because this class inherited the same precedence rule.
     *
     * ⚠ The precondition is ordinary: complete the prerequisite, complete the dependent, reopen the
     * prerequisite — which is unrestricted, since a prerequisite carries no link of its own.
     *
     * The second assertion is the load-bearing one: a refusal that still lost the link would leave
     * save 2 unguarded, which IS the exploit.
     */
    @isTest
    static void refusesReopenAndEraseAcrossTwoSaves() {
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_COMPLETED);
        update new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED);
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_NONE);

        Test.startTest();
        Database.SaveResult reopenAndErase = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_NONE, Blocked_By__c = null), false);
        Database.SaveResult recomplete = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED), false);
        Test.stopTest();

        Assert.isFalse(reopenAndErase.isSuccess(),
            'Erasing the link WHILE REOPENING must be refused — a row walking back through the gate '
                + 'is not past it, so pastTheGate must be false even though wasDone is true');
        Checklist_Item__c dependent = [
            SELECT Flag__c, Blocked_By__c FROM Checklist_Item__c WHERE Id = :items[1].Id];
        Assert.areEqual(items[0].Id, dependent.Blocked_By__c,
            'THE LOAD-BEARING ASSERTION: the link SURVIVED. A refusal that still lost it would leave '
                + 'save 2 unguarded, which is the whole exploit');
        Assert.isTrue(recomplete.isSuccess(),
            'Save 2 succeeds, and that is correct rather than alarming: with save 1 refused it is a '
                + 'no-op re-completion of a row that was already done and still carries its link');
        Assert.areEqual(FLAG_COMPLETED, dependent.Flag__c, 'and the row never left the done state');
    }

    /**
     * The counterweight: REOPENING WITHOUT TOUCHING THE LINK stays allowed. `pastTheGate` pulls a
     * reopen into branch (B)'s scope, so this pins that (B) still declines on `linkChanged` —
     * otherwise the tempting simplification "refuse any save that reopens a gated item" would look
     * correct and would quietly make done items unreopenable.
     */
    @isTest
    static void allowsReopeningWithoutTouchingTheLink() {
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_COMPLETED);
        update new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED);
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_NONE);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_NONE), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A done item can still be reopened');
        Checklist_Item__c dependent = [
            SELECT Blocked_By__c, Is_Prerequisite_Met__c FROM Checklist_Item__c WHERE Id = :items[1].Id];
        Assert.areEqual(items[0].Id, dependent.Blocked_By__c, 'with its link intact');
        Assert.isFalse(dependent.Is_Prerequisite_Met__c,
            'and the flag re-derives against the now-open prerequisite, so the row comes back RE-ARMED');
    }

    @isTest
    static void allowsAnOverrideHolderToRepairTheLink() {
        // The administrative escape hatch. Pinned TRUE so the branch is provably reachable - the
        // mirror image of the vacuity the other disarm tests guard against.
        forceOverrideAccess(true);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Blocked_By__c = null), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'A Transaction_Prereq_Override holder must be able to repair a gate coordinate');
    }

    @isTest
    static void allowsEditingAnAlreadyCompletedItem() {
        // The `!pastTheGate` narrowing: an item done BEFORE and still done AFTER is past the gate
        // and stays maintainable, which is what keeps
        // the Phase 4 migration and ordinary corrections working.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();
        update new Checklist_Item__c(Id = items[0].Id, Flag__c = FLAG_COMPLETED);
        update new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Blocked_By__c = null), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A completed item is past the gate and stays editable');
    }

    @isTest
    static void allowsAnUnrelatedEditToAnOpenGatedItem() {
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Checklist_Item__c(Id = items[1].Id, Comment__c = 'chasing title'), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'An edit that moves neither the flag nor the link must not be refused');
    }

    @isTest
    static void clampsSuppliedPrerequisiteMetOnInsert() {
        // The field default only applies when the field is ABSENT from the payload. A writer that
        // SUPPLIES true would otherwise satisfy every conjunct of the validation rule.
        List<Checklist_Item__c> items = fixtureItems();
        Checklist_Item__c hostile = TestDataFactory.createChecklistItem(items[0].Checklist__c, false);
        hostile.Sequence__c = 50;
        hostile.Blocked_By__c = items[0].Id;
        hostile.Is_Prerequisite_Met__c = true;

        Test.startTest();
        insert hostile;
        Test.stopTest();

        Checklist_Item__c stored = [
            SELECT Is_Prerequisite_Met__c FROM Checklist_Item__c WHERE Id = :hostile.Id
        ];
        Assert.isFalse(stored.Is_Prerequisite_Met__c,
            'A supplied Is_Prerequisite_Met__c must be clamped to false on insert');
    }

    @isTest
    static void refusesInsertingAnAlreadyCompleteBlockedItem() {
        // The validation rule's ISNEW() arm, reading the clamped value. The trigger deliberately
        // does no lookup on insert.
        List<Checklist_Item__c> items = fixtureItems();
        Checklist_Item__c hostile = TestDataFactory.createChecklistItem(items[0].Checklist__c, false);
        hostile.Sequence__c = 51;
        hostile.Blocked_By__c = items[0].Id;
        hostile.Flag__c = FLAG_COMPLETED;

        Test.startTest();
        Database.SaveResult result = Database.insert(hostile, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Creating a gated item already Completed must be refused by the validation rule');
    }

    @isTest
    static void isInertAndCostsNothingForUngatedItems() {
        // Qualified by the fixture group: 'the first ungated item anywhere' would happily pick a
        // Day-0 fan-out row, and this test's whole claim is about a row it knows the shape of.
        Checklist_Item__c ungated = [
            SELECT Id
            FROM Checklist_Item__c
            WHERE Checklist__r.Group_Name__c = :FIXTURE_GROUP AND Blocked_By__c = null
            ORDER BY Sequence__c ASC
            LIMIT 1
        ];

        Test.startTest();
        ChecklistItemPrerequisiteService.resetRunCounters();
        update new Checklist_Item__c(Id = ungated.Id, Flag__c = FLAG_COMPLETED);
        Integer queries = ChecklistItemPrerequisiteService.runQueryCount;
        Test.stopTest();

        Assert.areEqual(0, queries,
            'An item with no prerequisite on either side must cost ZERO queries in the gate');
    }

    @isTest
    static void bulkUpdateStaysAtOneQueryPerChunk() {
        // 251 forces a SECOND before-update firing (the platform chunks at 200), which is the whole
        // point of the number - a 200-row test cannot distinguish "one query per chunk" from "one
        // query per transaction".
        // 🔴 SUPPRESSED, AND THE VOLUME STAYS AT 251. A plain factory deal would add a Day-0
        // fan-out on top of the 251-row fixture: ~96 more items and their rollup cascade, charged
        // to this method's own 100-SOQL/150-DML budget before `Test.startTest()` ever runs. The fix
        // is to stop creating rows the test does not need, never to lower 251.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c prerequisite = TestDataFactory.createChecklistItem(checklistGroup.Id, true);
        List<Checklist_Item__c> dependents = TestDataFactory.createChecklistItems(251, checklistGroup.Id, false);
        for (Integer i = 0; i < dependents.size(); i++) {
            dependents[i].Sequence__c = i + 100;
        }
        insert dependents;
        List<Checklist_Item__c> links = new List<Checklist_Item__c>();
        for (Checklist_Item__c dependent : dependents) {
            links.add(new Checklist_Item__c(
                Id = dependent.Id, Blocked_By__c = prerequisite.Id, Is_Prerequisite_Met__c = false));
        }
        update links;

        List<Checklist_Item__c> completions = new List<Checklist_Item__c>();
        for (Checklist_Item__c dependent : dependents) {
            completions.add(new Checklist_Item__c(Id = dependent.Id, Flag__c = FLAG_COMPLETED));
        }

        Test.startTest();
        ChecklistItemPrerequisiteService.resetRunCounters();
        List<Database.SaveResult> results = Database.update(completions, false);
        // 🔴 CAPTURED INSIDE, BEFORE stopTest. `Test.stopTest()` restores the pre-test governor
        // counters, so a reading taken after it measures nothing and passes vacuously.
        Integer queries = ChecklistItemPrerequisiteService.runQueryCount;
        Integer chunks = ChecklistItemPrerequisiteService.runChunkCount;
        Integer dml = ChecklistItemPrerequisiteService.runDmlCount;
        Test.stopTest();

        Integer refused = 0;
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                refused++;
            }
        }
        Assert.areEqual(251, refused, 'Every one of the 251 gated completions must be refused');
        Assert.isTrue(chunks >= 2,
            'A 251-record update must fire before-update at least twice; fired ' + chunks);
        Assert.areEqual(chunks, queries,
            'EXACTLY one query per chunk, never a function of row count. Chunks=' + chunks
                + ' queries=' + queries);
        Assert.areEqual(0, dml, 'The gate must never perform DML');
    }

    @isTest
    static void enforceOnUpdateIsNullSafe() {
        Test.startTest();
        Map<Id, String> refusals = ChecklistItemPrerequisiteService.enforceOnUpdate(null, null);
        ChecklistItemPrerequisiteService.clampOnInsert(null);
        Test.stopTest();

        Assert.isTrue(refusals.isEmpty(), 'A null collection must be a no-op, never a throw');
    }

    @isTest
    static void asRefusalRecognisesItsOwnMessagesOnly() {
        // 🔴 THE MATCHING LOOP HAD ZERO COVERAGE — only the null path was tested. That matters more
        // than an ordinary coverage gap: `asRefusal` recognises a refusal by matching the very
        // constants that produced the text, and `addError` HTML-ESCAPES, so a single non-ASCII
        // character added to any constant later breaks the match SILENTLY. The symptom is not an
        // exception, it is the LWC falling back to the generic "refresh and try again" on the one
        // path a human uses. Phase 0 carried an explicit pin for this; it was not carried across.
        forceOverrideAccess(false);
        List<Checklist_Item__c> items = fixtureItems();

        Test.startTest();
        Assert.isNull(ChecklistItemPrerequisiteService.asRefusal(null),
            'A null DmlException must translate to null, not to a refusal');

        // (A) a real, platform-round-tripped completion refusal.
        DmlException blocked = null;
        try {
            update new Checklist_Item__c(Id = items[1].Id, Flag__c = FLAG_COMPLETED);
        } catch (DmlException e) {
            blocked = e;
        }
        // (B) a real disarm refusal.
        DmlException disarm = null;
        try {
            update new Checklist_Item__c(Id = items[1].Id, Blocked_By__c = null);
        } catch (DmlException e) {
            disarm = e;
        }
        // An UNRELATED platform failure, which must NOT be re-typed — otherwise this becomes a
        // route for raw DML text to reach the UI.
        DmlException unrelated = null;
        Checklist_Item__c doomed = TestDataFactory.createChecklistItem(items[0].Checklist__c, true);
        Id doomedId = doomed.Id;
        delete doomed;
        try {
            update new Checklist_Item__c(Id = doomedId, Sequence__c = 42);
        } catch (DmlException e) {
            unrelated = e;
        }
        Test.stopTest();

        Assert.isNotNull(blocked, 'Precondition: the completion was refused');
        Assert.isNotNull(disarm, 'Precondition: the disarm was refused');
        Assert.isNotNull(unrelated, 'Precondition: updating a deleted row failed');

        Assert.isNotNull(ChecklistItemPrerequisiteService.asRefusal(blocked),
            'MSG_BLOCKED must survive the round trip through addError and be recognised — if this '
                + 'is null, a non-ASCII character has been added to the constant');
        Assert.isNotNull(ChecklistItemPrerequisiteService.asRefusal(disarm),
            'MSG_DISARM must be recognised too');
        Assert.isNull(ChecklistItemPrerequisiteService.asRefusal(unrelated),
            'An unrelated DmlException must NOT be re-typed — the translation is narrow by design '
                + 'and must not leak platform error text to the LWC boundary');
    }

    /**
     * The ASCII pin, carried over from Phase 0 and covering ALL FOUR constants rather than only the
     * two the round-trip test above can reach.
     *
     * `SObject.addError` HTML-escapes, so an em-dash becomes `&mdash;` and a quotation mark becomes
     * `&quot;` in the message the platform actually stores. `asRefusal` matches on these constants,
     * so ONE such character silently breaks the match. This is a cheap direct assertion on the
     * property itself, which is what makes it catch the two constants no current fixture refuses.
     */
    @isTest
    static void refusalConstantsStayAsciiSoTheMatcherCannotDrift() {
        Map<String, String> constants = new Map<String, String>{
            'MSG_BLOCKED' => ChecklistItemPrerequisiteService.MSG_BLOCKED,
            'MSG_UNRESOLVED' => ChecklistItemPrerequisiteService.MSG_UNRESOLVED,
            'MSG_DISARM' => ChecklistItemPrerequisiteService.MSG_DISARM,
            'MSG_CROSS_DEAL' => ChecklistItemPrerequisiteService.MSG_CROSS_DEAL
        };

        Test.startTest();
        for (String name : constants.keySet()) {
            String value = constants.get(name);
            Assert.isNotNull(value, name + ' must exist');
            for (Integer i = 0; i < value.length(); i++) {
                Integer code = value.charAt(i);
                Assert.isTrue(code >= 32 && code <= 126,
                    name + ' must be pure printable ASCII, or addError HTML-escaping will break '
                        + 'asRefusal silently. Offending character code ' + code + ' at index ' + i);
                Assert.isTrue(
                    code != 38 && code != 60 && code != 62 && code != 34 && code != 39,
                    name + ' must contain no ampersand, angle bracket, double quote or apostrophe. '
                        + 'Every one of them is HTML-escaped by addError. Offending character code '
                        + code + ' at index ' + i);
            }
        }
        Test.stopTest();
    }
}
