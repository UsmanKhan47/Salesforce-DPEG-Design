/**
 * Test class for LLMExtractionCalloutService. All scenarios mock the single
 * callout boundary via LLMExtractionCalloutMock (Test.setMock) per
 * ARCHITECTURE.md §2 — never a real callout.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SECTION "PROMPT RESOLUTION" (T1-T4) IS THE REGRESSION NET FOR A LIVE
 *    P0. READ THIS BEFORE EDITING, DELETING OR "IMPROVING" ANY OF THOSE FOUR TESTS.
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * THE DEFECT. `Broker_Protection_Config__mdt.Extraction_Prompt__c` is a LongTextArea, and
 * `getInstance()`/`getAll()` SILENTLY CLIP long text to 255 characters. Measured on
 * `usman-dpeg` at API 67.0 on 2026-08-31: getInstance 255 / SOQL 20,596 / identical = false.
 * The 255-character head contains no `json`, OpenAI refuses `response_format: json_object`
 * without it, `ExtractAddressQueueable.extractOrDegrade` swallows the CalloutException BY
 * DESIGN, and the pipeline reported SUCCESS while extracting nothing at all.
 *
 * 🔴 WHY THIS FILE IS WHERE THE GUARD BELONGS. Before 2026-08-31 this class contained ZERO
 * assertions about the prompt's length or content — verified by grep — which is precisely how
 * the defect survived. The bug lived in the gap between two fakes: `HttpCalloutMock` means
 * OpenAI's own precheck never runs, and `overrideForTest(...)` injects an IN-MEMORY sObject
 * whose field is not truncated. Neither fake was wrong; nothing joined them.
 *
 * ⚠ COMPATIBLE WITH `ExtractionRegressionFixtureTest`'s "DO NOT RESTORE" BANNER (lines
 * ~326-331), AND THAT IS NOT AN OVERSIGHT. That banner forbids re-pinning the prompt TEXT,
 * because doing so turns every legitimate Setup prompt edit into a required code change —
 * undoing the configurability WS5 was asked to deliver. T1-T5 assert STRUCTURAL PROPERTIES
 * (T1-T4: length > 255, contains the token `json`, which of two prompts was sent. T5: no
 * response-schema key is orphaned OUTSIDE the schema regions — region exclusion, not a mention
 * count; see its own header), never verbatim bytes. A future reader
 * must not "strengthen" them into a byte pin, and must not delete them as a banner violation.
 * Both mistakes are available; this paragraph exists to prevent them.
 *
 * ⚠ ORG-STATE INDEPENDENT BY CONSTRUCTION. Every one of T1-T4 drives through
 * `BrokerProtectionConfig.overrideForTest(...)`, so they pass whether the org's `Default`
 * record is absent, present-and-blank (its deliberate state on 2026-08-31), or populated. CMDT
 * rows ARE visible to SOQL inside tests, so a test that did NOT inject would read live org
 * config and go green or red depending on when the loader was last run. ⚠ T5 IS THE EXCEPTION
 * AND DOES NOT INJECT: it reads `shippedPrompt()` — the compile-time constant — directly, so it
 * is org-state independent for a different reason (it never consults the org at all), and it
 * deliberately says nothing about an admin-edited Setup prompt. Its own header states that
 * limitation; do not "fix" it by routing it through overrideForTest.
 *
 * ═══ 🔴 NO 251-RECORD BULK TEST, AND THE EXEMPTION IS RECORDED SO REVIEW DOES NOT DEMAND ONE ═══
 * Per `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton carve-out, which already
 * names this class: `extract()` performs EXACTLY ONE callout per queueable execution. Prompt
 * resolution is a single-record CMDT read behind a per-transaction cache; there is no trigger,
 * no batch chunk and no loop, so 251 records would exercise zero additional code — and a test
 * CANNOT insert `__mdt` rows by DML at all, so the volume is not merely pointless but
 * impossible to construct. The rule's "no SOQL/DML in loops" half is untouched.
 *
 * @see BrokerProtectionConfigSelector.cls (the SOQL read that fixes the root cause)
 * @see BrokerProtectionConfigSelectorTest.cls (the selector's own contract test)
 * @author Unit Testing Agent
 */
