/**
 * Dedicated OpenAI callout wrapper for Broker-Protection LLM field extraction. Given the
 * text (and optionally an image) of a forwarded broker email, it asks a vision-capable
 * model to classify the email, identify the ORIGINAL broker, and pull the full
 * deal-screening field set for EVERY property the email pitches, returning a typed
 * LLMExtractionResult.
 *
 * LAYER — callout service. Per ARCHITECTURE.md §2 ("all ASB/Plaid callouts wrapped
 * in a dedicated service class ... so they can be mocked via HttpCalloutMock") the
 * single `Http.send` lives here and nowhere else, so callers (and their tests) mock this
 * one boundary via HttpCalloutMock. No SOQL, no DML.
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
 * ═══ 🔴 THE PROMPT IS PART OF THE CLAIM ENGINE. TREAT IT AS PRODUCTION LOGIC. ═══
 * The first-broker-wins ledger arbitrates on exactly two extracted values — `broker_email`
 * (repeat detection and submission attribution) and `property_address` (normalized into the
 * unique Property_Registry__c.Property_Key__c). A subtly differently-worded address produces
 * a DIFFERENT claim key, and the 0.6 Jaccard fuzzy threshold may or may not rescue it. The
 * failure is invisible: a competing broker quietly WINS a property they lost, or a repeat
 * registers as a new claim. No exception, no error row, no failing test.
 *
 * Three structural protections, all load-bearing:
 *   1. LEGACY_EXTRACTION_RULES is the pre-enrichment instruction VERBATIM and FIRST, in its
 *      own delimited block, ahead of every new instruction. Do not paraphrase it, reorder
 *      it, or "tidy" its wording — it is diffable against git history on purpose.
 *   2. MODEL and temperature are UNCHANGED (gpt-4o-mini, 0). Changing the model at the same
 *      time as the prompt would make any regression impossible to attribute.
 *   3. ROLLBACK IS ONE LINE. Set
 *        EXTRACTION_INSTRUCTION = LEGACY_EXTRACTION_RULES + LEGACY_RESPONSE_FORMAT;
 *      and the pipeline is back on the original four-key contract with NO other code
 *      change — LLMExtractionParser accepts a response with no `properties` array by
 *      synthesizing a one-element array from the top-level `property_address`.
 *
 * ═══ RESPONSE SIZING — WHY MAX_TOKENS IS 4096 AND NOT 512 (C-14) ═══
 * The enriched contract is roughly 20x the old one: ~150 tokens of email-level block, plus
 * 200-260 per property object, plus a narrative. Three properties is ~1,150 tokens; ten is
 * ~2,900. The previous 512 was 4-8x too small, and a TRUNCATED response is the most
 * dangerous failure this class has: it is cut mid-object, JSON.deserializeUntyped throws,
 * and (before this change) the email landed on an Error staging row with NO Lead, NO Task
 * and NO claim — strictly worse than an outage. Four changes address it together:
 * 4096 max_tokens, OpenAI JSON mode (`response_format: json_object`, which GUARANTEES
 * syntactically valid JSON), prompt-level caps on `deal_summary` and property count, and —
 * in ExtractAddressQueueable — a degrade catch widened to JSONException.
 *
 * Cost is NOT the constraint: ~10k input + ~1.5k output on gpt-4o-mini is ~$0.0024 per
 * email, about $36/month at 500 emails/day. Shrinking the prompt "for cost" would trade a
 * trivial saving for the truncation failure above.
 *
 * ═══ PROMPT TUNING 2026-08-02 — three rules added, ALL in the ENRICHED block ═══
 * Three extraction defects observed on live traffic (staging row a0aiw000000NEK1AAO). See
 * agent-output/design-requirements-prompt-tuning.md.
 *   1. property_name came back empty even when the name led the body. Now defined as the
 *      marketing / brand name, explicitly contrasted with property_address, with an
 *      example, and "leave it empty rather than invent one".
 *   2. offer_due_date was recalled from TRAINING DATA (a real 2023 campaign) for a date
 *      that appears nowhere in the email. Year-less dates now anchor on the year-bearing
 *      "Sent:"/"Date:" line, else the injected REFERENCE DATE, rolling forward a year only
 *      when the date would otherwise sit more than 30 days in the past — never backward,
 *      never from world knowledge.
 *   3. sent_datetime was fabricated the same way, and unlike offer_due_date it passes
 *      through NO plausibility gate — the 2023 value reached
 *      Competing_Broker_Submission__c.Submitted_DateTime__c, which is the 90-day recency
 *      filter behind REPEAT DETECTION. A submission stamped outside that window is
 *      invisible, so the broker's own follow-up re-routes as a fresh competing claim. That
 *      makes this an arbitration defect, not a display bug, and the highest-priority of the
 *      three. sent_datetime is now explicit-or-EMPTY.
 *
 * ⚠ LEGACY_EXTRACTION_RULES AND LEGACY_RESPONSE_FORMAT WERE NOT TOUCHED. Rule 3 concerns a
 * LEGACY value, and was still written into the enriched block as a paragraph that DEFERS to
 * the original rule (the pattern BROKER vs LISTING BROKER already uses). It may only narrow
 * sent_datetime toward empty; it does not restate WHERE the value is read from — the
 * OUTERMOST / EARLIEST "Sent:" line stays authoritative — and it names none of the other
 * claim values. Editing the legacy block would have broken both protection 1 and the
 * one-line rollback in protection 3 above.
 *
 * ⚠ THE REQUEST BODY IS NO LONGER CONSTANT ACROSS CALLOUTS. buildRequestBody now injects a
 * dynamic REFERENCE DATE line (yyyy-MM-dd, GMT, evaluated per callout) between the
 * instruction and the email text — see referenceDateLine() for the hazard it carries and
 * the guard sentence that contains it. No signature, caller, parser, model, temperature,
 * token or cap change accompanies it.
 *
 * @see LLMExtractionParser.cls (turns the response into typed values; never throws)
 * @see LLMExtractionResult.cls / PropertyExtraction.cls (the return types)
 * @see ExtractAddressQueueable.cls (the only caller; owns the degrade path)
 * @see .claude/skills/sf-integration (callout-patterns, named-credentials-guide)
 * @see force-app/main/default/namedCredentials/OpenAI_API.namedCredential-meta.xml
 * @see force-app/main/default/externalCredentials/OpenAI_Credential.externalCredential-meta.xml
 */
