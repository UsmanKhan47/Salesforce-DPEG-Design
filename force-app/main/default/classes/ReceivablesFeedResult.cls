/**
 * ONE PROVIDER FETCH: the rows, and - load-bearing - THE FEED'S OWN CLOCK.
 *
 * LAYER - DTO. Pure data; also the `JSON.deserialize` target for both providers, so its member
 * names are part of the wire contract (`feedAsOf`, `rows`).
 *
 * === `feedAsOf` IS WHY THIS TYPE EXISTS AT ALL ===
 * A naive health check asks "when did we fetch?" and always answers "just now", which makes the
 * staleness rule permanently vacuous. FSD 5.9.6 step 2 halts on a STALE FEED, and a feed can be
 * three days old while the HTTP call that retrieved it is two seconds old. So staleness is measured
 * against the SOURCE's own as-of timestamp and never against `System.now()` at the point of fetch.
 *
 * WARNING - A NULL `feedAsOf` IS TREATED AS STALE, NOT AS FRESH. A feed that will not state its own
 * age cannot be proven fresh, and the point of the halt rule is to refuse to act on data whose
 * provenance is unknown. `ReceivablesHealthCheckDomain` enforces that.
 *
 * WARNING - `rows` MAY ARRIVE NULL FROM `JSON.deserialize` when the payload omits the member; a
 * no-arg constructor does NOT reliably run on a deserialized instance. Both providers call
 * `normalize()` immediately after deserializing so no caller downstream has to null-check.
 *
 * @see ReceivablesHealthCheckDomain.cls (consumes feedAsOf and rows.size())
 */
public class ReceivablesFeedResult {

    /**
     * The SOURCE's as-of timestamp. Stamped onto `Sync_Run__c.Feed_As_Of_DateTime__c` and onto
     * every mirror row's `Yardi_Last_Synced_DateTime__c`. Null =&gt; the health check halts.
     */
    public DateTime feedAsOf;

    /** The normalized rows. Never null after `normalize()`. */
    public List<ReceivablesFeedDTO> rows;

    /**
     * The Apex class that produced this result - stamped onto
     * `Sync_Run__c.Provider_Class_Name__c`. Proves WHAT RAN, not what config claimed.
     */
    public String providerName;

    /**
     * `Sync_Run__c.Source__c` value ('Stub' or 'ASB'), supplied by the provider rather than
     * inferred from a class-name substring. Adding a provider must not require editing a
     * string-matching branch somewhere else.
     */
    public String source;

    public ReceivablesFeedResult() {
        this.rows = new List<ReceivablesFeedDTO>();
    }

    /**
     * Guarantees `rows` is non-null and drops rows with no `yardiArId` - such rows are unroutable,
     * because that value is both the mirror upsert key and the Case idempotency guard key. A silent
     * drop is correct here: the row count AFTER normalization is what the health check measures, so
     * a feed full of keyless rows fails the minimum-row-count arm rather than upserting garbage.
     *
     * @return This instance, for chaining after a deserialize.
     */
    public ReceivablesFeedResult normalize() {
        if (this.rows == null) {
            this.rows = new List<ReceivablesFeedDTO>();
            return this;
        }
        List<ReceivablesFeedDTO> kept = new List<ReceivablesFeedDTO>();
        for (ReceivablesFeedDTO row : this.rows) {
            if (row != null && String.isNotBlank(row.yardiArId)) {
                kept.add(row);
            }
        }
        this.rows = kept;
        return this;
    }
}
