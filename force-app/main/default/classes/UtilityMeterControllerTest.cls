/**
 * Tests for `UtilityMeterController` - the register list and the UT-001 capture screen.
 *
 * Controller tests, so the volume proof is not here: the 251-record mandate targets the
 * DML-performing layer and lives in `MeterCaptureServiceTest`. What IS proved here is the
 * per-call QUERY COUNT, because the register list is the one place in this feature where a
 * per-meter query could hide and still look fine on a two-meter fixture.
 */
@isTest
private class UtilityMeterControllerTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Unit__c unit = TestDataFactory.createUnit(asset.Id, true);

        List<Meter__c> meters = TestDataFactory.createMeters(3, asset.Id, false);
        meters[1].Unit__c = unit.Id;
        insert meters;
        update new Meter__c(Id = meters[2].Id, Master_Meter__c = meters[0].Id);

        // A two-bill chain on the first meter so the register can show a real variance:
        // prior $100, current $200 -> +$100, +100%.
        List<Utility_Bill__c> bills =
            TestDataFactory.createUtilityBills(2, meters[0].Id, true);
        TestDataFactory.createChargeLine(bills[0].Id, 100, true);
        TestDataFactory.createChargeLine(bills[1].Id, 200, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    // ==================== register ====================

    @isTest
    static void getRegister_returnsEveryMeterWithItsLatestBillingFigures() {
        Test.startTest();
        List<UtilityMeterController.RegisterRow> rows =
            UtilityMeterController.getRegister(assetId());
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Every meter at the property.');

        UtilityMeterController.RegisterRow withBills;
        UtilityMeterController.RegisterRow subMeter;
        UtilityMeterController.RegisterRow onAUnit;
        for (UtilityMeterController.RegisterRow r : rows) {
            if (r.latestBillId != null) {
                withBills = r;
            }
            if (r.isSubMeter == true) {
                subMeter = r;
            }
            if (r.unitLabel != 'Whole building') {
                onAUnit = r;
            }
        }

        Assert.isNotNull(withBills, 'The billed meter is present.');
        Assert.areEqual(200, withBills.latestTotalCharges, 'Newest bill total.');
        Assert.areEqual(100, withBills.latestVarianceAmount, '$200 - $100.');
        Assert.areEqual(100, withBills.latestVariancePct,
            'A doubling is +100%, on the scale a human reads. Read straight from '
            + 'Total_Variance_Pct__c, the same field the record page and the alert batch '
            + 'read, so the three cannot disagree about one bill.');

        Assert.isNotNull(subMeter, 'The sub-meter is identified as one.');
        Assert.isNotNull(subMeter.masterMeterNumber,
            'And carries its master\'s meter NUMBER, so a row reads as "under 1234" without '
            + 'the client having to join anything.');

        Assert.isNotNull(onAUnit, 'The unit-scoped meter is labelled with its suite.');
    }

    @isTest
    static void getRegister_wholeBuildingMeter_saysSoRatherThanShowingABlank() {
        Test.startTest();
        List<UtilityMeterController.RegisterRow> rows =
            UtilityMeterController.getRegister(assetId());
        Test.stopTest();

        Boolean found = false;
        for (UtilityMeterController.RegisterRow r : rows) {
            if (r.unitLabel == 'Whole building') {
                found = true;
            }
        }
        Assert.isTrue(found,
            'FSD 5.10.4 makes a blank space MEANINGFUL - the meter serves the whole '
            + 'building. Rendering an empty cell would read as missing data and invite '
            + 'someone to "fix" it by picking a unit.');
    }

    @isTest
    static void getRegister_isTwoQueriesRegardlessOfMeterCount() {
        // Hoisted OUT of the measured window: Apex evaluates the argument after
        // Limits.getQueries() is captured, so an inline assetId() adds its own SELECT to the
        // count and the assertion measures the test rather than the code.
        Id asset = assetId();

        Test.startTest();
        Integer before = Limits.getQueries();
        UtilityMeterController.getRegister(asset);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(2, used,
            'One query for the meters, one for their bills. A per-meter bill lookup would '
            + 'read 2 here and 61 on a 60-meter property, which is exactly the shape that '
            + 'passes review on a small fixture and breaks in production. Used: ' + used);
    }

    @isTest
    static void getRegister_propertyWithNoMeters_returnsEmptyWithoutASecondQuery() {
        Property_Asset__c bare = TestDataFactory.createPropertyAsset(
            [SELECT Id FROM Property__c LIMIT 1].Id, true);

        Test.startTest();
        Integer before = Limits.getQueries();
        List<UtilityMeterController.RegisterRow> rows =
            UtilityMeterController.getRegister(bare.Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'No meters, no rows.');
        Assert.areEqual(1, used,
            'The bill query is skipped entirely when there are no meters - which is EVERY '
            + 'property before its meters are captured, i.e. the common case on a new '
            + 'onboarding.');
    }

    /**
     * A user with NO access to anything in this feature.
     *
     * `Minimum Access - Salesforce`, NOT `Standard User`: the standard profile carries broad
     * grants that mask a denial and make a permission test pass for the wrong reason
     * (`.claude/rules`, and this repo's own recorded history). No permission set is assigned,
     * so `Meter__c` is genuinely invisible and the USER_MODE selector genuinely throws - which
     * is what makes this an error-path test rather than a mock.
     */
    private static User noAccessUser() {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User u = new User(
            FirstName = 'No', LastName = 'Access', Alias = 'noac',
            Email = 'dpeg.noaccess@example.invalid',
            Username = 'umc' + String.valueOf(DateTime.now().getTime())
                + String.valueOf(Math.abs(Crypto.getRandomInteger())) + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id, TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    @isTest
    static void getRegister_userWithoutAccess_getsTheGenericMessageAndNoPlatformDetail() {
        User denied = noAccessUser();
        Id asset = assetId();
        Boolean threw = false;
        String message;

        Test.startTest();
        System.runAs(denied) {
            try {
                UtilityMeterController.getRegister(asset);
            } catch (AuraHandledException e) {
                threw = true;
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'USER_MODE THROWS, IT DOES NOT DEGRADE - that is the whole reason this read is '
            + 'USER_MODE and the trigger-path one is not.');
        Assert.isFalse(message.containsIgnoreCase('sObject type'),
            'The user sees a fixed generic message with NO platform detail concatenated into '
            + 'it; the detail goes to the admin-only debug log. Got: ' + message);
        Assert.isTrue(message.contains('could not be loaded'),
            'And it is the READ-failure message, not the save one. Got: ' + message);
    }

    // ==================== capture screen ====================

    @isTest
    static void getCaptureModel_returnsTheSpacesAndTheExistingRegister() {
        Test.startTest();
        UtilityMeterController.CaptureModel model =
            UtilityMeterController.getCaptureModel(assetId());
        Test.stopTest();

        Assert.areEqual(assetId(), model.propertyAssetId, 'Echoed for the save call.');
        Assert.areEqual(1, model.units.size(), 'One space at this property.');
        Assert.isNotNull(model.units[0].label, 'And it is labelled.');
        Assert.areEqual(3, model.existingMeters.size(),
            'The EXISTING meters come back, not an empty grid. UT-001 can fire more than '
            + 'once in a property\'s life, and an empty grid would invite a duplicate '
            + 'register.');
        Assert.isNotNull(model.existingMeters[0].meterId,
            'Each carries its Id, which is what makes the save an UPDATE rather than an '
            + 'insert.');
    }

    @isTest
    static void getCaptureModel_unnamedSpace_getsAPlaceholderNotAnEmptyLabel() {
        Unit__c unit = [SELECT Id FROM Unit__c LIMIT 1];
        update new Unit__c(Id = unit.Id, Suite_Number__c = null);

        Test.startTest();
        UtilityMeterController.CaptureModel model =
            UtilityMeterController.getCaptureModel(assetId());
        Test.stopTest();

        Assert.areEqual('Unnamed space', model.units[0].label,
            'A blank label would render as an empty radio option the user cannot tell apart '
            + 'from the whole-building row.');
    }

    @isTest
    static void getCaptureModel_propertyWithNothing_returnsEmptyCollectionsNotNulls() {
        Property_Asset__c bare = TestDataFactory.createPropertyAsset(
            [SELECT Id FROM Property__c LIMIT 1].Id, true);

        Test.startTest();
        UtilityMeterController.CaptureModel model =
            UtilityMeterController.getCaptureModel(bare.Id);
        Test.stopTest();

        Assert.areEqual(0, model.units.size(), 'No spaces.');
        Assert.areEqual(0, model.existingMeters.size(),
            'And no meters - but both are EMPTY LISTS, never null. A null here becomes an '
            + 'undefined the client would iterate.');
    }

    @isTest
    static void getCaptureModel_userWithoutAccess_raisesTheGenericReadFailure() {
        User denied = noAccessUser();
        Id asset = assetId();
        Boolean threw = false;

        Test.startTest();
        System.runAs(denied) {
            try {
                UtilityMeterController.getCaptureModel(asset);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'The capture screen is a user-requested read into a Private-OWD object. A user '
            + 'who cannot see a property\'s meters must not be handed them by a modal.');
    }

    // ==================== save ====================

    @isTest
    static void saveMeters_delegatesToTheServiceAndReturnsWhatHappened() {
        MeterCaptureService.MeterRow r = new MeterCaptureService.MeterRow();
        r.meterNumber = 'VIA-CONTROLLER';
        r.utilityType = 'Water';
        r.registerSize = 5;
        r.serviceStatus = 'Active';

        Test.startTest();
        MeterCaptureService.CaptureResult result = UtilityMeterController.saveMeters(
            assetId(), new List<MeterCaptureService.MeterRow>{ r });
        Test.stopTest();

        Assert.areEqual(1, result.created, 'The controller is a pass-through to the service.');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Meter__c WHERE Meter_Number__c = 'VIA-CONTROLLER'],
            'And the meter is on the register.');
    }

    @isTest
    static void saveMeters_serviceRefusal_becomesTheGenericSaveFailureMessage() {
        Boolean threw = false;
        String message;
        Test.startTest();
        try {
            // Null property: the service throws IllegalArgumentException, which must NOT
            // reach the client as itself.
            UtilityMeterController.saveMeters(null, new List<MeterCaptureService.MeterRow>());
        } catch (AuraHandledException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Every failure crosses the boundary as AuraHandledException.');
        Assert.isTrue(message.contains('could not be saved'),
            'And it is the fixed, user-safe save message rather than the internal one. '
            + 'Got: ' + message);
    }
}