public with sharing class LLMExtractionCalloutService {

    /** Named-Credential-backed chat-completions endpoint. Only this line changes when
     *  the callout is later re-homed onto an ASB LLM-extraction spoke. */
    private static final String ENDPOINT = 'callout:OpenAI_API/v1/chat/completions';

    /** Vision-capable, low-cost model used for the extraction. UNCHANGED by the enrichment
     *  on purpose — see protection 2 in the class header. */
    private static final String MODEL = 'gpt-4o-mini';

    /** Callout timeout in milliseconds. Raised from 30s: a ten-property extraction is
     *  materially slower than a four-key one, and a timeout costs the email its address.
     *  The platform's per-callout ceiling is 120s, so this is comfortably inside it. */
    private static final Integer TIMEOUT_MS = 60000;

    /** Upper bound on the model's response tokens. 512 -> 4096 (C-14) — see the class
     *  header's RESPONSE SIZING note. Well inside gpt-4o-mini's 16k output ceiling. */
    private static final Integer MAX_TOKENS = 4096;

    /**
     * Ceiling on the email text sent to the model (C-15). Raw_Body__c can hold 131,072
     * characters (~33k tokens) and the tail of a long forward is quoted history that adds
     * cost and latency without adding facts.
     *
     * ⚠ This clip touches the LEGACY four values, so it is only safe because the outermost
     * "From:" / "Sent:" lines of a forward sit at the TOP of the body — which is exactly
     * what the regression fixtures assert (ExtractionRegressionFixtureTest).
     */
    private static final Integer MAX_INPUT_CHARS = 40000;

    /** Property objects the model is asked to return at most. MUST stay in step with
     *  ExtractAddressQueueable.MAX_PROPERTIES — the prompt cap bounds the RESPONSE, the
     *  queueable cap bounds the WORK, and a mismatch merely wastes tokens. */
    private static final Integer MAX_PROPERTIES_IN_PROMPT = 10;

    /**
     * 🔴 THE PRE-ENRICHMENT INSTRUCTION, VERBATIM. Every sentence below shipped in
     * production and produced the `broker_email` / `property_address` values the existing
     * Property_Registry__c rows are keyed on. It is reproduced character for character,
     * minus only its final response-format sentence (retained separately as
     * LEGACY_RESPONSE_FORMAT, because "respond with exactly these four keys" is
     * incompatible with the enriched schema). DO NOT EDIT.
     *
     * @TestVisible so ExtractionRegressionFixtureTest can pin the exact text: an accidental
     * edit to the claim engine's prompt would otherwise be invisible until a broker lost a
     * property.
     */
    @TestVisible
    private static final String LEGACY_EXTRACTION_RULES =
        'You are extracting fields from a FORWARDED email. The content below is the ' +
        'body of a broker email that an internal DPEG user forwarded on. ' +
        'The OUTERMOST / EARLIEST "From:" line identifies the ORIGINAL BROKER — take ' +
        'broker_name and broker_email from that line. The "To:" line identifies the ' +
        'internal person who forwarded the email — IGNORE it; never use it for the ' +
        'broker. property_address is any property address found anywhere in the body. ' +
        'sent_datetime is the OUTERMOST / EARLIEST "Sent:" line, converted to UTC and ' +
        'formatted as "yyyy-MM-dd HH:mm:ss". If a value is absent, use an empty ' +
        'string.';

    /**
     * The retired tail of the original instruction, kept ONLY as the rollback lever
     * described in the class header. Nothing references it on the enriched path; the
     * regression test asserts it still composes back into the original prompt verbatim.
     */
    @TestVisible
    private static final String LEGACY_RESPONSE_FORMAT =
        ' Respond ONLY with a single JSON object of exactly these keys and no ' +
        'other text: {"broker_name": "", "broker_email": "", "property_address": "", ' +
        '"sent_datetime": ""}.';

    /**
     * The enrichment layered ON TOP of the legacy rules. It never restates or contradicts
     * them — where the two could disagree it defers explicitly, because the four legacy
     * values are the claim engine's input and their behaviour must not drift.
     */
    private static final String ENRICHED_EXTRACTION_RULES =
        '\n\n=== END OF THE ORIGINAL RULES. THEY REMAIN AUTHORITATIVE FOR broker_name, ' +
        'broker_email, property_address AND sent_datetime. ===\n\n' +
        'In addition to those four values, extract the full deal-screening field set and ' +
        'classify the email.\n\n' +
        '- property_name is the marketing or brand name of the property — typically the ' +
        'subject line, the first sentence of the body, or the headline of an attached ' +
        'flyer image. It is DISTINCT from property_address: in "Orion ParkView, 1400 ' +
        'Royal Lane, Dallas TX", property_name is "Orion ParkView" and property_address ' +
        'is "1400 Royal Lane, Dallas TX". If the email gives the property no name, leave ' +
        'property_name empty; never invent one.\n\n' +
        'MULTIPLE PROPERTIES: one email may pitch several properties. Return ONE object in ' +
        '"properties" per DISTINCT property, and take its "property_address" using the ' +
        'original rule above. Return at most ' + MAX_PROPERTIES_IN_PROMPT + ' property ' +
        'objects; if the email lists more, return the first ' + MAX_PROPERTIES_IN_PROMPT +
        ' and describe the remainder in "deal_summary".\n\n' +
        'BROKER vs LISTING BROKER: broker_name / broker_email are the sender of the ' +
        'original email, per the rules above. Some emails are blast or marketing sends ' +
        'where the sender is NOT the listing broker; put that person in ' +
        'listing_broker_name / listing_broker_email. NEVER put the listing broker into ' +
        'broker_name or broker_email.\n\n' +
        'sent_datetime WHEN NO DATE IS STATED: the rules above remain authoritative for ' +
        'which line sent_datetime is taken from. This adds only one restriction on ' +
        'whether it may be filled at all. It must come from explicit content — a "Sent:" ' +
        'or "Date:" header line, or a date written in the body. If the email states no ' +
        'send date, return an EMPTY STRING for sent_datetime. Never infer it from ' +
        'knowledge of the property, the campaign or the listing.\n\n' +
        'ANTI-HALLUCINATION RULES (these matter more than completeness):\n' +
        '- Use null for any value the email does not state. Never guess and never infer.\n' +
        '- NEVER derive one number from another. Do not compute price from cap rate and ' +
        'NOI, do not compute NOI from price and cap rate, and do not convert square feet ' +
        'to acres or acres to square feet. Report only what is written.\n' +
        '- lot_size_acres ONLY if the email states acres. lot_size_sf ONLY if it states ' +
        'square feet. Never fill both from a single figure.\n' +
        '- Numbers must be plain numerics with no symbols, units or separators: write ' +
        '7100000, not "$7.1M".\n' +
        '- cap_rate and occupancy_pct are PERCENTAGE numbers: 6.75 means 6.75 percent and ' +
        '88 means 88 percent. Never return a fraction such as 0.0675 or 0.88.\n' +
        '- year_built and year_renovated: return the year exactly as written ("88/22" ' +
        'means year_built 88 and year_renovated 22); do not expand it.\n' +
        '- If the email quotes both a reported and an adjusted or pro-forma NOI, put the ' +
        'ADJUSTED figure in "noi" and mention BOTH in "deal_summary".\n' +
        '- If a price is quoted as a range, use guidance_price_low and guidance_price_high ' +
        'and leave guidance_price null. If a single asking price is quoted, use ' +
        'guidance_price and leave the range null.\n' +
        '- unit_count is apartment units, or hotel keys for a hospitality asset.\n' +
        '- Relative deadlines are resolved against sent_datetime: "offers due today" means ' +
        'the date of sent_datetime, or the date of the anchor A defined below when the ' +
        'email states no send date. For an auction DATE RANGE use the START date. ' +
        'offer_due_date is formatted "yyyy-MM-dd". A date written WITHOUT A YEAR takes ' +
        'its year from the anchor date A, where A is the year-bearing "Sent:" or "Date:" ' +
        'line in the email when one exists, and otherwise the supplied REFERENCE DATE. ' +
        'Give such a date the year of A; give it the year AFTER A only if it would ' +
        'otherwise fall more than 30 days before A. Never roll a year backward, and never ' +
        'use knowledge of when a real-world campaign or listing happened.\n' +
        '- asset_type, deal_type and sale_process MUST be one of the listed values or ' +
        'null. Never invent a value.\n' +
        '- deal_summary is at most 800 characters.\n\n' +
        'CLASSIFICATION: email_category is one of acquisition_deal, call_for_offers, ' +
        'reply, system_notification, newsletter, out_of_office, other. ' +
        'is_acquisition_related is true when the email offers, markets or discusses a ' +
        'commercial real-estate property for potential acquisition, and false for ' +
        'automated notifications, forwarding confirmations, out-of-office replies and ' +
        'newsletters. confidence is a number from 0 to 1 expressing how certain you are ' +
        'of is_acquisition_related.\n\n' +
        'Respond ONLY with a single JSON object in exactly this shape, with no other ' +
        'text:\n' +
        '{"email_category": "other", "is_acquisition_related": true, "confidence": 0.0, ' +
        '"broker_name": "", "broker_email": "", "broker_company": "", "broker_phone": "", ' +
        '"broker_mobile": "", "broker_title": "", "listing_broker_name": "", ' +
        '"listing_broker_email": "", "sent_datetime": "", "deal_summary": "", ' +
        '"properties": [{"property_name": "", "property_address": "", "asset_type": null, ' +
        '"deal_type": null, "sale_process": null, "guidance_price": null, ' +
        '"guidance_price_low": null, "guidance_price_high": null, "cap_rate": null, ' +
        '"noi": null, "occupancy_pct": null, "building_sf": null, "lot_size_acres": null, ' +
        '"lot_size_sf": null, "unit_count": null, "year_built": null, ' +
        '"year_renovated": null, "walt_years": null, "adr": null, "zoning": "", ' +
        '"seller_entity": "", "deal_room_link": "", "offer_due_date": null}]}\n\n' +
        'asset_type must be one of: Retail, C-Store, Land, Industrial, Office, ' +
        'Multifamily, Storage, Mixed-Use, Hospitality, Medical Office.\n' +
        'deal_type must be one of: Land, Commercial.\n' +
        'sale_process must be one of: Off-Market, On-Market Listing, Call for Offers, ' +
        'Auction.';

    /**
     * THE prompt — ONE constant, which is what makes the rollback described in the class
     * header a single-line change.
     */
    private static final String EXTRACTION_INSTRUCTION =
        LEGACY_EXTRACTION_RULES + ENRICHED_EXTRACTION_RULES;

    /**
     * Extract the broker identity, email classification and per-property deal fields from a
     * forwarded broker email.
     *
     * The user message content is built as a list of parts. When `imageBase64` is
     * non-blank an image_url part (a `data:<mime>;base64,<data>` URL) is added first,
     * then the text part carrying the extraction instruction plus `textContent`; when
     * there is no image the content is just the text part. No Authorization header is
     * set here — the platform injects it from the OpenAI_Credential external credential.
     *
     * The response is parsed by LLMExtractionParser, which NEVER throws: an unexpected
     * response shape yields an empty-but-valid result still carrying the raw content, so
     * the D3 tier-1 store is written either way.
     *
     * @param textContent   The forwarded email body text; may be blank. Clipped to
     *                      MAX_INPUT_CHARS before sending.
     * @param imageBase64   Base64 of an optional inline image (e.g. a screenshot of
     *                      the forwarded email); blank/null to send text only.
     * @param imageMimeType MIME type for the image data URL (e.g. 'image/png'); used
     *                      only when `imageBase64` is non-blank.
     * @return The typed extraction. `rawJson` carries the model's content (code fences
     *         removed) for Inbound_Email_Staging__c.Extracted_JSON__c.
     * @throws CalloutException when the OpenAI endpoint returns a non-200 status. The
     *         caller DEGRADES on this rather than failing — an outage is a missing optional
     *         input, not a pipeline failure.
     * @throws JSONException when the OpenAI ENVELOPE itself is unparseable. The caller
     *         degrades on this too (C-14) — see ExtractAddressQueueable's degrade block.
     * @example
     * LLMExtractionResult extraction =
     *     new LLMExtractionCalloutService().extract(emailBody, null, null);
     */
    public LLMExtractionResult extract(String textContent, String imageBase64, String imageMimeType) {
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
        return LLMExtractionParser.parse(stripCodeFences(rawContent));
    }

    /**
     * Serialize the chat-completions request body: model, temperature 0 (deterministic),
     * max_tokens, JSON mode, and one user message whose content is the ordered parts list.
     * JSON.serialize handles all escaping of the embedded instruction/email text.
     *
     * `response_format: {"type": "json_object"}` is the single strongest mitigation against
     * the truncation failure described in the class header: OpenAI JSON mode guarantees the
     * content is syntactically valid JSON, which also demotes stripCodeFences from
     * load-bearing to belt-and-braces.
     *
     * ⚠ A dynamic REFERENCE DATE line sits between the instruction and the email text
     * (D4, 2026-08-02) — see referenceDateLine(). It is the only part of this body that
     * is not constant across callouts.
     *
     * @param textContent   Forwarded email body (may be blank); clipped to MAX_INPUT_CHARS.
     * @param imageBase64   Optional base64 image; when non-blank, added as the first
     *                      content part.
     * @param imageMimeType MIME type for the image data URL.
     * @return The serialized JSON request body.
     */
    private String buildRequestBody(String textContent, String imageBase64, String imageMimeType) {
        String clippedText = InboundEmailFieldUtil.clip(textContent, MAX_INPUT_CHARS);
        Map<String, Object> textPart = new Map<String, Object>{
            'type' => 'text',
            'text' => EXTRACTION_INSTRUCTION + '\n\n' + referenceDateLine() + '\n\n' +
                (clippedText == null ? '' : clippedText)
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
            'response_format' => new Map<String, Object>{ 'type' => 'json_object' },
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => content }
            }
        };
        return JSON.serialize(body);
    }

    /**
     * The labelled REFERENCE DATE line injected between the instruction and the email
     * text (D4, 2026-08-02).
     *
     * WHY IT EXISTS: the year-less-date rule in the enriched block anchors on the
     * year-bearing "Sent:"/"Date:" line of the forward — but some emails carry no date
     * anywhere (the Orion case). Without an injected anchor the rule is un-actionable for
     * exactly those emails, and a legitimately extractable deadline would be dropped.
     *
     * ⚠ THE GUARD SENTENCE IS THE POINT, NOT DECORATION. Handing a date to a model that
     * is also being asked for `sent_datetime` creates one obvious hazard: it harvests the
     * reference date as the send time — reintroducing the fabricated timestamp this whole
     * change exists to remove, and in a form that looks plausible. The line therefore says
     * outright that it is context only and is never sent_datetime, and that is a named UAT
     * check (case B: `sent_datetime` must still come back empty).
     *
     * AND IF THE GUARD IS IGNORED, THE FORMAT FAILS SAFE — the no-time-component choice is
     * a second line of defence, not only an anti-harvest hint. A harvested `2026-08-02`
     * reaches ExtractAddressQueueable.parseSentDatetime, whose Datetime.valueOfGmt REQUIRES
     * `yyyy-MM-dd HH:mm:ss` and REJECTS a date-only string (verified in usman-dpeg:
     * `System.TypeException: Invalid date/time: 2026-08-02`). Its catch then falls back to
     * Datetime.now() — which for a just-received email is the CORRECT value. So the harvest
     * hazard degrades from plausible-looking fabrication to harmless. Emitting a full
     * timestamp here would forfeit that property.
     *
     * FORMAT: `yyyy-MM-dd` in GMT — ISO, unambiguous, no locale and no time component to
     * be mistaken for a timestamp. Evaluated at RUNTIME, once per callout, so the request
     * body is not constant across calls; `LLMExtractionCalloutServiceTest` asserts on
     * `contains` and an UPPER BOUND on length (`< 80000`), both of which are unaffected.
     *
     * GMT IS DELIBERATE AND MUST NOT BE "FIXED" TO ORG TIME. An email arriving near
     * midnight org-time (say 23:30) gets a REFERENCE DATE one day ahead of the local date.
     * That can only change an outcome when a year-less date sits exactly on the 30-day
     * boundary of the roll-forward rule, and it can only affect offer_due_date — a
     * screening field, never a claim key. Formatting in org time instead would buy that
     * negligible edge at the price of locale dependence and a Setup-changeable timezone
     * silently altering prompt behaviour.
     *
     * @return The labelled reference-date line.
     */
    private static String referenceDateLine() {
        return 'REFERENCE DATE (the date this email was received): ' +
            Datetime.now().formatGmt('yyyy-MM-dd') +
            '. Use it ONLY to resolve a date written without a year. It is NOT a value ' +
            'to extract; it is never sent_datetime.';
    }

    /**
     * Pull `choices[0].message.content` (the model's text) out of the raw response
     * body. Returns an empty string if the response shape is unexpected rather than
     * dereferencing a missing node.
     *
     * @param responseBody The raw OpenAI response JSON.
     * @return The assistant message content, or '' when it cannot be located.
     * @throws JSONException when `responseBody` is not valid JSON at all.
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
     * Strip a leading ```json / ``` fence and a trailing ``` fence that models often
     * wrap JSON in, leaving the bare JSON object. Belt-and-braces since JSON mode was
     * enabled, and retained because it also guarantees Extracted_JSON__c holds parseable
     * JSON rather than a fenced blob.
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
}
