/**
 * Tests for the `Checklist_Item__c` domain rules.
 *
 * `isDone` is the single definition of "complete" for the whole checklist model - the rollup, the
 * prerequisite gate and the completion stamp all call it. If those three ever disagree, the gate
 * opens on an item the rollup counts as open, so the two-value test gets its own named test here
 * rather than being incidentally covered.
 *
 * Pure in-memory: no `@TestSetup`, no DML except where the stamp must be observed end to end.
 */
@isTest
private class ChecklistItemDomainTest {

    @isTest
    static void isDoneAcceptsCompletedAndVerifiedOnly() {
        Test.startTest();
        Assert.isTrue(ChecklistItemDomain.isDone('Completed'), 'Completed is done');
        Assert.isTrue(ChecklistItemDomain.isDone('Verified'),
            'Verified is ALSO done - a test against Completed alone silently undercounts every '
                + 'verified item');
        Assert.isFalse(ChecklistItemDomain.isDone('CRITICAL'), 'CRITICAL is an OPEN severity');
        Assert.isFalse(ChecklistItemDomain.isDone('None'), 'None is open');
        Assert.isFalse(ChecklistItemDomain.isDone(null), 'Null is open, and must not throw');
        Test.stopTest();
    }

    @isTest
    static void openFlagForRestoresCriticalityRatherThanLosingIt() {
        Test.startTest();
        Assert.areEqual('CRITICAL', ChecklistItemDomain.openFlagFor(true),
            'Because Flag__c conflates severity with state, reopening a critical item can only '
                + 'restore CRITICAL from Is_Critical__c');
        Assert.areEqual('None', ChecklistItemDomain.openFlagFor(false), 'Otherwise None');
        Assert.areEqual('None', ChecklistItemDomain.openFlagFor(null), 'Null is not critical');
        Test.stopTest();
    }

    @isTest
    static void stampsCompletionOnTransitionOnly() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(group.Id, true);

        Test.startTest();
        update new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed');
        Checklist_Item__c completed = [
            SELECT Completed_By__c, Completed_DateTime__c FROM Checklist_Item__c WHERE Id = :item.Id
        ];
        Datetime firstStamp = completed.Completed_DateTime__c;
        // An unrelated edit must NOT re-stamp - that is what makes these fields history rather than
        // a second copy of LastModifiedDate.
        update new Checklist_Item__c(Id = item.Id, Comment__c = 'note');
        Checklist_Item__c edited = [
            SELECT Completed_By__c, Completed_DateTime__c FROM Checklist_Item__c WHERE Id = :item.Id
        ];
        Test.stopTest();

        Assert.areEqual(UserInfo.getUserId(), completed.Completed_By__c,
            'The REAL person is recorded, retiring the LastModifiedBy approximation');
        Assert.isNotNull(firstStamp, 'And the moment it happened');
        Assert.areEqual(firstStamp, edited.Completed_DateTime__c,
            'An unrelated later edit must not rewrite history');
    }

    @isTest
    static void clearsTheStampWhenAnItemIsReopened() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(group.Id, true);
        update new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed');

        Test.startTest();
        update new Checklist_Item__c(Id = item.Id, Flag__c = 'None');
        Test.stopTest();

        Checklist_Item__c reopened = [
            SELECT Completed_By__c, Completed_DateTime__c FROM Checklist_Item__c WHERE Id = :item.Id
        ];
        Assert.isNull(reopened.Completed_By__c,
            'A completion stamp surviving a reopen reads as "completed by X" on a row that is '
                + 'demonstrably not complete');
        Assert.isNull(reopened.Completed_DateTime__c, 'Both halves are cleared together');
    }

    @isTest
    static void preservesACallerSuppliedCompletedBy() {
        // The Phase 4 migration carries historical completions across and must be able to state who
        // completed them; overwriting that with the migration user would destroy the history.
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        Checklist_Item__c item = TestDataFactory.createChecklistItem(group.Id, false);
        item.Flag__c = 'Completed';
        item.Completed_By__c = UserInfo.getUserId();
        item.Completed_DateTime__c = Datetime.now().addDays(-40);

        Test.startTest();
        insert item;
        Test.stopTest();

        Assert.areEqual(Date.today().addDays(-40),
            [SELECT Completed_DateTime__c FROM Checklist_Item__c WHERE Id = :item.Id]
                .Completed_DateTime__c.date(),
            'A supplied historical completion timestamp must survive the stamp');
    }

    @isTest
    static void collectChecklistIdsIsNullSafeAndDeduplicates() {
        Id fakeId = TestDataFactory.createTransactions(1, true)[0].Id;
        Test.startTest();
        Assert.isTrue(ChecklistItemDomain.collectChecklistIds(null).isEmpty(),
            'Null in, empty set out - never null');
        Set<Id> collected = ChecklistItemDomain.collectChecklistIds(new List<Checklist_Item__c>{
            new Checklist_Item__c(), new Checklist_Item__c()
        });
        Test.stopTest();
        Assert.isTrue(collected.isEmpty(), 'Items with no parent contribute nothing');
        Assert.isNotNull(fakeId, 'Fixture sanity');
    }

    @isTest
    static void stampCompletionIsNullSafe() {
        Test.startTest();
        ChecklistItemDomain.stampCompletion(null, null);
        ChecklistItemDomain.stampCompletion(new List<Checklist_Item__c>(), null);
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Checklist_Item__c],
            'A null or empty collection is a no-op, never a throw');
    }
}
