/**
 * Tests for BovSubmissionSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population, BOV_Score__c DESC NULLS LAST
 * ordering, the empty-result contract, and a 251-record data-volume read
 * (.claude/rules/bulk-test-rule.md).
 *
 * @TestSetup builds the Property -> Property_Asset -> Disposition scaffold with
 * explicit parent Ids (never default*()), and every test queries for that
 * Disposition — the TestDataFactory header warns the static scaffold cache does
 * NOT survive the @TestSetup boundary.
 *
 * No System.runAs USER_MODE test: BOV_Submission__c is a custom object and P3
 * proved the custom-field FLS gap is 0, so the running user reads every selected
 * field (the runAs assertion is reserved for standard-object selectors).
 */
@isTest
private class BovSubmissionSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    @isTest
    static void selectByDispositionId_populatesEverySelectedField() {
        Id dispId = dispositionId();
        // Factory defaults are known values; asserting them proves each field is selected.
        // 🔴 Broker_Firm__c / Contact_Name__c ARE THE STAMPED CONTACT'S VALUES, NOT THE FACTORY'S
        // OWN TEXT LITERALS, AS OF 2026-08-20 (Tranche 2, requirements §3 D1).
        // BovSubmissionBrokerStampService overwrites both the instant Broker__c is set on insert,
        // which is now every insert (Broker_Required_On_Submission). createBovSubmission's
        // singular convenience path reuses the shared TestDataFactory.defaultBrokerContact(),
        // whose known values are 'Test Brokerage 0' (Broker_Firm__c, matching the factory's own
        // former literal by coincidence) and 'Test Contact 0' (Name = FirstName 'Test' + LastName
        // 'Contact 0' — NOT the retired 'Test Broker 0' literal).
        TestDataFactory.createBovSubmission(dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one BOV submission exists for the Disposition');
        BOV_Submission__c s = result[0];
        Assert.areEqual('Test Brokerage 0', s.Broker_Firm__c, 'Broker_Firm__c should be selected');
        Assert.areEqual('Test Contact 0', s.Contact_Name__c, 'Contact_Name__c should be selected');
        Assert.areEqual(1200000, s.BOV_Amount__c, 'BOV_Amount__c should be selected');
        Assert.areEqual(2.5, s.Commission_Rate__c, 'Commission_Rate__c should be selected');
        Assert.areEqual(30, s.Days_To_Market__c, 'Days_To_Market__c should be selected');
        Assert.areEqual(75, s.Hist_Success_Rate__c, 'Hist_Success_Rate__c should be selected');
        Assert.areEqual(6.25, s.Cap_Rate__c, 'Cap_Rate__c should be selected');
        Assert.areEqual(80, s.BOV_Score__c, 'BOV_Score__c should be selected');
        Assert.areEqual('Backup', s.Submission_Status__c, 'Submission_Status__c should be selected');
    }

    @isTest
    static void selectByDispositionId_ordersByScoreDescNullsLast() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(3, dispId, false);
        subs[0].BOV_Score__c = 90;
        subs[1].BOV_Score__c = 80;
        subs[2].BOV_Score__c = null;
        insert subs;

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three submissions should return');
        Assert.areEqual(90, result[0].BOV_Score__c, 'Highest score should sort first');
        Assert.areEqual(80, result[1].BOV_Score__c, 'Middle score should sort second');
        Assert.isNull(result[2].BOV_Score__c, 'A null score should sort last (NULLS LAST)');
    }

    @isTest
    static void selectByDispositionId_noSubmissions_returnsEmpty() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A Disposition with no submissions returns an empty list, not null');
    }

    @isTest
    static void selectByDispositionId_bulk251_readsAll() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmissions(BULK_N, dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 submissions under the Disposition should be read');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectedByDispositionId — backs DispositionApprovalService's BOV Outreach branch
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectSelectedByDispositionId_noSelected_returnsNull() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmission(dispId, true); // Backup only

        Test.startTest();
        BOV_Submission__c result = BovSubmissionSelector.selectSelectedByDispositionId(dispId);
        Test.stopTest();

        Assert.isNull(result,
            'NULL IS A FIRST-CLASS ANSWER — "no broker is Selected yet" is user-actionable, not an error');
    }

    @isTest
    static void selectSelectedByDispositionId_returnsTheSelectedOne() {
        Id dispId = dispositionId();
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(dispId, false);
        backup.Submission_Status__c = 'Backup';
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(dispId, false);
        selected.Submission_Status__c = 'Selected';
        // Pinned via Broker__c, not a hand-typed literal — see TestDataFactory.createBrokerContactWithFirm.
        selected.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - The Winner', true).Id;
        insert new List<BOV_Submission__c>{ backup, selected };

        Test.startTest();
        BOV_Submission__c result = BovSubmissionSelector.selectSelectedByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(selected.Id, result.Id, 'Only the Selected submission must be returned');
        Assert.areEqual('CBRE - The Winner', result.Broker_Firm__c);
    }

    @isTest
    static void selectSelectedByDispositionId_nullInput_returnsNullWithoutQuerying() {
        Assert.isNull(BovSubmissionSelector.selectSelectedByDispositionId(null));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectStatusesByDispositionId — backs BovSubmissionService.replaceSelectedBroker
    // (WITH SYSTEM_MODE — the field, not the caller, forces it: Approval_Status__c arrives with
    // no FLS for any profile until the permission-set deploy lands)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectStatusesByDispositionId_returnsEveryRowNotJustSelected() {
        Id dispId = dispositionId();
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(dispId, false);
        selected.Submission_Status__c = 'Selected';
        selected.Approval_Status__c = 'Approved';
        BOV_Submission__c backup = TestDataFactory.createBovSubmission(dispId, false);
        backup.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ selected, backup };

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectStatusesByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            '🔴 EVERY SUBMISSION MUST RETURN, NOT JUST THE SELECTED ONE — this is what makes the '
            + 'replace operation self-healing against a partial earlier failure');
        Map<Id, BOV_Submission__c> byId = new Map<Id, BOV_Submission__c>(result);
        Assert.areEqual('Approved', byId.get(selected.Id).Approval_Status__c,
            'Approval_Status__c must be selected — the field this method exists to reach');
    }

    @isTest
    static void selectStatusesByDispositionId_nullAndEmptyInput_returnsEmptyList() {
        Assert.areEqual(0, BovSubmissionSelector.selectStatusesByDispositionId(null).size());
    }

    @isTest
    static void selectStatusesByDispositionId_noSubmissions_returnsEmptyList() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectStatusesByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(0, result.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectSelectedByDispositionIds — backs BovSubmissionSelectionGuardService
    // (SET-keyed, WITH SYSTEM_MODE — the CALLER forces the mode: a before-trigger read the running
    // user never asked for, where a USER_MODE throw would roll back their own save)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The SET is the point: one query must answer for MANY dispositions at once, because the caller
     * runs inside a trigger chunk. A per-parent implementation would be SOQL in a loop.
     *
     * ⚠ ONE Selected ROW PER DISPOSITION, NOT TWO ON ONE. Since 2026-08-20 the trigger guard this
     * method backs makes a second Selected row on one disposition UNSAVABLE, so a fixture that
     * built one would fail at `insert`, not at the assertion.
     */
    @isTest
    static void selectSelectedByDispositionIds_spansManyParentsAndReturnsOnlySelected() {
        Id firstDisp = dispositionId();
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c secondDisp = TestDataFactory.createDisposition(asset.Id, true);

        BOV_Submission__c firstSelected = TestDataFactory.createBovSubmission(firstDisp, false);
        firstSelected.Submission_Status__c = 'Selected';
        BOV_Submission__c firstBackup = TestDataFactory.createBovSubmission(firstDisp, false);
        firstBackup.Submission_Status__c = 'Backup';
        BOV_Submission__c secondSelected =
            TestDataFactory.createBovSubmission(secondDisp.Id, false);
        secondSelected.Submission_Status__c = 'Selected';
        insert new List<BOV_Submission__c>{ firstSelected, firstBackup, secondSelected };

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectSelectedByDispositionIds(
            new Set<Id>{ firstDisp, secondDisp.Id });
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            'ONE query must answer for BOTH dispositions — that is what keeps the guard out of a '
            + 'per-record loop');
        Map<Id, BOV_Submission__c> byId = new Map<Id, BOV_Submission__c>(result);
        Assert.isTrue(byId.containsKey(firstSelected.Id), 'The first parent\'s Selected row');
        Assert.isTrue(byId.containsKey(secondSelected.Id), 'The second parent\'s Selected row');
        Assert.isFalse(byId.containsKey(firstBackup.Id),
            'A Backup row must NOT be returned — the guard counts Selected siblings only');
        Assert.areEqual(firstDisp, byId.get(firstSelected.Id).Disposition__c,
            'Disposition__c must be selected — the caller groups the count by it');
    }

    /** Null/empty-safe and, on empty, issues NO query at all. */
    @isTest
    static void selectSelectedByDispositionIds_nullAndEmptyInput_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer nullSize = BovSubmissionSelector.selectSelectedByDispositionIds(null).size();
        Integer emptySize =
            BovSubmissionSelector.selectSelectedByDispositionIds(new Set<Id>()).size();
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, nullSize, 'Null input returns an empty list');
        Assert.areEqual(0, emptySize, 'An empty set returns an empty list');
        Assert.areEqual(0, queriesUsed,
            'Neither may issue a query — the guard\'s zero-query fast path depends on this');
    }
}
