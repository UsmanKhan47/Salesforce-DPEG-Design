/**
 * Shared HttpCalloutMock for the Broker-Protection LLM extraction boundary
 * (LLMExtractionCalloutService.extract → callout:OpenAI_API/v1/chat/completions).
 * Test-support utility, not a competing TestDataFactory — this mocks the HTTP
 * response shape, TestDataFactory owns all SObject construction.
 *
 * Reused across LLMExtractionCalloutServiceTest, ExtractAddressQueueableTest,
 * EmailToLeadServiceTest, and EmailToLeadHandlerTest so every test hitting this
 * callout boundary shares one mock implementation (per
 * .claude/skills/sf-apex-test/references/mocking-patterns.md).
 *
 * Captures the last HTTPRequest it was asked to respond to (`lastRequest`) so a
 * test can assert on what was actually sent — e.g. that an image_url part was
 * included when an inline image attachment was supplied.
 *
 * @see LLMExtractionCalloutService.cls (the callout wrapper this mocks)
 */
@isTest
public class LLMExtractionCalloutMock implements HttpCalloutMock {

    private final Integer statusCode;
    private final String responseBody;

    /** The most recent HTTPRequest this mock responded to; null until respond() is called. */
    public HttpRequest lastRequest;

    /**
     * @param statusCode   HTTP status code to return.
     * @param responseBody Raw response body to return.
     */
    public LLMExtractionCalloutMock(Integer statusCode, String responseBody) {
        this.statusCode = statusCode;
        this.responseBody = responseBody;
    }

    public HTTPResponse respond(HTTPRequest req) {
        lastRequest = req;
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setBody(responseBody);
        res.setHeader('Content-Type', 'application/json');
        return res;
    }

    /**
     * Builds a well-formed OpenAI chat-completions success envelope whose
     * choices[0].message.content is exactly `content` (verbatim — caller decides
     * whether it is fenced, malformed, etc).
     *
     * @param content The assistant message content to embed.
     * @return The serialized response body.
     */
    public static String successBody(String content) {
        Map<String, Object> payload = new Map<String, Object>{
            'choices' => new List<Object>{
                new Map<String, Object>{
                    'message' => new Map<String, Object>{ 'content' => content }
                }
            }
        };
        return JSON.serialize(payload);
    }

    /**
     * Convenience: a success body whose content is the JSON serialization of
     * `fields` — the four-key extraction contract — optionally wrapped in a
     * ```json code fence the way real LLM responses often are.
     *
     * @param fields The extracted-field map to embed (broker_name, broker_email,
     *               property_address, sent_datetime).
     * @param fenced When true, wraps the JSON in a ```json ... ``` fence.
     * @return The serialized response body.
     */
    public static String extractionBody(Map<String, String> fields, Boolean fenced) {
        String json = JSON.serialize(fields);
        String content = fenced ? '```json\n' + json + '\n```' : json;
        return successBody(content);
    }
}
