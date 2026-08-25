/**
 * Selector for Property_Asset__c. Encapsulates ALL SOQL against Property_Asset__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - SellMeterController.getMeterSummary  -> selectAllForMeterSummary
 *   - SellMeterController.getPortfolio     -> selectAllForPortfolio
 *   - DispositionService.findOrCreate      -> selectPeakSellDateById
 *   - DispositionService.initiateAndSubmit -> selectPeakSellDateById (same read; since
 *     2026-08-25 it also carries Target_Sale_Price__c for the Expected Value stamp)
 *   - PropertyAssetService.ensureOnClosedWon -> selectByPropertyIds   (Tranche 5A,
 *     2026-08-10 — the ONE `WITH SYSTEM_MODE` + `without sharing` method here)
 *
 * ⚠ MODE IS NOW A PROPERTY OF THE METHOD, NOT OF THE CLASS. READ THE METHOD.
 * The three original queries use `WITH USER_MODE` (API 67); `selectByPropertyIds` uses
 * `WITH SYSTEM_MODE` and lives in the `private without sharing` inner class
 * `AssetCreationReads`. Property_Asset__c is a custom object and P3 proved the
 * custom-field FLS gap is 0, so USER_MODE is safe for the three user-requested reads and
 * enforces the running user's sharing + FLS.
 *
 * ⚠ selectPeakSellDateById is USER_MODE and does NOT belong in ARCHITECTURE.md §2's
 * SYSTEM_MODE automation-path table. It backs a read the user explicitly requested by
 * clicking Initiate/Override on the Sell Meter — no trigger, no queueable, no batch. A
 * USER_MODE denial there is a real provisioning gap the user should see, not a silently
 * disabled automation. The same is true of the two Sell Meter scans. 🔴 NONE OF THE THREE
 * MAY BE WIDENED on the strength of the fourth — its justification is specific to an
 * automation path that runs inside an after-update trigger.
 *
 * NOT-FOUND CONTRACT is per-caller and encoded in the method shape:
 *   - read-for-display (selectAllForMeterSummary / selectAllForPortfolio) -> portfolio
 *     scans the caller iterates, so each returns its natural empty List, never null.
 *   - fetch-for-use    (selectPeakSellDateById) -> the caller reads a field off the
 *     result immediately, so a miss is an error. A single-row SOQL assignment throws the
 *     native System.QueryException, matching OpportunitySelector.selectStageRequiredById
 *     and the contract documented in DispositionSelector's header.
 *
 * SELL-CANDIDATE FILTER — both queries share the SAME predicate:
 *     Property__c != null AND Peak_Sell_Date__c != null
 * so the top summary widgets (selectAllForMeterSummary) and the list
 * (selectAllForPortfolio) always agree. Rationale: the Sell Meter is a
 * disposition-evaluation widget, not a raw dump of every Property_Asset__c row.
 * An asset with a null Property__c is an un-parented seed/junk record, and
 * Peak_Sell_Date__c is the field that drives the readiness band
 * (SellMeterService.bandForPeak) — an asset with no peak date is not yet
 * "on the meter". Excluding both keeps the widget to real sell candidates.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class PropertyAssetSelector {

    /**
     * Sell-candidate Property Assets with just the fields the readiness-band
     * roll-up needs — backs SellMeterController.getMeterSummary. Filtered to
     * Property__c != null AND Peak_Sell_Date__c != null (see class header) so the
     * summary counts match the getPortfolio list exactly. No ordering: the caller
     * only aggregates (counts per band and sums portfolio upside), so order is
     * irrelevant.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property and
     *         Peak_Sell_Date) with NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c
     *         and Peak_Sell_Date__c; an empty list when none qualify.
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) { ... }
     */
    public static List<Property_Asset__c> selectAllForMeterSummary() {
        return [
            SELECT NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Peak_Sell_Date__c
            FROM Property_Asset__c
            WHERE Property__c != null AND Peak_Sell_Date__c != null
            WITH USER_MODE
        ];
    }

    /**
     * Sell-candidate Property Assets, name-ordered, with the full field set the
     * Sell Meter portfolio table renders — backs SellMeterController.getPortfolio.
     * Filtered to Property__c != null AND Peak_Sell_Date__c != null (see class
     * header) so the list matches the summary counts exactly. ORDER BY Name keeps
     * the table alphabetised.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property and
     *         Peak_Sell_Date) ordered by Name, with the portfolio field set (Id,
     *         Name, Property__r.Asset_Type__c, NOI__c, Market_Cap_Rate__c,
     *         Target_Sale_Price__c, Argus_Signal__c, Peak_Sell_Date__c,
     *         Projected_Value_At_Peak__c) populated; an empty list when none qualify.
     */
    public static List<Property_Asset__c> selectAllForPortfolio() {
        return [
            SELECT Id, Name, Property__r.Asset_Type__c,
                   NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c,
                   Peak_Sell_Date__c, Projected_Value_At_Peak__c
            FROM Property_Asset__c
            WHERE Property__c != null AND Peak_Sell_Date__c != null
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * The peak sell date AND the target sale price for ONE Property Asset — backs the
     * server-side sell-meter gate plus the Expected Value stamp on BOTH disposition create
     * paths (DispositionService.findOrCreate and .initiateAndSubmit, create branch only).
     *
     * ⚠ THE NAME SAYS PEAK SELL DATE AND THE QUERY NOW RETURNS TWO FIELDS. KEPT DELIBERATELY
     * (2026-08-25) — this is the single "read the asset before creating its Disposition" query,
     * both callers already had it in hand, and renaming it would churn every caller and every
     * test to describe a field list that will keep growing with the create path. Read this doc,
     * not the name, for what it returns.
     *
     * FETCH-FOR-USE: the caller feeds Peak_Sell_Date__c straight into
     * SellMeterService.bandForPeak, so an Id that resolves to no row is an error, not a
     * normal state. The single-row SOQL assignment throws the native
     * System.QueryException, which the controller maps to its generic write-failure
     * message — deliberately NOT the sell-meter refusal wording, because a missing asset
     * is a platform failure and a red band is a designed refusal.
     *
     * ⚠ THE FIELD LIST IS STILL MINIMAL, AND THE REASON IT MUST STAY THAT WAY IS UNCHANGED.
     * This query runs on every disposition CREATE, so every field added here becomes a new way
     * for a legitimate creation to be refused by an FLS gap under WITH USER_MODE. Two fields,
     * each with a named consumer: Peak_Sell_Date__c is the gate's only input, and
     * Target_Sale_Price__c is copied onto the new Disposition's Asking_Price__c ("Expected
     * Value"), which the Disposition Readiness submission guard requires and BOV_Score__c's
     * value dimension divides by. Nothing else may be added without a consumer of the same kind.
     *
     * ⚠ Target_Sale_Price__c MAY BE NULL AND THAT IS A NORMAL STATE, exactly like the peak date
     * below. The caller stamps the null through; the Readiness submission guard in
     * DispositionApprovalService is what refuses a blank Expected Value later, with an authored
     * message. This selector does not filter on it and must not start.
     *
     * ⚠ Note this method has NO sell-candidate filter, unlike its two siblings. Those
     * filter to Property__c != null AND Peak_Sell_Date__c != null because they paint the
     * meter; this one must be able to READ a null peak date, because a null peak is
     * precisely what bands RED and refuses the creation. Adding the filter here would turn
     * a refusal into a QueryException and the wrong error message.
     *
     * @param assetId Property_Asset__c Id to read; must reference an existing row.
     * @return The Property_Asset__c with Id, Peak_Sell_Date__c and Target_Sale_Price__c
     *         populated (either value may itself be null).
     * @throws System.QueryException when no Property_Asset__c matches the Id.
     * @example
     * Property_Asset__c a = PropertyAssetSelector.selectPeakSellDateById(assetId);
     * String band = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
     * d.Asking_Price__c = a.Target_Sale_Price__c;
     */
    public static Property_Asset__c selectPeakSellDateById(Id assetId) {
        return [
            SELECT Id, Peak_Sell_Date__c, Target_Sale_Price__c
            FROM Property_Asset__c
            WHERE Id = :assetId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Every existing asset for a set of properties — the IDEMPOTENCY GUARD behind
     * `PropertyAssetService.ensureOnClosedWon` (Tranche 5A, decision D27.3: "never a second
     * asset for one property").
     *
     * 🔴 THE KEY IS `Property__c` ALONE, WITH NO `Status__c` FILTER, AND THAT IS THE
     * DECISION RATHER THAN AN OMISSION. A property bought, sold (`Status__c = 'Disposed'`)
     * and bought back therefore gets NO second asset. That is correct here: the whole
     * Property Management tree — Units, Rent Steps, Onboarding, CAM, Delinquency, Insurance,
     * Broker Assignments, Lease Inquiries, Lease Renewals, Work Orders — hangs off the asset,
     * so a second one would SPLIT that history in two and give every PM child's parent picker
     * two identically-named rows. Re-acquisition is expressed by moving the existing asset
     * back to `Active`, not by minting a rival.
     *
     * ⚠ THE FIELD SET IS DELIBERATELY MINIMAL (Id + Property__c) and must stay that way. The
     * caller uses the result ONLY as a set-membership test — it reads `Property__c` and never
     * touches `Id` beyond selecting a valid row. This query runs on every Closed Won org-wide,
     * so each added field is another way for a deal close to fail.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read (ARCHITECTURE.md §2): it runs inside an after-update trigger
     * nobody asked for. `WITH USER_MODE` does not degrade, it THROWS, and the throw escapes
     * as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, rolling back the deal close — verbatim the
     * `TaskSelector.selectByTransactionDealIds` production incident. Measured on this repo
     * 2026-08-10: `DPEG_Transaction_Team` (the persona whose Transaction save drives the
     * `Transaction_Complete_Close` flow, which writes `StageName = 'Closed Won'` with NO
     * `<runInMode>` and therefore as that user) grants **no `Property_Asset__c` permission of
     * any kind** — not read, not create. A `USER_MODE` query for them does not merely lose
     * FLS on a field; it fails CRUD on the object.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `AssetCreationReads` INNER CLASS ── For an
     * idempotency guard the sharing half is the DANGEROUS half: a filtered read returns
     * "no asset exists" and the caller creates a DUPLICATE. Read that class's header.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per trigger chunk regardless of deal count.
     * Never call it per record.
     *
     * @param propertyIds Property Ids whose assets to look for (bound with IN); null/empty-safe.
     * @return Property_Asset__c records with Id and Property__c populated, one row per
     *         EXISTING asset (a property with two assets returns two); an empty list when the
     *         input is null/empty or no property has an asset yet (never null).
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectByPropertyIds(propertyIds)) {
     *     propertyIds.remove(a.Property__c);
     * }
     */
    public static List<Property_Asset__c> selectByPropertyIds(Set<Id> propertyIds) {
        if (propertyIds == null || propertyIds.isEmpty()) {
            return new List<Property_Asset__c>();
        }
        return new AssetCreationReads().byPropertyIds(propertyIds);
    }

    /**
     * 🔴 THE CLOSED-WON IDEMPOTENCY GUARD'S READ, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH, AND HERE THE COST OF GETTING IT WRONG IS
     * A DUPLICATE RATHER THAN A SILENCE ═══
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing. Measured
     * against this repo 2026-08-10:
     *   - `objects/Property_Asset__c/Property_Asset__c.object-meta.xml` ->
     *     `sharingModel = Private`.
     *   - `sharingRules/Property_Asset__c.sharingRules-meta.xml` holds ONE criteria rule,
     *     sharing `Status__c != ''` to the `DPEG_Property_Mgmt_Team` public group ONLY.
     *   - `viewAllRecords = true` comes from `DPEG_Acquisitions`, `DPEG_PropertyAsset_View`,
     *     `DPEG_PropertyMgmt_Edit` and `DPEG_PropertyMgmt_View`. `Property_Management_Access`
     *     sets it FALSE, and `DPEG_Transaction_Team` grants the object nothing at all.
     *
     * So under `with sharing` a Transactions persona closing a deal through
     * `Transaction_Complete_Close` sees NONE of the assets that already exist, the guard
     * passes, and a SECOND `Property_Asset__c` is created for a property that already had
     * one — silently, with both rows carrying the same Name. That is the exact failure D27.3
     * calls out as the one thing this feature must never do, reproduced inside the fix.
     * Every other guard in this repo (`ensureNda`, `openTransactionsOnAboutToClose`) is
     * keyed on an object whose OWD makes the question moot; this one is not.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * Two Ids, consumed as a `Set` membership test inside one service method, never returned
     * to a caller and never rendered. The three user-facing reads on the outer class are
     * untouched and stay `with sharing` + `WITH USER_MODE`.
     *
     * ═══ PRECEDENT ═══
     * `InboundEmailStagingSelector.RoutingReads` (2026-08-08) and `LeadSelector.GuestReads`.
     * An automation that must act on ALL matching rows cannot be scoped by an incidental
     * principal's sharing.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly
     * and `PropertyAssetSelector` itself STAYS `with sharing`. It is `private`, so the only
     * way in is the public static wrapper above.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new AssetCreationReads()` at the call site.
     */
    private without sharing class AssetCreationReads {

        /**
         * Existing assets for a set of properties, read without sharing. See
         * `selectByPropertyIds` for the key choice and the `SYSTEM_MODE` justification, and
         * the enclosing class for the sharing one.
         *
         * @param propertyIds The properties to check; never null/empty (the wrapper guards it).
         * @return One row per existing asset; empty when none of the properties has one.
         */
        private List<Property_Asset__c> byPropertyIds(Set<Id> propertyIds) {
            return [
                SELECT Id, Property__c
                FROM Property_Asset__c
                WHERE Property__c IN :propertyIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
