/**
 * Dedicated OpenAI callout wrapper for Broker-Protection LLM field extraction
 * (CHUNK 1). Given the text (and optionally an image) of a forwarded broker email,
 * it asks a vision-capable model to pull the ORIGINAL broker's identity, the
 * property address, and the send timestamp, and returns them as a flat String map.
 *
 * LAYER — callout service. Per ARCHITECTURE.md §2 ("all ASB/Plaid callouts wrapped
 * in a dedicated service class ... so they can be mocked via HttpCalloutMock") the
 * single `Http.send` lives here and nowhere else, so CHUNK 2/3 callers (and their
 * tests) mock this one boundary via HttpCalloutMock. No SOQL, no DML.
 *
 * ⚠ DELIBERATE, TEMPORARY §3 EXCEPTION — DIRECT (NON-ASB) EXTERNAL CALLOUT.
 * ARCHITECTURE.md §3 mandates a hub-and-spoke model where "All external integrations
 * route through ASB. No direct peer-to-peer integrations between Salesforce and
 * external systems." This class INTENTIONALLY breaks that rule: it calls OpenAI
 * directly via the `OpenAI_API` Named Credential rather than through the Avanza
 * Service Bus. The exception is accepted because NO ASB LLM-extraction endpoint
 * exists yet — there is nothing on the bus to route to. It is scoped and reversible:
 * when ASB exposes an LLM-extraction spoke, ONLY this class's endpoint constant (and
 * the Named Credential it points at) change; the public `extract(...)` signature,
 * the request-shaping, and every downstream caller stay identical. Credentials are
 * never hardcoded — the API key lives entirely in the OpenAI_Credential external
 * credential (§3.2), injected into the Authorization header by the platform.
 *
 * @see .claude/skills/sf-integration (callout-patterns, named-credentials-guide)
 * @see force-app/main/default/namedCredentials/OpenAI_API.namedCredential-meta.xml
 * @see force-app/main/default/externalCredentials/OpenAI_Credential.externalCredential-meta.xml
 */
