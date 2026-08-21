/**
 * Selector for LOI__c. Encapsulates ALL SOQL against LOI__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's LOI row
 *     (primary-else-latest, read-for-display, null-on-empty).
 *   - OpportunityApprovalController.resolveDealId — resolves the parent deal Id
 *     from a clicked LOI record (fetch-for-use, throws on miss).
 *   - RecordStageAdvanceService — selectStageRequiredById, the stage-advance quick action.
 *   - CounterOfferService — selectNegotiationContextById, added Tranche 3B (2026-08-09).
 *   - DispositionStageEntryService — selectByDispositionIds, the disposition LOI-stage
 *     idempotency read, added 2026-08-10 (Tranche 3B fix pass).
 *   - DispositionDealSummaryService — selectLatestByDispositionId, the disposition Deal Summary
 *     card's LOI row, added 2026-08-20 (Tranche 2 Workstream C).
 *
 * ⚠ MODE COUNT — CORRECTED 2026-08-20, AND THE OLD SENTENCE IS QUOTED RATHER THAN DELETED SO A
 * READER CARRYING IT KNOWS IT WAS WRONG. This header used to read:
 *     > "LOI__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0) on four of the six
 *     >  methods."
 * That was already false before this tranche touched the file: the class held SEVEN methods, FIVE
 * of them USER_MODE. It is the same miscount NdaSelector's header records having propagated into
 * ARCHITECTURE.md twice, and it is not cosmetic — ARCHITECTURE.md §2 makes these headers the
 * authoritative SYSTEM_MODE inventory, so the number here is what a reviewer reconciles the doc
 * against. Re-count against the method list, never against this sentence.
 *   NOW: **EIGHT** public methods. **TWO** are `WITH SYSTEM_MODE` — `selectNegotiationContextById`
 *   and `selectByDispositionIds`. The **SIX** remaining stay `WITH USER_MODE`: `selectById`,
 *   `selectLatestByOpportunityId`, `selectOpportunityIdRequiredById`, `selectStageRequiredById`,
 *   `selectByOpportunityIds` and `selectLatestByDispositionId`. LOI__c is a custom object (P3
 *   custom-field FLS gap = 0), so USER_MODE is the correct default for every read a human asked
 *   for.
 *
 * ⚠ MIXED MODES SINCE 2026-08-09: selectNegotiationContextById and (since 2026-08-10)
 * selectByDispositionIds are `WITH SYSTEM_MODE`, under the ARCHITECTURE.md §2 automation-path
 * exception. The mode is a property of the METHOD, never of the class — read the method, not the
 * class header. Each full justification lives at its own declaration, which is where §2's table
 * says the authoritative inventory lives.
 *
 * Two not-found contracts (see UnderwritingSelector for the shared rationale):
 * selectById / selectLatestByOpportunityId return null; selectOpportunityIdRequiredById,
 * selectStageRequiredById and selectNegotiationContextById throw native
 * System.QueryException on a miss, matching the original
 * `[SELECT Opportunity__c FROM LOI__c WHERE Id = :recordId LIMIT 1].Opportunity__c`.
 *
 * ── 🔴 TWO METHODS HERE CARRY A "DO NOT NARROW" CONTRACT ON RecordTypeId ─────
 * Tranche 3B (D6) gave LOI__c an Acquisition_LOI / Disposition_LOI pair whose stage sets and
 * whose negotiation VOCABULARY differ, so two callers now branch on the record type:
 * RecordStageAdvanceService picks the stage sequence, the explicit-target allow-list AND the
 * permission gate from it, and CounterOfferService picks the counterparty label from it.
 * Neither issues a second query — RecordTypeId rides along on the read they already make.
 *
 * ⚠ Dropping RecordTypeId from either SELECT does NOT fail loudly. RecordStageAdvanceService
 * reads it through getPopulatedFieldsAsMap(), which cannot tell "not selected" from "selected
 * and null", so both degrade to the ACQUISITION default — silently applying buy-side behaviour
 * to a sale. CounterOfferService reads the typed field directly and WOULD throw
 * System.SObjectException, which is the louder of the two but still a runtime failure on a
 * user's save rather than a compile error. Keep both fields.
 *
 * @see agent-output/p4-selector-design.md (§3 #10, §5)
 */
