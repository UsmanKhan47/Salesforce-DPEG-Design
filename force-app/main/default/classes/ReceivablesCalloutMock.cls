/**
 * Shared `HttpCalloutMock` for the receivables feed
 * (`ReceivablesCalloutService.fetchDelinquencyFeed` -&gt; `callout:ASB/receivables/delinquency`).
 * Test-support utility, not a competing `TestDataFactory` - it mocks the HTTP response shape only.
 *
 * `ReceivablesCalloutService` is the ONLY `Http.send` in the whole feature (ARCHITECTURE.md section
 * 2), so every test that exercises the ASB path mocks through this one class. Modelled on
 * `SharePointCalloutMock` and `LLMExtractionCalloutMock`, the in-repo precedents.
 *
 * `requestCount` / `requests` let a test assert on CALL VOLUME directly - the assertion that
 * matters most here being the reverse one: that the STUB provider drives the entire FSD 5.9
 * lifecycle with ZERO callouts, which is the brief's central claim and is proved by installing this
 * mock and asserting `requestCount == 0`.
 *
 * @see ReceivablesCalloutService.cls (the boundary this mocks)
 * @see SharePointCalloutMock.cls     (the precedent for this shape)
 */
@isTest
public class ReceivablesCalloutMock implements HttpCalloutMock {

    private final Integer statusCode;
    private final String body;

    /** How many times `respond` was invoked - the call-volume assertion surface. */
    public Integer requestCount = 0;
    /** Every request this mock has responded to, in order. */
    public List<HttpRequest> requests = new List<HttpRequest>();
    /** The most recent request; null until the first callout. */
    public HttpRequest lastRequest;
    /**
     * When set, `respond` THROWS a `CalloutException` instead of returning. Exercises the transport
     * failure arm of `ReceivablesCalloutService`, which no status code can reach.
     */
    public Boolean throwTransportFailure = false;

    /**
     * @param statusCode HTTP status to return.
     * @param body       Response body to return. May be blank or malformed - the caller decides
     *                   what the scenario needs.
     */
    public ReceivablesCalloutMock(Integer statusCode, String body) {
        this.statusCode = statusCode;
        this.body = body;
    }

    /**
     * A mock that returns a well-formed feed envelope with the supplied as-of stamp and rows.
     *
     * @param feedAsOf The feed's own clock; may be null to exercise the "no clock" halt.
     * @param rows     Rows to serialize into the envelope; may be empty.
     * @return A configured mock returning HTTP 200.
     */
    public static ReceivablesCalloutMock success(DateTime feedAsOf, List<ReceivablesFeedDTO> rows) {
        ReceivablesFeedResult payload = new ReceivablesFeedResult();
        payload.feedAsOf = feedAsOf;
        payload.rows = (rows == null) ? new List<ReceivablesFeedDTO>() : rows;
        return new ReceivablesCalloutMock(200, JSON.serialize(payload));
    }

    public HttpResponse respond(HttpRequest request) {
        requestCount++;
        requests.add(request);
        lastRequest = request;

        if (throwTransportFailure == true) {
            throw new System.CalloutException('Simulated transport failure');
        }

        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setHeader('Content-Type', 'application/json');
        if (body != null) {
            response.setBody(body);
        }
        return response;
    }
}