public with sharing class LLMExtractionCalloutService {

    /** Named-Credential-backed chat-completions endpoint. Only this line changes when
     *  the callout is later re-homed onto an ASB LLM-extraction spoke. */
    private static final String ENDPOINT = 'callout:OpenAI_API/v1/chat/completions';

    /** Vision-capable, low-cost model used for the extraction. */
    private static final String MODEL = 'gpt-4o-mini';

    /** Callout timeout in milliseconds. */
    private static final Integer TIMEOUT_MS = 30000;

    /** Upper bound on the model's response tokens. */
    private static final Integer MAX_TOKENS = 512;

    /**
     * Instruction embedded as the user-message text part. It pins the "forwarded
     * email" parsing rules and forces a strict JSON-only response of exactly the four
     * keys this service returns.
     */
    private static final String EXTRACTION_INSTRUCTION =
        'You are extracting fields from a FORWARDED email. The content below is the ' +
        'body of a broker email that an internal DPEG user forwarded on. ' +
        'The OUTERMOST / EARLIEST "From:" line identifies the ORIGINAL BROKER — take ' +
        'broker_name and broker_email from that line. The "To:" line identifies the ' +
        'internal person who forwarded the email — IGNORE it; never use it for the ' +
        'broker. property_address is any property address found anywhere in the body. ' +
        'sent_datetime is the OUTERMOST / EARLIEST "Sent:" line, converted to UTC and ' +
        'formatted as "yyyy-MM-dd HH:mm:ss". If a value is absent, use an empty ' +
        'string. Respond ONLY with a single JSON object of exactly these keys and no ' +
        'other text: {"broker_name": "", "broker_email": "", "property_address": "", ' +
        '"sent_datetime": ""}.';

    /** Fixed key set of the returned map — the exact contract CHUNK 2/3 relies on. */
    private static final String KEY_BROKER_NAME = 'broker_name';
    private static final String KEY_BROKER_EMAIL = 'broker_email';
    private static final String KEY_PROPERTY_ADDRESS = 'property_address';
    private static final String KEY_SENT_DATETIME = 'sent_datetime';

    /**
     * Extract broker / property / timestamp fields from a forwarded broker email via
     * OpenAI. The result map ALWAYS carries exactly the four keys broker_name,
     * broker_email, property_address, sent_datetime; any field the model could not
     * find comes back as an empty string (never null, never absent).
     *
     * The user message content is built as a list of parts. When `imageBase64` is
     * non-blank an image_url part (a `data:<mime>;base64,<data>` URL) is added first,
     * then the text part carrying the extraction instruction plus `textContent`; when
     * there is no image the content is just the text part. No Authorization header is
     * set here — the platform injects it from the OpenAI_Credential external
     * credential.
     *
     * @param textContent   The forwarded email body text; may be blank.
     * @param imageBase64   Base64 of an optional inline image (e.g. a screenshot of
     *                      the forwarded email); blank/null to send text only.
     * @param imageMimeType MIME type for the image data URL (e.g. 'image/png'); used
     *                      only when `imageBase64` is non-blank.
     * @return A Map with exactly {broker_name, broker_email, property_address,
     *         sent_datetime}; missing values are empty strings.
     * @throws CalloutException when the OpenAI endpoint returns a non-200 status.
     * @example
     * Map<String, String> fields =
     *     new LLMExtractionCalloutService().extract(emailBody, null, null);
     */
    public Map<String, String> extract(String textContent, String imageBase64, String imageMimeType) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(TIMEOUT_MS);
        request.setBody(buildRequestBody(textContent, imageBase64, imageMimeType));

        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() != 200) {
            throw new CalloutException(
                'OpenAI extraction callout failed: HTTP ' + response.getStatusCode() +
                ' ' + response.getStatus() + ' — ' + response.getBody()
            );
        }

        String rawContent = extractMessageContent(response.getBody());
        Map<String, Object> parsedFields = parseFieldObject(stripCodeFences(rawContent));

        return new Map<String, String>{
            KEY_BROKER_NAME => stringOrEmpty(parsedFields.get(KEY_BROKER_NAME)),
            KEY_BROKER_EMAIL => stringOrEmpty(parsedFields.get(KEY_BROKER_EMAIL)),
            KEY_PROPERTY_ADDRESS => stringOrEmpty(parsedFields.get(KEY_PROPERTY_ADDRESS)),
            KEY_SENT_DATETIME => stringOrEmpty(parsedFields.get(KEY_SENT_DATETIME))
        };
    }

    /**
     * Serialize the chat-completions request body: model, temperature 0 (deterministic),
     * max_tokens, and one user message whose content is the ordered parts list.
     * JSON.serialize handles all escaping of the embedded instruction/email text.
     *
     * @param textContent   Forwarded email body (may be blank).
     * @param imageBase64   Optional base64 image; when non-blank, added as the first
     *                      content part.
     * @param imageMimeType MIME type for the image data URL.
     * @return The serialized JSON request body.
     */
    private String buildRequestBody(String textContent, String imageBase64, String imageMimeType) {
        Map<String, Object> textPart = new Map<String, Object>{
            'type' => 'text',
            'text' => EXTRACTION_INSTRUCTION + '\n\n' + (textContent == null ? '' : textContent)
        };

        List<Object> content = new List<Object>();
        if (String.isNotBlank(imageBase64)) {
            String dataUrl = 'data:' + imageMimeType + ';base64,' + imageBase64;
            content.add(new Map<String, Object>{
                'type' => 'image_url',
                'image_url' => new Map<String, Object>{ 'url' => dataUrl }
            });
        }
        content.add(textPart);

        Map<String, Object> body = new Map<String, Object>{
            'model' => MODEL,
            'temperature' => 0,
            'max_tokens' => MAX_TOKENS,
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => content }
            }
        };
        return JSON.serialize(body);
    }

    /**
     * Pull `choices[0].message.content` (the model's text) out of the raw response
     * body. Returns an empty string if the response shape is unexpected rather than
     * dereferencing a missing node.
     *
     * @param responseBody The raw OpenAI response JSON.
     * @return The assistant message content, or '' when it cannot be located.
     */
    private String extractMessageContent(String responseBody) {
        if (String.isBlank(responseBody)) {
            return '';
        }
        Object parsed = JSON.deserializeUntyped(responseBody);
        if (!(parsed instanceof Map<String, Object>)) {
            return '';
        }
        Object choicesObj = ((Map<String, Object>) parsed).get('choices');
        if (!(choicesObj instanceof List<Object>)) {
            return '';
        }
        List<Object> choices = (List<Object>) choicesObj;
        if (choices.isEmpty() || !(choices[0] instanceof Map<String, Object>)) {
            return '';
        }
        Object messageObj = ((Map<String, Object>) choices[0]).get('message');
        if (!(messageObj instanceof Map<String, Object>)) {
            return '';
        }
        Object contentObj = ((Map<String, Object>) messageObj).get('content');
        return contentObj == null ? '' : String.valueOf(contentObj);
    }

    /**
     * Deserialize the model's (fence-stripped) content into a field map, tolerating a
     * non-object payload by returning an empty map so callers still get the four-key
     * contract.
     *
     * @param cleaned Fence-stripped model content expected to be a JSON object.
     * @return The parsed field map, or an empty map when the payload is not a JSON
     *         object.
     */
    private Map<String, Object> parseFieldObject(String cleaned) {
        if (String.isBlank(cleaned)) {
            return new Map<String, Object>();
        }
        Object parsed = JSON.deserializeUntyped(cleaned);
        return (parsed instanceof Map<String, Object>)
            ? (Map<String, Object>) parsed
            : new Map<String, Object>();
    }

    /**
     * Strip a leading ```json / ``` fence and a trailing ``` fence that models often
     * wrap JSON in, leaving the bare JSON object.
     *
     * @param raw The model content, possibly fenced.
     * @return The content with surrounding code fences removed and trimmed.
     */
    private String stripCodeFences(String raw) {
        if (String.isBlank(raw)) {
            return '';
        }
        String cleaned = raw.trim();
        cleaned = cleaned.replaceFirst('^```[a-zA-Z]*\\s*', '');
        cleaned = cleaned.replaceFirst('\\s*```\\s*$', '');
        return cleaned.trim();
    }

    /**
     * Null-safe String coercion — the empty-string default for absent fields.
     *
     * @param value The raw deserialized value.
     * @return `value` as a String, or '' when null.
     */
    private String stringOrEmpty(Object value) {
        return value == null ? '' : String.valueOf(value);
    }
}
