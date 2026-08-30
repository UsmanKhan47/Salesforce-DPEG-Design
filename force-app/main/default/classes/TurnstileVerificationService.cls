/**
 * Dedicated Cloudflare Turnstile callout wrapper. Verifies ONE CAPTCHA token against Cloudflare's
 * /siteverify endpoint and returns a typed result.
 *
 * LAYER — callout service. Per ARCHITECTURE.md §2 Standards ("all ASB/Plaid callouts wrapped in a
 * dedicated service class ... so they can be mocked via `HttpCalloutMock`") the single `Http.send`
 * in this feature lives here and NOWHERE else, so `BrokerPortalService` and its tests mock this one
 * boundary. No SOQL, no DML, no configuration reads. Modelled on `SharePointCalloutService`, which
 * is modelled on `LLMExtractionCalloutService` — the same shape, for the third time.
 *
 * ⚠ DELIBERATE, TEMPORARY §3 EXCEPTION — DIRECT (NON-ASB) EXTERNAL CALLOUT.
 * ARCHITECTURE.md §3.1 mandates that all external integrations route through the Avanza Service
 * Bus. This class INTENTIONALLY breaks that rule and is the THIRD standing exception, recorded and
 * explicitly acknowledged by the user at the design gate in ARCHITECTURE.md §3.5: no ASB CAPTCHA
 * spoke exists, so there is nothing on the bus to route to. §3.4 recorded that two exceptions was
 * the review threshold; this one crossed it knowingly and re-cut that sentence rather than quietly
 * ignoring it.
 *
 * ⚠ SHARING — `with sharing`, and it costs nothing: this class performs ZERO data access. Its only
 * caller, `BrokerPortalService`, is `without sharing` for reasons documented at length in its own
 * header; that declaration is deliberate, security-critical, and was NOT changed by this feature.
 * A `with sharing` class called from a `without sharing` one does not widen anything here because
 * there is nothing to widen — no SOQL, no DML, no describe of a protected object.
 *
 * ═══ 🔴 `ENDPOINT` IS THE ONE ENDPOINT CONSTANT IN THE ENTIRE FEATURE ═══
 * §3.5 promises the exception retires by repointing the Named Credential and changing this one
 * line, with `verify(...)`'s signature and every caller unchanged. That promise is only literally
 * true while no other class names a Cloudflare URL. Do not build one anywhere else, and do not let
 * a caller pass one in.
 *
 * ═══ 🔴 THE SECRET IS A MERGE FIELD IN THE BODY, NOT A HEADER. THIS WAS PROVEN, NOT ASSUMED. ═══
 * Turnstile authenticates by a form field in the POST body (`secret=...&response=...`), unlike the
 * other two direct-callout integrations in this repo, which both authenticate by header. So the
 * secret is written as the literal string `{!$Credential.Turnstile_Credential.Secret_Key}` into
 * the request body and substituted by the platform, which only happens when the Named Credential
 * sets `<allowMergeFieldsInBody>true</allowMergeFieldsInBody>`. That combination existed nowhere
 * in this repo before 2026-08-30 — `OpenAI_API` sets the same flag FALSE.
 *
 * 🔴 A GREEN DEPLOY PROVES NOTHING ABOUT IT. With the flag false the literal, unsubstituted merge
 * string is transmitted as the secret and Cloudflare answers a perfectly well-formed
 * `{"success":false,"error-codes":["invalid-input-secret"]}` — no exception, no stack trace, and
 * every broker submission refused with a message no log explains. The only proof is a live call.
 * It was run against usman-dpeg on 2026-08-30, twice, so the discriminator itself was proven
 * non-vacuous:
 *
 *   A  body = "secret={!$Credential...Secret_Key}&response=<deliberately invalid token>"
 *      -> HTTP 200 {"success":true,...,"metadata":{"result_with_testing_key":true}}
 *         The merge field RESOLVED — Cloudflare recognised the secret it received.
 *   B  body = "secret=this-is-not-a-real-turnstile-secret&response=<same invalid token>"  (control)
 *      -> HTTP 400 {"success":false,"error-codes":["invalid-input-secret"]}
 *         An unresolved/wrong secret IS detectable, so A did not pass vacuously.
 *
 * ⚠ Anyone who edits `allowMergeFieldsInBody`, renames `Secret_Key`, or re-homes the endpoint MUST
 * re-run that pair. `SECRET_MERGE_FIELD` below and the credential are a matched set.
 *
 * ═══ 🔴 IT NEVER THROWS. EVERY OUTCOME COMES BACK AS A `VerificationResult`. ═══
 * A transport failure, a timeout, a refused credential, a 4xx, a 5xx and an unparseable body all
 * resolve to a result. Policy — whether an unverifiable submission is accepted or refused — is NOT
 * this class's decision and is deliberately not encoded here; it belongs to `BrokerPortalService`,
 * which owns the user-facing contract and chooses to fail CLOSED. Keeping the two apart is what
 * lets the policy be read in one place and changed without touching a callout.
 *
 * ═══ 🔴 NOTHING IN THIS CLASS MAY EVER LOG THE REQUEST BODY ═══
 * The request body contains the resolved secret after the platform substitutes the merge field.
 * `errorMessage` below is built ONLY from the response body and the exception text, never from the
 * request. A debug statement added here that echoes `request.getBody()` would write the Cloudflare
 * secret into a log any admin can read, and would require rotating the key at Cloudflare.
 *
 * @see BrokerPortalService.cls       (the only caller; owns the fail-closed policy and the messages)
 * @see SharePointCalloutService.cls  (the in-repo precedent for this shape)
 * @see ARCHITECTURE.md §3.5          (the accepted direct-Turnstile exception and its retirement plan)
 */
