/**
 * Tests for `DelinquencyAlertService` - FSD 5.9.7 rows 6 and 7.
 *
 * Two deliberately OPPOSITE idempotency contracts are asserted here, and the contrast is the point:
 *   - the stale-follow-up reminder is SUPPOSED to repeat until somebody acts;
 *   - the write-off routing must fire exactly ONCE.
 * Getting either backwards produces a plausible-looking feature that is wrong in a way nobody notices.
 */
@isTest
private class DelinquencyAlertServiceTest {

    private static final String STATUS_IDENTIFIED = 'Identified';

    /**
     * @return One open delinquency Case.
     */
    private static Case openCase() {
        List<Receivables_Summary__c> summaries =
            ReceivablesTestData.summaries(1, null, null, 9000, 95, null, true);
        return ReceivablesTestData.delinquencyCases(summaries, STATUS_IDENTIFIED, true)[0];
    }

    @isTest
    static void shouldRemind_WhenFollowUpHasGoneStale() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Case target = openCase();
        update new Case(Id = target.Id, Last_Follow_Up_DateTime__c = System.now().addDays(-30));

        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.staleReminders, 'A silent Case must produce a reminder');
    }

    @isTest
    static void shouldRemindAgain_WhenConditionPersists() {
        // DELIBERATELY NOT IDEMPOTENT. "No follow-up in seven days" persists until somebody acts, and
        // silencing it after the first night would turn the one alert designed to nag into another
        // one that fires once and is missed.
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Case target = openCase();
        update new Case(Id = target.Id, Last_Follow_Up_DateTime__c = System.now().addDays(-30));

        Test.startTest();
        DelinquencyAlertService.sweepAlerts(Date.today());
        DelinquencyAlertService.AlertResult second = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(1, second.staleReminders,
            'The reminder MUST repeat while the condition persists - it stops when the PM records a '
            + 'follow-up, which is the correct termination');
    }

    @isTest
    static void shouldNotRemind_WhenStaleWindowIsUnconfigured() {
        ReceivablesTestData.config(true, 'StubReceivablesFeedProvider', 5000, null);
        Case target = openCase();
        update new Case(Id = target.Id, Last_Follow_Up_DateTime__c = System.now().addDays(-90));

        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(0, result.staleReminders,
            'An unconfigured window disables the alert rather than defaulting to the FSD 7');
    }

    @isTest
    static void shouldRouteWriteOff_WhenRequestedAndUndecided() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Case target = openCase();
        update new Case(Id = target.Id, Write_Off_Requested__c = true,
            Write_Off_Requested_Amount__c = 9000, Write_Off_Decision__c = 'Pending');

        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(1, result.writeOffsRouted, 'The write-off must reach the principals');
        Assert.areEqual(3, [SELECT Escalation_Level__c FROM Case WHERE Id = :target.Id]
            .Escalation_Level__c,
            'And the ladder must be stamped at the write-off rung - reusing the one-way marker rather '
            + 'than inventing a second one');
    }

    @isTest
    static void shouldRouteWriteOffOnce_WhenSweptTwice() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Case target = openCase();
        update new Case(Id = target.Id, Write_Off_Requested__c = true,
            Write_Off_Requested_Amount__c = 9000, Write_Off_Decision__c = 'Pending');

        Test.startTest();
        DelinquencyAlertService.sweepAlerts(Date.today());
        DelinquencyAlertService.AlertResult second = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(0, second.writeOffsRouted,
            'A write-off must be routed EXACTLY ONCE - the opposite contract to the stale reminder, '
            + 'and getting them backwards is a plausible-looking bug nobody notices');
    }

    @isTest
    static void shouldNotRouteWriteOff_WhenDecisionIsAlreadyMade() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        Case target = openCase();
        update new Case(Id = target.Id, Write_Off_Requested__c = true,
            Write_Off_Decision__c = 'Rejected');

        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(0, result.writeOffsRouted,
            'A decided write-off must stop being routed');
    }

    @isTest
    static void shouldBeNoOp_WhenGivenNoDate() {
        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(null);
        Test.stopTest();

        Assert.areEqual(0, result.staleReminders, 'A null as-of date must short-circuit cleanly');
        Assert.areEqual(0, result.writeOffsRouted, 'Both arms');
    }

    @isTest
    static void shouldBeNoOp_WhenNothingNeedsAlerting() {
        ReceivablesTestData.configWithHealthArms(24, 1, 500, 7);
        openCase();

        Test.startTest();
        DelinquencyAlertService.AlertResult result = DelinquencyAlertService.sweepAlerts(Date.today());
        Test.stopTest();

        Assert.areEqual(0, result.staleReminders, 'A freshly opened Case is not yet stale');
        Assert.areEqual(0, result.writeOffsRouted, 'And has no write-off requested');
    }
}
