/**
 * Tests for LeaseActivitySelector (P4 cleanup wave F1 — Lease Activity Tracker).
 *
 * Covers both timeline forms of the relocated Lease_Activity__c query:
 *   - selectByInquiryId  : field population (incl. Logged_By__r.Name and the parent
 *                          Lease_Inquiry__c), newest-first Entry_DateTime__c order,
 *                          parent isolation, and the null-input guard.
 *   - selectByInquiryIds : the 251-parent bulk read mandated by
 *                          .claude/rules/bulk-test-rule.md, plus null / empty guards.
 *
 * @TestSetup builds only the Property -> Property_Asset scaffold; each test builds its
 * own inquiries and queries for the asset (TestDataFactory header: the static scaffold
 * cache does not survive the @TestSetup boundary).
 *
 * FLOW DEPENDENCY: inserting a Lease_Inquiry__c fires the Open Log flow, which creates
 * exactly one "opening" Lease_Activity__c per inquiry (the same behaviour
 * LeaseInquiryControllerTest.openingEntryAndStageTimer relies on). The ordering test
 * neutralises the opening entry by dating its own three entries in the future (2030) so
 * they sort newest regardless; the 251-parent test asserts against those opening entries
 * directly (one per parent).
 *
 * No System.runAs USER_MODE test: Lease_Activity__c is custom (FLS gap 0, P3);
 * Logged_By__r.Name traverses a custom User lookup enforced under USER_MODE, and
 * User.Name is standard/always-readable. Entry_DateTime__c is the post-D3-migration
 * timeline stamp (ARCHITECTURE.md §1 rule 9); the dropped Entry_Date__c is never used.
 */
@isTest
private class LeaseActivitySelectorTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByInquiryId_populatesFields_newestFirst() {
        Lease_Inquiry__c inq = TestDataFactory.createLeaseInquiry(assetId(), true); // Open Log -> 1 opening entry
        List<Lease_Activity__c> acts = TestDataFactory.createLeaseActivities(3, inq.Id, false);
        // Date the three entries in the future so they deterministically outrank the
        // opening entry (stamped ~System.now()); i = 2 is the newest of the three.
        Datetime base = Datetime.newInstance(2030, 1, 1, 9, 0, 0);
        for (Integer i = 0; i < acts.size(); i++) {
            acts[i].Entry_DateTime__c = base.addMinutes(i);
            acts[i].Details__c = 'ENTRY-' + i;
        }
        insert acts;

        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryId(inq.Id);
        Test.stopTest();

        Assert.areEqual(4, result.size(), 'Three inserted entries plus the one opening entry should return');
        Assert.areEqual('ENTRY-2', result[0].Details__c, 'Newest Entry_DateTime__c should sort first');
        Assert.areEqual('ENTRY-0', result[2].Details__c, 'Oldest of the three should sort third');
        Assert.areEqual(inq.Id, result[0].Lease_Inquiry__c, 'Parent Lease_Inquiry__c should be selected for grouping');
        Assert.isNotNull(result[0].Logged_By__r.Name, 'Logged_By__r.Name should be selected for the "entered by" column');
    }

    @isTest
    static void selectByInquiryId_excludesOtherParents() {
        Lease_Inquiry__c inqA = TestDataFactory.createLeaseInquiry(assetId(), true);
        Lease_Inquiry__c inqB = TestDataFactory.createLeaseInquiry(assetId(), true);

        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryId(inqA.Id);
        Test.stopTest();

        Assert.isFalse(result.isEmpty(), 'Inquiry A should have its own opening entry');
        for (Lease_Activity__c a : result) {
            Assert.areEqual(inqA.Id, a.Lease_Inquiry__c, 'Only inquiry A entries should return, never inquiry B');
        }
    }

    @isTest
    static void selectByInquiryId_nullInput_returnsEmpty() {
        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryId(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null parent Id should short-circuit to an empty list, not query');
    }

    @isTest
    static void selectByInquiryIds_251Parents_returnsAllGroupedByParent() {
        List<Lease_Inquiry__c> inqs = TestDataFactory.createLeaseInquiries(251, assetId(), true);
        Set<Id> inqIds = new Map<Id, Lease_Inquiry__c>(inqs).keySet();

        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryIds(inqIds);
        Test.stopTest();

        Assert.areEqual(251, result.size(), 'One opening entry per parent across 251 parents should all return');
        Set<Id> parentsSeen = new Set<Id>();
        for (Lease_Activity__c a : result) {
            parentsSeen.add(a.Lease_Inquiry__c);
        }
        Assert.areEqual(251, parentsSeen.size(), 'Every one of the 251 parents should be represented');
    }

    @isTest
    static void selectByInquiryIds_nullInput_returnsEmpty() {
        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryIds(null);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null Id set should short-circuit to an empty list');
    }

    @isTest
    static void selectByInquiryIds_emptyInput_returnsEmpty() {
        Test.startTest();
        List<Lease_Activity__c> result = LeaseActivitySelector.selectByInquiryIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'An empty Id set should short-circuit to an empty list');
    }
}
