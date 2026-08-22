/**
 * ONE NORMALIZED RECEIVABLES ROW, SOURCE-AGNOSTIC BY CONSTRUCTION.
 *
 * LAYER - DTO. Pure data. No SOQL, no DML, no sharing keyword (it holds nothing to protect).
 *
 * === WHY THIS TYPE IS THE POINT OF THE WHOLE FEATURE ===
 * `ReceivablesSyncService.ingest(List<ReceivablesFeedDTO>, Id)` is the ONE entry point every
 * provider funnels into. Nothing downstream of that call - not the mirror upsert, not the Case
 * lifecycle, not a single alert - knows or can ask where a row came from. That is what makes the
 * Yardi switch-on a CONFIG CHANGE rather than a rebuild: a new provider produces this shape and
 * stops.
 *
 * WARNING - THE FIELD NAMES HERE ARE ALSO THE JSON CONTRACT. Both providers reach this type
 * through `JSON.deserialize`, so renaming a member silently changes the wire format the ASB spoke
 * must emit and the static-resource fixture must carry. `JSON.deserialize` is used deliberately
 * rather than `deserializeStrict` so an ASB payload carrying EXTRA fields does not break the sync -
 * unknown members are ignored, missing members arrive null.
 *
 * WARNING - EVERY NUMERIC MEMBER IS NULLABLE AND CALLERS MUST TREAT NULL AS "NOT SUPPLIED", NOT AS
 * ZERO. A feed that omits `monthlyRent` is the OQ-3 case: `Months_Outstanding__c` is a formula over
 * `Monthly_Rent__c`, so substituting 0 would not blank the metric, it would corrupt it.
 * `ReceivablesSummaryDomain` falls back to `Unit__c.Current_Monthly_Rent__c` for exactly this
 * reason and never substitutes 0.
 *
 * @see ReceivablesSyncService.cls   (the single ingest entry point)
 * @see ReceivablesSummaryDomain.cls (the DTO to sObject mapping, and the null rules)
 */
public class ReceivablesFeedDTO {

    /**
     * Yardi's own AR-row key. Upsert key for `Receivables_Summary__c.Yardi_AR_Id__c` (unique) and
     * the denormalised guard key on `Case.Yardi_AR_Id__c` (external id, deliberately NOT unique -
     * see `CaseSelector`). A row with this blank is UNROUTABLE and is dropped by
     * `ReceivablesFeedResult.normalize()`.
     */
    public String yardiArId;

    /**
     * Yardi's unit key, matched against `Unit__c.Yardi_Unit_Id__c` (unique external id). This is
     * the ONLY join the feed carries: `Property_Asset__c` is derived from the matched Unit's
     * master, because `Property_Asset__c` has no external id in this org (measured 2026-08-22 via
     * describe).
     */
    public String yardiUnitId;

    /**
     * Free-text tenant label. Denormalised onto the mirror because tenant identity in this org is a
     * string - there is no `Tenant__c` object (design C3) - and the section 6.5 rankings group on it.
     */
    public String tenantName;

    /** Monthly rent - the `Months_Outstanding__c` DENOMINATOR. Null =&gt; fall back to the Unit. */
    public Decimal monthlyRent;

    /** Total outstanding across all charge types. The opening-threshold amount compares to this. */
    public Decimal totalOutstanding;

    /**
     * FSD 5.9.1's charge-type split. The whole complaint the mirror exists to answer is "is this
     * base rent, CAM, or a late fee?" - a single total cannot answer it.
     */
    public Decimal baseRentOutstanding;
    public Decimal nnnCamOutstanding;
    public Decimal lateFeeOutstanding;
    public Decimal otherOutstanding;

    /**
     * The five aging buckets (user decision 2). `currentAmount` is bucket 1 of 5 - named with the
     * `Amount` suffix rather than a bare `current` so it cannot read as a Boolean or a flag.
     */
    public Decimal currentAmount;
    public Decimal aging1To30;
    public Decimal aging31To60;
    public Decimal aging61To90;
    public Decimal aging90Plus;

    /** Days past due on the OLDEST unpaid item. Drives the 60/90-day escalation ladder. */
    public Integer daysPastDue;

    /**
     * Username of the responsible property manager (OQ-4). Resolved to a `User` by
     * `UserSelector.selectActiveByUsernames`; an unresolvable username leaves the lookup null
     * rather than guessing an owner.
     */
    public String responsiblePropertyManagerUsername;

    /**
     * Optional `Case.Reason` value - one of Non-payment / Short payment / Billing dispute /
     * Prior-owner balance. BLANK IS A FIRST-CLASS ANSWER AND MUST STAY ONE: see
     * `DelinquencyCaseService` for why an auto-defaulted reason would re-create the exact FSD 5.9.5
     * failure (chasing a tenant for a charge DPEG should never have billed).
     */
    public String delinquencyReason;
}
