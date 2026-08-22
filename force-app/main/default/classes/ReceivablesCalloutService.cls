/**
 * THE ONLY `Http.send` AND THE ONLY ENDPOINT CONSTANT IN THE ENTIRE RECEIVABLES FEATURE.
 *
 * LAYER - callout service. Per ARCHITECTURE.md section 2 ("all ASB/Plaid callouts wrapped in a
 * dedicated service class ... so they can be mocked via `HttpCalloutMock`") the single `Http.send`
 * for FSD 5.9 lives here and NOWHERE else, so callers and their tests mock this one boundary. No
 * SOQL, no DML, no configuration reads - every value it needs is a parameter. Modelled on
 * `SharePointCalloutService` and `LLMExtractionCalloutService`; read both headers before changing
 * anything here.
 *
 * ==========================================================================================
 * THIS IS NOT A SECTION 3.x EXCEPTION. IT IS THE FIRST SECTION 3.1-CONFORMING INTEGRATION.
 * ==========================================================================================
 * The design brief asked whether this becomes the THIRD standing direct-callout exception. It does
 * not, and the distinction is not a technicality:
 *
 *   section 3.3 (OpenAI) and section 3.4 (Microsoft Graph) are exceptions BECAUSE THEY CALL THE
 *   THIRD-PARTY SYSTEM DIRECTLY, bypassing the bus. This class calls THE BUS. `BASE` below is
 *   `callout:ASB`, not `callout:Yardi`. Yardi's credentials stay in ASB's secrets vault, which is
 *   verbatim what section 3.1 prescribes.
 *
 * MEASURED 2026-08-22 against `usman-dpeg`: the org holds exactly two Named Credentials,
 * `OpenAI_API` and `SharePoint`. There is NO `ASB` Named Credential, in the org or in this repo,
 * and `grep -o 'callout:[A-Za-z_]*'` across `force-app` returns only those two. So the ASB
 * receivables SPOKE IS NOT PROVISIONED YET - which is exactly why `StubReceivablesFeedProvider`
 * ships as the configured default and why the entire FSD 5.9 lifecycle is live and testable with
 * zero callouts today. When the spoke is provisioned this class needs no change: create the `ASB`
 * Named Credential, flip `Receivables_Sync_Config__c.Provider_Class_Name__c` to
 * `AsbReceivablesFeedProvider`, done.
 *
 * WARNING - the External Credential is DELIBERATELY not shipped as metadata, the same decision
 * `SharePoint_Credential` records in ARCHITECTURE.md section 3.4: the OAuth External Credential XML
 * shape could not be confirmed at 67.0 and a malformed guess fails at token acquisition with an
 * opaque error. Build it by hand in Setup.
 *
 * === `BASE` IS THE ONE ENDPOINT CONSTANT, AND THAT IS THE WHOLE POINT ===
 * Every path segment and every query parameter is composed HERE, from parameters. Do not build a
 * receivables URL anywhere else and do not let a caller pass one in. Re-homing the feed - onto a
 * different bus, a different path, or (if section 3.1 is ever relaxed) directly at Yardi - is then
 * a one-line change with an unchanged `fetchDelinquencyFeed` signature and unchanged callers.
 *
 * === IT NEVER THROWS. EVERY FAILURE COMES BACK AS A `FeedResponse`. ===
 * A transport failure, a timeout and a refused credential all resolve to a response carrying
 * `statusCode` and a human-readable `errorMessage`. That is not defensive tidiness: it is what lets
 * `AsbReceivablesFeedProvider` return an empty, clock-less result, which is what makes the health
 * check HALT the run with `Halt_Reason__c = 'Callout Failure'` instead of the run dying with an
 * unhandled exception and no `Sync_Run__c` audit row to explain it. The audit row IS the FSD 5.9.6
 * halt rule's evidence; losing it loses the rule.
 * WARNING - it cannot catch an UNCATCHABLE platform limit (callout count, cumulative callout time,
 * heap). One callout per run means none of those is reachable today; a future paging loop would
 * have to bound itself.
 *
 * @see AsbReceivablesFeedProvider.cls (the only caller)
 * @see ReceivablesCalloutMock.cls     (the test double for this boundary)
 * @see SharePointCalloutService.cls   (the in-repo precedent for this shape)
 */
