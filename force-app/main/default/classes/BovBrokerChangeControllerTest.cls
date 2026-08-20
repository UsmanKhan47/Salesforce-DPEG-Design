/**
 * @description Tests BovBrokerChangeController — the thin read behind `c/bovBrokerChangeHistory`
 * (2026-08-20, Tranche 2 Workstream B / design D4.6).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE MOST IMPORTANT TEST HERE IS `getHistory_noChanges_returnsAnEmptyListAndDoesNotThrow`
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Most dispositions never replace a broker, so EMPTY is the majority state of this card — commoner
 * than any populated one. If empty ever became a throw (or the client ever rendered it as one),
 * the visible result would be a permanent error banner on most disposition record pages. Everything
 * else in this class is a detail by comparison.
 *
 * ⚠ THE DTO MEMBER-NAME TEST IS THE SILENT HALF. A renamed `@AuraEnabled` member does not fail a
 * deploy, does not fail an Apex test that reads it through Apex, and does not throw in the browser —
 * the card just renders blanks. `getHistory_mapsEveryDtoMember` asserts every member is populated
 * from a known fixture value, so a mapping dropped in a refactor fails HERE rather than silently in
 * production. The NAMES themselves are pinned on the client side, in the Jest suite.
 *
 * NO 251-RECORD BULK TEST, AND THE REASON IS THE SELECTOR'S CAP. `getHistory` is a straight map
 * over whatever `BovBrokerChangeSelector.selectByDispositionId` returns, and that method caps at
 * 200 rows — the volume behaviour therefore belongs to the selector and is tested there
 * (`BovBrokerChangeSelectorTest.selectByDispositionId_bulk251_isCappedAtTheDocumentedLimit`, which
 * does insert 251). Duplicating the fixture here would re-test the selector through a wrapper.
 *
 * @see force-app/main/default/classes/BovBrokerChangeController.cls
 */
@isTest
private class BovBrokerChangeControllerTest {

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
    static void getHistory_mapsEveryDtoMember() {
        Id dispId = dispositionId();
        BOV_Broker_Change__c seeded = TestDataFactory.createBovBrokerChange(dispId, true);
        String changeNumber =
            [SELECT Name FROM BOV_Broker_Change__c WHERE Id = :seeded.Id].Name;

        Test.startTest();
        List<BovBrokerChangeController.ChangeRow> rows =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One seeded change, one row');
        BovBrokerChangeController.ChangeRow row = rows[0];
        Assert.areEqual(String.valueOf(seeded.Id), row.id, 'id');
        Assert.areEqual(changeNumber, row.changeNumber, 'changeNumber (the BBC- AutoNumber)');
        Assert.areEqual('Outgoing Brokerage 0', row.outgoingBrokerFirm, 'outgoingBrokerFirm');
        Assert.areEqual('Incoming Brokerage 0', row.incomingBrokerFirm, 'incomingBrokerFirm');
        Assert.areEqual('Performance Issue', row.reason, 'reason');
        Assert.areEqual('Test broker change 0', row.notes, 'notes');
        Assert.isNotNull(row.entryDateTime, 'entryDateTime');
        Assert.areEqual(UserInfo.getName(), row.loggedBy,
            'loggedBy must be the User NAME, flattened off Logged_By__r — not the Id');
    }

    /**
     * 🔴 EMPTY IS SUCCESS. See the class header: this is the majority state of the card, and the
     * one failure mode that would be visible on most disposition record pages in the org.
     */
    @isTest
    static void getHistory_noChanges_returnsAnEmptyListAndDoesNotThrow() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BovBrokerChangeController.ChangeRow> rows =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.isNotNull(rows, 'Never null — the client iterates this directly');
        Assert.areEqual(0, rows.size(),
            'A disposition that never replaced a broker returns an empty list, NOT an exception. '
            + 'The client renders "No broker changes recorded" from exactly this.');
    }

    @isTest
    static void getHistory_nullDispositionId_returnsEmptyRatherThanThrowing() {
        Test.startTest();
        List<BovBrokerChangeController.ChangeRow> rows =
            BovBrokerChangeController.getHistory(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A card rendered before its recordId arrives must degrade to empty, not to an error '
            + 'toast on page load');
    }

    /** The controller must not re-sort or reverse what the selector already ordered. */
    @isTest
    static void getHistory_preservesTheSelectorsNewestFirstOrder() {
        Id dispId = dispositionId();
        List<BOV_Broker_Change__c> seeded =
            TestDataFactory.createBovBrokerChanges(3, dispId, false);
        // Inserted oldest-first so insert order is the OPPOSITE of the expected read order.
        insert new List<BOV_Broker_Change__c>{ seeded[2], seeded[1], seeded[0] };

        Test.startTest();
        List<BovBrokerChangeController.ChangeRow> rows =
            BovBrokerChangeController.getHistory(dispId);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'All three rows');
        Assert.areEqual('Incoming Brokerage 0', rows[0].incomingBrokerFirm,
            'The newest change must still be first after the DTO mapping');
        Assert.areEqual('Incoming Brokerage 2', rows[2].incomingBrokerFirm,
            'And the oldest last');
    }

    /**
     * 🔴 THE CONTRACT UNDER TEST IS "NO RAW EXCEPTION EVER REACHES THE CLIENT" — not any particular
     * exception.
     *
     * ⚠ THIS TEST DELIBERATELY ACCEPTS TWO OUTCOMES, WHICH NEEDS DEFENDING. A wrong-SObjectType Id
     * bound into `WHERE Disposition__c = :id` is the only failure this class can provoke without a
     * mocking seam, and the platform is entitled to answer it either by throwing (a QueryException,
     * which the catch must convert) or by simply matching nothing (an empty list, which is a
     * perfectly good answer). Asserting ONE of those would pin an implementation detail of the
     * platform rather than the behaviour of this class. What is asserted instead is the thing that
     * actually matters and holds in both branches: an `AuraHandledException` carrying the FIXED
     * GENERIC message, never a raw exception and never platform text naming a column — because the
     * real trigger for this path in production is an FLS denial on a 2026-08-20 field, whose
     * QueryException reads `No such column`, which would be shown to a user as a schema error.
     */
    @isTest
    static void getHistory_wrongTypeId_neverLeaksARawException() {
        Id notADisposition = UserInfo.getUserId();

        Test.startTest();
        Boolean threwSomethingElse = false;
        try {
            List<BovBrokerChangeController.ChangeRow> rows =
                BovBrokerChangeController.getHistory(notADisposition);
            Assert.areEqual(0, rows.size(),
                'If the platform matched instead of throwing, it must have matched nothing');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('could not be loaded'),
                'The FIXED GENERIC message must be surfaced, not platform detail: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('No such column'),
                'An FLS denial must never reach the user as a schema error');
        } catch (Exception e) {
            threwSomethingElse = true;
        }
        Test.stopTest();

        Assert.isFalse(threwSomethingElse,
            'Anything other than AuraHandledException escaping this method reaches the LWC as an '
            + 'unhandled error — ARCHITECTURE.md §5 requires the boundary to convert it');
    }
}
