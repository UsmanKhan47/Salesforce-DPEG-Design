/**
 * Test class for ExtractAddressQueueable: the async orchestrator chaining the LLM
 * callout, the regex fallback, the Lead detail write, and the first-broker-wins claim.
 * Every scenario mocks the LLM callout boundary (Test.setMock, set before
 * Test.startTest()) and wraps the enqueue in Test.startTest()/Test.stopTest() so the
 * job runs synchronously and its effects can be asserted.
 *
 * @author Unit Testing Agent
 */
@isTest
private class ExtractAddressQueueableTest {

    private static void setMock(Map<String, String> fields) {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fields, false)));
    }

    private static Map<String, String> blankFields() {
        return new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '', 'sent_datetime' => ''
        };
    }

    // ── winner path ──────────────────────────────────────────────────────────

    @isTest
    static void execute_newProperty_claimsWinnerAndAppliesLeadDetails() {
        Lead sourceLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Winner St',
            'sent_datetime' => '2026-07-01 10:00:00'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            sourceLead.Id, 'some forwarded email body', null, null, 'forwarder@example.invalid', 'FW: 100 Winner St'
        ));
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName, Email, Property_Address__c, Forwarded_By_Email__c FROM Lead WHERE Id = :sourceLead.Id];
        Assert.areEqual('Jane', updated.FirstName, 'FirstName should be applied from the LLM extraction');
        Assert.areEqual('Broker', updated.LastName, 'LastName should be applied from the LLM extraction');
        Assert.areEqual('jane@brokerfirm.example.invalid', updated.Email, 'Email should be applied from the LLM extraction');
        Assert.areEqual('100 Winner St', updated.Property_Address__c, 'Property_Address__c should be applied');

        List<Property_Registry__c> registries = [
            SELECT Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c = '100 winner st'
        ];
        Assert.areEqual(1, registries.size(), 'A winner registry row should be created for the normalized address');
        Assert.areEqual(sourceLead.Id, registries[0].Winning_Lead__c, 'The lead should win the claim');

        Competing_Broker_Submission__c sub = [
            SELECT Is_Winning_Submission__c, Submitted_DateTime__c
            FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :sourceLead.Id
        ];
        Assert.isTrue(sub.Is_Winning_Submission__c, 'The submission should be flagged as the winner');
        Assert.areEqual(Datetime.valueOfGmt('2026-07-01 10:00:00'), sub.Submitted_DateTime__c,
            'Submitted_DateTime__c should be parsed from the LLM\'s sent_datetime');
    }

    // ── duplicate path (property already claimed) ───────────────────────────

    @isTest
    static void execute_alreadyClaimedProperty_marksDuplicateNotSecondWinner() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('200 duplicate st', winnerLead.Id, true);
        Lead newLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => 'Competing Broker',
            'broker_email' => 'competing@example.invalid',
            'property_address' => '200 Duplicate St',
            'sent_datetime' => '2026-07-02 09:00:00'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            newLead.Id, 'some forwarded email body', null, null, 'forwarder2@example.invalid', 'FW: 200 Duplicate St'
        ));
        Test.stopTest();

        Lead updated = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :newLead.Id];
        Assert.isTrue(updated.Is_Duplicate_Property__c, 'The second submitter should be flagged a duplicate');
        Assert.areEqual(winnerLead.Id, updated.Duplicate_Of_Lead__c, 'It should point at the existing winner');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '200 duplicate st'],
            'No second registry row should be created for an already-claimed property');

        Competing_Broker_Submission__c sub = [
            SELECT Winning_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :newLead.Id
        ];
        Assert.areEqual(winnerLead.Id, sub.Winning_Lead__c, 'The duplicate submission should roll up under the existing winner');
        Assert.isFalse(sub.Is_Winning_Submission__c, 'The duplicate submission must not be flagged as the winner');
    }

    // ── blank-address early return ───────────────────────────────────────────

    @isTest
    static void execute_blankPropertyAddress_appliesDetailsButNeverClaims() {
        Lead sourceLead = TestDataFactory.createLead(true);
        sourceLead.Property_Address__c = null;
        update sourceLead;
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '',
            'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            sourceLead.Id, null, null, null, 'forwarder@example.invalid', 'FW: no address'
        ));
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName, Property_Address__c FROM Lead WHERE Id = :sourceLead.Id];
        Assert.areEqual('Jane', updated.FirstName, 'Broker details should still be applied even with no usable address');
        Assert.isNull(updated.Property_Address__c, 'A blank extracted address should never be applied');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :sourceLead.Id],
            'No registry row should be created when there is no usable normalized address');
        Assert.areEqual(0, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :sourceLead.Id],
            'No submission should be logged when there is no usable normalized address');
    }

    // ── regex fallback ────────────────────────────────────────────────────────

    @isTest
    static void execute_blankBrokerFields_backfillsFromFromLineRegex() {
        Lead sourceLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '500 Fallback Ave', 'sent_datetime' => ''
        });
        String textContent = 'From: Jane Broker <jane@x.com>\n' +
            'Sent: Monday, January 5, 2026 10:00 AM\n' +
            'To: forwarder@dpeg.example.invalid\n' +
            'Subject: FW: Property listing\n\n' +
            'Please see attached.';

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            sourceLead.Id, textContent, null, null, 'forwarder@dpeg.example.invalid', 'FW: Property listing'
        ));
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :sourceLead.Id];
        Assert.areEqual('Jane', updated.FirstName, 'FirstName should be backfilled from the raw From: line via regex');
        Assert.areEqual('Broker', updated.LastName, 'LastName should be backfilled from the raw From: line via regex');
        Assert.areEqual('jane@x.com', updated.Email, 'Email should be backfilled from the raw From: line via regex');
    }

    @isTest
    static void execute_onlyBrokerNameBlank_regexFallbackDoesNotOverwriteLlmEmail() {
        Lead sourceLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => 'llm.broker@example.invalid', 'property_address' => '', 'sent_datetime' => ''
        });
        String textContent = 'From: Jane Broker <jane@x.com>\nSent: Monday\nTo: forwarder@dpeg.example.invalid\n\nBody.';

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            sourceLead.Id, textContent, null, null, 'forwarder@dpeg.example.invalid', 'FW: partial'
        ));
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :sourceLead.Id];
        Assert.areEqual('Jane', updated.FirstName, 'The blank broker_name should still be backfilled by regex');
        Assert.areEqual('Broker', updated.LastName, 'The blank broker_name should still be backfilled by regex');
        Assert.areEqual('llm.broker@example.invalid', updated.Email,
            'A non-blank LLM broker_email must not be overwritten by the regex fallback');
    }

    // ── forceClaimRace seam ───────────────────────────────────────────────────

    @isTest
    static void execute_forceClaimRace_forcesClaimDmlRaceRecovery() {
        Lead existingWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('600 race ave', existingWinner.Id, true);
        Lead newLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => 'Racer Broker', 'broker_email' => 'racer@example.invalid',
            'property_address' => '600 Race Ave', 'sent_datetime' => ''
        });

        ExtractAddressQueueable.forceClaimRace = true;
        try {
            Test.startTest();
            System.enqueueJob(new ExtractAddressQueueable(
                newLead.Id, 'body', null, null, 'forwarder3@example.invalid', 'FW: 600 Race Ave'
            ));
            Test.stopTest();
        } finally {
            ExtractAddressQueueable.forceClaimRace = false;
        }

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '600 race ave'],
            'Forcing the race must not create a second registry row for the same key');

        Lead updated = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :newLead.Id];
        // W4 NOTE: forceClaimRace skips ONLY the queueable's own cheap upfront
        // findMatchingRegistry short-circuit — PropertyClaimService.claim() now runs its OWN
        // findMatchingRegistry check (under the cluster lock) before ever attempting an insert,
        // so this no longer forces the DUPLICATE_VALUE-DmlException catch path inside
        // registerWinner (that path is now reachable only for the orphan-adoption case; see
        // PropertyClaimServiceTest's class header for why the live-winner catch re-check is an
        // accepted-uncovered defensive branch). This still legitimately proves the two callers
        // (the queueable's shortcut vs. claim()'s own pre-check) converge on the same correct
        // outcome regardless of which one runs.
        Assert.isTrue(updated.Is_Duplicate_Property__c,
            'With forceClaimRace=true, claim() must still correctly reconcile this lead as a duplicate via its own pre-lock findMatchingRegistry check');
        Assert.areEqual(existingWinner.Id, updated.Duplicate_Of_Lead__c, 'The race recovery should point at the real existing winner');
    }

    // ── parseSentDatetime fallback ────────────────────────────────────────────

    @isTest
    static void execute_unparseableSentDatetime_fallsBackToNow() {
        Lead sourceLead = TestDataFactory.createLead(true);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'jane@example.invalid',
            'property_address' => '700 Fallback Time Ave', 'sent_datetime' => 'not-a-real-date'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(
            sourceLead.Id, 'body', null, null, 'forwarder4@example.invalid', 'FW: bad date'
        ));
        Test.stopTest();

        Competing_Broker_Submission__c sub = [
            SELECT Submitted_DateTime__c FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :sourceLead.Id
        ];
        Assert.isNotNull(sub.Submitted_DateTime__c, 'An unparseable sent_datetime must still stamp a value (now())');
        Assert.isTrue(Math.abs(sub.Submitted_DateTime__c.getTime() - Datetime.now().getTime()) < 60000,
            'The fallback value should be approximately now(), not the unparseable raw string');
    }
}
