/**
 * The LIVE provider: pulls the receivables feed from the ASB receivables spoke and maps the JSON
 * onto the normalized DTOs. Thin by design - it owns the mapping and nothing else.
 *
 * LAYER - provider (`ReceivablesFeedProvider` implementation). No SOQL, no DML, and - importantly -
 * NO `Http.send`. The single callout in this feature belongs to `ReceivablesCalloutService` and
 * this class calls it. Putting the `Http.send` here would put a second endpoint into the feature
 * and break the one-line-retirement promise in that class's header.
 *
 * === NOT ENABLED TODAY, AND THAT IS DELIBERATE ===
 * The `ASB` Named Credential does not exist in `usman-dpeg` (measured 2026-08-22: the org holds
 * `OpenAI_API` and `SharePoint` and nothing else). Until it does, selecting this provider in
 * `Receivables_Sync_Config__c.Provider_Class_Name__c` produces an honest, recorded halt -
 * `Halt_Reason__c = 'Callout Failure'`, `Lifecycle_Ran__c = false`, zero Cases touched - rather than
 * an exception or a silent no-op. Switching the feature on later is: create the Named Credential and
 * its hand-built External Credential, then set the config value. No deploy.
 *
 * === EVERY FAILURE BECOMES A CLOCK-LESS EMPTY RESULT, NOT AN EXCEPTION ===
 * A refused credential, a 500 from the bus, a truncated body and a malformed payload all resolve to
 * `rows = []` and `feedAsOf = null`. `ReceivablesHealthCheckDomain` reads a null clock as stale, so
 * the run halts with a recorded reason and a `Sync_Run__c` row survives to say why. An exception
 * escaping here would instead kill the queueable and destroy the audit row that IS the FSD 5.9.6
 * halt rule's evidence.
 *
 * === THE FEED'S OWN CLOCK IS TAKEN FROM THE PAYLOAD, NEVER FROM `System.now()` ===
 * Unlike the stub, this provider does NOT rebase the clock. If the bus does not state the feed's
 * as-of time, the feed cannot be proven fresh and the run halts. That is the whole point of the
 * staleness rule: a payload fetched two seconds ago can be three days old.
 *
 * @see ReceivablesCalloutService.cls  (the single Http.send and the single endpoint constant)
 * @see StubReceivablesFeedProvider.cls (the sibling that makes no callout)
 */
public with sharing class AsbReceivablesFeedProvider implements ReceivablesFeedProvider {

    /** `Sync_Run__c.Source__c` value. Restricted picklist - must exist before this provider runs. */
    @TestVisible
    private static final String SOURCE_LABEL = 'ASB';

    /**
     * Default row cap sent to the bus when the caller does not supply one. Sized well above any
     * plausible DPEG tenant count so it acts as a runaway guard rather than a pagination boundary;
     * genuine paging is OQ-8 and is not implemented.
     */
    @TestVisible
    private static final Integer DEFAULT_MAX_ROWS = 5000;

    /**
     * Pull one feed from the bus.
     *
     * @param request Fetch parameters; null-safe.
     * @return The feed. Never null, never thrown from. Rows-empty with a null clock on any failure.
     */
    public ReceivablesFeedResult fetch(ReceivablesFeedRequest request) {
        ReceivablesFeedResult result = new ReceivablesFeedResult();
        result.providerName = AsbReceivablesFeedProvider.class.getName();
        result.source = SOURCE_LABEL;

        DateTime asOf = (request == null) ? null : request.asOf;
        Integer maxRows = (request == null || request.maxRows == null) ? DEFAULT_MAX_ROWS : request.maxRows;

        ReceivablesCalloutService.FeedResponse response =
            ReceivablesCalloutService.fetchDelinquencyFeed(asOf, maxRows);

        if (response == null || response.isSuccess != true) {
            System.debug(LoggingLevel.WARN, 'AsbReceivablesFeedProvider: fetch failed - '
                + (response == null ? 'null response' : response.errorMessage));
            return result;
        }

        ReceivablesFeedResult parsed;
        try {
            parsed = (ReceivablesFeedResult) JSON.deserialize(response.body, ReceivablesFeedResult.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'AsbReceivablesFeedProvider: payload parse failed - ' + e.getTypeName() + ': ' + e.getMessage());
            return result;
        }
        if (parsed == null) {
            return result;
        }

        parsed.normalize();
        result.rows = parsed.rows;
        // No rebase. A payload with no clock cannot be proven fresh; the health check halts it.
        result.feedAsOf = parsed.feedAsOf;
        return result;
    }

    /**
     * @return `'ASB'` - the `Sync_Run__c.Source__c` value recorded for a bus-driven run.
     */
    public String sourceLabel() {
        return SOURCE_LABEL;
    }
}
