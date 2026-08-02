/**
 * Test class for LLMExtractionCalloutService. All scenarios mock the single
 * callout boundary via LLMExtractionCalloutMock (Test.setMock) per
 * ARCHITECTURE.md §2 — never a real callout.
 *
 * @author Unit Testing Agent
 */
@isTest
private class LLMExtractionCalloutServiceTest {

    private static Map<String, String> fullFields() {
        return new Map<String, String>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Main St, Houston, TX',
            'sent_datetime' => '2026-07-01 10:00:00'
        };
    }

    @isTest
    static void extract_200LegacyShape_stillYieldsTheFourClaimValues() {
        // The four-key body is the PRE-ENRICHMENT contract. It is kept as a first-class test
        // because reverting the prompt constant produces exactly this response, and the pipeline
        // must keep working with no other code change (the documented one-line rollback).
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false)));

        Test.startTest();
        LLMExtractionResult result = new LLMExtractionCalloutService().extract('some forwarded email body', null, null);
        Test.stopTest();

        Assert.areEqual('Jane Broker', result.brokerName, 'broker_name should be parsed from the response');
        Assert.areEqual('jane@brokerfirm.example.invalid', result.brokerEmail, 'broker_email should be parsed');
        Assert.areEqual('2026-07-01 10:00:00', result.sentDatetime, 'sent_datetime should be parsed');
        Assert.areEqual(1, result.properties.size(), 'The legacy shape must synthesize one property');
        Assert.areEqual('100 Main St, Houston, TX', result.properties[0].propertyAddress,
            'property_address must travel verbatim — it is the claim key');
        Assert.areEqual(4, result.toLegacyMap(result.properties[0]).size(),
            'The claim engine still receives exactly the four-key map it always has');
    }

    @isTest
    static void extract_200EnrichedShape_readsPerPropertyFields() {
        String body = LLMExtractionCalloutMock.enrichedBody(
            new Map<String, Object>{
                'broker_email' => 'jane@brokerfirm.example.invalid',
                'is_acquisition_related' => true,
                'confidence' => 0.95
            },
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'property_address' => '100 Main St', 'asset_type' => 'Retail' },
                new Map<String, Object>{ 'property_address' => '200 Oak Ave', 'noi' => 450000 }
            });
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200, body));

        Test.startTest();
        LLMExtractionResult result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.areEqual(2, result.properties.size(), 'Both property objects should come back');
        Assert.areEqual('Retail', result.properties[0].assetType, 'A valid asset type should survive validation');
        Assert.areEqual(450000.00, result.properties[1].noi, 'A per-property currency value should be typed');
        Assert.areEqual(LLMExtractionParser.BAND_HIGH, result.confidenceBand,
            'Apex derives the band from the numeric confidence — the model never names it');
    }

    @isTest
    static void extract_jsonFencedResponse_stripsCodeFenceAndParses() {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), true)));

        Test.startTest();
        LLMExtractionResult result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.areEqual('Jane Broker', result.brokerName,
            'A ```json-fenced response body should still parse correctly once fences are stripped');
        Assert.areEqual('100 Main St, Houston, TX', result.properties[0].propertyAddress,
            'property_address should still parse');
    }

    @isTest
    static void extract_requestBody_carriesTheEnrichedLimitsAndJsonMode() {
        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        String sentBody = mock.lastRequest.getBody();
        Assert.isTrue(sentBody.contains('"max_tokens":4096'),
            'MAX_TOKENS must be 4096: 512 is 4-8x too small for the enriched contract, and a truncated '
            + 'response is the most dangerous failure this class has');
        Assert.isTrue(sentBody.contains('"response_format":{"type":"json_object"}'),
            'JSON mode GUARANTEES syntactically valid JSON — the single strongest truncation mitigation');
        Assert.isTrue(sentBody.contains('"model":"gpt-4o-mini"'),
            'The MODEL must NOT change alongside the prompt, or a regression could not be attributed');
        Assert.isTrue(sentBody.contains('"temperature":0'), 'temperature 0 keeps extraction deterministic');
    }

    @isTest
    static void extract_overLongBody_isClippedBeforeSending() {
        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);
        String head = 'From: Jane Broker <jane@brokerfirm.example.invalid>\nSent: Monday, July 1, 2026 10:00 AM\n\n';
        String hugeBody = head + ''.rightPad(80000, 'q');

        Test.startTest();
        new LLMExtractionCalloutService().extract(hugeBody, null, null);
        Test.stopTest();

        String sentBody = mock.lastRequest.getBody();
        Assert.isTrue(sentBody.contains('From: Jane Broker'),
            'Clipping must keep the HEAD of the email: the outermost From:/Sent: lines are what the legacy '
            + 'claim-engine rules read, and losing them would silently re-attribute claims');
        Assert.isTrue(sentBody.length() < 80000,
            'The 80k body must have been clipped to the 40k ceiling rather than sent whole');
    }

    @isTest
    static void extract_withImage_includesImageUrlPartInRequestBody() {
        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', 'ZmFrZWJhc2U2NA==', 'image/png');
        Test.stopTest();

        Assert.isNotNull(mock.lastRequest, 'The mock should have captured the outgoing request');
        String sentBody = mock.lastRequest.getBody();
        Assert.isTrue(sentBody.contains('"image_url"'), 'Request body should include an image_url content part when imageBase64 is supplied');
        Assert.isTrue(sentBody.contains('data:image/png;base64,ZmFrZWJhc2U2NA=='),
            'Request body should embed the image as a data: URL using the supplied mime type and base64 payload');
    }

    @isTest
    static void extract_noImage_omitsImageUrlPart() {
        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.isFalse(mock.lastRequest.getBody().contains('"image_url"'),
            'Request body should not include an image_url part when no image is supplied');
    }

    @isTest
    static void extract_non200_throwsCalloutException() {
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(500, '{"error":"server error"}'));

        Boolean threw = false;
        Test.startTest();
        try {
            new LLMExtractionCalloutService().extract('body text', null, null);
            Assert.fail('Expected a CalloutException for a non-200 response');
        } catch (CalloutException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('500'), 'Exception message should surface the HTTP status code');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A non-200 response must raise CalloutException');
    }

    @isTest
    static void extract_missingKeys_defaultToEmptyStringInTheLegacyMap() {
        Map<String, String> partial = new Map<String, String>{ 'broker_name' => 'Jane Broker' };
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(partial, false)));

        Test.startTest();
        LLMExtractionResult result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Map<String, String> legacy = result.toLegacyMap(null);
        Assert.areEqual('Jane Broker', legacy.get('broker_name'), 'The present key should still parse');
        Assert.areEqual('', legacy.get('broker_email'), 'A missing key must default to empty string, never null');
        Assert.areEqual('', legacy.get('property_address'), 'A missing key must default to empty string, never null');
        Assert.areEqual('', legacy.get('sent_datetime'), 'A missing key must default to empty string, never null');
    }

    @isTest
    static void extract_malformedResponseShapes_returnEmptyResultsWithoutThrowing() {
        List<String> malformedBodies = new List<String>{
            '',                                                   // blank body
            '{"unexpected":"shape"}',                              // no choices key
            '{"choices":[]}',                                      // empty choices array
            '{"choices":[{"unexpected":"shape"}]}',                // choice with no message
            '{"choices":[{"message":{"unexpected":"shape"}}]}',    // message with no content
            '["not","a","map"]'                                    // top-level not a JSON object
        };

        Test.startTest();
        for (String body : malformedBodies) {
            Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200, body));
            LLMExtractionResult result = new LLMExtractionCalloutService().extract('body text', null, null);
            Assert.areEqual(0, result.properties.size(),
                'A malformed envelope must yield no properties rather than throwing: ' + body);
            Map<String, String> legacy = result.toLegacyMap(null);
            Assert.areEqual('', legacy.get('broker_email'),
                'The legacy contract still holds for a malformed body: ' + body);
        }
        Test.stopTest();
    }

    @isTest
    static void extract_truncatedJsonContent_degradesInsteadOfThrowing() {
        // The C-14 failure mode, at its source. The parser must absorb a reply cut mid-object so
        // the QUEUEABLE's widened degrade catch has something safe to work with — an exception
        // here would put the email on an Error staging row with no Lead at all.
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200,
            LLMExtractionCalloutMock.successBody('{"properties":[{"property_address":"100 Main')));

        Test.startTest();
        LLMExtractionResult result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.areEqual(0, result.properties.size(), 'A truncated response yields no usable property');
        Assert.isFalse(result.notes.isEmpty(),
            'The truncation must be recorded as a note so a human can see why the fields are blank');
    }
}