public with sharing class TurnstileVerificationService {

    /**
     * 🔴 THE ONE ENDPOINT CONSTANT. The `Cloudflare_Turnstile` Named Credential resolves to
     * `https://challenges.cloudflare.com`; only this line and the credential change when the
     * callout is re-homed onto an ASB spoke (ARCHITECTURE.md §3.5).
     */
    private static final String ENDPOINT = 'callout:Cloudflare_Turnstile/turnstile/v0/siteverify';

    /**
     * 🔴 NOT A SECRET. This is the merge-field EXPRESSION; the platform substitutes the real value
     * at send time from the `Turnstile_Credential` External Credential's `Secret_Key` parameter,
     * which is entered in Setup post-deploy and exists nowhere in metadata or source
     * (ARCHITECTURE.md §3.2). Committing this literal is safe and is the whole point of the
     * pattern. Committing the value it resolves to would not be.
     */
    private static final String SECRET_MERGE_FIELD = '{!$Credential.Turnstile_Credential.Secret_Key}';

    /**
     * A public guest submission is a SYNCHRONOUS page interaction, so this timeout is felt directly
     * as a spinner by a broker filling in a form. 10 s is Salesforce's own default and roughly 20x
     * a healthy siteverify round trip (~200-400 ms observed), so it truncates a HUNG call, not a
     * slow one. It is deliberately NOT derived from a cumulative-callout budget the way
     * `SharePointCalloutService.TIMEOUT_MS` is: this feature makes exactly ONE callout per
     * transaction, so the 120 s cumulative limit is not the binding constraint — the guest's
     * patience is.
     *
     * ⚠ Raising it makes a Cloudflare brown-out feel like a hung portal; lowering it converts slow
     * verifications into refused submissions, because the policy is fail-closed.
     */
    private static final Integer TIMEOUT_MS = 10000;

    /**
     * Turnstile tokens are ~short and bounded (Cloudflare documents a ceiling well under this). An
     * over-long value is not a real token, so it is refused WITHOUT a callout — the public form is
     * an unauthenticated endpoint and there is no reason to relay an obviously-bogus megabyte to
     * Cloudflare, nor to hold it on the heap while doing so.
     */
    private static final Integer MAX_TOKEN_CHARS = 4096;

    /** How much of a response body or exception message is worth keeping for diagnosis. */
    private static final Integer MAX_ERROR_CHARS = 600;

    /**
     * Cloudflare's error code for "the secret you sent is not a valid secret". It is the single
     * most important string in this class: it is the ONLY signal that the credential wiring is
     * broken, and it arrives as an ordinary, successful-looking HTTP response rather than as an
     * exception. `BrokerPortalService` logs it at ERROR precisely because it is an ops emergency —
     * every submission is being refused — and not a bot.
     */
    @TestVisible private static final String ERROR_INVALID_SECRET = 'invalid-input-secret';

    /** Cloudflare's error code for "the secret is missing entirely" — same class of failure. */
    @TestVisible private static final String ERROR_MISSING_SECRET = 'missing-input-secret';

    /**
     * The outcome of one verification attempt. A value object — no behaviour beyond the two
     * predicates, no callout state, safe to hold or pass around.
     *
     * `statusCode` is 0 when no HTTP exchange completed at all (transport failure, timeout, or a
     * running user with no External Credential Principal Access); in that case `errorMessage`
     * carries the exception type and message, which is the only diagnostic available for the
     * credential-grant gap this feature has to fail visibly on.
     *
     * ⚠ `statusCode` 400 is NOT necessarily a transport problem — Cloudflare answers a bad secret
     * with 400 AND a well-formed JSON body (measured 2026-08-30). `errorCodes` is therefore
     * populated from the body regardless of status, and callers must read the codes, not the
     * status, to tell a configuration failure from a rejected token.
     */
    public class VerificationResult {
        /** True only when Cloudflare affirmatively confirmed the token. Never null. */
        public Boolean verified = false;
        /** HTTP status, or 0 when no exchange completed. Never null. */
        public Integer statusCode = 0;
        /** Cloudflare's `error-codes` array, or empty. Never null. */
        public List<String> errorCodes = new List<String>();
        /** Human-readable diagnostic for the log. NEVER contains the request body. Null on success. */
        public String errorMessage;

        /**
         * Whether Cloudflare affirmatively said this token is good.
         *
         * @return true only on an explicit `"success": true`. Anything else — refused, unreachable,
         *         misconfigured, unparseable — is false. There is no third state, deliberately:
         *         a caller that wants to distinguish them reads `isConfigurationFailure()` and
         *         `errorMessage`, and a caller that forgets to gets the safe answer.
         */
        public Boolean isVerified() {
            return verified == true;
        }

        /**
         * Whether the failure is OUR misconfiguration rather than a bad or absent token.
         *
         * This is the distinction that decides whether an alert should wake someone up. A refused
         * token is the feature working; an invalid secret is the feature down for every visitor,
         * and it presents as a normal HTTP response that no exception handler will ever see.
         *
         * @return true when Cloudflare reported the secret itself as missing or invalid.
         */
        public Boolean isConfigurationFailure() {
            for (String code : errorCodes) {
                if (ERROR_INVALID_SECRET.equals(code) || ERROR_MISSING_SECRET.equals(code)) {
                    return true;
                }
            }
            return false;
        }
    }

    /**
     * Verify one Turnstile token with Cloudflare.
     *
     * Exactly ONE callout, and only when a plausible token was supplied — a blank or absurdly long
     * token is refused locally, so a bot cannot make the public form spend a callout per request.
     *
     * @param token    The `cf-turnstile-response` value produced by the widget in the visitor's
     *                 browser. Blank or over-long values are refused without a callout.
     *                 ⚠ Tokens are SINGLE-USE and short-lived: verifying the same token twice
     *                 returns `timeout-or-duplicate` and is a refusal, not a success. That is why
     *                 the LWC resets the widget after every failed submit.
     * @param remoteIp Optional visitor IP. 🔴 PASS NULL UNLESS YOU HAVE THE VISITOR'S REAL IP.
     *                 Cloudflare validates a supplied `remoteip` against the one the token was
     *                 issued to, so a proxy/load-balancer address — which is all a Salesforce guest
     *                 context can offer — turns legitimate submissions into refusals. Omitting it
     *                 is explicitly supported by Cloudflare and loses nothing this feature uses.
     * @return The typed outcome. NEVER null and NEVER thrown; inspect `isVerified()`.
     * @example
     * TurnstileVerificationService.VerificationResult r =
     *     new TurnstileVerificationService().verify(input.turnstileToken, null);
     * if (!r.isVerified()) { throw new SubmissionException(CAPTCHA_FAILED_MSG); }
     */
    public VerificationResult verify(String token, String remoteIp) {
        VerificationResult result = new VerificationResult();

        if (String.isBlank(token)) {
            result.errorMessage = 'No verification token was supplied; no callout was attempted.';
            return result;
        }
        if (token.length() > MAX_TOKEN_CHARS) {
            result.errorMessage = 'Verification token exceeded ' + MAX_TOKEN_CHARS
                + ' characters (' + token.length() + '); no callout was attempted.';
            return result;
        }

        try {
            HttpRequest request = new HttpRequest();
            request.setEndpoint(ENDPOINT);
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            request.setTimeout(TIMEOUT_MS);
            // 🔴 Never log this value — after platform substitution it contains the secret.
            request.setBody(buildRequestBody(token, remoteIp));

            HttpResponse response = new Http().send(request);
            result.statusCode = response.getStatusCode();
            populateFromBody(result, response.getBody());

            if (!result.verified && String.isBlank(result.errorMessage)) {
                result.errorMessage = 'HTTP ' + result.statusCode + ' ' + response.getStatus()
                    + ' — Turnstile did not confirm the token'
                    + (result.errorCodes.isEmpty() ? '.' : ': ' + String.join(result.errorCodes, ', '));
            }
        } catch (Exception e) {
            // Transport failure, timeout, or — the case this feature must surface loudly — a
            // running user with no External Credential Principal Access to Turnstile_Credential.
            // That one presents as "System.CalloutException: We couldn't access the credential(s)"
            // and names a missing credential as its first hypothesis, which sends a diagnosis down
            // the wrong path; measured on this org 2026-08-30, the credential existed and the
            // permission-set assignment did not. statusCode stays 0, which is how the caller tells
            // "the exchange never happened" from "Cloudflare said no".
            result.verified = false;
            result.statusCode = 0;
            result.errorMessage = e.getTypeName() + ' | ' + clip(e.getMessage(), MAX_ERROR_CHARS);
        }
        return result;
    }

    /**
     * Compose the form-urlencoded siteverify payload. 🔴 The ONLY place the secret merge field is
     * written, and the ONLY place a request body is built for this feature.
     *
     * The token is URL-encoded because it is attacker-controlled input arriving from a public form
     * and may contain `&` or `=`; without encoding, a crafted token could inject a second form
     * field into the body. The merge field is deliberately NOT encoded — encoding it would corrupt
     * the `{!$Credential...}` expression and the platform would never substitute it, producing the
     * exact `invalid-input-secret` failure this class's header warns about.
     *
     * @param token    Non-blank, length-checked by the caller.
     * @param remoteIp Optional; omitted from the body entirely when blank (see `verify`).
     * @return The request body, containing an unsubstituted merge expression at this point.
     */
    private static String buildRequestBody(String token, String remoteIp) {
        String body = 'secret=' + SECRET_MERGE_FIELD
            + '&response=' + EncodingUtil.urlEncode(token, 'UTF-8');
        if (String.isNotBlank(remoteIp)) {
            body += '&remoteip=' + EncodingUtil.urlEncode(remoteIp, 'UTF-8');
        }
        return body;
    }

    /**
     * Read Cloudflare's JSON answer into the result.
     *
     * 🔴 Parsed REGARDLESS OF HTTP STATUS. Cloudflare answers an invalid secret with HTTP 400 and a
     * well-formed body carrying `error-codes` (measured 2026-08-30). Gating this on 2xx would throw
     * away the single most diagnostic field in the whole feature and reduce a broken credential to
     * an anonymous "HTTP 400".
     *
     * Never throws: an unparseable or unexpectedly-shaped body leaves `verified` false and records
     * the body text, which is the safe outcome under a fail-closed policy.
     *
     * @param result The result to populate in place.
     * @param body   The raw response body; may be null, blank or malformed.
     */
    private static void populateFromBody(VerificationResult result, String body) {
        if (String.isBlank(body)) {
            result.errorMessage = 'HTTP ' + result.statusCode + ' with an empty response body.';
            return;
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (!(parsed instanceof Map<String, Object>)) {
                result.errorMessage = 'Unexpected Turnstile response shape: '
                    + clip(body, MAX_ERROR_CHARS);
                return;
            }
            Map<String, Object> payload = (Map<String, Object>) parsed;
            Object success = payload.get('success');
            result.verified = (success instanceof Boolean) && (Boolean) success;

            Object codes = payload.get('error-codes');
            if (codes instanceof List<Object>) {
                for (Object code : (List<Object>) codes) {
                    if (code != null) {
                        result.errorCodes.add(String.valueOf(code));
                    }
                }
            }
        } catch (Exception e) {
            result.verified = false;
            result.errorMessage = 'Unparseable Turnstile response (' + e.getTypeName() + '): '
                + clip(body, MAX_ERROR_CHARS);
        }
    }

    /**
     * @param value The text to bound.
     * @param max   Maximum characters to keep.
     * @return `value` truncated to `max` characters, or `value` unchanged when short enough.
     */
    private static String clip(String value, Integer max) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.length() <= max ? value : value.substring(0, max) + '...';
    }
}
