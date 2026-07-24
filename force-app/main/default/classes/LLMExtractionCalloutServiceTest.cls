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
    static void extract_200Success_returnsAllFourKeys() {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false)));

        Test.startTest();
        Map<String, String> result = new LLMExtractionCalloutService().extract('some forwarded email body', null, null);
        Test.stopTest();

        Assert.areEqual(4, result.size(), 'Result map must always carry exactly the 4-key contract');
        Assert.areEqual('Jane Broker', result.get('broker_name'), 'broker_name should be parsed from the response');
        Assert.areEqual('jane@brokerfirm.example.invalid', result.get('broker_email'), 'broker_email should be parsed');
        Assert.areEqual('100 Main St, Houston, TX', result.get('property_address'), 'property_address should be parsed');
        Assert.areEqual('2026-07-01 10:00:00', result.get('sent_datetime'), 'sent_datetime should be parsed');
    }

    @isTest
    static void extract_jsonFencedResponse_stripsCodeFenceAndParses() {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), true)));

        Test.startTest();
        Map<String, String> result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.areEqual('Jane Broker', result.get('broker_name'),
            'A ```json-fenced response body should still parse correctly once fences are stripped');
        Assert.areEqual('100 Main St, Houston, TX', result.get('property_address'), 'property_address should still parse');
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
    static void extract_missingKeys_defaultToEmptyString() {
        Map<String, String> partial = new Map<String, String>{ 'broker_name' => 'Jane Broker' };
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(partial, false)));

        Test.startTest();
        Map<String, String> result = new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.areEqual('Jane Broker', result.get('broker_name'), 'The present key should still parse');
        Assert.areEqual('', result.get('broker_email'), 'A missing key must default to empty string, never null');
        Assert.areEqual('', result.get('property_address'), 'A missing key must default to empty string, never null');
        Assert.areEqual('', result.get('sent_datetime'), 'A missing key must default to empty string, never null');
    }

    @isTest
    static void extract_malformedResponseShapes_returnEmptyDefaults() {
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
            Map<String, String> result = new LLMExtractionCalloutService().extract('body text', null, null);
            Assert.areEqual('', result.get('broker_name'), 'broker_name should default to empty for malformed body: ' + body);
            Assert.areEqual('', result.get('broker_email'), 'broker_email should default to empty for malformed body: ' + body);
            Assert.areEqual('', result.get('property_address'), 'property_address should default to empty for malformed body: ' + body);
            Assert.areEqual('', result.get('sent_datetime'), 'sent_datetime should default to empty for malformed body: ' + body);
        }
        Test.stopTest();
    }
}
