/**
 * Tests for `MeterCaptureService` - the UAT UT-001 save ("meters saved against property and
 * spaces").
 *
 * VOLUME: 251 per `.claude/rules/bulk-test-rule.md`. This is a DML-performing service, so
 * the mandate applies in full and the carve-outs do not: no content object is involved
 * (`.claude/rules/content-publication-rule.md`) and the method is NOT a per-transaction
 * singleton - a 60-suite property submits its whole grid in one call, so a per-row DML would
 * be a real production failure at a realistic size, not a theoretical one.
 */
@isTest
private class MeterCaptureServiceTest {

    // `bulk` is a reserved word in Apex; `BULK_ROWS` is the project's spelling.
    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        TestDataFactory.createUnits(2, asset.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static MeterCaptureService.MeterRow row(Id unitId, String meterNumber) {
        MeterCaptureService.MeterRow r = new MeterCaptureService.MeterRow();
        r.unitId = unitId;
        r.meterNumber = meterNumber;
        r.utilityType = 'Electricity';
        r.utilityAccountNumber = 'ACCT-' + meterNumber;
        r.providerName = 'CenterPoint Energy';
        r.paidBy = 'Tenant';
        r.registerSize = 5;
        r.serviceStatus = 'Active';
        return r;
    }

    @isTest
    static void save_newRows_createsMetersAgainstThePropertyAndItsSpaces() {
        List<Unit__c> units = [SELECT Id FROM Unit__c ORDER BY Suite_Number__c];
        List<MeterCaptureService.MeterRow> rows = new List<MeterCaptureService.MeterRow>{
            row(units[0].Id, 'M-1'), row(units[1].Id, 'M-2'), row(null, 'M-HOUSE') };

        Test.startTest();
        MeterCaptureService.CaptureResult result =
            MeterCaptureService.save(assetId(), rows);
        Test.stopTest();

        Assert.areEqual(3, result.created, 'Three meters created.');
        Assert.areEqual(0, result.updated, 'None updated.');
        Assert.areEqual(3, result.meterIds.size(), 'And their Ids come back for the refresh.');
        Assert.areEqual(3, [SELECT COUNT() FROM Meter__c WHERE Property_Asset__c = :assetId()],
            'UT-001: meters saved against the PROPERTY.');
        Assert.areEqual(1, [SELECT COUNT() FROM Meter__c WHERE Unit__c = NULL],
            'And a blank space is preserved as "whole building" (FSD 5.10.4) rather than '
            + 'being defaulted to the first unit.');
    }

    @isTest
    static void save_existingRows_updateRatherThanDuplicate() {
        Meter__c existing = TestDataFactory.createMeter(assetId(), true);
        MeterCaptureService.MeterRow edit = row(null, 'RENUMBERED');
        edit.meterId = existing.Id;

        Test.startTest();
        MeterCaptureService.CaptureResult result = MeterCaptureService.save(
            assetId(), new List<MeterCaptureService.MeterRow>{ edit });
        Test.stopTest();

        Assert.areEqual(0, result.created, 'Nothing new.');
        Assert.areEqual(1, result.updated, 'The existing meter is edited in place.');
        Assert.areEqual(1, [SELECT COUNT() FROM Meter__c],
            'UT-001 can fire more than once in a property\'s life (a re-opened task, a second '
            + 'transfer). Returning existing meters to the grid is what keeps the second run '
            + 'from building a duplicate register.');
        Assert.areEqual('RENUMBERED',
            [SELECT Meter_Number__c FROM Meter__c LIMIT 1].Meter_Number__c, 'The edit stuck.');
    }

    @isTest
    static void save_untouchedGridLines_areSkippedNotSavedAsEmptyMeters() {
        MeterCaptureService.MeterRow blank = new MeterCaptureService.MeterRow();
        blank.unitLabel = 'Suite 101';   // display only - the user typed nothing

        Test.startTest();
        MeterCaptureService.CaptureResult result = MeterCaptureService.save(
            assetId(), new List<MeterCaptureService.MeterRow>{ blank, row(null, 'M-REAL') });
        Test.stopTest();

        Assert.areEqual(1, result.skipped,
            'The grid draws a line per space whether or not that space has a meter. Saving '
            + 'the empty ones would fill the register with blank rows that then appear on '
            + 'every list and every report.');
        Assert.areEqual(1, result.created, 'Only the row with data.');
        Assert.areEqual(1, [SELECT COUNT() FROM Meter__c], 'One meter on the register.');
    }

    @isTest
    static void save_reusedServiceIdentifier_warnsWithoutRefusing() {
        // The earliest point in the whole feature at which a physical meter swap can be
        // named: the same ESID arriving under a different meter number.
        Meter__c original = TestDataFactory.createMeter(assetId(), false);
        original.Meter_Number__c = 'OLD-DEVICE';
        original.Service_Identifier__c = 'ESID-SHARED-1';
        insert original;

        MeterCaptureService.MeterRow replacement = row(null, 'NEW-DEVICE');
        replacement.serviceIdentifier = 'ESID-SHARED-1';

        Test.startTest();
        MeterCaptureService.CaptureResult result = MeterCaptureService.save(
            assetId(), new List<MeterCaptureService.MeterRow>{ replacement });
        Test.stopTest();

        Assert.areEqual(1, result.created,
            'A WARNING, NEVER A REFUSAL. Two meters legitimately share an ESID during a '
            + 'changeover, and FSD 5.10 asks for no validation rules.');
        Assert.areEqual(1, result.warnings.size(), 'One warning raised.');
        Assert.isTrue(result.warnings[0].contains('OLD-DEVICE'),
            'And it NAMES the meter number already on that service point, so the user can '
            + 'act on it: ' + result.warnings[0]);
    }

    @isTest
    static void save_editingTheMeterThatOwnsTheServiceIdentifier_doesNotWarn() {
        // The falsifier: without this branch, every subsequent edit of a meter would warn
        // about its own ESID and the warning would become noise nobody reads.
        Meter__c existing = TestDataFactory.createMeter(assetId(), false);
        existing.Service_Identifier__c = 'ESID-SELF-1';
        existing.Meter_Number__c = 'SAME-DEVICE';
        insert existing;

        MeterCaptureService.MeterRow edit = row(null, 'RENAMED-DEVICE');
        edit.meterId = existing.Id;
        edit.serviceIdentifier = 'ESID-SELF-1';

        Test.startTest();
        MeterCaptureService.CaptureResult result = MeterCaptureService.save(
            assetId(), new List<MeterCaptureService.MeterRow>{ edit });
        Test.stopTest();

        Assert.areEqual(0, result.warnings.size(),
            'The ESID belongs to the very meter being edited, and that meter is the only '
            + 'holder - so this is a rename, not a swap.');
        Assert.areEqual(1, result.updated, 'And the edit still saved.');
    }

    @isTest
    static void save_failingUpdate_rollsBackTheInsertThatAlreadySucceeded() {
        // THE REASON THE SAVEPOINT EXISTS. The grid can produce an insert list AND an update
        // list. `allOrNone = true` makes each DML atomic ON ITS OWN but not the PAIR - so an
        // insert that succeeded followed by an update that failed would leave half the grid
        // committed while the screen shows an error, which is the worst of both outcomes.
        Meter__c existing = TestDataFactory.createMeter(assetId(), true);

        MeterCaptureService.MeterRow goodInsert = row(null, 'WILL-BE-ROLLED-BACK');
        MeterCaptureService.MeterRow badUpdate = row(null, 'BAD');
        badUpdate.meterId = existing.Id;
        // Utility_Type__c is a RESTRICTED picklist, and restricted picklists on this project
        // are enforced AT DML (measured 4x) - not merely in the UI. So this update fails.
        badUpdate.utilityType = 'Plutonium';

        Boolean threw = false;
        Test.startTest();
        try {
            MeterCaptureService.save(assetId(),
                new List<MeterCaptureService.MeterRow>{ goodInsert, badUpdate });
        } catch (DmlException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The invalid picklist value must fail the save.');
        Assert.areEqual(1, [SELECT COUNT() FROM Meter__c],
            'ONLY the pre-existing meter survives. Without the savepoint the new meter would '
            + 'have stayed committed after the update failed, and the user - who saw an '
            + 'error - would have no idea it was there.');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Meter__c WHERE Meter_Number__c = 'WILL-BE-ROLLED-BACK'],
            'Named explicitly so the assertion cannot pass on a miscount.');
    }