public with sharing class LoiSelector {

    /**
     * The LOI designated as an Opportunity's primary (Primary_LOI__c lookup).
     *
     * @param loiId LOI__c Id; null-safe.
     * @return The record with the Deal Summary fields set, or null when the input
     *         is null or the row does not exist.
     */
    public static LOI__c selectById(Id loiId) {
        if (loiId == null) {
            return null;
        }
        List<LOI__c> rows = [
            SELECT Id, Name, LOI_Status__c, Offer_Price__c, Offer_Cap_Rate__c, Submitted_Date__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created LOI related to an Opportunity — the fallback when
     * no primary is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related LOI (ORDER BY CreatedDate DESC LIMIT 1), or null
     *         when the input is null or the Opportunity has none.
     */
    public static LOI__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<LOI__c> rows = [
            SELECT Id, Name, LOI_Status__c, Offer_Price__c, Offer_Cap_Rate__c, Submitted_Date__c
            FROM LOI__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Loads an LOI for parent-deal resolution — backs
     * OpportunityApprovalController.resolveDealId.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param loiId LOI__c Id; must reference an existing row.
     * @return The LOI with Id and Opportunity__c populated.
     * @throws System.QueryException when no LOI matches the Id.
     */
    public static LOI__c selectOpportunityIdRequiredById(Id loiId) {
        return [
            SELECT Id, Opportunity__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads an LOI for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error. Single-row SOQL assignment -> native System.QueryException, matching
     * OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ `Stage__c` is the Path field and is NOT `LOI_Status__c` — the approval audit writes the
     * latter, this action writes the former. Widening this method to select or write LOI_Status__c
     * would silently couple the quick action to the approval's field.
     *
     * Field list is deliberately MINIMAL (Id + Stage__c + RecordTypeId) — see the per-caller note
     * in the class header.
     *
     * 🔴 RecordTypeId WAS ADDED 2026-08-09 (Tranche 3B) AND IS NOT OPTIONAL. From it
     * RecordStageAdvanceService picks THREE things: the stage sequence (Draft -> … -> Signed vs
     * Received -> … -> Signed — ⚠ this read "Draft -> … -> Completed vs Received -> … -> Executed"
     * until 2026-08-21; BOTH SEQUENCES NOW END AT 'Signed', which makes RecordTypeId MORE
     * load-bearing, not less: the terminal no longer identifies the side), the explicit-target
     * allow-list (empty on Disposition_LOI since 2026-08-21), and the permission gate
     * (DEAL_DRIVER vs DISPOSITION_DRIVER). Omitting it degrades every disposition LOI to the
     * acquisition sequence SILENTLY — the service reads it through getPopulatedFieldsAsMap(),
     * which cannot distinguish "not selected" from "selected and null". Same contract
     * NdaSelector.selectStageRequiredById has carried since Tranche 3A.
     *
     * @param loiId LOI__c Id; must reference an existing row.
     * @return The LOI with Id, Stage__c and RecordTypeId populated.
     * @throws System.QueryException when no LOI matches the Id.
     */
    public static LOI__c selectStageRequiredById(Id loiId) {
        return [
            SELECT Id, Stage__c, RecordTypeId
            FROM LOI__c
            WHERE Id = :loiId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads an LOI for the counter-offer write — backs CounterOfferService.saveCounterOffer.
     *
     * 🔴 IT EXISTS TO ANSWER ONE QUESTION: IS THIS A PURCHASE OR A SALE? The counter-offer
     * vocabulary INVERTS between the two (`Ball_In_Court__c = 'Seller'` names the counterparty on
     * a purchase and names DPEG on a sale), so the label written to `Ball_In_Court__c` and
     * `Counter_Offer__c.Direction__c` must be derived from the parent's side of the deal and never
     * supplied by the caller. Before Tranche 3B saveCounterOffer read nothing at all and hardcoded
     * 'Us' / 'Seller'.
     *
     * BOTH fields are load-bearing and neither is redundant:
     *   - RecordTypeId is the AUTHORITATIVE discriminator (D6) — but it is null on a Master-type
     *     row, which is every LOI in the org until post-deploy gate T-A1/T-A2 runs.
     *   - Disposition__c is the FALLBACK for exactly that window: a sell-side LOI hangs off a
     *     Disposition, so a populated lookup identifies the side even with no record type at all.
     * See CounterOfferService.isSaleSide for the precedence rule between them.
     *
     * FETCH-FOR-USE: the caller derives a picklist value from the result and then writes the
     * record, so a miss is an error. Single-row SOQL assignment -> native System.QueryException,
     * matching selectOpportunityIdRequiredById / selectStageRequiredById.
     *
     * ⚠ It deliberately does NOT select the counter fields the service writes. Those are blind
     * writes on an Id-only stamp record, exactly as before; reading them back would add nothing
     * and would invite a read-modify-write where none is wanted.
     *
     * ── 🔴 WITH SYSTEM_MODE, AND IT IS THE ONLY QUERY IN THIS CLASS THAT IS ─────
     * The other four methods stay WITH USER_MODE and must. This one takes the ARCHITECTURE.md §2
     * automation-path exception ("a read the running user never asked for must not depend on the
     * running user's FLS"), on three grounds:
     *
     *  1. THE USER DID NOT ASK FOR THIS DATA. They asked to record a counter offer. This read
     *     exists so the SERVICE can decide whether the counterparty is called Seller or Buyer, and
     *     nothing it returns is shown to anyone. USER_MODE therefore protects nothing observable
     *     while being able to fail the whole save.
     *  2. MEASURED, not anticipated: `Disposition__c` is a NEW field in this tranche, and a
     *     Metadata-API-deployed custom field arrives with NO field permissions for ANY profile,
     *     System Administrator included. A check-only run on 2026-08-09 reproduced exactly that —
     *     `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`, which is how
     *     the platform reports an FLS denial — and it took down the ACQUISITION counter-offer path,
     *     which has nothing to do with dispositions and was working before this tranche.
     *  3. THE GRANT IS FRAGILE IN A WAY THIS REPO HAS ALREADY BEEN BURNED BY TWICE. A PermissionSet
     *     deploy REPLACES its entire <fieldPermissions> set, so one unrelated redeploy of
     *     DPEG_Acquisition_Edit that happens to drop this one line would silently break every
     *     counter offer, on both sides, with a generic "could not be saved" toast.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. SYSTEM_MODE lifts CRUD and
     * FLS, NOT sharing, and this class stays `with sharing`: the caller is saving a counter on this
     * very LOI, so they demonstrably have the record, and a sharing denial here should still fail.
     * No `without sharing` inner class is warranted — contrast
     * InboundEmailStagingSelector.RoutingReads, where the automation runs as a principal that does
     * NOT own the rows.
     *
     * @param loiId LOI__c Id; must reference an existing row.
     * @return The LOI with Id, RecordTypeId and Disposition__c populated.
     * @throws System.QueryException when no LOI matches the Id or the running user cannot see it.
     */
    public static LOI__c selectNegotiationContextById(Id loiId) {
        return [
            SELECT Id, RecordTypeId, Disposition__c
            FROM LOI__c
            WHERE Id = :loiId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    /**
     * LOIs related to a set of Opportunities — backs OpportunityReviewService's LOI-stage
     * idempotency (drop any deal that already has an LOI so a second is never opened).
     * Mirrors NdaSelector / UnderwritingSelector.selectByOpportunityIds exactly; the existing
     * single-record methods on this selector cannot answer a set-based existence question.
     * Bulk-safe (one query for the whole set).
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return LOIs with Id and Opportunity__c populated; empty when the input is null or empty.
     */
    public static List<LOI__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<LOI__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM LOI__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * The most recently created LOI related to a DISPOSITION — backs the LOI row of the
     * disposition Deal Summary card (`DispositionDealSummaryService` ->
     * `c/dispositionDealSummary`). Added 2026-08-20, Tranche 2 Workstream C (design D5).
     *
     * 🔴 TWO FIELDS THE ACQUISITION SIBLING SELECTS ARE DELIBERATELY ABSENT, AND NEITHER IS AN
     * OVERSIGHT. `selectLatestByOpportunityId` reads `LOI_Status__c` and the card's design brief
     * lists `LOI_Signed_Date__c` as an obvious candidate. On the DISPOSITION path both are dead:
     *   - `LOI_Status__c` — the `LOI_Signed_Status_Sync` flow's own header states this is "a
     *     separate approval/deal vocabulary field that NO AUTOMATION EVER SETS". On a disposition
     *     LOI it holds its default, `Draft`, forever, so selecting it would put "Draft" on the
     *     card beside a real `Stage__c` (design §0 C-10). ⚠ UNCHANGED by the 2026-08-21 stage
     *     change — no automation sets it on either side.
     *   - `LOI_Signed_Date__c` — 🔴 STILL EXCLUDED, BUT ITS STATED REASON IS RETRACTED AS OF
     *     2026-08-21. Verbatim, what stood here: "`LOI_Signed_Status_Sync` keys on
     *     `Stage__c = 'Signed'`, which is the ACQUISITION terminal. The disposition terminal is
     *     `Executed`, so that flow can never fire on a sale and the field is STRUCTURALLY always
     *     blank here (design §0 C-11). It would render a permanent em-dash that reads as missing
     *     data."
     *     The user's new sell-side sequence is Received -> Under Review -> Negotiation -> Signed,
     *     so `Signed` IS the disposition terminal now. `LOI_Signed_Status_Sync` is a before-save
     *     flow on `LOI__c` with no record-type and no lookup criterion, so it fires on disposition
     *     LOIs reaching Signed and stamps this field — the value will be REAL, not blank. The
     *     exclusion is retained as a product decision (the card does not show it), not as a
     *     structural inevitability. Do not repeat the old justification.
     * ⚠ Adding either later is not a widening, it is a regression against a decision. The
     * PRECONDITION that used to protect `LOI_Signed_Date__c` ("the thing to change first is the
     * automation") has already happened by side-effect; if the card should show it, that is now
     * purely a design question.
     *
     * ⚠ `Ball_In_Court__c` IS SELECTED AND ITS VOCABULARY INVERTS BETWEEN THE TWO SIDES —
     * 'Seller' names the counterparty on a purchase and names DPEG on a sale (see
     * `selectNegotiationContextById`). The card renders the raw value, which is correct for a
     * disposition page, where the reader is the seller. Do not reuse this method behind an
     * acquisition surface without re-reading that.
     *
     * READ-FOR-DISPLAY, null on miss: a disposition with no LOI yet is the normal state on 8 of
     * the 11 stages — the card renders it as an empty state, never as an error. Same contract as
     * `selectById` / `selectLatestByOpportunityId`, and deliberately NOT the throwing
     * fetch-for-use contract the three `...RequiredById` methods carry.
     *
     * ⚠ ORDER BY carries an `Id DESC` TIE-BREAK. `CreatedDate` is second-granular, so two LOIs
     * created under one Disposition inside the same second leave a single-key sort free to return
     * either row and the card becomes non-deterministic between refreshes. Same reasoning, in
     * full, on `NdaSelector.selectLatestByDispositionId`.
     * ⚠ Its acquisition sibling has NO tie-break, and that is a preserved-verbatim P4 refactor
     * artefact, not a precedent to copy.
     *
     * ── FLS: `WITH USER_MODE`, unlike the two disposition-facing methods around it ──
     * This backs a read a human explicitly asked for by opening the record page, so
     * ARCHITECTURE.md §2's automation-path exception does not apply. `USER_MODE` enforces FLS on
     * the `WHERE` field too, so `LOI__c.Disposition__c` must stay granted alongside `Stage__c`,
     * `Offer_Price__c` and `Ball_In_Court__c` — all four verified present in
     * `DPEG_Disposition_View` and `DPEG_Disposition_Edit` on 2026-08-20. `USER_MODE` throws, it
     * does not degrade, which is why the caller wraps this in a narrow fail-soft try/catch.
     *
     * @param dispositionId Parent Disposition__c Id; null-safe.
     * @return The latest related LOI with Id, Stage__c, Offer_Price__c and Ball_In_Court__c
     *         populated (ORDER BY CreatedDate DESC, Id DESC LIMIT 1), or null when the input is
     *         null or the Disposition has no LOI. ⚠ `Id` IS CONSUMED — since 2026-08-21 it becomes
     *         `DealSummary.loiId` and backs the card's click-through link on the LOI row label. It
     *         costs no FLS and SOQL returns it regardless of the SELECT list. 🔴 It is NOT a
     *         re-opening of the two field exclusions above: an Id carries no status, no date and
     *         no vocabulary.
     * @example
     * LOI__c loi = LoiSelector.selectLatestByDispositionId(dispositionId);
     */
    public static LOI__c selectLatestByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<LOI__c> rows = [
            SELECT Id, Stage__c, Offer_Price__c, Ball_In_Court__c
            FROM LOI__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * LOIs related to a set of DISPOSITIONS — backs DispositionStageEntryService's idempotency on
     * the `LOI` stage ("never a second disposition LOI on one disposition"). Bulk-safe: one query
     * for the whole set, called once per trigger chunk.
     *
     * ⚠ IT IS A SEPARATE METHOD FROM selectByOpportunityIds RATHER THAN A PARAMETERISED ONE, for
     * the reason NdaSelector's header already states about its own pair: the two parents are
     * DIFFERENT FIELDS on a dual-parented object, and a caller must not be able to pass the wrong
     * one. There is no shared query text to save.
     *
     * 🔴 `WITH SYSTEM_MODE`, AND IT IS THE ONLY MODE THAT IS CORRECT HERE — the same
     * automation-path argument NdaSelector.selectByDispositionIds carries, with the same
     * consequence. The running user asked to move a disposition to the LOI stage, not to read LOIs.
     * Under `WITH USER_MODE` a principal lacking FLS on `Disposition__c` — a Tranche 3B field, so
     * no profile has it, System Administrator included — makes the query THROW rather than degrade,
     * and that throw happens inside an AFTER-UPDATE trigger, so it ROLLS BACK THE USER'S OWN STAGE
     * CHANGE with CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY rather than merely disabling auto-create.
     * Not anticipated: the sibling read on this very field reproduced the FLS denial on 2026-08-09
     * (see selectNegotiationContextById, ground 2).
     *
     * ⚠ SYSTEM_MODE lifts CRUD/FLS ONLY — it does NOT lift sharing, and that is deliberate. The
     * class stays `with sharing`: every disposition in the set was just edited by the running user,
     * so they can already see it, and the LOIs hanging off it are theirs to see too. This is NOT
     * the shape that needed a `private without sharing` inner class (contrast
     * InboundEmailStagingSelector.RoutingReads, whose rows are owned by a DIFFERENT principal than
     * the one running the automation).
     *
     * ⚠ THE QUERY IS DELIBERATELY NOT SCOPED TO THE Disposition_LOI RECORD TYPE. In the window
     * between the record-type deploy and post-deploy gate T-A1 a disposition LOI can legitimately
     * sit on MASTER, and suppressing on record type would then mint a second one. The
     * `Disposition__c` lookup is the whole key.
     *
     * @param dispositionIds Parent Disposition__c Ids; null/empty-safe.
     * @return LOIs with Id and Disposition__c populated; empty when the input is null or empty.
     */
    public static List<LOI__c> selectByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<LOI__c>();
        }
        return [
            SELECT Id, Disposition__c
            FROM LOI__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }
}