public with sharing class ReceivablesCalloutService {

    /**
     * THE ONE ENDPOINT CONSTANT. The `ASB` Named Credential resolves to the Avanza Service Bus
     * base URL; only this line and the credential change when the feed is re-homed.
     */
    private static final String BASE = 'callout:ASB';

    /** The receivables spoke's path on the bus. Composed here and nowhere else. */
    @TestVisible
    private static final String DELINQUENCY_PATH = '/receivables/delinquency';

    /**
     * PER-CALLOUT TIMEOUT - 60 s, half the 120 s cumulative per-transaction budget.
     *
     * This feature makes exactly ONE callout per run, so the binding limit is the per-call ceiling
     * (120 000 ms) rather than the cumulative one, and there is no seven-calls-per-record arithmetic
     * of the kind `SharePointCalloutService` had to close. 60 s is chosen rather than the 120 s
     * maximum for one reason: it leaves a whole second call's worth of headroom inside the same
     * transaction, so adding paging (OQ-8) later does not silently push the run past the cumulative
     * limit on its first slow night.
     *
     * WARNING - a client-side timeout is not proof the bus failed; the request may have completed
     * remotely. That is harmless HERE and would not be harmless in a push design: this is a PULL, so
     * a timeout costs one skipped nightly run, recorded as `Halt_Reason__c = 'Callout Failure'`,
     * and the next run re-reads the same data. Nothing is created, nothing is duplicated.
     */
    @TestVisible
    private static final Integer TIMEOUT_MS = 60000;

    /**
     * ATTEMPTS MADE BY THIS TRANSACTION, counted at the boundary itself rather than at the mock.
     *
     * A test cannot prove "exactly one callout attempt per run" by counting `HttpCalloutMock`
     * invocations while the `ASB` Named Credential is unprovisioned: an endpoint of the form
     * `callout:&lt;missing&gt;` is refused by the PLATFORM before the mock is ever consulted, so the mock
     * legitimately records ZERO for a run that did attempt one call. Counting here makes the claim
     * hold on both sides of provisioning - the assertion does not change on the day ASB appears, and
     * a future paging loop that quietly issues a second call fails the test instead of the limit.
     * Same pattern, and the same reason, as `DelinquencyCaseService.lastRunQueryCount`.
     */
    @TestVisible
    private static Integer lastRunAttemptCount = 0;

    /**
     * The failure text from the most recent attempt; null after a success.
     *
     * Retained because `AsbReceivablesFeedProvider` deliberately converts every failure into an
     * empty, clock-less result, which by design tells the health check WHAT to do and tells the
     * operator NOTHING about why. Reading this is the only way a test - or a future `Halt_Detail__c`
     * enrichment - can distinguish "the bus said 500" from "the credential does not exist".
     */
    @TestVisible
    private static String lastRunErrorMessage;

    /** Typed outcome of one bus call. Never null; `isSuccess` is never null. */
    public class FeedResponse {
        /** True only for a 2xx with a non-blank body. */
        public Boolean isSuccess = false;
        /** HTTP status, or null when the request never reached a response. */
        public Integer statusCode;
        /** Raw response body on success; null otherwise. */
        public String body;
        /** Human-readable failure description; null on success. */
        public String errorMessage;
    }

    /**
     * Fetch the delinquency receivables feed from the ASB receivables spoke.
     *
     * @param asOf    The run's start moment, used as the `asOf` query parameter so the bus can
     *                return a feed consistent with a single point in time. Nullable; omitted when
     *                null.
     * @param maxRows Optional row cap passed to the bus. Nullable; omitted when null.
     * @return A `FeedResponse`; never null and never thrown from.
     * @example
     * ReceivablesCalloutService.FeedResponse r =
     *     ReceivablesCalloutService.fetchDelinquencyFeed(System.now(), 5000);
     */
    public static FeedResponse fetchDelinquencyFeed(DateTime asOf, Integer maxRows) {
        lastRunAttemptCount++;
        lastRunErrorMessage = null;
        FeedResponse result = new FeedResponse();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE + DELINQUENCY_PATH + buildQuery(asOf, maxRows));
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(TIMEOUT_MS);

        try {
            HttpResponse response = new Http().send(request);
            result.statusCode = response.getStatusCode();
            String responseBody = response.getBody();
            if (result.statusCode >= 200 && result.statusCode < 300) {
                if (String.isBlank(responseBody)) {
                    result.errorMessage = 'ASB returned HTTP ' + result.statusCode + ' with an empty body.';
                    lastRunErrorMessage = result.errorMessage;
                    return result;
                }
                result.isSuccess = true;
                result.body = responseBody;
                return result;
            }
            result.errorMessage = 'ASB returned HTTP ' + result.statusCode + ': '
                + (String.isBlank(responseBody) ? '(no body)' : responseBody.abbreviate(500));
            lastRunErrorMessage = result.errorMessage;
            return result;
        } catch (System.CalloutException e) {
            // Transport-level: DNS, TLS, timeout, refused credential, unconfigured Named Credential.
            result.errorMessage = 'Callout failed: ' + e.getMessage();
            lastRunErrorMessage = result.errorMessage;
            return result;
        } catch (Exception e) {
            // Deliberately broad and deliberately LAST. The never-throw contract above is what keeps
            // the Sync_Run__c audit row - and therefore the halt rule's evidence - reachable.
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
            lastRunErrorMessage = result.errorMessage;
            return result;
        }
    }

    /**
     * Composes the query string. `EncodingUtil.urlEncode` emits `+` for a space, which is CORRECT
     * for a query string (and would be wrong for a path segment - the trap
     * `SharePointCalloutService` documents). Nothing here is ever a path segment.
     *
     * @param asOf    Nullable as-of moment.
     * @param maxRows Nullable row cap.
     * @return A query string beginning with `?`, or the empty string when both inputs are null.
     */
    private static String buildQuery(DateTime asOf, Integer maxRows) {
        List<String> parts = new List<String>();
        if (asOf != null) {
            parts.add('asOf=' + EncodingUtil.urlEncode(asOf.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''), 'UTF-8'));
        }
        if (maxRows != null) {
            parts.add('maxRows=' + maxRows);
        }
        return parts.isEmpty() ? '' : ('?' + String.join(parts, '&'));
    }
}
