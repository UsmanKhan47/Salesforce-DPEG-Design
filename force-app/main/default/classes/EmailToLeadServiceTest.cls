/**
 * Test class for EmailToLeadService: the Lead DML layer for the inbound-email intake
 * pipeline. createLeadAndEnqueue tests set a benign, all-blank LLM mock so the
 * enqueued ExtractAddressQueueable (which runs synchronously at Test.stopTest()) has
 * no side effects to worry about — those are covered in ExtractAddressQueueableTest.
 *
 * @author Unit Testing Agent
 */
@isTest
private class EmailToLeadServiceTest {

    private static void setBenignMock() {
        Map<String, String> blank = new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '', 'sent_datetime' => ''
        };
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(blank, false)));
    }

    // ── createLeadAndEnqueue ─────────────────────────────────────────────────

    @isTest
    static void createLeadAndEnqueue_fromNameWithSpace_splitsFirstAndLastName() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Jane Broker', 'jane@brokerfirm.example.invalid', 'FW: 100 Main St',
            'Plain body text', '<p>Html body</p>', null, null
        );
        Test.stopTest();

        Lead created = [
            SELECT FirstName, LastName, Email, Email_Subject__c, Company, LeadSource, Status, Description
            FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be the first token of fromName');
        Assert.areEqual('Broker', created.LastName, 'LastName should be the second token of fromName');
        Assert.areEqual('jane@brokerfirm.example.invalid', created.Email, 'Email should be the envelope fromAddress');
        Assert.areEqual('FW: 100 Main St', created.Email_Subject__c, 'Email_Subject__c should be the inbound subject');
        Assert.areEqual('Unknown - Via Email', created.Company, 'Company should be the required placeholder');
        Assert.areEqual('Email-to-Lead', created.LeadSource, 'LeadSource should be stamped');
        Assert.areEqual('New', created.Status, 'Status should be New');
        Assert.areEqual('Plain body text', created.Description, 'Description should prefer the plain-text body');
    }

    @isTest
    static void createLeadAndEnqueue_singleWordFromName_setsLastNameOnly() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Broker', 'broker@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A spaceless fromName should not populate FirstName');
        Assert.areEqual('Broker', created.LastName, 'A spaceless fromName should become the whole LastName');
    }

    @isTest
    static void createLeadAndEnqueue_nullFromName_defaultsLastNameToUnknown() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            null, 'anon@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A null fromName should leave FirstName unset');
        Assert.areEqual('Unknown', created.LastName, 'A null fromName should fall back to the required LastName default');
    }

    @isTest
    static void createLeadAndEnqueue_noPlainTextBody_usesHtmlBodyForDescription() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Jane Broker', 'jane@example.invalid', 'FW: subject', null, '<p>Html only body</p>', null, null
        );
        Test.stopTest();

        Lead created = [SELECT Description FROM Lead WHERE Id = :leadId];
        Assert.areEqual('<p>Html only body</p>', created.Description, 'Description should fall back to the HTML body when there is no plain text');
    }

    // ── applyName edge cases (W3) — via createLeadAndEnqueue(fromName) ───────
    // W3 hardened applyName to trim() + split('\\s+') + guard size + join the tail,
    // so a trailing/double space no longer throws an index-out-of-bounds or blanks
    // the required LastName, and a 3+ token name no longer drops everything past
    // the second token.

    @isTest
    static void createLeadAndEnqueue_fromNameTrailingSpace_collapsesToSingleTokenLastName() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Jane ', 'jane.trailing@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A trailing-space name that trims to one token should not populate FirstName');
        Assert.areEqual('Jane', created.LastName,
            'W3: a trailing space must trim + collapse to a single token (LastName="Jane"), not throw an index-out-of-bounds');
    }

    @isTest
    static void createLeadAndEnqueue_fromNameDoubleSpace_splitsFirstAndLastNameNotBlank() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Jane  Broker', 'jane.double@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be the first token even across a run of whitespace');
        Assert.areEqual('Broker', created.LastName,
            'W3: a double space must collapse via \\s+ splitting, so LastName is "Broker", not blank');
    }

    @isTest
    static void createLeadAndEnqueue_fromNameThreeTokens_joinsTailIntoLastName() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            'Mary Jane Watson', 'mary.three@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Mary', created.FirstName, 'FirstName should be only the first token');
        Assert.areEqual('Jane Watson', created.LastName,
            'W3: a 3-token name must join the remaining tokens into LastName ("Jane Watson"), never dropping the tail');
    }

    @isTest
    static void createLeadAndEnqueue_whitespaceOnlyFromName_defaultsLastNameToUnknown() {
        setBenignMock();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadAndEnqueue(
            '   ', 'blank.name@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Lead created = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.FirstName, 'A whitespace-only fromName should leave FirstName unset');
        Assert.areEqual('Unknown', created.LastName,
            'A whitespace-only (non-null) fromName should still fall back to the required LastName default');
    }

    @isTest
    static void createLeadAndEnqueue_enqueuesExtractAddressQueueable() {
        setBenignMock();

        Test.startTest();
        EmailToLeadService.createLeadAndEnqueue(
            'Jane Broker', 'jane@example.invalid', 'FW: subject', 'body', null, null, null
        );
        Test.stopTest();

        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ExtractAddressQueueable'
        ];
        Assert.areEqual(1, jobCount, 'createLeadAndEnqueue should enqueue exactly one ExtractAddressQueueable job');
    }

    // ── applyExtractedDetails ────────────────────────────────────────────────

    private static Id insertBareLead() {
        Lead l = TestDataFactory.createLead(false);
        l.LastName = 'Placeholder';
        l.FirstName = 'Original';
        l.Email = 'original@example.invalid';
        insert l;
        return l.Id;
    }

    @isTest
    static void applyExtractedDetails_brokerNameWithSpace_splitsFirstAndLastName() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Real Broker' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Real', updated.FirstName, 'FirstName should be updated from the extracted broker name');
        Assert.areEqual('Broker', updated.LastName, 'LastName should be updated from the extracted broker name');
    }

    @isTest
    static void applyExtractedDetails_singleWordBrokerName_setsLastNameOnlyLeavesFirstNameUnchanged() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Solo' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Solo', updated.LastName, 'A spaceless broker name should become LastName');
        Assert.areEqual('Original', updated.FirstName, 'A spaceless broker name update must not clear the existing FirstName');
    }

    // ── applyName edge cases (W3) — via applyExtractedDetails(broker_name) ───
    // Same hardened split contract exercised through the second entry point. Note:
    // the blank/whitespace-only case is NOT retested here — applyExtractedDetails
    // only calls applyName when String.isNotBlank(brokerName), so that branch of
    // applyName is unreachable from this entry point (covered above via
    // createLeadAndEnqueue, whose null-name branch calls applyName unconditionally
    // on any non-null string).

    @isTest
    static void applyExtractedDetails_brokerNameTrailingSpace_collapsesToSingleTokenLastName() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Jane ' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Jane', updated.LastName,
            'W3: a trailing space must trim + collapse to a single token (LastName="Jane"), not throw an index-out-of-bounds');
    }

    @isTest
    static void applyExtractedDetails_brokerNameDoubleSpace_splitsFirstAndLastNameNotBlank() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Jane  Broker' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Jane', updated.FirstName, 'FirstName should be the first token even across a run of whitespace');
        Assert.areEqual('Broker', updated.LastName,
            'W3: a double space must collapse via \\s+ splitting, so LastName is "Broker", not blank');
    }

    @isTest
    static void applyExtractedDetails_brokerNameThreeTokens_joinsTailIntoLastName() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Mary Jane Watson' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Mary', updated.FirstName, 'FirstName should be only the first token');
        Assert.areEqual('Jane Watson', updated.LastName,
            'W3: a 3-token name must join the remaining tokens into LastName ("Jane Watson"), never dropping the tail');
    }

    @isTest
    static void applyExtractedDetails_allFieldsPresent_appliesEachOne() {
        Id leadId = insertBareLead();
        Map<String, String> extracted = new Map<String, String>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Main St, Houston, TX'
        };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, 'forwarder@example.invalid');
        Test.stopTest();

        Lead updated = [
            SELECT FirstName, LastName, Email, Property_Address__c, Forwarded_By_Email__c FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('Jane', updated.FirstName, 'FirstName should be applied');
        Assert.areEqual('Broker', updated.LastName, 'LastName should be applied');
        Assert.areEqual('jane@brokerfirm.example.invalid', updated.Email, 'Email should be applied from broker_email');
        Assert.areEqual('100 Main St, Houston, TX', updated.Property_Address__c, 'Property_Address__c should be applied');
        Assert.areEqual('forwarder@example.invalid', updated.Forwarded_By_Email__c, 'Forwarded_By_Email__c should be applied');
    }

    @isTest
    static void applyExtractedDetails_partialExtraction_doesNotBlankExistingValues() {
        Id leadId = insertBareLead();
        // broker_email intentionally absent from the map.
        Map<String, String> extracted = new Map<String, String>{ 'broker_name' => 'Jane Broker' };

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, extracted, null);
        Test.stopTest();

        Lead updated = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('original@example.invalid', updated.Email,
            'A missing broker_email must never blank out an already-correct Email value');
    }

    @isTest
    static void applyExtractedDetails_nullExtractedMap_doesNotThrow() {
        Id leadId = insertBareLead();

        Test.startTest();
        EmailToLeadService.applyExtractedDetails(leadId, null, null);
        Test.stopTest();

        Lead updated = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Original', updated.FirstName, 'A null extracted map should null-coalesce to empty; no fields change');
        Assert.areEqual('original@example.invalid', updated.Email, 'A null extracted map must not blank the Email');
    }
}
