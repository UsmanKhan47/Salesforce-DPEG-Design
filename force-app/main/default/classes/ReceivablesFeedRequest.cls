/**
 * The parameters one provider fetch is given. Pure data.
 *
 * LAYER - DTO. Exists so `ReceivablesFeedProvider.fetch` has a stable single-argument signature:
 * adding a parameter later (a page cursor, a property filter) becomes a member on this class and
 * NOT a signature change rippling through both providers, the queueable and every test.
 *
 * @see ReceivablesFeedProvider.cls
 */
public class ReceivablesFeedRequest {

    /**
     * The `Sync_Run__c` this fetch belongs to. Carried so a provider can correlate its own logging
     * with the audit row; no provider is required to use it.
     */
    public Id syncRunId;

    /**
     * The moment the run started, captured ONCE by the queueable. Providers must use this rather
     * than calling `System.now()` themselves, so every timestamp in one run agrees.
     */
    public DateTime asOf;

    /** Upper bound on rows requested. Null =&gt; provider default. */
    public Integer maxRows;

    public ReceivablesFeedRequest() {}

    /**
     * @param syncRunId The audit row this fetch belongs to.
     * @param asOf      Run start, captured once.
     * @param maxRows   Row cap, or null for the provider default.
     */
    public ReceivablesFeedRequest(Id syncRunId, DateTime asOf, Integer maxRows) {
        this.syncRunId = syncRunId;
        this.asOf = asOf;
        this.maxRows = maxRows;
    }
}
