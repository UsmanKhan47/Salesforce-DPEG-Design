/**
 * Creates the `Property_Asset__c` when an acquisition deal reaches **Closed Won** — the
 * handoff from Acquisitions to Property Management. Called from
 * `OpportunityReviewTriggerHandler`, after insert and after update.
 *
 * Tranche 5 Item A · decisions D27.3 + D28 · design
 * `agent-output/design-requirements-asset-and-listing.md` §2.
 *
 * ── 🔴 WHY THIS EXISTS: NOTHING CREATED A `Property_Asset__c` ──
 * Measured repo-wide 2026-08-10 and again independently at design time: **zero** creators in
 * Apex apart from `TestDataFactory`, **zero** in Flow — not one flow even REFERENCES the
 * object — and nine seed scripts. Every asset in the org today is seeded data, which is
 * precisely why the behaviour looked automatic. On a real deployment a deal closed,
 * `Deal_Status__c` read "Asset Under Management", and no asset existed — leaving the entire
 * Property Management tree (Units, Rent Steps, Onboarding, CAM, Delinquency, Insurance,
 * Broker Assignments, Lease Inquiries, Lease Renewals, Work Orders — all parented to the
 * asset) with nothing to hang from.
 *
 * ── 🔴 WHY HERE AND NOT IN THE `Transaction_Complete_Close` FLOW ──
 * That flow is the obvious home and it is the WRONG one: it would miss half the closes.
 * `StageAdvanceService.NEXT_STAGE` maps **both** `Under Contract (PSA) ⇒ Closed Won` and
 * `About to Close ⇒ Closed Won`, so a deal driver clicking Advance Stage reaches Closed Won
 * with **no `Transaction__c` in the picture at all**, and the gap would be invisible.
 * Keying on the OPPORTUNITY STAGE catches every route by construction. The trigger handler
 * already routes a non-review, stage-keyed concern for exactly this reason —
 * `ContractExecutionService.openTransactionsOnAboutToClose`, moved there 2026-08-05 — and
 * this follows that precedent rather than inventing one.
 *
 * A NEW SERVICE, not a fifth method on `OpportunityReviewService`: a `Property_Asset__c` is
 * not a REVIEW child and is not part of the deal tree. It is the handoff to a different
 * module, which is the same argument `ContractExecutionService` won.
 *
 * ── THE FIELD SET, AND WHY EACH FIELD IS IN OR OUT (D28) ──
 * The baseline is what the NINE SEED SCRIPTS populate — they already build assets that work
 * across the whole PM module, so they are the working reference for a USABLE asset rather than
 * a guess. `Property_Asset__c` has 16 custom fields plus a mandatory Text `Name`; five are
 * written here and the rest belong to Argus and Yardi, which are read-only spokes (§0).
 *
 *   WRITTEN
 *     Name              <- Property__r.Name, VERBATIM (see the inline note at the assignment)
 *     Property__c       <- Opportunity.Property__c
 *     Status__c         <- literal 'Active'
 *     Property_Type__c  <- Property__r.Asset_Type__c, MAPPED through an allow-list, never copied
 *     Closing_Date__c   <- Opportunity.CloseDate  (added 2026-08-10, user decision)
 *
 * ⚠ `Closing_Date__c` IS THE ONE EXCEPTION TO "MATCH THE SEEDS", AND THE REASON IS THE REASON
 * ITS THREE NEIGHBOURS ARE STILL OUT. No seed populates any of the four. But
 * `Final_Purchase_Price__c` has THREE candidate sources (`Opportunity.Amount`,
 * `Opportunity.My_Price__c`, `Transaction__c.Contract_Value__c` — and the last lives on a record
 * that may not exist), and `NOI__c` / `Market_Cap_Rate__c` each have TWO that are
 * SEMANTICALLY DIFFERENT NUMBERS (DPEG's own underwriting vs. the seller's marketing figure).
 * Picking one of those without a decision would store a plausible wrong number, which is the
 * same class of defect as a mismapped `Property_Type__c`. `Closing_Date__c` has exactly ONE
 * candidate — `Opportunity.CloseDate`, a required standard field, semantically exact, already
 * in `Trigger.new`, and the same type on both sides — so there is nothing to choose and no
 * query to pay for. If a source is ever settled for the other three, they belong here too.
 *
 * 🔴 ⚠ WHAT `Closing_Date__c` WILL ACTUALLY HOLD IN PRODUCTION — MEASURED, AND IT IS NOT
 * NECESSARILY THE DATE ON THE DEAL YESTERDAY. On this org, a save that moves an Opportunity
 * into `Closed Won` **without supplying `CloseDate` in that same save** hands this trigger a
 * `Trigger.new` whose `CloseDate` has been rewritten to **TODAY**; a previously committed
 * future close date is NOT what arrives. When the same save does supply a `CloseDate`, the
 * supplied value survives untouched. Both halves were isolated with a two-shape probe
 * (2026-08-10). **Nothing in this repo does this** — no flow and no workflow references
 * `CloseDate` — so it is org-side automation or platform behaviour that source control cannot
 * see. Two consequences worth knowing: the asset will normally carry the date the deal was
 * ACTUALLY closed, which is the right meaning for a field named "Closing Date" and is a happy
 * accident rather than a design; and the earliest-wins tie-break below is therefore
 * unobservable on the ordinary path, because every deal in one save arrives with the same
 * date. Post-deploy gate A-G1 reads the value back on a real close — do not infer it from here.
 *
 *   DELIBERATELY BLANK: Target_Sale_Price__c, Peak_Sell_Date__c, Argus_Signal__c,
 *   Projected_Value_At_Peak__c, Vacant_Area__c, Sell_Readiness_Score__c, Argus_Value__c
 *   (no acquisition-side source at all — Argus/Yardi), plus the three named above.
 *   Sell_Readiness_Band__c, Readiness_Score__c and Property_Name__c are FORMULAS.
 *
 * ── IDEMPOTENCY (D27.3, mandatory) ──
 * Keyed on `Property__c` ALONE, with no `Status__c` filter, so a property never acquires a
 * second asset — see `PropertyAssetSelector.selectByPropertyIds` for why a re-acquisition is
 * deliberately expressed by reactivating the existing asset rather than minting a rival.
 * Re-saving a closed deal is a no-op.
 *
 * ── 🔴 IT FAILS LOUDLY, ON PURPOSE ──
 * The insert is `allOrNone = true`, so a failure throws and rolls the deal close back. That
 * is the correct failure mode for a step whose silent absence is the bug being fixed — but it
 * is also why every input is shaped defensively before the DML: bulk-safe, no SOQL or DML in
 * a loop, both reads unable to fail on FLS or sharing (see the two selectors), and every
 * value written either a literal, a mandatory Text field, or a mapped allow-list member.
 *
 * ── ACCESS: `AccessLevel.SYSTEM_MODE` DML, AND IT IS LOAD-BEARING, NOT DEFENSIVE ──
 * Measured against this repo 2026-08-10: **no persona that can reach Closed Won holds Create
 * on `Property_Asset__c`.** `DPEG_Junior_Analyst_PSG` (the deal driver) reaches the object
 * only through `DPEG_PropertyMgmt_View` — read, `allowCreate = false`.
 * `DPEG_Transaction_Team` (whose `Transaction__c` save drives `Transaction_Complete_Close`,
 * which writes `StageName = 'Closed Won'` with **no `<runInMode>`**, i.e. as that user) holds
 * no `Property_Asset__c` permission at all. A bare `insert` therefore throws
 * `System.TypeException: DML operation INSERT not allowed on Property_Asset__c` — exactly the
 * failure `ContractExecutionService.openTransactionsOnAboutToClose` measured one object over
 * on 2026-08-05. Granting Create is the wrong fix for the same reason it was rejected there:
 * the asset is created BY THE PROCESS, and neither persona should be able to make one by hand.
 *
 * ── GOVERNOR BUDGET: 2 SOQL / 1 DML PER TRIGGER CHUNK, CONSTANT IN DEAL COUNT ──
 * A chunk closing no deal costs **zero** queries and zero DML — the guard returns before any
 * read. The counters below are what `PropertyAssetServiceTest` asserts against; they exist so
 * that a future change adding one query per record fails HERE rather than in production.
 *
 * ── ⚠ WHAT THIS DOES **NOT** DO, EACH ESTABLISHED RATHER THAN ASSUMED ──
 *  - **No record-type stamp.** `Property_Asset__c` has no record types (no
 *    `objects/Property_Asset__c/recordTypes/` directory exists), so there is nothing to stamp
 *    and `RecordTypeId` is not even a compilable field on it. The guarded-vs-unconditional
 *    argument is NOT answerable in the abstract and is deliberately not pre-decided: D16.3's
 *    (`ensureNda`), 3B's (LOI) and 3C's (PSA) three arguments each turned on a different fact
 *    — blast radius, approver identity, transaction coupling — and NONE of them transfers to a
 *    terminal stage driven by a deal driver with Edit. Whoever adds record types here makes a
 *    fourth argument, at the block, at the time.
 *  - **No parent back-stamp, therefore no `Queueable`.** There is no `Opportunity.Primary_Asset__c`
 *    and none is proposed: the join `Opportunity -> Property__c -> Property_Asset__c` already
 *    exists. Adding one would re-open the `ENTITY_IS_LOCKED` class of defect that forced
 *    `LoiPrimaryStampQueueable` and `DispositionNdaStampQueueable` into existence, for no
 *    requested benefit.
 *  - ~~**Starts no downstream automation.**~~ 🔴 **NO LONGER TRUE — AMENDED 2026-08-22.**
 *    This bullet used to read "Verified four ways at design time: no `Property_Asset__c`
 *    trigger, no flow with it as the start object, no `listViews/` directory, and its only
 *    Apex readers are `PropertyAssetSelector`, `DispositionService.findOrCreate`,
 *    `SellMeterController` and the child selectors that read UP to it." It was accurate when
 *    written and is corrected in place rather than deleted, because the next reader will
 *    otherwise trust it.
 *    `triggers/PropertyAssetTrigger.trigger` now exists (`after insert, after update`) and
 *    routes to `OnboardingAutoCreateService`, which opens a PM `Onboarding__c` for every
 *    asset whose `Closing_Date__c` transitions to non-null. **`Closing_Date__c` is written
 *    HERE, at line ~361, and nowhere else in the codebase — so THIS METHOD is what starts
 *    that cascade**, and the cascade runs on to the `Onboarding_Task_Fanout` flow, which
 *    enqueues a 45-Task-per-onboarding checklist fan-out.
 *    ⚠ Consequences to carry when editing this class:
 *      • `runQueryCount` / `runDmlCount` below now measure the DOWNSTREAM trigger too — the
 *        `Database.insert` they wrap fires it synchronously. Their asserted values in
 *        `PropertyAssetServiceTest` were updated in the same change; do not "restore" them.
 *      • `OnboardingAutoCreateService` is written so it can NEVER roll this save back
 *        (`allOrNone = false` + a catch-all). Do not add a rethrow to it: a broken
 *        onboarding checklist must not stop Acquisitions closing a signed deal.
 *      • The remaining three verifications (no flow with it as the start object, no
 *        `listViews/`, the reader list) are still accurate.
 *  - **The new asset is INVISIBLE to the Sell Meter, and that is CORRECT.**
 *    `PropertyAssetSelector` filters both meter queries on `Peak_Sell_Date__c != null`, which
 *    an auto-created asset will not have (it is Argus-derived). Recorded because the natural
 *    expectation after "closing a deal now creates an asset" is the opposite. Do not "fix" it.
 *
 * @see PropertyAssetSelector.selectByPropertyIds (idempotency read — SYSTEM_MODE + without sharing)
 * @see PropertySelector.selectAssetSeedByIds     (seed read — SYSTEM_MODE + without sharing)
 * @see ContractExecutionService.openTransactionsOnAboutToClose (the stage-keyed precedent)
 */