    @isTest
    static void save_nullProperty_isRefusedBeforeAnythingIsWritten() {
        Boolean threw = false;
        Test.startTest();
        try {
            MeterCaptureService.save(null,
                new List<MeterCaptureService.MeterRow>{ row(null, 'M-ORPHAN') });
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'A meter with no property is invisible on every register list in the app, so a '
            + 'null property is refused rather than silently accepted.');
        Assert.areEqual(0, [SELECT COUNT() FROM Meter__c], 'And nothing was written.');
    }

    @isTest
    static void save_nullAndEmptyRows_returnAnEmptyResultWithoutDml() {
        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        MeterCaptureService.CaptureResult nullRows = MeterCaptureService.save(assetId(), null);
        MeterCaptureService.CaptureResult noRows = MeterCaptureService.save(
            assetId(), new List<MeterCaptureService.MeterRow>());
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(),
            'An empty submit must not cost a DML statement.');
        Test.stopTest();

        Assert.areEqual(0, nullRows.created, 'Null rows.');
        Assert.areEqual(0, noRows.created, 'Empty rows.');
        Assert.areEqual(0, nullRows.warnings.size(), 'And the collections are never null.');
    }

    @isTest
    static void save_251Rows_isOneInsertNotTwoHundredAndFiftyOne() {
        List<MeterCaptureService.MeterRow> rows = new List<MeterCaptureService.MeterRow>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            rows.add(row(null, 'BULK-' + i));
        }

        // assetId() IS HOISTED OUT OF THE MEASURED WINDOW ON PURPOSE. Apex evaluates the
        // argument AFTER Limits.getQueries() has been captured, so calling it inline adds its
        // own SELECT to the count and the assertion silently measures the test instead of the
        // code. That cost one debugging round on this very method.
        Id asset = assetId();

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer queriesBefore = Limits.getQueries();
        MeterCaptureService.CaptureResult result = MeterCaptureService.save(asset, rows);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, result.created, 'All 251 created.');
        Assert.areEqual(BULK_ROWS, [SELECT COUNT() FROM Meter__c], 'And all 251 persisted.');
        // 2, not 1: Database.setSavepoint() itself counts against the DML STATEMENT limit,
        // so the pair is (savepoint, insert). It is worth the statement - see the class header
        // on why a half-committed grid is worse than a refused one.
        Assert.areEqual(2, dmlUsed,
            'ONE insert statement for 251 rows, plus the savepoint. A per-row DML would hit '
            + 'the 150-statement limit at row 151 - and a 60-suite property with several '
            + 'utilities each is a realistic size, so that is a production failure and not a '
            + 'theoretical one. Used: ' + dmlUsed);
        Assert.areEqual(0, queriesUsed,
            'ZERO queries: no row carried a service identifier, so the ESID probe was '
            + 'short-circuited before it reached the database.');
    }

    @isTest
    static void save_251RowsWithServiceIdentifiers_stillCostsOneQueryAndOneInsert() {
        List<MeterCaptureService.MeterRow> rows = new List<MeterCaptureService.MeterRow>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            MeterCaptureService.MeterRow r = row(null, 'ESIDBULK-' + i);
            r.serviceIdentifier = 'ESID-BULK-' + i;
            rows.add(r);
        }

        Id asset = assetId();   // hoisted - see the note in the test above

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer queriesBefore = Limits.getQueries();
        MeterCaptureService.save(asset, rows);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(2, dmlUsed, 'Still one insert (plus the savepoint statement).');
        Assert.areEqual(1, queriesUsed,
            'And ONE query for 251 distinct service identifiers. The ESID probe reads every '
            + 'one of them in a single IN clause; a per-row lookup would be 251 queries and '
            + 'would break the 100-query limit at row 101.');
        Assert.areEqual(BULK_ROWS, [SELECT COUNT() FROM Meter__c], 'All 251 persisted.');
    }
}
