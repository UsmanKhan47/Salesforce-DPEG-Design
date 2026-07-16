/**
 * Tests for WireSelector (P4, Module D — Disposition pilot selector).
 *
 * Covers both relocated queries end-to-end:
 *   - selectMostRecentByDispositionId : field population, most-recent ordering,
 *     null-input guard, empty result, and a 251-record data-volume read
 *     (.claude/rules/bulk-test-rule.md).
 *   - selectRequiredById : the happy path AND that Verified_DateTime__c is
 *     actually selected (the guard against the earlier SObjectException), plus
 *     the missing-Id -> System.QueryException contract that WireController.saveWire
 *     depends on.
 *
 * @TestSetup builds the Property -> Property_Asset -> Disposition scaffold with
 * explicit parent Ids (never default*()), and every test queries for that
 * Disposition rather than re-calling a factory default() accessor — the
 * TestDataFactory header warns that the static scaffold cache does NOT survive
 * the @TestSetup boundary, so a default*() call in a test method would silently
 * build a SECOND Disposition.
 *
 * No System.runAs USER_MODE test here: Wire__c is a custom object and P3 proved
 * the custom-field FLS gap is 0, so the running user reads every selected field.
 * The runAs assertion is reserved for standard-object selectors (design §7).
 */
@isTest
private class WireSelectorTest {

    private static final Datetime VERIFIED_AT = Datetime.newInstance(2026, 7, 16, 10, 30, 0);

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
    static void selectMostRecentByDispositionId_populatesEverySelectedField() {
        Id dispId = dispositionId();
        Wire__c w = TestDataFactory.createWire(dispId, false);
        w.Verbal_Verification_Completed__c = true;
        w.Verifier_Name__c = 'Jane Verifier';
        w.Verifier_Phone__c = '555-0100';
        w.Wire_Instructions_Source__c = 'Direct call to title company';
        w.Confirmed_Wire_Amount__c = 28500000;
        w.Verified_DateTime__c = VERIFIED_AT;
        insert w;

        Test.startTest();
        Wire__c result = WireSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.isNotNull(result, 'A Wire exists for the Disposition, so a row should return');
        Assert.areEqual(w.Id, result.Id, 'The returned Wire should be the one just inserted');
        Assert.areEqual(true, result.Verbal_Verification_Completed__c, 'Verbal_Verification_Completed__c should be selected and true');
        Assert.areEqual('Jane Verifier', result.Verifier_Name__c, 'Verifier_Name__c should be selected');
        Assert.areEqual('555-0100', result.Verifier_Phone__c, 'Verifier_Phone__c should be selected');
        Assert.areEqual('Direct call to title company', result.Wire_Instructions_Source__c, 'Wire_Instructions_Source__c should be selected');
        Assert.areEqual(28500000, result.Confirmed_Wire_Amount__c, 'Confirmed_Wire_Amount__c should be selected');
        Assert.areEqual(VERIFIED_AT, result.Verified_DateTime__c, 'Verified_DateTime__c should be selected');
    }

    @isTest
    static void selectMostRecentByDispositionId_returnsMostRecentWire() {
        Id dispId = dispositionId();
        TestDataFactory.createWire(dispId, true);
        Wire__c newer = TestDataFactory.createWire(dispId, false);
        newer.Verifier_Name__c = 'Newest Verifier';
        insert newer;

        Test.startTest();
        Wire__c result = WireSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual('Newest Verifier', result.Verifier_Name__c,
            'ORDER BY CreatedDate DESC, Id DESC should return the most recently created Wire');
    }

    @isTest
    static void selectMostRecentByDispositionId_nullInput_returnsNull() {
        Test.startTest();
        Wire__c result = WireSelector.selectMostRecentByDispositionId(null);
        Test.stopTest();

        Assert.isNull(result, 'A null Disposition Id should short-circuit to null, not query');
    }

    @isTest
    static void selectMostRecentByDispositionId_noWire_returnsNull() {
        Id dispId = dispositionId();

        Test.startTest();
        Wire__c result = WireSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.isNull(result, 'A Disposition with no Wire should return null, not throw');
    }

    @isTest
    static void selectMostRecentByDispositionId_251Wires_resolvesExactlyOne() {
        Id dispId = dispositionId();
        TestDataFactory.createWires(251, dispId, true);

        Test.startTest();
        Wire__c result = WireSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Integer wireCount = [SELECT COUNT() FROM Wire__c WHERE Disposition__c = :dispId];
        Assert.areEqual(251, wireCount, 'All 251 Wires should have been inserted under the Disposition');
        Assert.isNotNull(result, 'LIMIT 1 should still resolve exactly one row at 251-record volume');
    }

    @isTest
    static void selectRequiredById_existingId_returnsWireWithVerifiedDateTime() {
        Id dispId = dispositionId();
        Wire__c w = TestDataFactory.createWire(dispId, false);
        w.Verified_DateTime__c = VERIFIED_AT;
        insert w;

        Test.startTest();
        Wire__c result = WireSelector.selectRequiredById(w.Id);
        Test.stopTest();

        Assert.areEqual(w.Id, result.Id, 'selectRequiredById should return the record for the given Id');
        // Reading Verified_DateTime__c here proves the field is in the SELECT — a
        // SELECT Id-only query would have thrown SObjectException on this access.
        Assert.areEqual(VERIFIED_AT, result.Verified_DateTime__c,
            'Verified_DateTime__c must be selected so saveWire can decide whether to re-stamp it');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Id dispId = dispositionId();
        Wire__c w = TestDataFactory.createWire(dispId, true);
        Id deletedId = w.Id;
        delete w;

        Test.startTest();
        try {
            WireSelector.selectRequiredById(deletedId);
            Assert.fail('A Wire Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Wire row: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
