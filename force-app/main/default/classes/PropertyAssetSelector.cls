/**
 * Selector for Property_Asset__c. Encapsulates ALL SOQL against Property_Asset__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - SellMeterController.getMeterSummary  -> selectAllForMeterSummary
 *   - SellMeterController.getPortfolio     -> selectAllForPortfolio
 *   - DispositionService.findOrCreate      -> selectPeakSellDateById
 *   - DispositionService.initiateAndSubmit -> selectPeakSellDateById (same read)
 *   - PropertyAssetService.ensureOnClosedWon -> selectByPropertyIds   (Tranche 5A,
 *     2026-08-10 — `WITH SYSTEM_MODE` + `without sharing`)
 *   - DispositionAssetDisposalService.markAssetsDisposed -> selectStatusByIds
 *     (Conversion 6 / BA story 49, 2026-09-02 — the SECOND `WITH SYSTEM_MODE` +
 *     `without sharing` method here; it has its OWN inner class and its OWN justification,
 *     which is NOT a copy of the first one's)
 *
 * ⚠ MODE IS NOW A PROPERTY OF THE METHOD, NOT OF THE CLASS. READ THE METHOD.
 * The three original queries use `WITH USER_MODE` (API 67); `selectByPropertyIds` and
 * `selectStatusByIds` use `WITH SYSTEM_MODE` and live in the `private without sharing`
 * inner classes `AssetCreationReads` and `DisposalReads` respectively. Property_Asset__c is
 * a custom object and P3 proved the custom-field FLS gap is 0, so USER_MODE is safe for the
 * three user-requested reads and enforces the running user's sharing + FLS.
 * 🔴 TWO ESCAPING METHODS IS NOT A LICENCE FOR A THIRD BY ANALOGY. Each is an
 * AUTOMATION-PATH read running as a principal who did not ask for it (a Transactions
 * persona closing a deal; a disposition principal approving a closing), and each backs an
 * IDEMPOTENCY GUARD, where a sharing-filtered read does not disable the feature — it
 * INVERTS it. Anything user-requested stays USER_MODE and `with sharing`.
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
 * SELL-CANDIDATE FILTER — both queries share the SAME predicate, and as of
 * 2026-09-02 it has THREE terms, not two:
 *     Property__c != null AND Peak_Sell_Date__c != null AND Status__c != 'Disposed'
 * so the top summary widgets (selectAllForMeterSummary) and the list
 * (selectAllForPortfolio) always agree. Rationale for the first two: the Sell Meter
 * is a disposition-evaluation widget, not a raw dump of every Property_Asset__c row.
 * An asset with a null Property__c is an un-parented seed/junk record, and
 * Peak_Sell_Date__c is the field that drives the readiness band
 * (SellMeterService.bandForPeak) — an asset with no peak date is not yet
 * "on the meter". Excluding both keeps the widget to real sell candidates.
 *
 * 🔴 THE THIRD TERM IS CONVERSION 6 (BA story 49) AND IT MUST MOVE ON BOTH QUERIES
 * IN THE SAME EDIT. A building DPEG has already SOLD is not a sell candidate: it must
 * leave the Sell Meter table AND stop being counted in the band tiles and the Portfolio
 * Upside figure, or the Home page and the Disposition dashboard disagree about the same
 * portfolio — which is the disagreement decision A3 existed to end. If only one of the
 * two queries acquires the term, the summary tiles and the list below them disagree with
 * each other on the SAME page, which is the defect this shared-predicate paragraph exists
 * to prevent. `DispositionAssetDisposalService` is the writer that makes the term
 * load-bearing; before 2026-09-02 nothing in the application ever wrote `'Disposed'`.
 *
 * 🔴 `!= 'Disposed'`, NEVER `= 'Active'`, AND THAT IS NOT A STYLE CHOICE.
 * `Status__c` is `required = false`. SOQL's `!=` INCLUDES null rows, so a status-less
 * asset stays on the meter; `= 'Active'` would silently delete it from both surfaces the
 * day anyone created an asset without a status — and the restricted picklist's `Active`
 * default only applies to rows the platform defaults, not to an explicit null. The two
 * predicates are the same on today's data and diverge on the first blank.
 * ⚠ Both queries are `WITH USER_MODE`, and USER_MODE enforces FLS on WHERE-clause fields
 * as well as SELECTed ones. `Property_Asset__c.Status__c` is granted readable in BOTH
 * `DPEG_Disposition_View` and `DPEG_Disposition_Edit`, so adding it to the predicate costs
 * no permission work — but a future field added to this WHERE clause is a new way for the
 * whole Sell Meter to throw for a persona that lacks it.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class PropertyAssetSelector {

    /**
     * The one `Property_Asset__c.Status__c` value that takes an asset OFF the Sell Meter.
     *
     * 🔴 BOUND WITH `:STATUS_DISPOSED` RATHER THAN INLINED AS A LITERAL IN TWO QUERIES. The
     * shared-predicate invariant in the class header is only true if the two queries cannot
     * drift, and two hand-typed literals are exactly how they drift — a mis-cased `'disposed'`
     * would be silently accepted by SOQL's case-insensitive comparison today and is precisely
     * the kind of near-miss nobody re-reads. One constant, two bind variables.
     *
     * ⚠ IT IS DELIBERATELY NOT SHARED WITH `DispositionAssetDisposalService.STATUS_DISPOSED`.
     * That one is the value the WRITER writes; this one is the value the READER excludes. They
     * are the same string for an obvious reason and they answer different questions — a
     * selector that imported a service constant would invert this class's dependency direction
     * (selectors are called BY services, never the reverse) for no gain.
     */
    @TestVisible
    private static final String STATUS_DISPOSED = 'Disposed';

    /**
     * Sell-candidate Property Assets with just the fields the readiness-band
     * roll-up needs — backs SellMeterController.getMeterSummary. Filtered to
     * Property__c != null AND Peak_Sell_Date__c != null AND Status__c != 'Disposed'
     * (see class header) so the summary counts match the getPortfolio list exactly.
     * No ordering: the caller only aggregates (counts per band and sums portfolio
     * upside), so order is irrelevant.
     *
     * ⚠ `Status__c` IS IN THE WHERE CLAUSE AND NOT IN THE SELECT, DELIBERATELY. The caller
     * aggregates bands and sums upside; it never renders a status. Adding the column would
     * violate the minimal-field-list rule this class applies to `selectPeakSellDateById`
     * for the same reason — every selected field is another way for a USER_MODE read to
     * throw. A predicate-only field is still FLS-enforced, which is why the class header
     * records the grant rather than leaving it implied.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property, non-null
     *         Peak_Sell_Date, not `Disposed`) with NOI__c, Market_Cap_Rate__c,
     *         Target_Sale_Price__c and Peak_Sell_Date__c; an empty list when none qualify.
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) { ... }
     */
    public static List<Property_Asset__c> selectAllForMeterSummary() {
        return [
            SELECT NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Peak_Sell_Date__c
            FROM Property_Asset__c
            WHERE Property__c != null
              AND Peak_Sell_Date__c != null
              AND Status__c != :STATUS_DISPOSED
            WITH USER_MODE
        ];
    }

    /**
     * Sell-candidate Property Assets, name-ordered, with the full field set the
     * Sell Meter portfolio table renders — backs SellMeterController.getPortfolio.
     * Filtered to Property__c != null AND Peak_Sell_Date__c != null AND
     * Status__c != 'Disposed' (see class header) so the list matches the summary
     * counts exactly. ORDER BY Name keeps the table alphabetised.
     *
     * ⚠ THE THIRD PREDICATE TERM IS THE SAME EDIT AS `selectAllForMeterSummary`'s AND MUST
     * STAY THAT WAY. This is the query behind the table AND behind the Initiate button, so
     * this is where the user-visible half of Conversion 6 lands: after it, the Sell Meter
     * stops offering "Initiate Disposition" on a building DPEG has already sold.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property, non-null
     *         Peak_Sell_Date, not `Disposed`) ordered by Name, with the portfolio field set
     *         (Id, Name, Property__r.Asset_Type__c, NOI__c, Market_Cap_Rate__c,
     *         Target_Sale_Price__c, Argus_Signal__c, Peak_Sell_Date__c,
     *         Projected_Value_At_Peak__c) populated; an empty list when none qualify.
     */
    public static List<Property_Asset__c> selectAllForPortfolio() {
        return [
            SELECT Id, Name, Property__r.Asset_Type__c,
                   NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c,
                   Peak_Sell_Date__c, Projected_Value_At_Peak__c
            FROM Property_Asset__c
            WHERE Property__c != null
              AND Peak_Sell_Date__c != null
              AND Status__c != :STATUS_DISPOSED
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * The peak sell date for ONE Property Asset — backs the server-side sell-meter gate on BOTH
     * disposition create paths (DispositionService.findOrCreate and .initiateAndSubmit, create
     * branch only).
     *
     * ⚠ IT CARRIED `Target_Sale_Price__c` FOR A FEW HOURS ON 2026-08-25 AND NO LONGER DOES.
     * The column was added that morning to seed the new Disposition's `Asking_Price__c`
     * ("Expected Value"); the user then retired `Asking_Price__c` from the disposition flow, both
     * create paths lost the stamp, and the column was left with NO CONSUMER — so it was removed
     * the same day under the minimal-field-list rule below rather than kept "in case". The name
     * and the field list agree again. `BOV_Score__c` and the Disposition-Readiness submission gate
     * both read `Target_Sale_Price__c` straight off the asset now
     * (`Disposition__r.Property_Asset__r.…` / `DispositionSelector.selectApprovalContextById`),
     * neither through here.
     *
     * FETCH-FOR-USE: the caller feeds Peak_Sell_Date__c straight into
     * SellMeterService.bandForPeak, so an Id that resolves to no row is an error, not a
     * normal state. The single-row SOQL assignment throws the native
     * System.QueryException, which the controller maps to its generic write-failure
     * message — deliberately NOT the sell-meter refusal wording, because a missing asset
     * is a platform failure and a red band is a designed refusal.
     *
     * 🔴 THE FIELD LIST IS MINIMAL AND MUST STAY THAT WAY — THE 2026-08-25 ROUND TRIP IS THE
     * EVIDENCE, NOT A COUNTEREXAMPLE. This query runs on every disposition CREATE, so every field
     * added here becomes a new way for a legitimate creation to be refused by an FLS gap under
     * WITH USER_MODE. ONE field, one named consumer: Peak_Sell_Date__c is the sell-meter gate's
     * only input. Nothing may be added without a consumer of the same kind, and anything whose
     * consumer goes away comes back out.
     *
     * ⚠ Note this method has NO sell-candidate filter, unlike its two siblings. Those
     * filter to Property__c != null AND Peak_Sell_Date__c != null because they paint the
     * meter; this one must be able to READ a null peak date, because a null peak is
     * precisely what bands RED and refuses the creation. Adding the filter here would turn
     * a refusal into a QueryException and the wrong error message.
     *
     * @param assetId Property_Asset__c Id to read; must reference an existing row.
     * @return The Property_Asset__c with Id and Peak_Sell_Date__c populated (the date may itself
     *         be null — see the no-filter note above).
     * @throws System.QueryException when no Property_Asset__c matches the Id.
     * @example
     * Property_Asset__c a = PropertyAssetSelector.selectPeakSellDateById(assetId);
     * String band = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
     */
    public static Property_Asset__c selectPeakSellDateById(Id assetId) {
        return [
            SELECT Id, Peak_Sell_Date__c
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
    /**
     * The CURRENT status of a set of assets — the IDEMPOTENCY GUARD behind
     * `DispositionAssetDisposalService.markAssetsDisposed` (Conversion 6 / BA story 49,
     * 2026-09-02).
     *
     * The caller has already narrowed to the assets whose disposition just TRANSITIONED into
     * `Sale Closes`; this read answers the second question — "is it already `Disposed`?" — so
     * a second disposition closing on the same asset, or any re-entry, writes nothing at all
     * rather than firing `PropertyAssetTrigger` on a save that changes no value.
     *
     * ⚠ THE FIELD SET IS DELIBERATELY MINIMAL (Id + Status__c) AND MUST STAY THAT WAY, for the
     * same reason as `selectByPropertyIds`: this runs inside the transaction that closes a
     * sale, so every added field is another way for a closing to fail. The caller builds a
     * one-field SHELL from the Id and never reads anything else off these rows — see that
     * service's cascade note for why re-using the queried record would be actively wrong.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION-PATH read (ARCHITECTURE.md §2): it runs inside an after-update trigger
     * nobody asked for, on behalf of an approver who clicked Approve on an approval process.
     * `WITH USER_MODE` does not degrade, it THROWS, and the throw escapes as
     * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, rolling back the stage advance and — on the
     * approval path — failing the whole Queueable execution. The disposition principal
     * personas (`DPEG_Disposition_View` / `DPEG_Disposition_Edit`) DO grant
     * `Property_Asset__c.Status__c` today, so this is belt-and-braces on FLS; it is not
     * belt-and-braces on CRUD, because a future approver drawn from a persona with no
     * `Property_Asset__c` object permission at all would fail the query outright.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `DisposalReads` INNER CLASS ── This is the half
     * that actually bites, and it fails SILENTLY rather than loudly: a sharing-filtered read
     * returns no row, the caller's `updates` list comes back empty, and the asset is NEVER
     * disposed — with no exception, no log line and no marker on any record. Read that class's
     * header before changing anything here.
     *
     * BULK read (Set&lt;Id&gt;): called ONCE per trigger chunk regardless of disposition count,
     * and only when at least one row entered `Sale Closes`. Never call it per record.
     *
     * @param assetIds Property_Asset__c Ids to read; null/empty-safe.
     * @return Property_Asset__c records with Id and Status__c populated, one row per asset that
     *         exists; an empty list when the input is null/empty or no Id resolves (never null).
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectStatusByIds(assetIds)) { ... }
     */
    public static List<Property_Asset__c> selectStatusByIds(Set<Id> assetIds) {
        if (assetIds == null || assetIds.isEmpty()) {
            return new List<Property_Asset__c>();
        }
        return new DisposalReads().byIds(assetIds);
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 CONVERSION 6'S IDEMPOTENCY READ, WHICH MUST RUN **WITHOUT SHARING** — AND THE COST OF
     *    GETTING IT WRONG IS SILENCE, WHICH IS WORSE THAN THE DUPLICATE ITS SIBLING GUARDS.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `SYSTEM_MODE` lifts FLS and CRUD only; it does NOT lift record sharing (ARCHITECTURE.md §2).
     * Measured against this repo 2026-09-02:
     *   - `objects/Property_Asset__c/Property_Asset__c.object-meta.xml` ->
     *     `sharingModel = Private`.
     *   - `sharingRules/Property_Asset__c.sharingRules-meta.xml` holds ONE criteria rule,
     *     `Property_Asset_PM_All_RW`, sharing `Status__c != ''` to the `DPEG_Property_Mgmt_Team`
     *     public group ONLY. A DISPOSITION principal is not in that group.
     *   - `DPEG_Disposition_View` and `DPEG_Disposition_Edit` grant the FIELD, and neither grants
     *     `modifyAllRecords` on the object. `viewAllRecords` comes from the PropertyAsset /
     *     PropertyMgmt / Acquisitions sets, which a disposition approver need not hold.
     *
     * WHO RUNS IT: the `Closing_Approval` APPROVER. **A Queueable executes as the ENQUEUING
     * user**, and the enqueuing transaction is the approval itself, so
     * `DispositionApprovalAdvanceQueueable` -> `DispositionTrigger` -> the disposal service ->
     * here all run as whoever clicked Approve — a principal who does not own the asset, on an
     * object whose OWD is Private. That is structural, not incidental: an approval process exists
     * because approver and submitter are different people.
     *
     * 🔴 WHY THIS ONE IS MORE DANGEROUS THAN AN ORDINARY FILTERED READ. Under `with sharing` the
     * query returns ZERO rows, the caller finds nothing to update, and `markAssetsDisposed`
     * returns having done nothing — successfully. The disposition advances to `Sale Closes`, the
     * asset stays `Active`, it stays on the Sell Meter and in eight dashboard reports, and there
     * is no exception, no failed job and no stuck flag anywhere to notice. It would work
     * perfectly in every test (which run as an admin) and never once in production. That is the
     * exact shape of the `SYSTEM_MODE`-is-not-sharing incident this repo has already paid for on
     * `DispositionApprovalAdvanceService`, and of the duplicate-asset hazard `AssetCreationReads`
     * above exists to prevent — same mechanism, quieter symptom.
     *
     * ═══ WHAT THIS DOES NOT WIDEN ═══
     * Two fields, consumed as an "is it already Disposed?" test inside one service method, never
     * returned to a caller and never rendered. The three user-facing reads on the outer class are
     * untouched and stay `with sharing` + `WITH USER_MODE`.
     *
     * ═══ SCOPE — AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly and
     * `PropertyAssetSelector` itself STAYS `with sharing`. It is `private`, so the only way in is
     * the public static wrapper above. It is a SECOND inner class rather than a second method on
     * `AssetCreationReads` on purpose: that class is named and justified for the Closed-Won asset
     * CREATION path, and folding an unrelated disposition read into it would make one
     * justification cover two decisions it was never written to cover.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new DisposalReads()` at the call site.
     */
    private without sharing class DisposalReads {

        /**
         * Current status for a set of assets, read without sharing. See `selectStatusByIds` for
         * the `SYSTEM_MODE` justification and the enclosing class for the sharing one.
         *
         * @param assetIds The assets to check; never null/empty (the wrapper guards it).
         * @return One row per asset that exists, with Id and Status__c; empty when none resolve.
         */
        private List<Property_Asset__c> byIds(Set<Id> assetIds) {
            return [
                SELECT Id, Status__c
                FROM Property_Asset__c
                WHERE Id IN :assetIds
                WITH SYSTEM_MODE
            ];
        }
    }

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
