/**
 * Test class for EmailToLeadService — the Lead DML layer of the Broker-Protection
 * inbound-email intake pipeline (Phase 3 rewrite, staging model).
 *
 * PHASE 2 SIGNATURE CHANGE THIS REWRITE TRACKS: the old two-call shape
 * (createLeadAndEnqueue inserts a bare Lead from the envelope, then a later
 * applyExtractedDetails update fills in the LLM's answers) collapsed into ONE
 * method, createLeadFromExtracted(extracted, fromName, fromAddress, emailSubject,
 * rawBody, forwardedByEmail), which builds and inserts a COMPLETE Lead in a single
 * DML statement once extraction has already happened, and returns its Id. There is
 * no enqueue call in this class any more — EmailToLeadHandler owns that — so this
 * class covers ONLY createLeadFromExtracted (and its private applyName helper,
 * exercised through that one public entry point).
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in
 * this exact module (PropertyClaimServiceTest, PropertyMatchingServiceTest), which
 * takes precedence over the repo-wide System.assert* majority per this module's
 * established convention.
 *
 * @author Unit Testing Agent
 */
@isTest
private class EmailToLeadServiceTest {

    private static Map<String, String> extractedWith(String brokerName, String brokerEmail, String propertyAddress) {
        return new Map<String, String>{
            'broker_name' => brokerName, 'broker_email' => brokerEmail, 'property_address' => propertyAddress
        };
    }

    // ── name splitting (applyName, via broker_name / fromName precedence) ───────