@isTest
private class LLMExtractionCalloutServiceTest {

    /**
     * The exact composed user text this callout sent — prompt + reference-date line + email
     * body — pulled out of the request the mock captured.
     *
     * Deserializing rather than substring-matching the serialized JSON is deliberate: the
     * prompt contains quotes, braces and newlines that JSON.serialize escapes, so a
     * `sentBody.contains(prompt)` check would compare an unescaped needle against an escaped
     * haystack and fail for reasons that have nothing to do with the assertion.
     */
    private static String sentUserText(LLMExtractionCalloutMock mock) {
        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        List<Object> messages = (List<Object>) body.get('messages');
        Map<String, Object> message = (Map<String, Object>) messages[0];
        List<Object> content = (List<Object>) message.get('content');
        // The text part is always LAST; an image_url part, when present, is prepended.
        Map<String, Object> textPart = (Map<String, Object>) content[content.size() - 1];
        return (String) textPart.get('text');
    }

    private static LLMExtractionCalloutMock armedMock() {
        LLMExtractionCalloutMock mock =
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fullFields(), false));
        Test.setMock(HttpCalloutMock.class, mock);
        return mock;
    }

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

    // ═════════════════════════════════════════════════════════════════════════════════════
    // PROMPT RESOLUTION (T1-T4) and SCHEMA-KEY REINFORCEMENT (T5) — the 2026-08-31 P0 regression net. See the class header for
    // the defect, and for why these assert PROPERTIES and never verbatim prompt bytes.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * T1 — WHATEVER IS SENT MUST BE A USABLE PROMPT: longer than 255 characters and carrying
     * the token `json`.
     *
     * With no override configured, the shipped constant is what goes out. The two assertions
     * are the entire regression net for that constant: truncation is invisible to every other
     * check in this repo, and an edit that dropped the word `json` from the instruction would
     * make OpenAI refuse `response_format: json_object` on EVERY inbound email while every
     * existing test here stayed green (they all use HttpCalloutMock, so OpenAI's precheck never
     * runs).
     *
     * The `startsWith` assertion is what stops this being a statement about a constant nobody
     * sent — it ties the property to the request that actually left the class.
     */
    @isTest
    static void resolvedPrompt_isLongerThan255AndCarriesTheJsonToken() {
        BrokerProtectionConfig.overrideForTest(null);
        LLMExtractionCalloutMock mock = armedMock();

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        String shipped = LLMExtractionCalloutService.shippedPrompt();
        Assert.isTrue(sentUserText(mock).startsWith(shipped),
            'With no override configured, the shipped prompt must be the one actually sent');
        Assert.isTrue(shipped.length() > 255,
            'The prompt sent must exceed 255 characters. Exactly 255 is the signature of the '
            + 'getInstance()/getAll() LongTextArea truncation that caused the 2026-08-31 P0');
        Assert.isTrue(shipped.containsIgnoreCase('json'),
            'The prompt sent must contain the token \'json\'. OpenAI refuses response_format of '
            + 'type json_object without it, and ExtractAddressQueueable degrades that refusal '
            + 'silently — the pipeline reports SUCCESS while extracting nothing');
        Assert.isNull(LLMExtractionCalloutService.promptRejectionLogged,
            'No override was configured, so nothing may be REJECTED — absence of an override is '
            + 'the normal fresh-org state, not a misconfiguration');
    }

    /**
     * T2 — THE ACTUAL P0, REPRODUCED. A 255-character override is served as a truncation
     * artifact: the shipped prompt is sent instead, and the rejection is logged as TRUNCATED.
     *
     * The fixture is `shippedPrompt().substring(0, 255)` — the EXACT value the org served on
     * 2026-08-31, not an invented string. It fails both usability tests (255 characters, and no
     * `json` in that head), which is why the ORDER of the two checks matters and is asserted:
     * "truncated" is the root-cause diagnosis and must not be reported as "your prompt is
     * missing a word", which would send the reader to rewrite a prompt that is in fact fine and
     * merely clipped.
     */
    @isTest
    static void truncatedOverride_fallsBackToTheShippedPrompt_andLogsTruncation() {
        String truncatedHead = LLMExtractionCalloutService.shippedPrompt().substring(0, 255);
        Assert.isFalse(truncatedHead.containsIgnoreCase('json'),
            'FIXTURE PRECONDITION: the 255-char head must not contain \'json\' — that is what '
            + 'made the live defect fatal rather than merely degraded');

        BrokerProtectionConfig.overrideForTest(
            new Broker_Protection_Config__mdt(Extraction_Prompt__c = truncatedHead));
        LLMExtractionCalloutMock mock = armedMock();

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        String sent = sentUserText(mock);
        Assert.isTrue(sent.startsWith(LLMExtractionCalloutService.shippedPrompt()),
            'A truncated override must be discarded in favour of the shipped prompt');
        Assert.isFalse(sent.startsWith(truncatedHead + '\n\n'),
            'The truncated value must not be what was sent — this is the P0');
        Assert.areEqual(
            LLMExtractionCalloutService.PromptRejectionReason.TRUNCATED_AT_OR_BELOW_255,
            LLMExtractionCalloutService.promptRejectionLogged,
            'A value at or below 255 characters must be diagnosed as TRUNCATED, not as a missing '
            + 'json token — they are different diagnoses and must not share one message');
    }

    /**
     * T2b — the OTHER rejection branch, kept separate because the guard logs once per
     * transaction and the two reasons must stay distinguishable.
     *
     * A long, well-formed, clearly untruncated prompt that simply never says `json`. This is
     * the case the length floor cannot catch and the `json` test exists for: an admin writes a
     * perfectly reasonable instruction in Setup and every extraction silently dies, because
     * `response_format: json_object` is set in code they cannot see.
     */
    @isTest
    static void jsonlessOverride_fallsBackToTheShippedPrompt_andLogsMissingToken() {
        String noJson = 'Extract the broker name, the broker email address and the property '
            + 'address from the forwarded message below, and answer using the object notation '
            + 'described in the schema. ' + ''.rightPad(400, 'y');
        Assert.isTrue(noJson.length() > 255, 'FIXTURE PRECONDITION: must clear the length floor');
        Assert.isFalse(noJson.containsIgnoreCase('json'),
            'FIXTURE PRECONDITION: must fail ONLY the json-token test, so the branch is isolated');

        BrokerProtectionConfig.overrideForTest(
            new Broker_Protection_Config__mdt(Extraction_Prompt__c = noJson));
        LLMExtractionCalloutMock mock = armedMock();

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.isTrue(sentUserText(mock).startsWith(LLMExtractionCalloutService.shippedPrompt()),
            'An override that cannot satisfy response_format json_object must never be sent');
        Assert.areEqual(
            LLMExtractionCalloutService.PromptRejectionReason.MISSING_JSON_TOKEN,
            LLMExtractionCalloutService.promptRejectionLogged,
            'A long prompt lacking the json token is a PROMPT defect, not a truncated read');
    }

    /**
     * T3 — A BLANK OVERRIDE IS "NO OVERRIDE", AND IT IS NOT AN ERROR.
     *
     * The documented contract (BrokerProtectionConfig.extractionPromptOverride, and
     * resolvePrompt's own Javadoc): an admin who CLEARS the field in Setup gets the shipped
     * prompt back, not a callout with no instructions. This is also the org's live state on
     * 2026-08-31 — a deliberate zero-code unblock — so it is not a hypothetical path.
     *
     * 🔴 THE `promptRejectionLogged` ASSERTION IS THE POINT, NOT DECORATION. It is what proves
     * the new length floor does not mis-fire on the blank path. An implementation that tested
     * `length() <= 255` BEFORE the null/blank check would log TRUNCATED for an empty string —
     * still functionally correct, but it would fill the log with a false root-cause diagnosis
     * and send an operator hunting a truncation that never happened.
     */
    @isTest
    static void blankOverride_yieldsTheShippedPrompt_withoutLoggingARejection() {
        String shipped = LLMExtractionCalloutService.shippedPrompt();

        BrokerProtectionConfig.overrideForTest(
            new Broker_Protection_Config__mdt(Extraction_Prompt__c = null));
        LLMExtractionCalloutMock nullMock = armedMock();

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);

        BrokerProtectionConfig.overrideForTest(
            new Broker_Protection_Config__mdt(Extraction_Prompt__c = ''));
        LLMExtractionCalloutMock emptyMock = armedMock();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        Assert.isTrue(sentUserText(nullMock).startsWith(shipped),
            'A null Extraction_Prompt__c means "no override" and must yield the shipped prompt');
        Assert.isTrue(sentUserText(emptyMock).startsWith(shipped),
            'An empty-string Extraction_Prompt__c is equally "no override" — an admin who clears '
            + 'the field in Setup must not get a callout with no instructions');
        Assert.isNull(LLMExtractionCalloutService.promptRejectionLogged,
            'Blank is a SUPPORTED state, not a misconfiguration. Logging a rejection here would '
            + 'report a truncation that never happened');
    }

    /**
     * T4 — 🔴 THE ANTI-VACUITY CONTROL. A valid, full-length, json-bearing Setup override IS
     * used, and it is NOT the shipped prompt.
     *
     * WITHOUT THIS TEST, T1-T3 ARE ALL SATISFIED BY A GUARD THAT REJECTS EVERY OVERRIDE — i.e.
     * by the configurability feature being completely dead, with a green suite. T4 is what makes
     * the other three mean anything. It must not be deleted, weakened, or merged into T1.
     *
     * The override is deliberately unlike the shipped prompt (short-ish but over the floor, and
     * differently worded) so `startsWith` can discriminate in both directions.
     */
    @isTest
    static void validOverride_isActuallySent_andIsNotTheShippedPrompt() {
        String custom = 'SETUP-CONFIGURED TEST PROMPT. Respond only with a single json object '
            + 'containing broker_name, broker_email and property_address. ' + ''.rightPad(300, 'z');
        Assert.isTrue(custom.length() > 255, 'FIXTURE PRECONDITION: must clear the length floor');
        Assert.isTrue(custom.containsIgnoreCase('json'),
            'FIXTURE PRECONDITION: must carry the json token, or this test would only re-prove T2b');

        BrokerProtectionConfig.overrideForTest(
            new Broker_Protection_Config__mdt(Extraction_Prompt__c = custom));
        LLMExtractionCalloutMock mock = armedMock();

        Test.startTest();
        new LLMExtractionCalloutService().extract('body text', null, null);
        Test.stopTest();

        String sent = sentUserText(mock);
        Assert.isTrue(sent.startsWith(custom),
            'A usable Setup override MUST be the prompt that is sent — otherwise the whole '
            + 'configurability feature is dead and T1-T3 pass vacuously');
        Assert.isFalse(sent.startsWith(LLMExtractionCalloutService.shippedPrompt()),
            'The shipped constant must NOT have been substituted for a perfectly usable override');
        Assert.isNull(LLMExtractionCalloutService.promptRejectionLogged,
            'A usable override must not be rejected, and must not log an ERROR');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SCHEMA-KEY REINFORCEMENT (T5) — added 2026-08-31 with the definition pass.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * The blanket closed-set constraint T5 EXCLUDES. Upper-case `MUST` and no trailing colon —
     * that is what keeps it distinguishable from {@link #ENUM_MARKER} without a regex.
     */
    private static final String BLANKET_MARKER = 'MUST be one of the listed values';

    /**
     * The enum / allowed-value lines T5 EXCLUDES. The LEADING SPACE is load-bearing twice: it
     * makes `substringBefore` yield the bare key, and it stops this marker matching inside the
     * blanket line (which reads "MUST be one of the listed values", never "must be one of:").
     */
    private static final String ENUM_MARKER = ' must be one of:';

    /**
     * T5 — 🔴 THE STRUCTURAL INVARIANT: EVERY KEY THE RESPONSE TEMPLATE SHOWS THE MODEL MUST
     * CARRY A RULE SOMEWHERE ELSE IN THE PROMPT.
     *
     * THE DEFECT CLASS. A key that appears ONLY inside the JSON response shape is a slot the
     * model is shown and never told the meaning of. Nine keys were in exactly that state until
     * 2026-08-31 — `building_sf`, `broker_phone`, `broker_mobile`, `broker_title`, `walt_years`,
     * `adr`, `zoning`, `seller_entity`, `deal_room_link` — and `building_sf`'s slot was worse
     * than undefined: the only rule that fired on the phrase "square feet" routed it to
     * `lot_size_sf` and then forbade filling both. This test asserts the GENERAL FORM of that
     * bug, so it fixes the class and not the instance: it would have gone red the day
     * `building_sf` was added to the schema with no rule, and it goes red the next time anyone
     * adds a key to the template and stops there.
     *
     * ═══ 🔴 WHY THIS IS REGION EXCLUSION AND NOT A MENTION COUNT — MEASURED, 2026-08-31 ═══
     * The first version of this test asserted each template key was MENTIONED elsewhere. That is
     * WEAKER THAN THE DEFECT CLASS IT WAS WRITTEN FOR, and `deal_type` proved it: it PASSED that
     * test while being effectively template-only, because its only two non-template mentions are
     * the blanket line ("asset_type, deal_type, sale_process and listing_status MUST be one of
     * the listed values or null") and the enum line ("deal_type must be one of: Land, Retail").
     * NEITHER SAYS WHAT THE VALUES MEAN. A mention is not a definition, and the live consequence
     * was a Lead converting to an Opportunity with a null `Deal_Type__c` and therefore NO RECORD
     * TYPE at all.
     *
     * 🔴 A MENTION-COUNT THRESHOLD IS THE OBVIOUS IMPLEMENTATION AND IT IS WRONG IN BOTH
     * DIRECTIONS. Measured against the shipped prompt on 2026-08-31: `walt_years`,
     * `seller_entity`, `deal_room_link`, `broker_title` and `occupancy_pct` each carry exactly
     * TWO mentions (template + their one real rule) and are all fine, while the BROKEN
     * `deal_type` carries THREE (template + blanket + enum). A `&lt;= 2` threshold would flag five
     * healthy keys and miss the only sick one. Do not reintroduce one.
     *
     * WHAT IS EXCLUDED, AND WHY EACH REGION IS NOT A DEFINITION:
     *   (a) the JSON response template — the slot itself, which is what "orphaned" means;
     *   (b) the blanket closed-set line — it says the value must come from a list, never what
     *       any value on that list MEANS;
     *   (c) the `<key> must be one of: ...` enum lines — they enumerate the tokens the parser
     *       will accept. A closed set is a VALIDATION rule; the model still needs to be told
     *       which member applies to the email in front of it.
     * A key survives only if it appears in the REMAINDER — i.e. in prose that tells the model
     * something about the value. That correctly passes `walt_years` and correctly fails
     * `deal_type`.
     *
     * ═══ 🔴 THE FOUR ANTI-VACUITY PRECONDITIONS. A STRICT TEST THAT SILENTLY EXCLUDES
     *     EVERYTHING PASSES FOR THE WRONG REASON, SO EVERY EXCLUSION PROVES ITSELF ═══
     *   1. EVERY REGION WAS ACTUALLY FOUND, AND EXACTLY ONCE. `removeExactlyOnce` refuses an
     *      empty slice and asserts the length delta, so a regex that stopped matching, or that
     *      matched twice, fails HERE rather than quietly leaving the region in the remainder.
     *   2. EVERY KEY THE BLANKET LINE NAMES HAS AN ENUM LINE THAT WAS REMOVED. This is the one
     *      that closes the real hole: if the enum marker ever stops matching `deal_type must be
     *      one of:`, that line stays in the remainder and `deal_type` passes VACUOUSLY. The
     *      required set is DERIVED FROM THE BLANKET LINE ITSELF — no hand-maintained list, so it
     *      cannot decay. ⚠ IT IS A BLUNT DERIVATION, STATED SO NOBODY OVER-TRUSTS IT: the
     *      matcher is `[a-z][a-z0-9]*_[a-z0-9_]*` against the blanket LINE, so it harvests ANY
     *      snake_case token on it — a fifth closed-set key does extend the check automatically,
     *      but so does an unrelated snake_case word introduced by a reword, which then demands an
     *      enum line that was never meant to exist and turns this precondition RED. That is the
     *      right failure direction (loud, at the fixture, naming the token) and it is why this is
     *      a PRECONDITION rather than an assertion about the prompt — but it is not the clean
     *      "adding a key extends the check" the earlier wording implied.
     *   3. THE REMAINDER IS STILL THE BULK OF THE PROMPT. A runaway greedy match would otherwise
     *      exclude nearly everything and report every key as orphaned — loud, but for a reason
     *      the failure message would not explain.
     *   4. THE KEY REGEX STILL MATCHES SEVERAL DOZEN KEYS (the pre-existing floor).
     *
     * ✅ PROVEN NON-VACUOUS BY MUTATION, NOT BY INSPECTION. The mutation is "delete the
     * `deal_type` definition bullet from the ANTI-HALLUCINATION list": with it absent this test
     * FAILS naming `deal_type`, with it present it passes, and both halves were run against
     * `usman-dpeg` at API 67.0 on 2026-08-31 (check-only, RunSpecifiedTests). The FIRST half
     * is the real evidence — it was run BEFORE the bullet was written, against the prompt as
     * shipped, so the red is a property of the code and not of an edit made to produce it.
     *
     * ⚠ WHAT IT DOES *NOT* PROVE, STATED SO NOBODY OVER-TRUSTS IT. A rule is not a GOOD rule,
     * and a rule is not extraction. Measured on the whole `Inbound_Email_Staging__c` corpus on
     * 2026-08-31: `building_sf` populated on 3 of 4 property objects under the OLD prompt, and
     * the one row that dropped it ALSO dropped `lot_size_acres` and `year_renovated`, both of
     * which were already rule-bearing. So this invariant removes a necessary condition, not a
     * sufficient one. Only a live extraction proves the model reads a key — see the class
     * header's UAT list.
     *
     * ⚠ IT RUNS AGAINST `shippedPrompt()` — THE APEX FALLBACK, NOT THE LIVE SETUP VALUE. Since
     * WS5 the live prompt is `Broker_Protection_Config__mdt.Default.Extraction_Prompt__c`, which
     * an admin can edit without touching Apex. This test says nothing about such an edit. That
     * gap is precisely the one `ExtractionRegressionFixtureTest`'s section-2 banner describes as
     * unclosable while the prompt stays configurable, and T5 does not claim to close it. It does
     * guard the value the LOADER seeds, which is what every freshly-loaded org actually sends.
     *
     * ✅ COMPATIBLE WITH THAT "DO NOT RESTORE" BANNER, in the same shape T1-T4 argue it and
     * which the banner blesses by name. T5 asserts a PROPERTY of the text — "no key is
     * orphaned" — never its bytes. The three excluded regions are located by SHAPE (a key
     * followed by a colon; the phrase "MUST be one of the listed values"; the phrase
     * "must be one of:"), so rewording the prose around them keeps this green. 🔴 DO NOT
     * "STRENGTHEN" IT INTO A VERBATIM PIN OF `EXTRACTION_INSTRUCTION`; the banner forbids that
     * by name, and a pin would make every legitimate Setup prompt edit a required code change.
     *
     * ✅ NO ALLOWLIST AND NO HAND-MAINTAINED KEY LIST, AND THAT IS THE POINT. An earlier design
     * carried a dated allowlist of the eight keys that were to stay undefined. The user chose to
     * define all of them instead, so the invariant holds with NO exceptions — which is the only
     * form in which it cannot decay into a list nobody prunes. The one derived set in this test
     * (precondition 2) is read out of the prompt at runtime for the same reason.
     *
     * ⚠ NO 251-RECORD BULK TEST, per the class header's exemption and on independently
     * sufficient grounds: this asserts a property of a compile-time String constant. There is no
     * trigger, no loop, no batch and no record of any kind to insert.
     */
    @isTest
    static void everyResponseTemplateKey_isRuleBearingElsewhereInThePrompt() {
        String prompt = LLMExtractionCalloutService.shippedPrompt();

        // ---- REGION (a): the JSON response template ----------------------------------------
        // Anchor on the template's own first key rather than on the prose that introduces it,
        // so rewording that sentence cannot silently turn this test vacuous.
        Matcher templateMatcher = Pattern.compile('\\{"email_category".*?\\]\\}').matcher(prompt);
        Assert.isTrue(templateMatcher.find(),
            'FIXTURE PRECONDITION: the JSON response template must still be locatable in the '
            + 'prompt. If this fails the template was restructured and THIS TEST must be '
            + 'repaired — it has not proven anything about the prompt');
        String template = templateMatcher.group();
        String rest = removeExactlyOnce(prompt, template, 'the JSON response template');

        // ⚠ REGIONS (b) AND (c) ARE LOCATED BY LINE SPLIT + `contains`, NOT BY A REGEX, AND
        // THAT IS A MEASURED CONSTRAINT RATHER THAN A STYLE CHOICE. The natural expressions —
        // `[^\n]*MUST be one of the listed values[^\n]*` and `[a-z][a-z0-9_]* must be one of:`
        // — both begin with an UNANCHORED quantifier, so Apex retries them at every one of the
        // prompt's ~20,000 offsets and throws `System.LimitException: Regex too complicated`
        // before asserting anything (measured on `usman-dpeg` at API 67.0, 2026-08-31, the
        // first check-only run of this test). Splitting once and matching literals is O(n) and
        // cannot backtrack. Do not "simplify" this back into a Pattern.
        List<String> promptLines = rest.split('\n');

        // ---- REGION (b): the blanket closed-set constraint line -----------------------------
        String blanket = null;
        for (String line : promptLines) {
            if (line.contains(BLANKET_MARKER)) {
                blanket = line;
                break;
            }
        }
        Assert.isNotNull(blanket,
            'FIXTURE PRECONDITION: the blanket "' + BLANKET_MARKER + '" line must still be '
            + 'locatable. It is EXCLUDED on purpose — it constrains every closed-set key at '
            + 'once and defines none of them — so failing to find it would let those keys pass '
            + 'on a mention that says nothing. Repair this marker; do not delete the exclusion');
        rest = removeExactlyOnce(rest, blanket, 'the blanket closed-set constraint line');

        // ---- REGION (c): the "<key> must be one of: ..." enum lines -------------------------
        // Lower-case `must` is deliberate: the blanket line above says `MUST` and carries no
        // colon, so the two markers cannot claim each other's text.
        Set<String> enumeratedKeys = new Set<String>();
        for (String line : promptLines) {
            if (!line.contains(ENUM_MARKER)) {
                continue;
            }
            String enumeratedKey = line.substringBefore(ENUM_MARKER);
            enumeratedKeys.add(enumeratedKey);
            rest = removeExactlyOnce(rest, line, 'the enum line for ' + enumeratedKey);
        }

        // ---- ANTI-VACUITY 2: every key the blanket line NAMES must have had an enum line
        // removed. Derived from the prompt at runtime, never from a list maintained here.
        Set<String> blanketKeys = new Set<String>();
        Matcher blanketKeyMatcher = Pattern.compile('[a-z][a-z0-9]*_[a-z0-9_]*').matcher(blanket);
        while (blanketKeyMatcher.find()) {
            blanketKeys.add(blanketKeyMatcher.group());
        }
        Assert.isFalse(blanketKeys.isEmpty(),
            'FIXTURE PRECONDITION: the blanket line must name at least one closed-set key, or '
            + 'the enum-coverage check below is vacuous');
        Set<String> missingEnumLines = new Set<String>(blanketKeys);
        missingEnumLines.removeAll(enumeratedKeys);
        List<String> missing = new List<String>(missingEnumLines);
        missing.sort();
        Assert.areEqual('', String.join(missing, ', '),
            'FIXTURE PRECONDITION — THIS IS THE ONE THAT KEEPS THE TEST HONEST. The blanket '
            + 'line names these closed-set keys, but no "<key> must be one of:" line was found '
            + 'and excluded for them. Their enum line is therefore still in the remainder, and '
            + 'they would pass this test on a mention that defines nothing — exactly the '
            + 'vacuous green `deal_type` produced under the old mention-count version');

        // ---- ANTI-VACUITY 3: the exclusions must be surgical, not wholesale.
        Assert.isTrue(rest.length() > prompt.length() / 2,
            'FIXTURE PRECONDITION: the three excluded regions are short lines and a template. '
            + 'Removing more than half the prompt means a regex went greedy and every key below '
            + 'would be reported orphaned for a reason this message would not explain');

        // Whole-token membership, not substring: a `contains` check on a short key would be
        // satisfied by any word that happens to embed those letters, and a vacuous pass here is
        // the one failure mode this test cannot tolerate.
        Set<String> ruleBearingTokens = new Set<String>(rest.split('[^A-Za-z0-9_]+'));

        Matcher keyMatcher = Pattern.compile('"([a-z][a-z0-9_]*)"\\s*:').matcher(template);
        Set<String> schemaKeys = new Set<String>();
        List<String> orphaned = new List<String>();
        while (keyMatcher.find()) {
            String key = keyMatcher.group(1);
            if (!schemaKeys.add(key)) {
                continue;
            }
            if (!ruleBearingTokens.contains(key)) {
                orphaned.add(key);
            }
        }

        Assert.isTrue(schemaKeys.size() >= 30,
            'FIXTURE PRECONDITION: the response template carries several dozen distinct keys. '
            + 'Finding fewer than 30 means the key regex stopped matching and every assertion '
            + 'below it is vacuous — repair the regex, do not lower this floor. NO EXACT COUNT '
            + 'IS NAMED HERE ON PURPOSE: this change de-pinned every derived figure in this area '
            + 'because pinned figures went stale three times, and a count pinned in an assertion '
            + 'message would be the same mistake in a place nothing verifies (the floor is 30, '
            + 'so a wrong exact count stays green forever). Measure it if you need it.');

        orphaned.sort();
        Assert.areEqual('', String.join(orphaned, ', '),
            'These response-schema keys carry NO RULE anywhere in the prompt. Appearing in the '
            + 'JSON template, in the blanket "MUST be one of the listed values" line, or in a '
            + '"must be one of:" enum line does NOT count — those show a slot and a legal token '
            + 'set, and say nothing about what the value MEANS. The model is being shown a slot '
            + 'and told nothing about what belongs in it. Add a definition bullet to the '
            + 'ANTI-HALLUCINATION list — a meaning, a unit or format, and a contrast with the '
            + 'nearest competing key — in the register of unit_count, cap_rate and year_built. '
            + 'Do NOT satisfy this test by repeating the key name; the token count is the '
            + 'detector, not the mechanism');
    }

    /**
     * Delete `region` from `haystack` exactly once, refusing the two ways an exclusion can make
     * T5 pass for the wrong reason.
     *
     * 🔴 THIS HELPER IS THE ANTI-VACUITY MACHINERY, NOT A CONVENIENCE. T5 answers "does this key
     * appear OUTSIDE the excluded regions", so every failure of an exclusion makes the test
     * WEAKER, silently:
     *   • an EMPTY region (the regex stopped matching) removes nothing, and the excluded text
     *     stays in the remainder where it can satisfy a key that has no real rule;
     *   • a region appearing TWICE means `String.replace` removed both copies, so the exclusion
     *     deleted text it was never written to delete.
     * Both are asserted here rather than in the caller so no future exclusion can be added
     * without them.
     *
     * @param haystack The text to reduce.
     * @param region   The exact substring to remove; must be non-blank and appear exactly once.
     * @param label    Human-readable name of the region, used in the failure messages.
     * @return `haystack` with the single occurrence of `region` removed.
     */
    private static String removeExactlyOnce(String haystack, String region, String label) {
        Assert.isTrue(String.isNotBlank(region),
            'FIXTURE PRECONDITION: ' + label + ' matched an EMPTY region. An empty exclusion '
            + 'removes nothing, so every key it was meant to strip a mention from would pass '
            + 'this test on that mention — repair the regex');
        String reduced = haystack.replace(region, '');
        Assert.areEqual(haystack.length() - region.length(), reduced.length(),
            'FIXTURE PRECONDITION: ' + label + ' must appear EXACTLY ONCE. A second copy means '
            + 'this exclusion is deleting text it was not written to delete, and "rule-bearing '
            + 'elsewhere" could be satisfied by — or denied because of — that other copy');
        return reduced;
    }
}
