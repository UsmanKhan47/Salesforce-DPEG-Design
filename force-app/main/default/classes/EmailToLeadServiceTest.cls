/**
 * Test class for EmailToLeadService — the Lead DML layer of the Broker-Protection
 * inbound-email intake pipeline (Phase 3 rewrite, staging model).
 *
 * PHASE 2 SIGNATURE CHANGE THIS REWRITE TRACKS: the old two-call shape
 * (createLeadAndEnqueue inserts a bare Lead from the envelope, then a later
 * applyExtractedDetails update fills in the LLM's answers) collapsed into ONE
 * method, createLeadFromExtracted(...), which builds and inserts a COMPLETE Lead in a single
 * DML statement once extraction has already happened, and returns its Id. There is
 * no enqueue call in this class any more — EmailToLeadHandler owns that — so this
 * class covers createLeadFromExtracted (and its private applyName helper, exercised
 * through that one public entry point), plus deleteLead (added 2026-07-31 for the
 * lost-race path — see the class header).
 *
 * DELETELEAD DIRECT COVERAGE (added 2026-07-31): deleteLead was previously exercised
 * only indirectly, through ExtractAddressQueueableTest's forceClaimRace scenario
 * (an integration-level test of the whole routing tree). The tests below isolate the
 * method itself: it removes exactly the targeted Lead and leaves others untouched,
 * and a null id is a no-op rather than a NullPointerException.
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

    /**
     * Adapter for the pre-2026-07-31 positional call shape.
     *
     * `createLeadFromExtracted` now takes a `LeadRequest` DTO instead of a map plus five strings
     * (design §1.7 — the enrichment would otherwise have produced a ~25-parameter signature). The
     * NAME/EMAIL/COMPANY precedence, whitespace handling and field-length behaviour these tests
     * assert are unchanged, so the assertions below are kept verbatim and only the marshalling
     * moved here. That is deliberate: rewriting the assertions at the same time as the signature
     * would have destroyed the evidence that the behaviour did not change.
     *
     * @param extracted        Legacy four-key map; null is tolerated exactly as before.
     * @param fromName         Envelope display name.
     * @param fromAddress      Envelope From address.
     * @param emailSubject     Inbound subject.
     * @param rawBody          Raw email body.
     * @param forwardedByEmail Monitored inbox that forwarded the email.
     * @return The Id of the inserted Lead.
     */
    private static Id createLeadFrom(Map<String, String> extracted, String fromName, String fromAddress,
                                     String emailSubject, String rawBody, String forwardedByEmail) {
        Map<String, String> fields = (extracted == null) ? new Map<String, String>() : extracted;
        EmailToLeadService.LeadRequest request = new EmailToLeadService.LeadRequest();
        request.brokerName = fields.get('broker_name');
        request.brokerEmail = fields.get('broker_email');
        request.propertyAddress = fields.get('property_address');
        request.fromName = fromName;
        request.fromAddress = fromAddress;
        request.emailSubject = emailSubject;
        request.rawBody = rawBody;
        request.forwardedByEmail = forwardedByEmail;
        return EmailToLeadService.createLeadFromExtracted(request);
    }

    /** A request carrying only the enrichment fields under test, with the required minimum. */
    private static EmailToLeadService.LeadRequest enrichedRequest() {
        EmailToLeadService.LeadRequest request = new EmailToLeadService.LeadRequest();
        request.brokerName = 'Jane Broker';
        request.brokerEmail = 'jane@brokerfirm.example.invalid';
        request.fromAddress = 'jane@brokerfirm.example.invalid';
        request.emailSubject = 'FW: enrichment';
        request.rawBody = 'body';
        return request;
    }

    // ── name splitting (applyName, via broker_name / fromName precedence) ───────

    @isTest
    static void createLeadFromExtracted_singleTokenBrokerName_setsLastNameOnly() {
        Test.startTest();
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
            extractedWith('Jane Broker', 'llm.broker@example.invalid', null),
            'Jane Broker', 'envelope.from@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Email FROM Lead WHERE Id = :leadId];
        Assert.areEqual('llm.broker@example.invalid', created.Email, 'The LLM broker_email should win over the envelope From address');
    }

    @isTest
    static void createLeadFromExtracted_blankBrokerEmail_fallsBackToFromAddress() {
        Test.startTest();
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
            extractedWith('Jane Broker', 'jane@example.invalid', '100 Main St, Houston, TX'),
            null, 'jane@example.invalid', 'FW: subject', 'body', null);
        Test.stopTest();

        Lead created = [SELECT Property_Address__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('100 Main St, Houston, TX', created.Property_Address__c, 'Property_Address__c should be stamped from the extraction');
    }

    @isTest
    static void createLeadFromExtracted_blankPropertyAddress_leavesPropertyAddressBlank() {
        Test.startTest();
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
            extractedWith('Jane Broker', 'jane@example.invalid', null),
            null, 'jane@example.invalid', 'FW: subject', 'body', 'forwarder@example.invalid');
        Test.stopTest();

        Lead created = [SELECT Forwarded_By_Email__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('forwarder@example.invalid', created.Forwarded_By_Email__c, 'Forwarded_By_Email__c should be stamped from forwardedByEmail');
    }

    @isTest
    static void createLeadFromExtracted_blankForwardedBy_leavesForwardedByBlank() {
        Test.startTest();
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
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
        Id leadId = createLeadFrom(
            extractedWith('Jane Broker', 'jane@example.invalid', null),
            null, 'jane@example.invalid', longSubject, longBody, null);
        Test.stopTest();

        Lead created = [SELECT Email_Subject__c, Description FROM Lead WHERE Id = :leadId];
        Assert.areEqual(255, created.Email_Subject__c.length(), 'An over-long subject should be clipped to 255 characters, not throw STRING_TOO_LONG');
        Assert.areEqual(32000, created.Description.length(), 'An over-long body should be clipped to 32000 characters, not throw STRING_TOO_LONG');
    }

    // ── enrichment: the deal-screening block (2026-07-31) ────────────────────

    @isTest
    static void createLeadFromExtracted_typedPropertyValues_areStampedVerbatim() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        PropertyExtraction property = new PropertyExtraction();
        property.propertyName = 'Royal Inn';
        property.assetType = 'Retail';
        property.dealType = 'Retail';
        property.guidancePrice = 7100000;
        property.capRate = 6.75;
        property.noi = 479250;
        property.occupancyPct = 88.00;
        property.buildingSf = 128500;
        property.unitCount = 96;
        property.yearBuilt = 1988;
        property.yearRenovated = 2022;
        property.lotSizeAcres = 3.25;
        property.waltYears = 7.3;
        property.zoning = 'C-2';
        property.sellerEntity = 'Royal Holdings LP';
        property.dealRoomLink = 'https://deals.example.invalid/royal';
        property.offerDueDate = Date.today().addDays(14);
        request.property = property;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [
            SELECT Property_Name__c, Asset_Type__c, Deal_Type__c, Guidance_Price__c, Guidance_Cap_Rate__c,
                   NOI__c, Occupancy_Pct__c, Building_SF__c, Unit_Count__c, Year_Built__c, Year_Renovated__c,
                   Lot_Size_Acres__c, WALT_Years__c, Zoning__c, Seller_Entity__c, Deal_Room_Link__c,
                   Offer_Due_Date__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('Royal Inn', created.Property_Name__c, 'Property_Name__c should be stamped');
        Assert.areEqual('Retail', created.Asset_Type__c, 'A parser-validated picklist value should be written as-is');
        Assert.areEqual(7100000, created.Guidance_Price__c, 'Guidance_Price__c should be stamped');
        Assert.areEqual(6.75, created.Guidance_Cap_Rate__c, 'Guidance_Cap_Rate__c should be stamped');
        Assert.areEqual(88.00, created.Occupancy_Pct__c,
            'Occupancy 88.00 must survive — this also fails loudly if Occupancy_Pct__c ships as Percent(3,2), which caps at 9.99');
        Assert.areEqual(1988, created.Year_Built__c, 'Year_Built__c should be stamped');
        Assert.areEqual(3.25, created.Lot_Size_Acres__c, 'Lot_Size_Acres__c should be stamped');
        Assert.areEqual('https://deals.example.invalid/royal', created.Deal_Room_Link__c, 'Deal_Room_Link__c should be stamped');
        Assert.areEqual(Date.today().addDays(14), created.Offer_Due_Date__c, 'Offer_Due_Date__c should be stamped');
    }

    @isTest
    static void createLeadFromExtracted_brokerCompanyPresent_replacesThePlaceholder() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerCompany = 'Brokerfirm LLC';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.areEqual('Brokerfirm LLC', [SELECT Company FROM Lead WHERE Id = :leadId].Company,
            'An extracted broker_company should replace the placeholder Company');
    }

    @isTest
    static void createLeadFromExtracted_brokerCompanyBlank_keepsThePlaceholder() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Assert.areEqual('Unknown - Via Email', [SELECT Company FROM Lead WHERE Id = :leadId].Company,
            'Company is REQUIRED, so a blank broker_company must fall back to the placeholder and never write blank');
    }

    @isTest
    static void createLeadFromExtracted_brokerContactBlock_isStamped() {
        // ⚠ This test deliberately does NOT query Lead.MobilePhone. That field does not exist in
        // this org (newer org template retired it; the repo's field-meta snapshot is stale, same
        // as Task.Type) — selecting it would fail the query, and STAMPING it failed every Lead
        // insert in the pipeline until 2026-07-31. See EmailToLeadService.applyBrokerBlock.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerPhone = '214-555-0100';
        request.brokerMobile = '214-555-0199';
        request.brokerTitle = 'Managing Director';
        request.listingBrokerName = 'Alex Lister';
        request.listingBrokerEmail = 'alex@listingco.example.invalid';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [
            SELECT Phone, Title, Listing_Broker_Name__c, Listing_Broker_Email__c, Email, Deal_Notes__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('214-555-0100', created.Phone,
            'With both numbers extracted, the OFFICE line wins Phone');
        Assert.areEqual('Managing Director', created.Title, 'Title should be stamped from broker_title');
        Assert.areEqual('Alex Lister', created.Listing_Broker_Name__c, 'Listing_Broker_Name__c should be stamped');
        Assert.areEqual('alex@listingco.example.invalid', created.Listing_Broker_Email__c,
            'The LISTING broker is a separate field and must never overwrite the claim-engine broker');
        Assert.areEqual('jane@brokerfirm.example.invalid', created.Email,
            'Lead.Email must still be the SENDING broker — repointing it at the listing broker would re-attribute every claim');
        Assert.isTrue(created.Deal_Notes__c.contains('Mobile: 214-555-0199'),
            'The mobile must not be silently dropped just because Lead.MobilePhone does not exist — it lands on Deal_Notes__c where the person working the Lead will see it');
    }

    @isTest
    static void createLeadFromExtracted_cellOnlyBroker_putsTheMobileInPhone() {
        // A broker signature with only a cell number is common. Before the MobilePhone removal
        // that number went to a field that does not exist; now it must reach Phone, or the Lead
        // would carry NO reachable number at all.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerMobile = '214-555-0199';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT Phone, Deal_Notes__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('214-555-0199', created.Phone,
            'With no office line, the mobile must fall through to Phone so the broker stays reachable');
        Assert.isTrue(created.Deal_Notes__c == null || !created.Deal_Notes__c.contains('Mobile:'),
            'When the mobile IS the Phone there is nothing to duplicate onto Deal_Notes__c');
    }

    @isTest
    static void createLeadFromExtracted_noPhoneNumbersAtAll_leavesPhoneNull() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Assert.isNull([SELECT Phone FROM Lead WHERE Id = :leadId].Phone,
            'No extracted number must leave Phone null rather than writing an empty string');
    }

    @isTest
    static void createLeadFromExtracted_extractionNotes_landOnDealNotes() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.dealSummary = 'Roof replaced 2021. Reported NOI 500k, adjusted 479k.';
        request.extractionNotes = new List<String>{ 'cap_rate "six point five" was ignored: not a number.' };

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        String notes = [SELECT Deal_Notes__c FROM Lead WHERE Id = :leadId].Deal_Notes__c;
        Assert.isTrue(notes.contains('Roof replaced 2021'), 'The narrative should lead Deal_Notes__c');
        Assert.isTrue(notes.contains('-- Extraction notes --'),
            'Rejected values must be filed under a header so a reader can tell "the model said nothing" from "we refused to store it"');
        Assert.isTrue(notes.contains('cap_rate'), 'The rejection reason itself must reach the record');
    }

    @isTest
    static void createLeadFromExtracted_spilloverNote_landsOnDealNotes() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.spilloverNote = 'Additional properties in this email (not routed):\n- Bass Inn (no usable address)';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.isTrue([SELECT Deal_Notes__c FROM Lead WHERE Id = :leadId].Deal_Notes__c.contains('Bass Inn'),
            'A property the pipeline could not route must still be visible to the human working the deal (C-1)');
    }

    @isTest
    static void createLeadFromExtracted_parseConfidence_isStampedForTheReviewQueue() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.parseConfidence = LLMExtractionParser.BAND_LOW;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.areEqual('LOW', [SELECT Parse_Confidence__c FROM Lead WHERE Id = :leadId].Parse_Confidence__c,
            'The soft gate is expressed as Parse_Confidence__c = LOW, which is what feeds the existing Review_Queue list view');
    }

    // ── per-field confidence (WS7, 2026-08-30) ──────────────────────────────
    //
    // ⚠ ASSERTIONS ARE ON THE PARSED MAP, NEVER ON THE STORED STRING BYTE-FOR-BYTE.
    // Field_Confidence_JSON__c is a LongTextArea, and this org strips trailing whitespace from
    // long text on save — so a test that compared a composed JSON literal against the round-tripped
    // value would be asserting a platform behaviour rather than this class's. Deserializing and
    // asserting the MAP is what the consumer actually cares about anyway.
    //
    // 🔴 AND EVERY ONE OF THESE TESTS BRANCHES ON FLS, WHICH IS NOT HEDGING — IT IS THE FEATURE.
    // MEASURED 2026-08-30 (check-only 0Afiw000000TjplCAC): with these two fields deployed and no
    // FieldPermissions row anywhere, an UNGUARDED write made `insert lead` throw and 42 of this
    // class's 45 methods fail. applyFieldConfidence therefore skips a field the running principal
    // cannot write, so the Lead and the broker's claim survive a provisioning gap. A test that
    // asserted the stamp unconditionally would fail on exactly the org state this guard exists to
    // survive — and, worse, would push the next reader toward deleting the guard to make it green.
    // Each test below asserts the RIGHT thing on both sides of that branch, and the NOT-writable
    // side is the more important assertion: THE INSERT STILL SUCCEEDED.

    /** True when the running principal may write Field_Confidence_JSON__c — see the block above. */
    private static Boolean jsonWritable() {
        return Schema.SObjectType.Lead.fields.Field_Confidence_JSON__c.isCreateable();
    }

    /** True when the running principal may write Low_Confidence_Field_Count__c. */
    private static Boolean countWritable() {
        return Schema.SObjectType.Lead.fields.Low_Confidence_Field_Count__c.isCreateable();
    }

    /**
     * The stored JSON, or null when the running principal cannot READ the field.
     *
     * ⚠ THE SELECT LIVES BEHIND THE GUARD, AND IT HAS TO. Measured 2026-08-30 (check-only
     * 0Afiw000000TjwDCAS): with no FieldPermissions row, a plain
     * `SELECT Field_Confidence_JSON__c FROM Lead` throws
     * `System.QueryException: No such column 'Field_Confidence_JSON__c' on entity 'Lead'` — an FLS
     * denial wearing a schema error, exactly as ARCHITECTURE.md §2 describes. A test that ran the
     * query unconditionally would fail on the org state the production guard exists to survive,
     * and would send the next reader hunting for a missing field that is right there.
     *
     * @param leadId The Lead to read.
     * @return The stored value, or null when unreadable.
     */
    private static String storedFieldConfidence(Id leadId) {
        if (!Schema.SObjectType.Lead.fields.Field_Confidence_JSON__c.isAccessible()) {
            return null;
        }
        return [SELECT Field_Confidence_JSON__c FROM Lead WHERE Id = :leadId].Field_Confidence_JSON__c;
    }

    /** The stored count, or null when the running principal cannot READ the field. */
    private static Decimal storedLowConfidenceCount(Id leadId) {
        if (!Schema.SObjectType.Lead.fields.Low_Confidence_Field_Count__c.isAccessible()) {
            return null;
        }
        return [SELECT Low_Confidence_Field_Count__c FROM Lead WHERE Id = :leadId].Low_Confidence_Field_Count__c;
    }

    @isTest
    static void createLeadFromExtracted_fieldConfidence_isStampedAsJsonInTheSameInsert() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.fieldConfidence = new Map<String, Decimal>{ 'noi' => 0.92, 'year_built' => 0.40 };
        request.lowConfidenceFieldCount = 1;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.isNotNull(leadId,
            '🔴 THE ASSERTION THAT HOLDS EITHER WAY: the Lead exists. A field the principal cannot '
            + 'write must cost the review signal and NOTHING ELSE — never the Lead, never the claim');
        String storedJson = storedFieldConfidence(leadId);
        if (jsonWritable()) {
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(storedJson);
            Assert.areEqual(2, stored.size(), 'Both scores must survive the round trip');
            Assert.areEqual(0.92, Decimal.valueOf(String.valueOf(stored.get('noi'))),
                'and the value must be readable as a number, not as prose');
        } else {
            Assert.isNull(storedJson,
                'Not writable, so the guard skipped it — and skipping means leaving it blank, never '
                + 'half-writing it. Grant Field_Confidence_JSON__c on DPEG_Acquisition_Edit to turn '
                + 'the feature on; nothing else about this Lead changes');
        }
        if (countWritable()) {
            Assert.areEqual(1, storedLowConfidenceCount(leadId),
                'The count is the FILTERABLE half — a LongTextArea cannot appear in a list-view '
                + 'filter at all, which is the entire reason this second field exists');
        } else {
            Assert.isNull(storedLowConfidenceCount(leadId), 'Not writable, so blank');
        }
        Assert.isNull([SELECT Parse_Confidence__c FROM Lead WHERE Id = :leadId].Parse_Confidence__c,
            '🔴 AND THE WHOLE-EMAIL BAND IS UNTOUCHED BY IT, WRITABLE OR NOT. Parse_Confidence__c is '
            + 'set only from request.parseConfidence, which this request never populated. WS7 must '
            + 'not have acquired a second writer for the field driving the >= 0.85 suppression gate');
    }

    @isTest
    static void createLeadFromExtracted_emptyFieldConfidence_leavesTheJsonBlank() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.fieldConfidence = new Map<String, Decimal>();
        request.lowConfidenceFieldCount = 0;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.isNull(storedFieldConfidence(leadId),
            'An empty map writes NOTHING, not the literal "{}", and this holds whether or not the '
            + 'field is writable. A blank field reads as "no per-field signal"; "{}" reads as data '
            + 'that says nothing and would show up as content in every report and detail page');
        if (countWritable()) {
            Assert.areEqual(0, storedLowConfidenceCount(leadId),
                'while the count is still written as 0, which correctly keeps this Lead out of the '
                + 'per-field review queue (> 0) rather than leaving an unexplained blank');
        }
    }

    @isTest
    static void createLeadFromExtracted_nullFieldConfidence_doesNotThrowAndLeavesBothBlank() {
        // The LLM-down and legacy-shape paths, and every caller written before WS7 — including
        // BrokerPortalService, which does not use these members at all.
        EmailToLeadService.LeadRequest request = enrichedRequest();

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.isNotNull(leadId, 'A null map must not throw');
        Assert.isNull(storedFieldConfidence(leadId), 'and must write nothing');
        Assert.isNull(storedLowConfidenceCount(leadId),
            'and a null count leaves the field blank — additive and nullable, so every pre-WS7 caller '
            + 'behaves byte-identically');
    }

    @isTest
    static void createLeadFromExtracted_fieldConfidence_addsNoDmlAndNoSoql() {
        // 🔴 THE BRIEF'S HARD CONSTRAINT, ASSERTED RATHER THAN COMMENTED: zero new DML, zero new
        // SOQL. Both fields land in the SAME insert as everything else on this Lead.
        //
        // ⚠ THE REQUEST IS BUILT BEFORE THE COUNTERS ARE READ, deliberately. A governor assertion
        // that brackets its own fixture setup measures the fixture, not the method — the counters
        // are captured immediately either side of the one call under test and nothing else.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.fieldConfidence = new Map<String, Decimal>{ 'noi' => 0.92, 'year_built' => 0.40 };
        request.lowConfidenceFieldCount = 1;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer soqlBefore = Limits.getQueries();
        EmailToLeadService.createLeadFromExtracted(request);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer soqlUsed = Limits.getQueries() - soqlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed,
            'EXACTLY ONE DML STATEMENT — the Lead insert. If this is 2, someone has added an update '
            + 'to carry the confidence pair, which at N properties per email becomes N extra '
            + 'statements against ExtractAddressQueueable\'s pinned 45-statement budget');
        Assert.areEqual(0, soqlUsed,
            'and NO query. Serializing a map the caller already holds needs no read; a describe or a '
            + 'config re-read here would cost one per property');
    }

    // ── property package (2026-08-17, Decision C1) ──────────────────────────

    /**
     * `propertyPackageId` is an ADDITIVE, nullable field on `LeadRequest` (design §developer prompt
     * item 4): stamped onto the Lead AT INSERT so no Lead is ever re-updated to acquire its package.
     * `ExtractAddressQueueableTest`'s multi-property section exercises this line too, end to end
     * through the real routing tree — this is the DIRECT, isolated counterpart, matching the pattern
     * every other `LeadRequest` field on this class already has its own test for.
     */
    @isTest
    static void createLeadFromExtracted_propertyPackageId_isStampedOntoTheLeadAtInsert() {
        Portfolio_Deal__c pkg = new Portfolio_Deal__c(Name = 'FW: direct stamp check', Property_Count__c = 2);
        insert pkg;
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.propertyPackageId = pkg.Id;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Assert.areEqual(pkg.Id, [SELECT Portfolio_Deal__c FROM Lead WHERE Id = :leadId].Portfolio_Deal__c,
            'propertyPackageId must land on Portfolio_Deal__c in the SAME insert as every other field '
            + 'on this Lead — no second DML statement exists to carry it');
    }

    @isTest
    static void createLeadFromExtracted_noPropertyPackageId_leavesTheLookupBlank() {
        // The overwhelmingly common case: a single-property email never sets propertyPackageId, and
        // every pre-existing LeadRequest fixture in this file (via enrichedRequest()) leaves it at its
        // Apex default of null. This is the discriminator that proves the test above is asserting the
        // ASSIGNMENT and not a default that is always populated regardless of the request.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Assert.isNull([SELECT Portfolio_Deal__c FROM Lead WHERE Id = :leadId].Portfolio_Deal__c,
            'An ordinary request with no package must leave the Lead\'s Portfolio_Deal__c blank');
    }

    @isTest
    static void createLeadFromExtracted_nullProperty_leavesTheScreeningFieldsBlank() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Lead created = [SELECT Property_Name__c, NOI__c, Asset_Type__c FROM Lead WHERE Id = :leadId];
        Assert.isNull(created.Property_Name__c, 'A no-property Lead (branch c) must leave the screening block unset');
        Assert.isNull(created.NOI__c, 'A no-property Lead must not invent financials');
        Assert.isNull(created.Asset_Type__c, 'A no-property Lead must not invent a classification');
    }

    // ── record-type stamp (IR/Acquisitions segregation, Task 4) ─────────────

    @isTest
    static void createLeadFromExtracted_carriesTheAcquisitionRecordType() {
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Lead readBack = [SELECT RecordType.DeveloperName FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Acquisition_Broker', readBack.RecordType.DeveloperName,
            'An inbound broker Lead without this record type matches no sharing rule once Lead OWD '
            + 'is Private, so the acquisitions team never sees it.');
    }

    // ── listing status + extraction score (observation 1, 2026-08-14) ────────
    //
    // Both land in the SAME insert that already creates the Lead — no extra DML, no extra SOQL.
    // Every test below therefore reads the Lead back ONCE after a single createLeadFromExtracted
    // call; if either addition had needed a second statement, the existing budget assertions in
    // ExtractAddressQueueableTest would fail rather than these.

    /**
     * A request whose block captures a KNOWN 7 of the 9 signed-off keys, so the numbers asserted
     * below are derived from the fixture rather than copied from a passing run.
     *
     * Captured (7): property_name, property_address, offer_due_date, sale_process,
     *               listing_status, listing_broker_name, listing_broker_email.
     * Missing  (2): guidance_price, guidance_cap_rate — deliberately left out so the test can
     *               tell a real fraction from a hardcoded 100%.
     *
     * ⚠ `request.propertyAddress` IS SET AS WELL AS `property.propertyAddress`, and it is the one
     * that counts (code review C2, 2026-08-14). The score reads the RESOLVED address — the value
     * createLeadFromExtracted actually stamps onto Lead.Property_Address__c — because
     * ExtractAddressQueueable.claimableAddress nulls a raw address that does not normalize. Here
     * the two agree, which is the ordinary winner-branch shape; the case where they DISAGREE is
     * addressLessRequest() below.
     */
    private static EmailToLeadService.LeadRequest sevenOfNineRequest() {
        EmailToLeadService.LeadRequest request = enrichedRequest();
        PropertyExtraction property = new PropertyExtraction();
        property.propertyName = 'Orion ParkView';
        property.propertyAddress = '1400 Royal Lane, Dallas TX';
        property.offerDueDate = Date.today().addDays(21);
        property.saleProcess = 'Call for Offers';
        property.listingStatus = 'Off Market';
        request.property = property;
        request.propertyAddress = property.propertyAddress;   // what claimableAddress would return
        request.listingBrokerName = 'Dana Listing';
        request.listingBrokerEmail = 'dana@listingfirm.example.invalid';
        return request;
    }

    /**
     * The OUTCOME_NO_ADDRESS shape: the same seven-of-nine block, except the model's address is a
     * value that is non-blank but normalizes to empty, so ExtractAddressQueueable.claimableAddress
     * resolved it to NULL and this Lead will carry a blank Property_Address__c.
     *
     * Routing branch (c) — the population the score exists to queue up for chasing.
     */
    private static EmailToLeadService.LeadRequest addressLessRequest() {
        EmailToLeadService.LeadRequest request = sevenOfNineRequest();
        request.property.propertyAddress = '###';   // non-blank raw, empty normalized
        request.propertyAddress = null;             // claimableAddress' answer
        return request;
    }

    @isTest
    static void createLeadFromExtracted_listingStatus_isStampedVerbatim() {
        // The ninth extraction key. Written raw for the same reason Sale_Process__c is: the value
        // arrives PRE-VALIDATED from LLMExtractionParser against this very field's active values,
        // so a second rule set here is how the two would drift apart.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        PropertyExtraction property = new PropertyExtraction();
        property.listingStatus = 'Off Market';
        request.property = property;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT Listing_Status__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Off Market', created.Listing_Status__c,
            'A parser-validated Listing_Status__c value must be written as-is');
    }

    @isTest
    static void createLeadFromExtracted_extractionScore_isStampedFromTheStampedPropertyBlock() {
        // 🔴 THE SCORE MEASURES THE BLOCK THIS LEAD IS BEING STAMPED WITH, NOT THE EMAIL. One
        // email can pitch up to ten properties and each gets its own Lead, so a score computed
        // email-wide would describe a record it does not sit on. Asserting 7 / 2 / 78 — rather
        // than "not null" — is what makes that visible: the fixture supplies exactly seven of
        // the nine, and 7/9 is 77.77%, which rounds to 78. A truncating implementation would
        // give 0 here and a hardcoded one would give 100.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(sevenOfNineRequest());
        Test.stopTest();

        Lead created = [
            SELECT Extraction_Score_Pct__c, Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual(7, created.Fields_Captured_Count__c,
            'Seven of the nine signed-off keys were supplied by this fixture');
        Assert.areEqual(2, created.Fields_Missing_Count__c,
            'guidance_price and guidance_cap_rate were deliberately withheld');
        Assert.areEqual(78, created.Extraction_Score_Pct__c,
            '7/9 is 77.77%, which rounds to 78 — not 0 (integer truncation) and not 100');
        Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
            created.Fields_Captured_Count__c + created.Fields_Missing_Count__c,
            'captured + missing must recover the denominator FROM THE RECORD — that is what '
            + 'makes a future change to the nine keys auditable instead of a silent re-basing');
    }

    @isTest
    static void createLeadFromExtracted_rawAddressThatDoesNotNormalize_scoresTheAddressAsMissing() {
        // 🔴 CODE REVIEW C2 (2026-08-14), PINNED FROM THE STORED RECORD RATHER THAN FROM THE
        // SCORER. This is the OUTCOME_NO_ADDRESS population — routing branch (c) — and it is the
        // exact population the score exists to queue up, so getting it wrong is worse here than
        // anywhere else.
        //
        // The defect: ExtractionScoreUtil read `property.propertyAddress` (the RAW model value,
        // non-blank) while EmailToLeadService stamps Lead.Property_Address__c from
        // `request.propertyAddress` (already nulled by ExtractAddressQueueable.claimableAddress
        // because '###' normalizes to empty). So the score counted as CAPTURED a field the very
        // same insert left BLANK, and the work queue built to chase a missing address ranked
        // these leads as complete as an addressed one. Reverting the scorer to the DTO read makes
        // this test go red at 7 / 2 / 78 — byte-identical to the ADDRESSED fixture above — while
        // the Property_Address__c assertion below still passes. That contradiction, one record
        // reporting both "address captured" and "address blank", is what this test exists to
        // catch, and it is why the assertion is made against the STORED Lead.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(addressLessRequest());
        Test.stopTest();

        Lead created = [
            SELECT Property_Address__c, Property_Name__c,
                   Extraction_Score_Pct__c, Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.isNull(created.Property_Address__c,
            'PRECONDITION AND THE WHOLE POINT: an address that does not normalize is never '
            + 'stamped, so this Lead genuinely has no address to score as captured');
        Assert.areEqual('Orion ParkView', created.Property_Name__c,
            'The rest of the block is stamped exactly as on the addressed fixture — only the '
            + 'address differs, so the score delta below can have no other cause');
        Assert.areEqual(6, created.Fields_Captured_Count__c,
            'Six of the nine landed. The seventh, property_address, did not — and the score must '
            + 'report what the RECORD carries, not what the model said');
        Assert.areEqual(3, created.Fields_Missing_Count__c,
            'The address is NAMED as missing, which is what makes this lead findable by the '
            + 'queue that exists to chase exactly that');
        Assert.areEqual(ExtractionScoreUtil.DENOMINATOR,
            created.Fields_Captured_Count__c + created.Fields_Missing_Count__c,
            'captured + missing must still recover the denominator FROM THE RECORD on the '
            + 'address-less path');
        Assert.areEqual(67, created.Extraction_Score_Pct__c,
            '6/9 is 66.66%, which rounds to 67 — one whole point below the 78 the addressed '
            + 'fixture scores, and that difference IS the address');
    }

    @isTest
    static void createLeadFromExtracted_nullProperty_leavesTheScoreNullNotZero() {
        // 🔴 NULL AND ZERO ARE DIFFERENT ANSWERS, AND THIS IS THE PATH WHERE IT MATTERS MOST.
        // Routing branch (c) creates a Lead from the envelope alone when extraction degraded
        // (the LLM-down path), so nothing was ever scored. A 0 here would be a CLAIM that the
        // model ran and gave us none of the nine — which would put the most urgent-looking
        // "chase this" signal in the org on the one lead nobody can chase anything about.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Lead created = [
            SELECT Extraction_Score_Pct__c, Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.isNull(created.Extraction_Score_Pct__c,
            'A Lead with no property block was not scored, and not-scored is NULL, never 0');
        Assert.isNull(created.Fields_Captured_Count__c, 'All three read null together');
        Assert.isNull(created.Fields_Missing_Count__c, 'All three read null together');
    }

    @isTest
    static void createLeadFromExtracted_scoringFailure_stillCreatesTheLeadAndNotesTheGap() {
        // 🔴 THE FAIL-SOFT GUARANTEE, FALSIFIED RATHER THAN ASSERTED. Spec §1 constraint 7: the
        // inbound email pipeline must never be made to throw. ExtractionScoreUtil is total by
        // construction, so the only way to reach EmailToLeadService's catch is the seam — and
        // without reaching it, "a scoring defect costs nothing but the score" is a claim no test
        // has ever checked. Remove the try/catch and this test goes red with an uncaught
        // exception, having created no Lead at all: exactly the outage it exists to prevent.
        ExtractionScoreUtil.simulateScoreFailure = true;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(sevenOfNineRequest());
        Test.stopTest();

        Assert.isNotNull(leadId, 'The Lead must still be created — the score is the only casualty');

        Lead created = [
            SELECT Property_Name__c, Listing_Status__c, Deal_Notes__c,
                   Extraction_Score_Pct__c, Fields_Captured_Count__c, Fields_Missing_Count__c
            FROM Lead WHERE Id = :leadId
        ];
        Assert.areEqual('Orion ParkView', created.Property_Name__c,
            'Everything else on the record must be untouched by a scoring failure');
        Assert.areEqual('Off Market', created.Listing_Status__c,
            'The ninth extraction key is stamped independently of whether it can be SCORED');
        Assert.isNull(created.Extraction_Score_Pct__c,
            'A failed score is NULL — never a partial value and never a 0');
        Assert.isNull(created.Fields_Captured_Count__c, 'No half-written state: all three are null');
        Assert.isNull(created.Fields_Missing_Count__c, 'No half-written state: all three are null');
        Assert.isTrue(
            created.Deal_Notes__c != null
                && created.Deal_Notes__c.contains(EmailToLeadService.SCORE_FAILED_NOTE),
            'The omission must be EXPLAINED on the record a human is already working, not left '
            + 'as an unexplained blank — same contract as the parser rejection notes. Actual: '
            + created.Deal_Notes__c);
    }

    // ── deleteLead (lost-race cleanup) ───────────────────────────────────────

    @isTest
    static void deleteLead_existingLead_removesOnlyTheTargetedLead() {
        Lead racer = TestDataFactory.createLead(true);
        Lead untouched = TestDataFactory.createLead(true);

        Test.startTest();
        EmailToLeadService.deleteLead(racer.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Id = :racer.Id],
            'The targeted Lead must be deleted');
        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :untouched.Id],
            'An unrelated Lead must never be touched by deleteLead');
    }

    @isTest
    static void deleteLead_nullId_isANoOpAndDoesNotThrow() {
        Lead untouched = TestDataFactory.createLead(true);

        Test.startTest();
        EmailToLeadService.deleteLead(null);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :untouched.Id],
            'A null leadId must be a no-op — no Lead should be deleted and no exception should propagate');
    }

    @isTest
    static void deleteLead_leadWithSubmissionReference_clearsSourceLeadViaSetNull() {
        // Mirrors the real lost-race shape: a submission was written against this Lead
        // (PropertyClaimService.markDuplicate) BEFORE the caller decided to delete it.
        // The lookup's SetNull delete constraint — not any code in this class — is what
        // clears Source_Lead__c; this test proves deleteLead does not need to (and must
        // not have to) clean that reference up itself.
        Lead racer = TestDataFactory.createLead(true);
        Lead winner = TestDataFactory.createLead(true);
        Competing_Broker_Submission__c sub = TestDataFactory.createCompetingBrokerSubmission(winner.Id, false);
        sub.Source_Lead__c = racer.Id;
        sub.Is_Winning_Submission__c = false;
        insert sub;

        Test.startTest();
        EmailToLeadService.deleteLead(racer.Id);
        Test.stopTest();

        Competing_Broker_Submission__c subAfter = [SELECT Source_Lead__c FROM Competing_Broker_Submission__c WHERE Id = :sub.Id];
        Assert.isNull(subAfter.Source_Lead__c,
            'Deleting the racer\'s Lead should clear Source_Lead__c on its submission via the lookup\'s SetNull delete constraint');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Id = :racer.Id], 'The racer\'s Lead must be gone');
    }

    // ══ WS1 (2026-08-30) — LeadRequest.firstSeenDateTime → Lead.First_Seen_Date__c ══
    //
    // TWO BEHAVIOURS, AND THE SECOND IS THE ONE THAT IS EASY TO BREAK BY ACCIDENT.
    //   1. A supplied value is written AND SURVIVES. The `Lead_Intake_Stamp` flow stamps
    //      First_Seen_Date__c whenever it IsNull — so "the field equals what I passed" is
    //      simultaneously the assertion that the flow left it alone. That is the whole
    //      mechanism, and it is why this test asserts an EXACT value rather than "not null".
    //   2. A null LEAVES THE FLOW IN CHARGE. Every non-email caller passes nothing, and their
    //      behaviour must be byte-identical to before WS1. A "helpful" `Datetime.now()` default
    //      in this class would be invisible in test 1 and would quietly duplicate the flow's job.
    //
    // ⚠ These tests do NOT re-prove the CreatedDate fallback. That belongs to
    // ExtractAddressQueueable, which resolves it once at the staging load precisely so this class
    // has no fallback of its own to test. See ExtractAddressQueueableTest's WS1 section.

    @isTest
    static void createLeadFromExtracted_firstSeenDateTimeSupplied_isStampedAndTheFlowLeavesItAlone() {
        Datetime received = Datetime.newInstanceGmt(2026, 8, 26, 19, 3, 22);
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.firstSeenDateTime = received;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT First_Seen_Date__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual(received, created.First_Seen_Date__c,
            'First_Seen_Date__c must be the supplied arrival time. This assertion is doing double duty: '
            + 'Lead_Intake_Stamp only stamps when the field IsNull, so an EXACT match also proves the '
            + 'flow did not overwrite it with Datetime.now()');
    }

    @isTest
    static void createLeadFromExtracted_nullFirstSeenDateTime_leavesTheFlowToStampIt() {
        // ⚠ A ±5 MINUTE WINDOW, NOT `>= Datetime.now()` CAPTURED JUST BEFORE THE INSERT. MEASURED
        // 2026-08-30: the strict form FAILS. `Lead_Intake_Stamp` assigns `$Flow.CurrentDateTime`,
        // which is the TRANSACTION START time, and Apex's `Datetime.now()` called later in the
        // same method is strictly after it — so the flow's stamp is legitimately a few
        // milliseconds in the "past" relative to the local. The window keeps the assertion
        // meaningful (it still rejects any invented past/future value, which is all it ever
        // claimed to do) without pinning it to an ordering the platform does not guarantee.
        Datetime windowStart = Datetime.now().addMinutes(-5);
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.firstSeenDateTime = null;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT First_Seen_Date__c FROM Lead WHERE Id = :leadId];
        Assert.isNotNull(created.First_Seen_Date__c,
            'With nothing supplied, Lead_Intake_Stamp must still stamp the field — this is the UNCHANGED '
            + 'behaviour every non-email channel (portal, manual entry) depends on, and WS1 must not have '
            + 'disturbed it');
        Assert.isTrue(created.First_Seen_Date__c > windowStart
                && created.First_Seen_Date__c < Datetime.now().addMinutes(5),
            'The stamp must be the CURRENT time, i.e. the intake-time semantics this channel has always '
            + 'had. ⚠ Be honest about what this half proves: a Datetime.now() default hidden inside '
            + 'createLeadFromExtracted would satisfy it too. The test that discriminates between the flow '
            + 'and a hidden Apex default is the SUPPLIED-value one above, which such a default would '
            + 'break by overriding the email channel\'s arrival time');
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // WS8 (2026-08-30) — THE BROKERAGE FIRM NAME, AND THE INTAKE BROKER LINK
    //
    // ⚠ BULK VOLUME: THIS CLASS DELIBERATELY HAS NO 251-RECORD TEST, AND THAT IS RECORDED IN
    // `.claude/rules/bulk-test-rule.md` RATHER THAN DECIDED HERE. `createLeadFromExtracted` is
    // called once per PROPERTY by `ExtractAddressQueueable`, capped at MAX_PROPERTIES = 10, and a
    // literal 251 is not merely pointless here but UNREACHABLE — `System.enqueueJob` caps at 50
    // calls per transaction and 251 properties in one email would exhaust the SOQL limit at
    // roughly 14-24 properties. The rule's replacement obligations (MAX_PROPERTIES-volume,
    // truncation, governor headroom against a NAMED budget, mixed outcomes, ordering) are met in
    // `ExtractAddressQueueableTest`, which is where the loop actually lives. What THIS class owes
    // is the per-call behaviour, below — including a zero-SOQL pin, because the single most likely
    // future regression is someone moving the broker lookup into this per-property method.
    // ══════════════════════════════════════════════════════════════════════════════════════

    /** True when the running principal may write Lead.Broker__c. */
    private static Boolean brokerLinkWritable() {
        return Schema.SObjectType.Lead.fields.Broker__c.isCreateable();
    }

    /** True when the running principal may write Lead.Broker_Firm__c. */
    private static Boolean brokerFirmLinkWritable() {
        return Schema.SObjectType.Lead.fields.Broker_Firm__c.isCreateable();
    }

    /**
     * The stored broker link, or null when the running principal cannot READ the two lookups.
     *
     * ⚠ THE SELECT LIVES BEHIND THE GUARD FOR THE SAME MEASURED REASON `storedFieldConfidence`
     * above does: with no FieldPermissions row a plain `SELECT Broker__c FROM Lead` throws
     * `System.QueryException: No such column` — an FLS denial wearing a schema error. A test that
     * queried unconditionally would fail on exactly the org state the production guard exists to
     * survive, and would push the next reader toward deleting the guard to get green.
     *
     * @param leadId The Lead to read.
     * @return The Lead with both lookups populated, or null when they are not readable.
     */
    private static Lead storedBrokerLink(Id leadId) {
        if (!Schema.SObjectType.Lead.fields.Broker__c.isAccessible()
                || !Schema.SObjectType.Lead.fields.Broker_Firm__c.isAccessible()) {
            return null;
        }
        return [SELECT Broker__c, Broker_Firm__c FROM Lead WHERE Id = :leadId];
    }

    @isTest
    static void createLeadFromExtracted_brokerCompanyPresent_alsoStampsBrokerFirst() {
        // THE CARRIED-OVER GAP FIX. Before WS8 this class had ZERO references to Broker_First__c,
        // so it was blank on every genuinely email-born Lead while the portal channel populated
        // it — and WS6 has just made it the "Broker" column on five Lead list views.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerCompany = 'Brokerfirm LLC';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT Company, Broker_First__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual('Brokerfirm LLC', created.Broker_First__c,
            'Broker_First__c holds the brokerage FIRM NAME and must come from the same extracted '
            + 'value that feeds Company, so the two can never disagree');
        Assert.areEqual(created.Company, created.Broker_First__c,
            'and when a real firm name WAS extracted the two are identical. ⚠ This half alone would '
            + 'still pass if someone simplified the write to mirror Company unconditionally — the '
            + 'BLANK test below is the one that forbids it');
    }

    @isTest
    static void createLeadFromExtracted_brokerCompanyBlank_leavesBrokerFirstBlankNotThePlaceholder() {
        // 🔴 THE LOAD-BEARING HALF OF THE FIX. `lead.Company` is REQUIRED and therefore falls back
        // to COMPANY_PLACEHOLDER; Broker_First__c is a DISPLAY field on five list views and must
        // not. If this ever reads 'Unknown - Via Email', the guard at the assignment has been
        // removed and the org's PRIMARY intake channel is printing a placeholder into a broker
        // column on every firm-unknown email.
        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Lead created = [SELECT Company, Broker_First__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual(EmailToLeadService.COMPANY_PLACEHOLDER, created.Company,
            'Precondition: Company still falls back to the placeholder, because it is required');
        Assert.isNull(created.Broker_First__c,
            'BUT Broker_First__c MUST STAY BLANK. A blank cell says "we do not know the firm"; the '
            + 'placeholder says it in a way that sorts, filters and reports as though it were a firm '
            + 'name. The literal is read from the constant, so rewording it cannot make this vacuous');
    }

    @isTest
    static void createLeadFromExtracted_whitespaceOnlyBrokerCompany_leavesBrokerFirstBlank() {
        // `String.isNotBlank`, not `!= null` — a signature block that yielded only whitespace must
        // behave exactly like no firm at all, on BOTH fields.
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerCompany = '   ';

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        Lead created = [SELECT Company, Broker_First__c FROM Lead WHERE Id = :leadId];
        Assert.areEqual(EmailToLeadService.COMPANY_PLACEHOLDER, created.Company,
            'A whitespace-only firm is not a firm — Company falls back to the placeholder');
        Assert.isNull(created.Broker_First__c,
            'and Broker_First__c stays blank rather than storing three spaces that render as a '
            + 'populated-looking cell');
    }

    @isTest
    static void createLeadFromExtracted_brokerLink_isStampedInTheSameInsert() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createBrokerContact(firm.Id, true);

        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerContactId = broker.Id;
        request.brokerFirmAccountId = firm.Id;

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        Test.stopTest();

        // ⚠ ASSERTED UNCONDITIONALLY AND FIRST: whatever the FLS state, THE LEAD MUST EXIST. That
        // is the entire point of the isCreateable() guard — a missing grant costs the link and
        // nothing else. If this line ever fails, the guard has been removed and every inbound
        // broker email is dying at the insert (measured shape, 2026-08-30, WS7's two fields).
        Assert.isNotNull(leadId, 'The Lead is inserted whether or not the two lookups are writable');

        Lead created = storedBrokerLink(leadId);
        if (created != null && brokerLinkWritable()) {
            Assert.areEqual(broker.Id, created.Broker__c,
                'The matched broker Contact is stamped at INTAKE, in the insert that already existed');
        }
        if (created != null && brokerFirmLinkWritable()) {
            Assert.areEqual(firm.Id, created.Broker_Firm__c,
                'and their brokerage Account alongside it, from the SAME matched Contact row — which '
                + 'is what makes the pair impossible to contradict each other');
        }
    }

    @isTest
    static void createLeadFromExtracted_noBrokerMatch_leavesBothLookupsBlankAndStillInserts() {
        // 🔴 THE USER DECISION, ASSERTED RATHER THAN COMMENTED: MATCH ONLY. An unmatched sender
        // leaves both lookups BLANK. Nothing is created, and no firm is invented from the email
        // domain. If a future change starts minting a Contact or an Account at intake, the two
        // COUNT assertions below fail.
        Integer accountsBefore = [SELECT COUNT() FROM Account];
        Integer contactsBefore = [SELECT COUNT() FROM Contact];

        Test.startTest();
        Id leadId = EmailToLeadService.createLeadFromExtracted(enrichedRequest());
        Test.stopTest();

        Assert.isNotNull(leadId, 'An unmatched broker still gets a Lead — the link is an enrichment');
        Lead created = storedBrokerLink(leadId);
        if (created != null) {
            Assert.isNull(created.Broker__c,
                'No match means BLANK — not a newly created Contact, not a placeholder');
            Assert.isNull(created.Broker_Firm__c,
                'and blank on the firm too. A firm is NEVER derived from the sender email domain');
        }
        Assert.areEqual(accountsBefore, [SELECT COUNT() FROM Account],
            'INTAKE CREATES NO ACCOUNT. Creation stays at conversion; this count is the permanent '
            + 'falsifier for anyone who adds a "create the firm if missing" branch here');
        Assert.areEqual(contactsBefore, [SELECT COUNT() FROM Contact],
            'and no Contact either — same decision, same reason');
    }

    @isTest
    static void createLeadFromExtracted_brokerLink_addsNoDmlAndNoSoql() {
        // 🔴 THE BRIEF'S HARD CONSTRAINT AT THIS LAYER: ZERO NEW DML, ZERO NEW SOQL. The two
        // lookups ride the EXISTING insert, and the query that produced their Ids ran once per
        // EMAIL in ExtractAddressQueueable, not here.
        //
        // ⚠ THE FIXTURE IS BUILT BEFORE THE COUNTERS ARE READ, deliberately — a governor assertion
        // that brackets its own setup measures the setup. Same shape as the WS7 test above.
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createBrokerContact(firm.Id, true);
        EmailToLeadService.LeadRequest request = enrichedRequest();
        request.brokerCompany = 'Brokerfirm LLC';
        request.brokerContactId = broker.Id;
        request.brokerFirmAccountId = firm.Id;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer soqlBefore = Limits.getQueries();
        EmailToLeadService.createLeadFromExtracted(request);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Integer soqlUsed = Limits.getQueries() - soqlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed,
            'EXACTLY ONE DML STATEMENT — the Lead insert. A 2 here means someone added an update to '
            + 'carry the broker link, which at N properties per email becomes N extra statements '
            + 'against a PINNED equality of 45 in ExtractAddressQueueableTest');
        Assert.areEqual(0, soqlUsed,
            'AND ZERO SOQL. If this reads 1, the broker lookup has been moved INTO this method — '
            + 'which runs once per PROPERTY — turning one query per email into ten. The sender is an '
            + 'EMAIL-level fact and must be resolved once, by the caller; see '
            + 'ExtractAddressQueueable.resolveBrokerLink');
    }

    @isTest
    static void resolveBrokerEmail_prefersASanitizingExtractedAddressOverTheEnvelope() {
        // The rule promoted out of an inline expression by WS8. It is PUBLIC because
        // ExtractAddressQueueable keys the broker lookup on it, and the reason it was promoted
        // rather than copied is the SECOND assertion below.
        Assert.areEqual('jane@brokerfirm.example.invalid',
            EmailToLeadService.resolveBrokerEmail(
                'jane@brokerfirm.example.invalid', 'fwd@dpeg.example.invalid'),
            'A sanitizing extracted broker_email beats the envelope — on a manually forwarded email '
            + 'the envelope names DPEG own coordinator, not the broker');
        Assert.areEqual('fwd@dpeg.example.invalid',
            EmailToLeadService.resolveBrokerEmail('Jane at Acme', 'fwd@dpeg.example.invalid'),
            '🔴 AND A DISPLAY NAME IS NOT AN ADDRESS. This is the case that makes a SHARED rule '
            + 'necessary rather than a copy: ExtractAddressQueueable senderEmail member would take '
            + '"Jane at Acme" (it only tests isNotBlank) while Lead.Email falls back to the envelope. '
            + 'Keying the Contact lookup on the former would let intake and conversion disagree '
            + 'about who the broker is, since LeadConvertMatchService matches Contact.Email = Lead.Email');
        Assert.areEqual('fwd@dpeg.example.invalid',
            EmailToLeadService.resolveBrokerEmail(null, 'fwd@dpeg.example.invalid'),
            'A null extraction falls back to the envelope');
        Assert.isNull(EmailToLeadService.resolveBrokerEmail('   ', 'also not an address'),
            'and when neither side sanitizes the answer is null — no key, no lookup, and a blank '
            + 'Lead.Email, which is the pre-existing behaviour this refactor had to preserve exactly');
    }
}
