/**
 * Shared HttpCalloutMock for the SharePoint deal-folder feature
 * (SharePointCalloutService.createFolder → callout:SharePoint/...). Test-support utility, not a
 * competing TestDataFactory — this mocks the HTTP response shape only.
 *
 * `SharePointCalloutService` is the ONLY `Http.send` in the whole feature (ARCHITECTURE.md §2), so
 * every test in this feature — SharePointCalloutServiceTest, SharePointConfigTest (indirectly),
 * DealFolderServiceTest, DealFolderQueueableTest, DealFolderFinalizerTest, DealFolderSweepBatchTest —
 * mocks through this one class. Modelled on LLMExtractionCalloutMock, the in-repo precedent for a
 * shared callout mock (per .claude/skills/sf-apex-test/references/mocking-patterns.md).
 *
 * ═══ DEFAULT RESPONSE, PLUS PER-FOLDER-NAME OVERRIDES ═══
 * `DealFolderService.createTree` makes SEVEN calls per property in one transaction (one parent, six
 * lifecycle subfolders — see that class's header), and the ONLY thing that discriminates one call
 * from another in the outgoing request is the JSON body's `name` field (the request body is built
 * fresh per call by `SharePointCalloutService.buildRequestBody`; the endpoint differs too, but
 * dispatching on the folder NAME is simpler and is exactly what a test needs to express "the parent
 * succeeds but this one subfolder is refused" — required to pin residual R2, the partial-subfolder-
 * failure contract, without which DealFolderServiceTest could only ever prove all-succeed or
 * all-fail). A name with no override falls back to the mock's default status/body.
 *
 * `requestCount` / `requests` let a test assert on CALL VOLUME directly — e.g. that a blank site id
 * or a blank name makes ZERO callouts (SharePointCalloutService returns early), or that a converged
 * idempotency guard makes zero callouts on a second pass.
 *
 * @see SharePointCalloutService.cls (the callout wrapper this mocks)
 * @see LLMExtractionCalloutMock.cls (the precedent for this shape)
 */
@isTest
public class SharePointCalloutMock implements HttpCalloutMock {

    private final Integer defaultStatusCode;
    private final String defaultBody;

    /** Per-folder-name status override, keyed on the request body's `name` field. */
    public Map<String, Integer> statusByName = new Map<String, Integer>();
    /** Per-folder-name body override, keyed the same way. */
    public Map<String, String> bodyByName = new Map<String, String>();

    /** How many times `respond` was invoked — the call-volume assertion surface. */
    public Integer requestCount = 0;
    /** Every request this mock has responded to, in order. */
    public List<HttpRequest> requests = new List<HttpRequest>();
    /** The most recent request; null until the first callout. */
    public HttpRequest lastRequest;

    /**
     * @param defaultStatusCode HTTP status returned for a folder name with no override.
     * @param defaultBody       Response body returned for a folder name with no override. May be
     *                          malformed or blank — the caller decides what "default" means for a
     *                          given test.
     */
    public SharePointCalloutMock(Integer defaultStatusCode, String defaultBody) {
        this.defaultStatusCode = defaultStatusCode;
        this.defaultBody = defaultBody;
    }

    public HTTPResponse respond(HTTPRequest req) {
        requestCount++;
        requests.add(req);
        lastRequest = req;

        String name = folderNameFromBody(req.getBody());
        Integer status = (name != null && statusByName.containsKey(name))
            ? statusByName.get(name)
            : defaultStatusCode;
        String body = (name != null && bodyByName.containsKey(name))
            ? bodyByName.get(name)
            : defaultBody;

        HttpResponse res = new HttpResponse();
        res.setStatusCode(status);
        res.setBody(body);
        res.setHeader('Content-Type', 'application/json');
        return res;
    }

    /**
     * Register a per-folder-name outcome, e.g. so one specific lifecycle subfolder in a six-call
     * loop is refused while the other five (and the parent) succeed on the mock's default.
     *
     * @param folderName   The exact sanitized/subfolder name this request's body will carry.
     * @param statusCode   Status to return for that name.
     * @param body         Body to return for that name.
     * @return this, for chaining.
     */
    public SharePointCalloutMock withOverride(String folderName, Integer statusCode, String body) {
        statusByName.put(folderName, statusCode);
        bodyByName.put(folderName, body);
        return this;
    }

    /**
     * Pull the `name` field out of a Graph create-folder request body. Tolerates any shape rather
     * than throwing — an unparseable body simply falls back to the mock's default, which is the
     * behaviour a test author expects when they did not register an override.
     *
     * @param body The outgoing request body.
     * @return The folder name, or null when it cannot be determined.
     */
    private String folderNameFromBody(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (!(parsed instanceof Map<String, Object>)) {
                return null;
            }
            Object name = ((Map<String, Object>) parsed).get('name');
            return (name == null) ? null : String.valueOf(name);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * A well-formed Graph driveItem success body carrying `id` and `webUrl`.
     *
     * @param itemId The Graph item id to embed.
     * @param webUrl The Graph webUrl to embed; may be null.
     * @return The serialized response body.
     */
    public static String successBody(String itemId, String webUrl) {
        Map<String, Object> payload = new Map<String, Object>{ 'id' => itemId };
        if (webUrl != null) {
            payload.put('webUrl', webUrl);
        }
        return JSON.serialize(payload);
    }

    /**
     * A well-formed Graph error body: `{"error":{"message": "..."}}`, the shape
     * `SharePointCalloutService.graphErrorMessage` parses.
     *
     * @param message The human-readable error text to embed.
     * @return The serialized response body.
     */
    public static String errorBody(String message) {
        return JSON.serialize(new Map<String, Object>{
            'error' => new Map<String, Object>{ 'message' => message }
        });
    }
}
