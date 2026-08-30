/**
 * Tests for TurnstileVerificationService — the Cloudflare Turnstile callout wrapper.
 *
 * Covers the confirmed path, every refusal shape Cloudflare actually emits, the two no-callout
 * short circuits, transport failure, and the malformed-response paths. Asserts the class's two
 * standing contracts: it NEVER throws, and it distinguishes "Cloudflare said no" from "our
 * credential is broken".
 *
 * ═══ BULK VOLUME IS NOT APPLICABLE HERE — DELIBERATE, NOT AN OVERSIGHT ═══
 * `.claude/rules/bulk-test-rule.md` mandates 251 records for triggers, batches, queueables and
 * DML-performing services. This class is none of those: it is structurally ONE callout per guest
 * form submission, invoked from a synchronous @AuraEnabled entry point that handles exactly one
 * submission per transaction. There is no loop to force a second batch chunk, and Apex caps
 * synchronous callouts at 100 per transaction anyway, so a 251-iteration test could not run at all
 * — it would prove nothing and fail on a limit unrelated to the code under test. This is the same
 * per-transaction-singleton reasoning that rule's own exemption section applies to
 * `LLMExtractionCalloutService`, which remains exempt for the identical reason.
 *
 * ═══ 🔴 WHAT THESE TESTS CANNOT PROVE, AND IT IS THE MOST IMPORTANT THING ═══
 * Every response below comes from an HttpCalloutMock. A mock cannot prove that
 * `{!$Credential.Turnstile_Credential.Secret_Key}` is substituted into the request body by the
 * platform — the mock intercepts the request BEFORE substitution matters and would answer
 * identically if the merge field never resolved. That fact was proven separately, by a live
 * two-probe read-back against the org on 2026-08-30 (recorded in TurnstileVerificationService's
 * class header and in ARCHITECTURE.md §3.5), and it MUST be re-proven by hand if the Named
 * Credential's allowMergeFieldsInBody flag, the parameter name, or the endpoint ever changes.
 * A green run of this class is not evidence about the credential.
 */
@IsTest
private class TurnstileVerificationServiceTest {

    private static final String VALID_TOKEN = 'a-plausible-looking-turnstile-token';

    /**
     * Returns a canned body and status for the single siteverify call.
     *
     * Also captures the request so a test can assert on what was SENT — which is how the
     * "token is URL-encoded" and "remoteip is omitted" contracts are checked without a live call.
     */
    private class TurnstileMock implements HttpCalloutMock {
        private final Integer status;
        private final String body;
        private HttpRequest captured;

