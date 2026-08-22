/**
 * The FIXTURE provider: reads the `Receivables_Feed_Sample` static resource and returns it as a
 * normalized feed. MAKES NO CALLOUT AT ALL.
 *
 * LAYER - provider (`ReceivablesFeedProvider` implementation). No DML. Its one SOQL read lives in
 * `StaticResourceSelector`, per `.claude/rules/apex-layering-rule.md`.
 *
 * === WHY THIS CLASS IS THE DELIVERABLE, NOT A PLACEHOLDER ===
 * The brief's central ask is that the whole FSD 5.9 lifecycle - mirror upsert, health check, Case
 * open, escalation ladder, auto-close, every alert - is LIVE AND TESTABLE TODAY, before the ASB
 * receivables spoke exists (and it does not: measured 2026-08-22, `usman-dpeg` holds only the
 * `OpenAI_API` and `SharePoint` Named Credentials). This class is what delivers that. Everything
 * downstream of `ReceivablesSyncService.ingest` runs identically whether the rows came from here or
 * from the bus, because neither can be distinguished from the other by the time they get there.
 *
 * === THE CLOCK REBASE, AND WHY IT IS SAFE ONLY BECAUSE THIS IS A FIXTURE ===
 * `ReceivablesHealthCheckDomain` halts on a feed older than
 * `Receivables_Sync_Config__c.Staleness_Tolerance_Hours__c`, measured against the FEED's own
 * `feedAsOf`. A static JSON file has no clock: any timestamp baked into it is stale the day after
 * it is written, so a literal fixture would halt every run forever and the "live today" claim would
 * be false.
 *
 * So: when the fixture OMITS `feedAsOf`, this provider stamps `request.asOf` - the run's own start
 * moment. When the fixture SUPPLIES one, it is honoured verbatim, which is how a test proves the
 * stale-feed halt actually fires.
 *
 * THIS BEHAVIOUR IS THE SINGLE STRONGEST REASON THIS PROVIDER MUST NEVER BE THE PRODUCTION ONE. It
 * asserts freshness it cannot possibly know. `ReceivablesIngestQueueable` therefore never falls
 * back to this class on a config error - it halts instead. Do not "helpfully" add a fallback.
 *
 * === MISSING RESOURCE IS A HALT, NOT AN EMPTY FEED ===
 * If `Receivables_Feed_Sample` is absent or unparseable, `fetch` returns rows-empty AND
 * clock-null. Clock-null is what the health check reads as stale, so the run halts and records
 * `Halt_Reason__c`. Returning a fresh-looking empty feed would instead be read as "every tenant
 * paid up", and FSD 5.9.6 step 6 would AUTO-CLOSE nothing (closes are driven off rows that are
 * present) - but the row-count-collapse arm would be the only thing standing between an empty
 * fixture and a silently pointless run. Halting is the honest answer.
 *
 * @see ReceivablesFeedProvider.cls      (the interface and its contract)
 * @see StaticResourceSelector.cls       (the one SOQL read)
 * @see AsbReceivablesFeedProvider.cls   (the sibling that does call the bus)
 */
public with sharing class StubReceivablesFeedProvider implements ReceivablesFeedProvider {

    /** The static resource holding the fixture payload. */
    @TestVisible
    private static final String RESOURCE_NAME = 'Receivables_Feed_Sample';

    /** `Sync_Run__c.Source__c` value. Restricted picklist - must exist before this provider runs. */
    @TestVisible
    private static final String SOURCE_LABEL = 'Stub';

    /**
     * Test seam. When non-null, this JSON is used INSTEAD of reading the static resource, so unit
     * tests can drive every parse and clock branch without depending on a deployed resource (and
     * without a SOQL read). Production never sets it.
     */
    @TestVisible
    private static String fixtureOverride = null;

    /**
     * Read the fixture and return it as a normalized feed.
     *
     * @param request Fetch parameters; `asOf` supplies the clock rebase. Null-safe.
     * @return The feed. Never null. Rows-empty with a null clock when the fixture is missing or
     *         unparseable, which the health check reads as a halt.
     */
    public ReceivablesFeedResult fetch(ReceivablesFeedRequest request) {
        ReceivablesFeedResult result = new ReceivablesFeedResult();
        result.providerName = StubReceivablesFeedProvider.class.getName();
        result.source = SOURCE_LABEL;

        String payload = (fixtureOverride != null)
            ? fixtureOverride
            : StaticResourceSelector.selectBodyByName(RESOURCE_NAME);

        if (String.isBlank(payload)) {
            // Clock stays null on purpose - see the class header. This is a halt, not an empty feed.
            return result;
        }

        ReceivablesFeedResult parsed;
        try {
            parsed = (ReceivablesFeedResult) JSON.deserialize(payload, ReceivablesFeedResult.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'StubReceivablesFeedProvider: fixture parse failed - ' + e.getTypeName() + ': ' + e.getMessage());
            return result;
        }
        if (parsed == null) {
            return result;
        }

        parsed.normalize();
        result.rows = parsed.rows;
        // Honour a fixture-supplied clock (that is how the stale-feed halt is tested); otherwise
        // rebase onto the run's own start moment so the fixture does not rot into permanent staleness.
        result.feedAsOf = (parsed.feedAsOf != null)
            ? parsed.feedAsOf
            : ((request == null || request.asOf == null) ? System.now() : request.asOf);
        return result;
    }

    /**
     * @return `'Stub'` - the `Sync_Run__c.Source__c` value recorded for a fixture-driven run.
     */
    public String sourceLabel() {
        return SOURCE_LABEL;
    }
}
