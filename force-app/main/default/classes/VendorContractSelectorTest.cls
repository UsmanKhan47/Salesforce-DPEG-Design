/**
 * Tests for `VendorContractSelector` - the fixed-monthly arrangements with no meter and no
 * consumption (FSD 5.10.3: trash and maintenance).
 *
 * Read-only selector, so `.claude/rules/bulk-test-rule.md`'s 251 mandate does not apply.
 */
@isTest
private class VendorContractSelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        List<Vendor_Contract__c> contracts =
            TestDataFactory.createVendorContracts(3, asset.Id, false);
        // One expired, one open-ended (no end date), one running.
        contracts[0].End_Date__c = Date.today().addDays(-1);
        contracts[1].End_Date__c = null;
        insert contracts;
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    @isTest
    static void selectByPropertyAssetIds_activeOnlyFalse_returnsEverything() {
        Test.startTest();
        List<Vendor_Contract__c> all = VendorContractSelector.selectByPropertyAssetIds(
            new Set<Id>{ assetId() }, false);
        Test.stopTest();

        Assert.areEqual(3, all.size(),
            'Expired contracts are still history and a reviewer may need them.');
    }

    @isTest
    static void selectByPropertyAssetIds_activeOnly_excludesExpiredButKeepsOpenEnded() {
        Test.startTest();
        List<Vendor_Contract__c> active = VendorContractSelector.selectByPropertyAssetIds(
            new Set<Id>{ assetId() }, true);
        Test.stopTest();

        Assert.areEqual(2, active.size(),
            'The expired one is dropped, and BOTH the open-ended and the running one are '
            + 'kept.');
        for (Vendor_Contract__c c : active) {
            Assert.isTrue(c.End_Date__c == null || c.End_Date__c >= Date.today(),
                'A NULL End_Date__c means "still running", not "expired". Treating a blank as '
                + 'expired would silently hide every open-ended trash contract in the '
                + 'portfolio, which is the normal shape for that service.');
        }
    }

    @isTest
    static void selectByPropertyAssetIds_nullActiveOnlyFlag_behavesAsFalse() {
        Test.startTest();
        List<Vendor_Contract__c> all = VendorContractSelector.selectByPropertyAssetIds(
            new Set<Id>{ assetId() }, null);
        Test.stopTest();

        Assert.areEqual(3, all.size(),
            'A null flag must not be dereferenced - the comparison is `activeOnly == true`, '
            + 'so null falls to the unfiltered branch rather than throwing.');
    }

    @isTest
    static void selectByPropertyAssetIds_nullAndEmpty_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Assert.areEqual(0,
            VendorContractSelector.selectByPropertyAssetIds(null, true).size(), 'Null input.');
        Assert.areEqual(0,
            VendorContractSelector.selectByPropertyAssetIds(new Set<Id>(), false).size(),
            'Empty input.');
        Assert.areEqual(before, Limits.getQueries(), 'Neither reaches the database.');
        Test.stopTest();
    }
}