    @isTest
    static void createLeadFromExtracted_singleTokenBrokerName_setsLastNameOnly() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Smith', 'smith@brokerfirm.example.invalid', '100 Main St'),
            'Fallback Name', 'fallback@example.invalid', 'FW: 100 Main St', 'body text', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A spaceless broker_name should not populate FirstName');
        Assert.areEqual('Smith', created.LastName, 'A spaceless broker_name should become the whole LastName');
    }

    @isTest
    static void createLeadFromExtracted_twoTokenBrokerName_splitsFirstAndLastName() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@brokerfirm.example.invalid', '100 Main St'),
            null, 'jane@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be the first token');
        Assert.areEqual('Broker', created.LastName, 'LastName should be the second token');
    }

    @isTest
    static void createLeadFromExtracted_threeTokenBrokerName_joinsTailIntoLastName() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Mary Jane Watson', 'mary@example.invalid', null),
            null, 'mary@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Mary', created.FirstName, 'FirstName should be only the first token');
        Assert.areEqual('Jane Watson', created.LastName, 'The tail must be joined into LastName, never dropped');
    }

    @isTest
    static void createLeadFromExtracted_brokerNameTrailingSpace_collapsesToSingleTokenLastName() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane ', 'jane.trailing@example.invalid', null),
            null, 'jane.trailing@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A trailing-space name that trims to one token should not populate FirstName');
        Assert.areEqual('Jane', created.LastName, 'A trailing space must trim + collapse to a single token, not throw an index-out-of-bounds');
    }

    @isTest
    static void createLeadFromExtracted_brokerNameDoubleSpace_splitsFirstAndLastNameNotBlank() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane  Broker', 'jane.double@example.invalid', null),
            null, 'jane.double@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be the first token even across a run of whitespace');
        Assert.areEqual('Broker', created.LastName, 'A double space must collapse via \\s+ splitting, so LastName is not blank');
    }

    @isTest
    static void createLeadFromExtracted_nullBrokerNameAndFromName_defaultsLastNameToUnknown() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith(null, null, null),
            null, 'anon@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'No usable name should leave FirstName unset');
        Assert.areEqual('Unknown', created.LastName, 'No usable name should fall back to the required LastName default');
    }

    @isTest
    static void createLeadFromExtracted_blankBrokerName_fallsBackToEnvelopeFromName() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('', '', null),
            'Envelope Sender', 'sender@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Envelope', created.FirstName, 'A blank broker_name should fall back to the envelope fromName');
        Assert.areEqual('Sender', created.LastName, 'A blank broker_name should fall back to the envelope fromName');
    }

    // ── email precedence ──────────────────────────────────────────────────────

    @isTest
    static void createLeadFromExtracted_brokerEmailPresent_takesPrecedenceOverFromAddress() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'llm.broker@example.invalid', null),
            'Jane Broker', 'envelope.from@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('llm.broker@example.invalid', created.Email, 'The LLM broker_email should win over the envelope From address');
    }

    @isTest
    static void createLeadFromExtracted_blankBrokerEmail_fallsBackToFromAddress() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', '', null),
            'Jane Broker', 'envelope.from@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('envelope.from@example.invalid', created.Email, 'A blank broker_email should fall back to the envelope From address');
    }

    @isTest
    static void createLeadFromExtracted_malformedBrokerEmail_fallsBackToFromAddress() {
        // sanitizeEmail rejects a malformed LLM answer (e.g. a display name instead of an
        // address) rather than writing it to the Email field and throwing
        // INVALID_EMAIL_ADDRESS and rolling back the whole claim.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'not an email address', null),
            'Jane Broker', 'envelope.from@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('envelope.from@example.invalid', created.Email,
            'A malformed broker_email must be sanitized away and fall back to the envelope From address, not throw');
    }

    @isTest
    static void createLeadFromExtracted_bothEmailsBlank_leavesEmailNull() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', '', null),
            'Jane Broker', '', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.Email, 'With no usable broker_email and no usable fromAddress, Email should be left null');
    }

    // ── property address ──────────────────────────────────────────────────────

    @isTest
    static void createLeadFromExtracted_propertyAddressPresent_stampsPropertyAddress() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', '100 Main St, Houston, TX'),
            null, 'jane@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Property_Address__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('100 Main St, Houston, TX', created.Property_Address__c, 'Property_Address__c should be stamped from the extraction');
    }

    @isTest
    static void createLeadFromExtracted_blankPropertyAddress_leavesPropertyAddressBlank() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', ''),
            null, 'jane@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Property_Address__c FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.Property_Address__c, 'A blank extracted address should never be stamped');
    }

    // ── forwarded-by ──────────────────────────────────────────────────────────

    @isTest
    static void createLeadFromExtracted_forwardedByPresent_stampsForwardedByEmail() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', null),
            null, 'jane@example.invalid', 'FW: subject', 'body', 'forwarder@example.invalid');
        Test.stopTest();

        Lead created = [SELECT Forwarded_By_Email__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('forwarder@example.invalid', created.Forwarded_By_Email__c, 'Forwarded_By_Email__c should be stamped from forwardedByEmail');
    }

    @isTest
    static void createLeadFromExtracted_blankForwardedBy_leavesForwardedByBlank() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', null),
            null, 'jane@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Forwarded_By_Email__c FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.Forwarded_By_Email__c, 'A blank forwardedByEmail should leave Forwarded_By_Email__c unset');
    }

    // ── fixed fields + null-map safety + field-length safety ────────────────────

    @isTest
    static void createLeadFromExtracted_allFieldsPresent_stampsCompanyLeadSourceStatusSubjectDescription() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', '100 Main St'),
            null, 'jane@example.invalid', 'FW: 100 Main St', 'The raw email body', 'forwarder@example.invalid');
        Test.stopTest();

        Lead created = [
            SELECT Company, LeadSource, Status, Email_Subject__c, Description FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('Unknown - Via Email', created.Company, 'Company should be the required placeholder');
        Assert.areEqual('Email-to-Lead', created.LeadSource, 'LeadSource should be stamped');
        Assert.areEqual('New', created.Status, 'Status should be New');
        Assert.areEqual('FW: 100 Main St', created.Email_Subject__c, 'Email_Subject__c should be the inbound subject');
        Assert.areEqual('The raw email body', created.Description, 'Description should be the raw email body');
    }

    @isTest
    static void createLeadFromExtracted_nullExtractedMap_doesNotThrowAndFallsBackToEnvelope() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            null, 'Envelope Name', 'envelope@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Envelope', created.FirstName, 'A null extracted map should null-coalesce to empty and fall back to the envelope name');
        Assert.areEqual('Name', created.LastName, 'A null extracted map should null-coalesce to empty and fall back to the envelope name');
        Assert.areEqual('envelope@example.invalid', created.Email, 'A null extracted map should fall back to the envelope From address for Email');
    }

    @isTest
    static void createLeadFromExtracted_overLongSubjectAndBody_areClippedNotThrown() {
        String longSubject = ''.rightPad(300, 'x');
        String longBody = ''.rightPad(33000, 'y');

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(
            extractedWith('Jane Broker', 'jane@example.invalid', null),
            null, 'jane@example.invalid', longSubject, longBody, null);
        Test.stopTest();

        Lead created = [SELECT Email_Subject__c, Description FROM Lead WHERE Id = :leadId];
        Assert.areEqual(255, created.Email_Subject__c.length(), 'An over-long subject should be clipped to 255 characters, not throw STRING_TOO_LONG');
        Assert.areEqual(32000, created.Description.length(), 'An over-long body should be clipped to 32000 characters, not throw STRING_TOO_LONG');
    }
}
