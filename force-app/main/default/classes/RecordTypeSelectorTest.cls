/**
 * Tests for RecordTypeSelector.selectByObjectAndDeveloperNames — the sole method —
 * covering the match / unknown-name / null / empty / blank-object branches and a
 * Standard-User USER_MODE proof.
 *
 * RecordType is a system object with no TestDataFactory equivalent; the Opportunity
 * Land / Retail record types are deployed org metadata, so the "match" test grounds
 * its expectation on Schema describe (getRecordTypeInfosByDeveloperName) rather than a
 * hardcoded count — robust to either type being absent while still asserting exact
 * equality against what actually exists.
 *
 * NO 251-BULK SCENARIO — documented, not omitted: record types are org metadata, not
 * insertable test data; an org has a fixed, small number of Opportunity record types
 * (this org: Land + Retail). "251 record types" is not a producible state. The
 * IN-bind is exercised with the real requested set instead.
 */
@isTest
private class RecordTypeSelectorTest {

    private static Set<String> existingOpportunityTypes(Set<String> requested) {
        Map<String, Schema.RecordTypeInfo> infos =
            Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName();
        Set<String> existing = new Set<String>();
        for (String name : requested) {
            if (infos.containsKey(name)) {
                existing.add(name);
            }
        }
        return existing;
    }

    @isTest
    static void selectByObjectAndDeveloperNames_returnsMatchingOpportunityTypes() {
        Set<String> requested = new Set<String>{ 'Land', 'Retail' };
        Set<String> expected = existingOpportunityTypes(requested);
        // Precondition assertion: the DPEG org deploys both Opportunity record types.
        // Stated explicitly so the test cannot silently pass on an empty expectation.
        Assert.areEqual(2, expected.size(),
            'Precondition: the org must have Opportunity Land + Retail record types');

        Test.startTest();
        List<RecordType> rows =
            RecordTypeSelector.selectByObjectAndDeveloperNames('Opportunity', requested);
        Test.stopTest();

        Set<String> got = new Set<String>();
        for (RecordType rt : rows) {
            got.add(rt.DeveloperName);
            Assert.isNotNull(rt.Id, 'Id must be selected so the caller can stamp RecordTypeId');
        }
        Assert.areEqual(expected, got,
            'Selector returns exactly the requested Opportunity record types that exist');
    }

    @isTest
    static void selectByObjectAndDeveloperNames_unknownName_returnsEmpty() {
        Test.startTest();
        List<RecordType> rows = RecordTypeSelector.selectByObjectAndDeveloperNames(
            'Opportunity', new Set<String>{ 'NoSuchRecordType_ZZZ' });
        Test.stopTest();

        Assert.isTrue(rows.isEmpty(), 'A DeveloperName that matches nothing returns an empty list');
    }

    @isTest
    static void selectByObjectAndDeveloperNames_nullOrEmptyNames_returnsEmpty() {
        Test.startTest();
        List<RecordType> nullRows = RecordTypeSelector.selectByObjectAndDeveloperNames('Opportunity', null);
        List<RecordType> emptyRows =
            RecordTypeSelector.selectByObjectAndDeveloperNames('Opportunity', new Set<String>());
        Test.stopTest();

        Assert.isTrue(nullRows.isEmpty(), 'Null names short-circuit to an empty list without querying');
        Assert.isTrue(emptyRows.isEmpty(), 'Empty names short-circuit to an empty list without querying');
    }

    @isTest
    static void selectByObjectAndDeveloperNames_blankObject_returnsEmpty() {
        Test.startTest();
        List<RecordType> nullObj =
            RecordTypeSelector.selectByObjectAndDeveloperNames(null, new Set<String>{ 'Land' });
        List<RecordType> blankObj =
            RecordTypeSelector.selectByObjectAndDeveloperNames('   ', new Set<String>{ 'Land' });
        Test.stopTest();

        Assert.isTrue(nullObj.isEmpty(), 'Null sobjectType short-circuits to an empty list');
        Assert.isTrue(blankObj.isEmpty(), 'Blank sobjectType short-circuits to an empty list');
    }

    /**
     * USER_MODE proof: RecordType has no record-level sharing and the fields touched
     * (Id, DeveloperName, SobjectType) are non-permissionable, so WITH USER_MODE must
     * not throw for a bare Standard User and must return the deployed types.
     */
    @isTest
    static void selectByObjectAndDeveloperNames_standardUser_userModeReturnsTypes() {
        User standardUser = buildStandardUser();
        insert standardUser;
        Set<String> requested = new Set<String>{ 'Land', 'Retail' };

        Test.startTest();
        System.runAs(standardUser) {
            List<RecordType> rows =
                RecordTypeSelector.selectByObjectAndDeveloperNames('Opportunity', requested);
            Assert.areEqual(existingOpportunityTypes(requested).size(), rows.size(),
                'A Standard User reads Opportunity record types under WITH USER_MODE');
        }
        Test.stopTest();
    }

    private static User buildStandardUser() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'rtsel' + System.currentTimeMillis();
        return new User(
            ProfileId = standard.Id,
            LastName = 'RtSelTest',
            Email = 'rtseltest@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            Alias = 'rtsel',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