public with sharing class PropertyAssetService {

    /** The terminal stage that turns a deal into a managed asset. */
    @TestVisible private static final String CLOSED_WON = 'Closed Won';

    /**
     * `Property_Asset__c.Status__c` on creation. A RESTRICTED picklist whose default is
     * `Active`, so this literal is provably a member and cannot be the silent-store hazard
     * `Property_Type__c` is. Every seed script sets it, and a blank status makes the asset
     * invisible to the `Managed_Properties` / `Properties_in_AUM` reports AND excluded from
     * `Property_Asset_PM_All_RW`, the only sharing rule on the object (its criterion is
     * `Status__c != ''`) — so a blank here would hide the new asset from the Property
     * Management team that is supposed to work it.
     */
    @TestVisible private static final String STATUS_ACTIVE = 'Active';

    /**
     * 🔴 THE `Property_Type__c` ALLOW-LIST. THIS MAP IS THE ONLY THING PREVENTING A SILENT
     * BAD WRITE, AND IT IS NOT DECORATION.
     *
     * Source `Property__c.Asset_Type__c` is `<restricted>true</restricted>` with **10**
     * values. Target `Property_Asset__c.Property_Type__c` is **NOT** restricted and has **5**.
     * Five source values have no counterpart, and because the target is unrestricted an
     * off-list value **stores successfully, silently** — no error, no DML failure, no test
     * failure — producing a value nobody can pick in the UI that every report grouping by
     * property type then buckets separately. A blank is visibly incomplete; a wrong type looks
     * correct and misreports forever. So anything without a CLEAN counterpart is left blank
     * and never copied.
     *
     * MAPPED (5, all identity):
     *   Retail -> Retail · Industrial -> Industrial · Office -> Office ·
     *   Multifamily -> Multifamily · Mixed-Use -> Mixed-Use
     *
     * DELIBERATELY UNMAPPED (5) — each is a REFUSAL, not an oversight:
     *   - `Land`           no counterpart at all. A land acquisition produces an asset with a
     *                      blank type, which is the honest answer; inventing one is not.
     *   - `Storage`        no counterpart.
     *   - `Hospitality`    no counterpart.
     *   - `C-Store`        NOT folded into `Retail`. The source picklist carries `Retail` AND
     *                      `C-Store` as separate values, i.e. this org deliberately
     *                      distinguishes them; collapsing them here would destroy a
     *                      distinction the schema exists to make.
     *   - `Medical Office` NOT folded into `Office`. A distinct CRE asset class — different
     *                      tenant covenant, different cap rate. "Nearly right" is the failure
     *                      mode this map exists to prevent.
     *
     * ⚠ MATCHING IS CASE-SENSITIVE, deliberately. Apex `Map<String, String>` keys are
     * case-sensitive while the `==` operator on Strings is case-INSENSITIVE, so a map lookup
     * is the STRICTER of the two available comparisons. The source is a restricted picklist,
     * so only its own literal values can ever be stored — an exact match is correct here and a
     * case-folding "fix" would only widen what qualifies.
     *
     * ⚠ IT IS ALSO RE-CHECKED AGAINST THE LIVE PICKLIST AT RUNTIME — see `activeTypeMap()`.
     * Because the target is unrestricted, deleting a value from it would NOT start failing
     * this write; it would start silently storing an orphan.
     */
    @TestVisible
    private static final Map<String, String> PROPERTY_TYPE_BY_ASSET_TYPE = new Map<String, String>{
        'Retail'      => 'Retail',
        'Industrial'  => 'Industrial',
        'Office'      => 'Office',
        'Multifamily' => 'Multifamily',
        'Mixed-Use'   => 'Mixed-Use'
    };

    /**
     * TEST SEAM ONLY — replaces `PROPERTY_TYPE_BY_ASSET_TYPE` for one transaction.
     *
     * It exists because the describe guard in `activeTypeMap()` is otherwise UNFALSIFIABLE:
     * every target in the real map is a live picklist value, so the guard never fires and a
     * test cannot tell "the guard works" from "there is no guard". Injecting a map with a
     * target that is NOT on the picklist is the only way to prove the guard drops it instead
     * of storing it. Same problem, same remedy as the `LeadConvertService` describe guards.
     * Never set from production code.
     */
    @TestVisible private static Map<String, String> typeMapOverride;

    // ═════════════════════════════════════════════════════════════════════════════════════
    // RUN COUNTERS — test instrumentation for the governor-budget and skip-path assertions.
    //
    // They record MEASURED limit consumption (`Limits` deltas), not a hand-maintained tally of
    // the statements written here: a hand tally would assert the code back to itself and could
    // not see a query added inside a selector. Cumulative across every invocation in the
    // transaction, so a 251-record bulk update — which is TWO trigger chunks — is expected to
    // read `runInvocations = 2`, `runQueryCount = 4`, `runDmlCount = 2`.
    //
    // ⚠ They are updated after the work returns, so a throw leaves them stale. That is
    // deliberate and harmless: this service fails all-or-none, so a throw means the whole
    // transaction is already gone.
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Times the trigger handler called this service, including no-op chunks. */
    @TestVisible private static Integer runInvocations = 0;
    /** SOQL queries this service actually consumed, measured via `Limits`. */
    @TestVisible private static Integer runQueryCount = 0;
    /** DML statements this service actually consumed, measured via `Limits`. */
    @TestVisible private static Integer runDmlCount = 0;
    /** Deals that entered Closed Won carrying no `Property__c` and were skipped. */
    @TestVisible private static Integer runSkippedNoProperty = 0;
    /** Properties whose row did not come back from the seed read, so no asset was built. */
    @TestVisible private static Integer runSkippedUnreadableProperty = 0;
    /** Assets created with a blank type because the source value has no clean counterpart. */
    @TestVisible private static Integer runSkippedUnmappedType = 0;

    /** Zeroes every counter. Test-only; each test that asserts a budget calls it first. */
    @TestVisible
    private static void resetRunCounters() {
        runInvocations = 0;
        runQueryCount = 0;
        runDmlCount = 0;
        runSkippedNoProperty = 0;
        runSkippedUnreadableProperty = 0;
        runSkippedUnmappedType = 0;
    }

    /**
     * Opens the `Property_Asset__c` for every deal that just ENTERED `Closed Won`.
     *
     * Stage-ENTRY, not stage-IS: a deal already at Closed Won that is re-saved for any other
     * reason does nothing. On insert (`oldMap == null`) a record created directly at Closed Won
     * counts as entering — the same reading `openTransactionsOnAboutToClose` uses for `About to
     * Close`, and the shape data loads and migrations arrive in.
     *
     * This method is the accounting wrapper; `createAssets` does the work and owns the early
     * returns. Splitting them keeps a single exit point for the counters without wrapping
     * production logic in a `try/finally` that exists only for tests.
     *
     * @param newOpps   Trigger.new.
     * @param oldMap    Trigger.oldMap on update; null on insert.
     */
    public static void ensureOnClosedWon(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        runInvocations++;

        createAssets(newOpps, oldMap);

        runQueryCount += Limits.getQueries() - queriesBefore;
        runDmlCount += Limits.getDmlStatements() - dmlBefore;
    }

    /**
     * The work: collect, guard, read, build, insert. Bulk-safe and CONSTANT in deal count —
     * one selector call each, one bulk DML, nothing inside a loop.
     *
     * 🔴 A DEAL WITH A NULL `Property__c` IS SKIPPED, AND THAT IS A TRADE WITH A RESIDUAL.
     * `LeadConvertService` creates the `Property__c` at lead conversion, so a converted deal
     * always has one by Closed Won — but a MANUALLY created Opportunity does not. The three
     * available answers were: throw (a manually created deal could then never be closed at all
     * — an existing, legitimate workflow made impossible, which is worse than the bug being
     * fixed); create a Property-less asset (an un-parented row, exactly the "seed/junk" shape
     * `PropertyAssetSelector`'s own header says the Sell Meter filter exists to exclude, and
     * with no source for the mandatory `Name`); or skip. Skip is the least-bad, and it is NOT
     * costless: such a deal closes with no asset and nothing says so. ⚠ The count is exposed on
     * `runSkippedNoProperty` for tests, but there is no runtime surface for it — a
     * notification is deferred by D9 and a new field was out of scope for Tranche 5A. Anyone
     * reading this because assets are missing should query
     * `SELECT Id FROM Opportunity WHERE StageName = 'Closed Won' AND Property__c = null`.
     *
     * @param newOpps Trigger.new.
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    private static void createAssets(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> propertyIds = new Set<Id>();
        // Carried off Trigger.new — `CloseDate` is an ordinary field on the record, so this
        // costs NO query. Keyed by property because that is what the asset is keyed by.
        Map<Id, Date> closingDateByProperty = new Map<Id, Date>();
        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            Boolean justEntered = CLOSED_WON.equals(o.StageName)
                && (prior == null || !CLOSED_WON.equals(prior.StageName));
            if (!justEntered) {
                continue;
            }
            if (o.Property__c == null) {
                runSkippedNoProperty++;
                continue;
            }
            propertyIds.add(o.Property__c);
            // EARLIEST close wins when two deals close against ONE property in the same chunk.
            // A tie-break is unavoidable here — a bare `put` in this loop is already one
            // (last-in-Trigger.new-order wins), it is just an undocumented one, and Trigger.new
            // order is not a guarantee. Earliest is deterministic and is the honest reading: the
            // property was ACQUIRED on the first close; a later close against the same property
            // is a second deal on an asset that already existed.
            Date known = closingDateByProperty.get(o.Property__c);
            if (o.CloseDate != null && (known == null || o.CloseDate < known)) {
                closingDateByProperty.put(o.Property__c, o.CloseDate);
            }
        }
        if (propertyIds.isEmpty()) {
            return; // zero queries, zero DML — the ordinary cost of an unrelated Opportunity save
        }

        // SOQL 1 of 2 — idempotency. Drop every property that already carries an asset.
        for (Property_Asset__c existing : PropertyAssetSelector.selectByPropertyIds(propertyIds)) {
            propertyIds.remove(existing.Property__c);
        }
        if (propertyIds.isEmpty()) {
            return; // every closing deal's property already has its asset; nothing to do
        }

        // Resolved ONCE for the whole chunk. A describe per record would be 251 describes for
        // an answer that cannot vary inside a transaction.
        Map<String, String> typeByAssetType = activeTypeMap();

        // SOQL 2 of 2 — the seed values. Trigger.new carries Property__c (an ordinary field on
        // the record) but not the parent's Name or Asset_Type__c, so this read is unavoidable.
        List<Property_Asset__c> toInsert = new List<Property_Asset__c>();
        for (Property__c p : PropertySelector.selectAssetSeedByIds(propertyIds)) {
            Property_Asset__c asset = new Property_Asset__c(
                // Verbatim, NOT `p.Name + ' Asset'`. Both conventions appear across the nine
                // seed scripts, but Name is what SellMeterController.getPortfolio,
                // BovController.getOutreachSummary and BrokerListingController.getListing all
                // render as the PROPERTY label, and Property_Name__c is a formula returning it.
                // Both name fields are Text(80), so a verbatim copy can never overflow.
                Name = p.Name,
                Property__c = p.Id,
                Status__c = STATUS_ACTIVE,
                // Opportunity.CloseDate. BOTH SIDES ARE `Date` — verified against the metadata,
                // not assumed: Property_Asset__c.Closing_Date__c is `<type>Date</type>` and
                // CloseDate is the standard Date field (the repo's CloseDate.field-meta.xml is a
                // feed-history stub that declares no type, i.e. it does not redefine it). So this
                // is a straight assignment with no coercion. ⚠ Contrast the near-miss one object
                // over: Opportunity.Contract_Executed_Date__c is a DateTime, which is why
                // ContractExecutionService has to call `.date()` on it. Do not copy that idiom here.
                Closing_Date__c = closingDateByProperty.get(p.Id)
            );
            String mapped = typeByAssetType.get(p.Asset_Type__c);
            if (mapped != null) {
                asset.Property_Type__c = mapped;
            } else if (p.Asset_Type__c != null) {
                // A real source value with no clean counterpart. Blank is the DECISION.
                runSkippedUnmappedType++;
            }
            toInsert.add(asset);
        }
        // A property whose row did not come back cannot be given the mandatory Name, so it
        // produces no asset rather than a nameless one that would fail the whole insert. With
        // both reads running SYSTEM_MODE + without sharing the only way this happens is a row
        // that genuinely no longer exists.
        runSkippedUnreadableProperty += propertyIds.size() - toInsert.size();
        if (toInsert.isEmpty()) {
            return;
        }

        // DML 1 of 1. SYSTEM_MODE because no persona reaching Closed Won holds Create on this
        // object (see the class header); allOrNone = true because this step failing silently is
        // the bug being fixed.
        Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * `PROPERTY_TYPE_BY_ASSET_TYPE` (or the test override) narrowed to targets that are
     * ACTIVE picklist values on `Property_Asset__c.Property_Type__c` right now.
     *
     * 🔴 THE GUARD IS NEEDED **BECAUSE** THE FIELD IS UNRESTRICTED, WHICH INVERTS THE USUAL
     * ARGUMENT. On a restricted picklist a stale map entry would throw
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` and announce itself. Here it would not: an
     * unrestricted picklist ACCEPTS any string, so deleting or renaming a value on the target
     * would turn this map from correct into a silent producer of orphan values that no UI can
     * select and every report groups separately. This closes that, and it is the same
     * standing rule that governs picklist removal ("grep the repo AND query the org first")
     * expressed in code so it cannot be forgotten.
     *
     * A describe, not a query — it costs no SOQL. `isActive()` is checked because an inactive
     * value is still returned by some describe paths and is not a legal write target.
     *
     * @return A map whose every value is a live, active `Property_Type__c` picklist entry;
     *         possibly smaller than the source map, never larger, never null.
     */
    private static Map<String, String> activeTypeMap() {
        Map<String, String> source =
            (typeMapOverride != null) ? typeMapOverride : PROPERTY_TYPE_BY_ASSET_TYPE;

        Set<String> live = new Set<String>();
        for (Schema.PicklistEntry entry
                : Property_Asset__c.Property_Type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                live.add(entry.getValue());
            }
        }

        Map<String, String> safe = new Map<String, String>();
        for (String assetType : source.keySet()) {
            String target = source.get(assetType);
            if (target != null && live.contains(target)) {
                safe.put(assetType, target);
            }
        }
        return safe;
    }
}