        private TurnstileMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.captured = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(this.status);
            response.setStatus(this.status == 200 ? 'OK' : 'Bad Request');
            response.setBody(this.body);
            return response;
        }
    }

    /** Simulates Cloudflare being unreachable — the mock itself throws, as a timeout would. */
    private class ThrowingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    private static TurnstileVerificationService.VerificationResult run(
        Integer status, String body, String token, String remoteIp
    ) {
        Test.setMock(HttpCalloutMock.class, new TurnstileMock(status, body));
        Test.startTest();
        TurnstileVerificationService.VerificationResult result =
            new TurnstileVerificationService().verify(token, remoteIp);
        Test.stopTest();
        return result;
    }

    // ---- Confirmed ----

    @IsTest
    static void shouldVerify_WhenCloudflareConfirmsTheToken() {
        TurnstileVerificationService.VerificationResult result = run(
            200,
            '{"success":true,"challenge_ts":"2026-08-30T15:42:28.902Z","hostname":"dpeg.example.com","error-codes":[]}',
            VALID_TOKEN,
            null
        );

        Assert.isTrue(result.isVerified(), 'An explicit success:true must verify');
        Assert.areEqual(200, result.statusCode, 'Status is carried through');
        Assert.isTrue(result.errorCodes.isEmpty(), 'No error codes on a confirmed token');
        Assert.isNull(result.errorMessage, 'No diagnostic message on success');
        Assert.isFalse(result.isConfigurationFailure(), 'A success is not a configuration failure');
    }

    // ---- Refusals: Cloudflare answered, and said no ----

    @IsTest
    static void shouldRefuse_WhenTokenIsInvalid() {
        TurnstileVerificationService.VerificationResult result = run(
            200, '{"success":false,"error-codes":["invalid-input-response"]}', VALID_TOKEN, null
        );

        Assert.isFalse(result.isVerified(), 'An invalid token must not verify');
        Assert.areEqual(
            new List<String>{ 'invalid-input-response' },
            result.errorCodes,
            'Cloudflare error codes are surfaced verbatim for diagnosis'
        );
        Assert.isFalse(
            result.isConfigurationFailure(),
            'A rejected TOKEN is the feature working, not a broken credential — the caller '
                + 'must not log this at ERROR or it will drown the real signal'
        );
    }

    /**
     * Tokens are single-use. This is the exact response a resubmitted token produces, and it is
     * why the LWC resets the widget after every failed submit.
     */
    @IsTest
    static void shouldRefuse_WhenTokenIsReplayed() {
        TurnstileVerificationService.VerificationResult result = run(
            200, '{"success":false,"error-codes":["timeout-or-duplicate"]}', VALID_TOKEN, null
        );

        Assert.isFalse(result.isVerified(), 'A spent token must not verify');
        Assert.isFalse(result.isConfigurationFailure(), 'A replayed token is not misconfiguration');
        Assert.isTrue(
            result.errorMessage.contains('timeout-or-duplicate'),
            'The diagnostic names the reason: ' + result.errorMessage
        );
    }

    // ---- Configuration failure: the case that presents as an ordinary HTTP response ----

    /**
     * 🔴 THE HIGHEST-VALUE TEST IN THIS CLASS.
     *
     * This is precisely what a broken `allowMergeFieldsInBody` flag looks like on the wire, and it
     * was MEASURED against the org on 2026-08-30: HTTP 400, a well-formed JSON body, no exception.
     * Nothing throws, so no catch block sees it; the status is 4xx, so a naive "parse only on 2xx"
     * implementation would discard the one field that explains it. If this test ever goes red
     * because someone gated body parsing on the status code, the production symptom is a public
     * form that refuses every broker with a message no log explains.
     */
    @IsTest
    static void shouldReportConfigurationFailure_WhenSecretIsRejected_At400() {
        TurnstileVerificationService.VerificationResult result = run(
            400, '{"error-codes":["invalid-input-secret"],"success":false,"messages":[]}', VALID_TOKEN, null
        );

        Assert.isFalse(result.isVerified(), 'A rejected secret cannot verify anyone');
        Assert.areEqual(400, result.statusCode, 'Cloudflare answers a bad secret with 400');
        Assert.isTrue(
            result.isConfigurationFailure(),
            'invalid-input-secret is OUR misconfiguration and must be distinguishable from a bot'
        );
        Assert.areEqual(
            new List<String>{ 'invalid-input-secret' },
            result.errorCodes,
            'The body must be parsed even though the status is 4xx'
        );
    }

    @IsTest
    static void shouldReportConfigurationFailure_WhenSecretIsMissing() {
        TurnstileVerificationService.VerificationResult result = run(
            400, '{"success":false,"error-codes":["missing-input-secret"]}', VALID_TOKEN, null
        );

        Assert.isTrue(
            result.isConfigurationFailure(),
            'A missing secret is the same class of failure as an invalid one'
        );
    }

    // ---- No callout at all ----

    @IsTest
    static void shouldRefuseWithoutCallout_WhenTokenIsBlank() {
        Test.setMock(HttpCalloutMock.class, new TurnstileMock(200, '{"success":true}'));
        Test.startTest();
        TurnstileVerificationService.VerificationResult result =
            new TurnstileVerificationService().verify('   ', null);
        Integer callouts = Limits.getCallouts();
        Test.stopTest();

        Assert.isFalse(result.isVerified(), 'A blank token cannot verify');
        Assert.areEqual(
            0,
            callouts,
            'A blank token must NOT spend a callout — this is an unauthenticated public endpoint '
                + 'and the cheapest rejection has to come first'
        );
        Assert.areEqual(0, result.statusCode, 'No exchange happened, so the status stays 0');
    }

    @IsTest
    static void shouldRefuseWithoutCallout_WhenTokenIsAbsurdlyLong() {
        String oversized = 'x'.repeat(4097);
        Test.setMock(HttpCalloutMock.class, new TurnstileMock(200, '{"success":true}'));
        Test.startTest();
        TurnstileVerificationService.VerificationResult result =
            new TurnstileVerificationService().verify(oversized, null);
        Integer callouts = Limits.getCallouts();
        Test.stopTest();

        Assert.isFalse(result.isVerified(), 'An over-long token cannot verify');
        Assert.areEqual(0, callouts, 'An obviously-bogus token must not be relayed to Cloudflare');
        Assert.isTrue(
            result.errorMessage.contains('4097'),
            'The diagnostic states the observed length: ' + result.errorMessage
        );
    }

    // ---- Transport ----

    @IsTest
    static void shouldFailSafely_WhenCloudflareIsUnreachable() {
        Test.setMock(HttpCalloutMock.class, new ThrowingMock());
        Test.startTest();
        TurnstileVerificationService.VerificationResult result =
            new TurnstileVerificationService().verify(VALID_TOKEN, null);
        Test.stopTest();

        Assert.isFalse(result.isVerified(), 'An unreachable verifier cannot confirm anything');
        Assert.areEqual(
            0,
            result.statusCode,
            'statusCode 0 is how the caller tells "no exchange happened" from "Cloudflare said no"'
        );
        Assert.isFalse(
            result.isConfigurationFailure(),
            'A transport failure is not a credential failure — different alert, different message'
        );
        Assert.isNotNull(result.errorMessage, 'The exception detail is kept for the log');
    }

    // ---- Malformed responses: it still must not throw ----

    @IsTest
    static void shouldFailSafely_WhenResponseBodyIsNotJson() {
        TurnstileVerificationService.VerificationResult result = run(
            200, '<html>503 Service Unavailable</html>', VALID_TOKEN, null
        );

        Assert.isFalse(result.isVerified(), 'An unparseable body must never be read as success');
        Assert.isNotNull(result.errorMessage, 'The body is captured for diagnosis');
    }

    @IsTest
    static void shouldFailSafely_WhenResponseBodyIsEmpty() {
        TurnstileVerificationService.VerificationResult result = run(200, '', VALID_TOKEN, null);

        Assert.isFalse(result.isVerified(), 'An empty body must never be read as success');
        Assert.isTrue(
            result.errorMessage.contains('empty response body'),
            'The diagnostic says what was wrong: ' + result.errorMessage
        );
    }

    @IsTest
    static void shouldFailSafely_WhenResponseIsAJsonArray() {
        TurnstileVerificationService.VerificationResult result = run(
            200, '["not","an","object"]', VALID_TOKEN, null
        );

        Assert.isFalse(result.isVerified(), 'A non-object payload must not verify');
        Assert.isTrue(
            result.errorMessage.contains('Unexpected Turnstile response shape'),
            'The shape mismatch is named explicitly: ' + result.errorMessage
        );
    }

    /** `success` present but not a Boolean — a shape change on Cloudflare's side must fail closed. */
    @IsTest
    static void shouldFailSafely_WhenSuccessIsNotABoolean() {
        TurnstileVerificationService.VerificationResult result = run(
            200, '{"success":"true"}', VALID_TOKEN, null
        );

        Assert.isFalse(
            result.isVerified(),
            'The string "true" is not the Boolean true — a truthy-coercion bug here would let '
                + 'a malformed response wave every submission through'
        );
    }

    // ---- Request composition ----

    @IsTest
    static void shouldUrlEncodeTheToken_AndOmitRemoteIpWhenBlank() {
        TurnstileMock mock = new TurnstileMock(200, '{"success":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        new TurnstileVerificationService().verify('tok&injected=1', null);
        Test.stopTest();

        String body = mock.captured.getBody();
        Assert.isTrue(
            body.contains('response=tok%26injected%3D1'),
            'An attacker-supplied token must be URL-encoded so it cannot inject a second form '
                + 'field into the body. Body was: ' + body
        );
        Assert.isFalse(
            body.contains('remoteip='),
            'A null remoteIp must be omitted entirely — Cloudflare validates a supplied remoteip '
                + 'against the token, so sending a proxy address would refuse real brokers'
        );
        Assert.isTrue(
            body.startsWith('secret='),
            'The secret merge field leads the body. Body was: ' + body
        );
    }

    @IsTest
    static void shouldIncludeRemoteIp_WhenSupplied() {
        TurnstileMock mock = new TurnstileMock(200, '{"success":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        new TurnstileVerificationService().verify(VALID_TOKEN, '203.0.113.7');
        Test.stopTest();

        Assert.isTrue(
            mock.captured.getBody().contains('remoteip=203.0.113.7'),
            'A supplied remoteIp is forwarded: ' + mock.captured.getBody()
        );
    }

    @IsTest
    static void shouldPostToTheSiteverifyEndpoint_ViaTheNamedCredential() {
        TurnstileMock mock = new TurnstileMock(200, '{"success":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        new TurnstileVerificationService().verify(VALID_TOKEN, null);
        Test.stopTest();

        Assert.areEqual(
            'callout:Cloudflare_Turnstile/turnstile/v0/siteverify',
            mock.captured.getEndpoint(),
            'The endpoint must resolve through the Named Credential, never a literal Cloudflare '
                + 'URL — that indirection is what makes ARCHITECTURE.md 3.5 retirable in one line'
        );
        Assert.areEqual('POST', mock.captured.getMethod(), 'siteverify is a POST');
        Assert.areEqual(
            'application/x-www-form-urlencoded',
            mock.captured.getHeader('Content-Type'),
            'Turnstile takes form fields, not JSON'
        );
    }
}
