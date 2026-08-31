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

    @TestSetup
    static void setupTestData() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        // Two items: [0] is the prerequisite (B2), [1] is the dependent (B3).
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(2, group.Id, true);
        TestDataFactory.linkPrerequisite(items[1], items[0], true);
    }

    /** @return The two fixture items, prerequisite first, dependent second. */
    private static List<Checklist_Item__c> fixtureItems() {
        return [
            SELECT Id, Flag__c, Blocked_By__c, Is_Prerequisite_Met__c, Checklist__c, Sequence__c
            FROM Checklist_Item__c
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
        Transaction__c otherDeal = TestDataFactory.createTransactions(1, true)[0];
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
        Transaction__c otherDeal = TestDataFactory.createTransactions(1, true)[0];
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
        // The `!wasDone` narrowing: an item past the gate stays maintainable, which is what keeps
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
        Checklist_Item__c ungated = [
            SELECT Id FROM Checklist_Item__c WHERE Blocked_By__c = null LIMIT 1
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
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c prerequisite = TestDataFactory.createChecklistItem(group.Id, true);
        List<Checklist_Item__c> dependents = TestDataFactory.createChecklistItems(251, group.Id, false);
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
        Test.startTest();
        Assert.isNull(ChecklistItemPrerequisiteService.asRefusal(null),
            'A null DmlException must translate to null, not to a refusal');
        Test.stopTest();
    }
}
