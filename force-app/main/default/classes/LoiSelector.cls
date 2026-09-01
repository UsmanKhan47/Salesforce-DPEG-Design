/**
 * Selector for LOI__c. Encapsulates ALL SOQL against LOI__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's LOI row
 *     (primary-else-latest, read-for-display, null-on-empty).
 *   - OpportunityApprovalService — ⚠ TWO ENTRIES SINCE 2026-09-01, AND THE FIRST IS RETRACTED:
 *       · `resolveApprovalTargetId` USED to call `selectOpportunityIdRequiredById` to resolve the
 *         parent deal Id from a clicked LOI record (fetch-for-use, throws on miss). W4 of the LOI
 *         approval cutover repointed that branch to return the LOI's OWN Id, so it queries
 *         NOTHING. That method now has no production caller; it is KEPT and annotated rather than
 *         deleted, the same treatment `UnderwritingSelector.selectIdsByOpportunityIds` got when
 *         the Underwriting cutover stranded it.
 *       · `submitForApproval`'s signed-NDA gate calls `selectNdaGateByLoiId` (below), which is
 *         `without sharing` + `WITH SYSTEM_MODE` for reasons argued at its own declaration.
 *       · `submitForApproval`'s catch-block refusal derivation calls `selectStageRequiredById`.
 *   - RecordStageAdvanceService — selectStageRequiredById, the stage-advance quick action.
 *   - CounterOfferService — selectNegotiationContextById, added Tranche 3B (2026-08-09).
 *   - DispositionStageEntryService — selectByDispositionIds, the disposition LOI-stage
 *     idempotency read, added 2026-08-10 (Tranche 3B fix pass).
 *   - DispositionDealSummaryService — selectLatestByDispositionId, the disposition Deal Summary
 *     card's LOI row, added 2026-08-20 (Tranche 2 Workstream C).
 *   - LoiApprovalStampService — via the ApprovalAutomationReads inner class at the bottom of this
 *     file (NOT via the USER_MODE methods above; see that class's header for the two separate
 *     justifications). Added 2026-09-01 with W1 of the LOI approval cutover.
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
 *   ⚠ AMENDED AGAIN 2026-09-01 (W4): `selectNdaGateByLoiId` was added, so the figures below moved
 *   from EIGHT/TWO/SIX to NINE/THREE/SIX. Re-count against the method list, as this block's own
 *   instruction says — do not trust either sentence.
 *   NOW: **NINE** public methods ON THE OUTER CLASS. **THREE** are `WITH SYSTEM_MODE` —
 *   `selectNegotiationContextById`, `selectByDispositionIds`
 *   and `selectNdaGateByLoiId` (⚠ the third is ALSO `without sharing`, via its own
 *   `NdaGateReads` inner class — a SEPARATE decision, argued at its own declaration). The **SIX**
 *   remaining stay `WITH USER_MODE`: `selectById`,
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
 * ⚠ AND SINCE 2026-09-01 THE COUNT ABOVE NO LONGER COVERS THE WHOLE FILE. The
 * `ApprovalAutomationReads` inner class at the bottom is `without sharing` and `WITH SYSTEM_MODE`,
 * and it is the documented exception — exactly the shape UnderwritingSelector already carries. It
 * is deliberately NOT folded into the outer count, because the two escapes it makes (FLS *and*
 * sharing) are a different decision from the mode question the count answers. Read that class's
 * own header before reusing it.
 * ⚠ THERE ARE NOW **TWO** SUCH INNER CLASSES, ADDED FOUR HOURS APART AND DELIBERATELY NOT MERGED:
 * `NdaGateReads` (W4 — the SUBMITTER's pre-`Approval.process` gate, failure mode = a wrong
 * REFUSAL) and `ApprovalAutomationReads` (W1 — the APPROVER's post-decision mirror read, failure
 * mode = a silently unstamped deal). Same two keywords, different principals, different moments,
 * different justifications. Read the one you are reusing, not the one you found first.
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
     * Loads an LOI for parent-deal resolution.
     *
     * 🔴 NO PRODUCTION CALLER SINCE 2026-09-01 (W4 of the LOI approval cutover). It backed
     * `OpportunityApprovalService.resolveApprovalTargetId`, whose `LOI__c` branch now returns the
     * clicked record's OWN Id and issues no query at all. KEPT, not deleted, and the reasoning is
     * the same one `UnderwritingSelector.selectIdsByOpportunityIds` carries: the method is
     * correct, tested (`LoiSelectorTest.selectOpportunityIdRequiredById_*`, both the found and the
     * throws-on-miss halves), and a plausible future caller wanting a throwing child -> parent
     * resolution should find it here rather than write a fourth one.
     * ⚠ IT IS NOT THE RIGHT METHOD FOR APPROVAL AUTOMATION. It is `WITH USER_MODE`,
     * single-record, and THROWS — see `ApprovalAutomationReads.selectByIds` for why routing
     * automation through it turns a deleted LOI into a rolled-back approval.
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

    /**
     * 🔴 THE SIGNED-NDA SUBMISSION GATE'S INPUTS, READ FROM THE **LOI** SIDE. Added 2026-09-01
     * with W4 of the LOI approval cutover, when `OpportunityApprovalService` stopped resolving an
     * `LOI__c` click to its parent deal and started submitting the LOI itself.
     *
     * It is the LOI-rooted twin of `OpportunitySelector.selectNdaGateById`. Read that method's
     * header — the argument, the 2026-08-30 measurement behind it, and the not-found contract are
     * all made in full there and are not repeated here; what follows is only what DIFFERS.
     *
     * ── WHY A NEW METHOD RATHER THAN "resolve the parent, then call the existing one" ─────────
     * Two queries instead of one, on a synchronous path a human is waiting on, to answer one
     * question. And the two-step version would re-introduce the throwing
     * `selectOpportunityIdRequiredById` (or a second read of the same row) into a gate whose whole
     * contract is that it must NOT change where an unexpected failure originates.
     *
     * ── 🔴 THE TRAVERSAL IS NOW TWO HOPS, WHICH DOUBLES THE THING THAT WAS MEASURED WRONG ────
     * `Opportunity__r.Primary_NDA__r.NDA_Signed__c` crosses TWO Private-OWD parents
     * (`Opportunity`, then `NDA__c`). A `WITH SYSTEM_MODE` spanning read IS sharing-filtered on
     * the parent — MEASURED on 2026-08-30 (test run `707iw000003bQwp`), one hop, on this exact
     * gate: the parent came back NULL and the gate REFUSED a deal whose NDA was signed. With two
     * hops there are two independent ways to get that null, and BOTH fabricate "this deal has no
     * signed NDA". The failure does not degrade, it INVERTS — it blocks a legitimate submission —
     * which is the test ARCHITECTURE.md §2 sets for whether a read may stay `with sharing`. It
     * may not. Hence `without sharing`, on this ONE query, exactly as the Opportunity-side twin.
     *
     * ⚠ AND `WITH SYSTEM_MODE` FOR THE SEPARATE, SECOND REASON: the submitter never asked to read
     * an NDA. Under USER_MODE this read needs object read on `Opportunity` AND on `NDA__c` plus
     * FLS on three fields, for every persona that can click Submit for Approval — and a single
     * gap raises `No such column`, which the controller then masks as "The deal could not be
     * submitted for approval." Nobody could diagnose that. 🔴 That is not hypothetical here: the
     * SAME WEEK, `OpportunitySelector.selectPrimaryLoiByIds` was measured throwing exactly that
     * on `Opportunity.Primary_LOI__c` for a persona that HELD the FLS grant, because it lacked
     * whole-object read on the lookup's target.
     *
     * ⚠ IT WIDENS NOTHING A USER CAN OBSERVE: a `Boolean` and two Ids are consumed by a guard;
     * no NDA field is returned to the caller, rendered or logged.
     *
     * NOT-FOUND CONTRACT — returns NULL for a null Id or an Id that resolves to no row, matching
     * the Opportunity-side twin and DELIBERATELY not the throwing fetch-for-use contract the
     * three `...RequiredById` methods above carry. A null row means "cannot evaluate the gate",
     * the gate is skipped, and `Approval.process` fails exactly as it would have anyway.
     * ⚠ A row whose `Opportunity__c` is BLANK is a legal state, not a miss — a sell-side LOI
     * hangs off `Disposition__c` — and the caller skips it.
     *
     * @param loiId LOI__c Id; null-safe.
     * @return The LOI with Id, Opportunity__c, Opportunity__r.Primary_NDA__c and
     *         Opportunity__r.Primary_NDA__r.NDA_Signed__c populated, or null when the input is
     *         null or the Id resolves to no row.
     * @example
     * LOI__c loi = LoiSelector.selectNdaGateByLoiId(targetId);
     */
    public static LOI__c selectNdaGateByLoiId(Id loiId) {
        if (loiId == null) {
            return null;
        }
        return new NdaGateReads().ndaGateByLoiId(loiId);
    }

    /**
     * 🔴 THE SHARING ESCAPE FOR THE SIGNED-NDA GATE'S LOI-ROOTED READ, AND NOTHING ELSE.
     *
     * `without sharing` is confined to this inner class so it applies to ONE query. The enclosing
     * `LoiSelector` stays `with sharing` and must: it backs six user-facing `USER_MODE` reads
     * whose entire job is to respect what the running user may see. This is the
     * `OpportunitySelector.NdaGateReads` shape, which is itself the
     * `InboundEmailStagingSelector.RoutingReads` shape ARCHITECTURE.md §2 prescribes.
     *
     * ⚠ IT IS A SEPARATE INNER CLASS FROM `ApprovalAutomationReads` BELOW, DELIBERATELY, EVEN
     * THOUGH BOTH ARE `without sharing` + `WITH SYSTEM_MODE`. They are escapes argued for
     * DIFFERENT principals at DIFFERENT moments: that one runs as the APPROVER, after the
     * decision, from a record-triggered flow, and its failure mode is a silently unstamped deal;
     * this one runs as the SUBMITTER, before `Approval.process`, and its failure mode is a
     * refusal. Folding them together would let either read inherit the other's justification.
     *
     * ⚠ DO NOT ADD A SECOND METHOD HERE — the instruction `OpportunitySelector.NdaGateReads`
     * already carries, for the same reason.
     */
    private without sharing class NdaGateReads {

        /**
         * The gate's fields, read without sharing so neither the `Opportunity__r` nor the
         * `Primary_NDA__r` hop is filtered by the submitter's access to a Private-OWD parent.
         *
         * @param loiId The LOI to read; never null (the wrapper guards it).
         * @return The row, or null when no row matches.
         */
        private LOI__c ndaGateByLoiId(Id loiId) {
            List<LOI__c> rows = [
                SELECT Id, Opportunity__c,
                       Opportunity__r.Primary_NDA__c,
                       Opportunity__r.Primary_NDA__r.NDA_Signed__c
                FROM LOI__c
                WHERE Id = :loiId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }
    }

    /**
     * LOI reads performed ON A PRINCIPAL'S BEHALF by approval automation, rather than at the
     * running user's request. Added 2026-09-01 with W1 of the LOI approval cutover
     * (agent-output/loi-approval-cutover-design.md), which moves the principal LOI approval OFF
     * the Opportunity and ONTO the LOI__c record and therefore needs a child -> parent edge that
     * an approving principal can traverse.
     *
     * 🔴 THIS INNER CLASS ESCAPES BOTH FLS *AND* SHARING, AND THOSE ARE TWO SEPARATE DECISIONS.
     * ARCHITECTURE.md §2 requires each to be justified at its own declaration, so:
     *
     * 1. `WITH SYSTEM_MODE` (the automation-path exception, ARCHITECTURE.md §2). The caller runs
     *    inside an after-save record-triggered flow fired by the APPROVER's decision, not by a
     *    user asking to read anything. Under USER_MODE a single field the approving principal
     *    lacks FLS on raises `System.QueryException: No such column` — an FLS denial wearing a
     *    schema error — which from a flow-invoked Apex action aborts the approval save itself.
     *    Every DPEG persona is on Minimum Access and a Metadata-API-deployed field arrives with no
     *    FLS for anyone, System Administrator included, so this is the default case for automation
     *    here, not an edge case. This selector has already been bitten by exactly that on this
     *    very object — see `selectNegotiationContextById`, ground 2, where `LOI__c.Disposition__c`
     *    reproduced the denial on 2026-08-09.
     *
     * 2. `without sharing` (the inner class). SYSTEM_MODE lifts CRUD/FLS but NEVER sharing, and
     *    that distinction has already cost this project a live incident: an approval's parent
     *    write "silently wrote nothing" for every approver who did not OWN the record, and worked
     *    only when approver == owner — which is exactly what every test does, so no test caught
     *    it. Three facts make the same hole reachable here:
     *      (a) `LOI__c` is OWD `Private` (LOI__c.object-meta.xml:165);
     *      (b) an auto-created acquisition LOI is owned by the **`Acquisition` QUEUE**, not by any
     *          person (OpportunityReviewService's header, :170-186), so an approving principal is
     *          never the owner — non-ownership is the NORMAL case here, not the exception;
     *      (c) the approver's read today comes from a single `viewAllRecords` line on
     *          `DPEG_Acquisition_View` (:1908-1909), and a PermissionSet deploy REPLACES its whole
     *          permission set — this repo has lost grants that way twice.
     *    🔴 THE FAILURE MODE IS SILENT AND IT INVERTS THE FEATURE, WHICH IS WHY THIS IS NOT
     *    BELT-AND-BRACES. An empty list here is indistinguishable from "no such LOI", so
     *    `LoiApprovalStampService` skips instead of throwing, `Opportunity.LOI_Approved__c` is
     *    never written, and `Approved_LOI_Before_PSA` then blocks that deal out of
     *    `Under Contract (PSA)` FOREVER with no error anywhere and no route out.
     *    Inner classes do not inherit the outer class's sharing, so `without sharing` is stated
     *    explicitly; the outer LoiSelector stays `with sharing` and every method above it is
     *    unchanged.
     *
     * Scope is kept as narrow as the rule demands: ONE read, Id + Opportunity__c only. Apex forbids
     * static methods on inner classes, so this is an instance method — call
     * `new LoiSelector.ApprovalAutomationReads().selectByIds(...)`.
     *
     * @see force-app/main/default/classes/UnderwritingSelector.cls (ApprovalAutomationReads — the
     *      sibling this mirrors exactly, added by the Underwriting cutover on 2026-08-28)
     * @see force-app/main/default/classes/ProcessInstanceStepSelector.cls (AuditReads — the
     *      original precedent for the shape)
     */
    public without sharing class ApprovalAutomationReads {

        /**
         * The parent Opportunity of each of a set of LOIs — backs LoiApprovalStampService, which
         * mirrors an approved LOI's decision onto its deal and therefore needs the child -> parent
         * edge in bulk.
         *
         * NOT-FOUND CONTRACT — read-for-automation: returns a List (never null), and deliberately
         * NOT the throwing fetch-for-use contract `selectOpportunityIdRequiredById` carries three
         * methods above. A missing row, or a row whose `Opportunity__c` is blank, simply does not
         * appear / carries null, and the caller skips it. An orphan LOI is a LEGAL state —
         * `LOI__c.Opportunity__c` is a Lookup with `deleteConstraint SetNull`
         * (objects/LOI__c/fields/Opportunity__c.field-meta.xml — both lines verified 2026-09-01),
         * and a sell-side LOI hangs off `Disposition__c`
         * instead and has no Opportunity at all — so it must not throw.
         *
         * ⚠ IT IS A SEPARATE METHOD FROM `selectOpportunityIdRequiredById` rather than a reuse of
         * it, and the difference is not cosmetic: that one is `WITH USER_MODE`, single-record, and
         * THROWS. Routing approval automation through it would reintroduce both failures this
         * class exists to prevent, and would do so one row at a time.
         *
         * ⚠ NO RECORD-TYPE FILTER, DELIBERATELY. The caller is invoked only from the acquisition
         * LOI approval's own mirror flow, so the scoping is done by the approval's entry criteria
         * where it belongs. Filtering here as well would mean a Master-typed row — a real shape in
         * this org until the record-type post-deploy gate runs — is silently dropped and its deal
         * never stamped.
         *
         * @param loiIds LOI__c Ids; null/empty-safe.
         * @return LOIs with Id and Opportunity__c populated; empty when the input is null or empty
         *         (never null).
         */
        public List<LOI__c> selectByIds(Set<Id> loiIds) {
            if (loiIds == null || loiIds.isEmpty()) {
                return new List<LOI__c>();
            }
            return [
                SELECT Id, Opportunity__c
                FROM LOI__c
                WHERE Id IN :loiIds
                WITH SYSTEM_MODE
            ];
        }
    }
}
