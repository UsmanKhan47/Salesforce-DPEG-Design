/**
 * Tests for NotificationTypeSelector (SYSTEM_MODE guest/automation lookup).
 *
 * CustomNotificationType is a setup/metadata object that cannot be inserted via
 * Apex DML, so the found path cannot be seeded under SeeAllData=false. These tests
 * exercise the query body and the not-found / blank-input contracts, which is the
 * full behavioural surface of the single method. The found path is validated
 * end-to-end by the deployed 'Broker_Portal_New_Lead' type in the target org.
 */
@isTest
private class NotificationTypeSelectorTest {

    @isTest
    static void selectByDeveloperName_missing_returnsNull() {
        Test.startTest();
        CustomNotificationType result =
            NotificationTypeSelector.selectByDeveloperName('ZZ_Nonexistent_Notif_Type_9x7');
        Test.stopTest();

        Assert.isNull(result, 'An unknown DeveloperName returns null (skip-notification state)');
    }

    @isTest
    static void selectByDeveloperName_blankInput_returnsNull() {
        Test.startTest();
        CustomNotificationType nullResult = NotificationTypeSelector.selectByDeveloperName(null);
        CustomNotificationType blankResult = NotificationTypeSelector.selectByDeveloperName('   ');
        Test.stopTest();

        Assert.isNull(nullResult, 'Null input returns null');
        Assert.isNull(blankResult, 'Blank input returns null');
    }
}
