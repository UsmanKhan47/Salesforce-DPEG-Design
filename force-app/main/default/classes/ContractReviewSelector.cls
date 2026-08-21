/**
 * Selector for Contract_Review__c. Encapsulates ALL SOQL against Contract_Review__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumers:
 *   - OpportunityDocStatusController — Deal Summary card's Contract Review row
 *     (latest-related only; the card has no primary-contract-review lookup).
 *   - OpportunityApprovalController.resolveDealId — resolves the parent deal Id
 *     from a clicked Contract Review record (fetch-for-use, throws on miss).
 *   - OpportunityReviewService — selectByOpportunityIds, the PSA-stage idempotency read.
 *   - RecordStageAdvanceService — selectStageRequiredById, the stage-advance quick action.
 *   - PsaVersionService — selectNegotiationContextById, added 2026-08-10 (Tranche 3C fix pass).
 *   - DispositionStageEntryService — selectByDispositionIds, the disposition PSA-stage
 *     idempotency read, added 2026-08-10 (Tranche 3C fix pass).
 *   - DispositionDealSummaryService — selectLatestByDispositionId, the disposition Deal Summary
 *     card's PSA row, added 2026-08-20 (Tranche 2 Workstream C).
 *
 * ⚠ THE CLAIM "USER_MODE ON EVERY METHOD … NO AUTOMATION PATH ON THIS OBJECT" WAS TRUE UNTIL
 * 2026-08-10 AND IS NOW FALSE. It has been REPLACED rather than left to mislead. Of the **SEVEN**
 * public methods (SIX until 2026-08-20), two are `WITH SYSTEM_MODE` under the ARCHITECTURE.md §2
 * automation-path exception — `selectNegotiationContextById` and `selectByDispositionIds` — and
 * the other **FIVE** stay `WITH USER_MODE` because each backs a read a human explicitly asked
 * for: `selectLatestByOpportunityId`, `selectOpportunityIdRequiredById`,
 * `selectByOpportunityIds`, `selectStageRequiredById` and `selectLatestByDispositionId`. THE MODE
 * IS A PROPERTY OF THE METHOD, NEVER OF THIS CLASS: read the method's own Javadoc, which is where
 * §2 says the authoritative inventory lives. Same shape as LoiSelector, NdaSelector and
 * TaskSelector — and the count is ENUMERATED rather than asserted because a bare count in
 * exactly this position has already gone stale twice in this repo (see NdaSelector's header).
 *
 * ⚠ Contrast its SIBLING PsaVersionSelector, which has been mixed-mode since 2026-08-09 for a
 * DIFFERENT reason again: its COUNT() feeds this object's derived Latest_Version__c, and an
 * access-narrowed COUNT corrupts rather than throws.
 *
 * ── 🔴 TWO METHODS CARRY A "DO NOT NARROW" CONTRACT ON RecordTypeId (Tranche 3C) ──
 * Contract_Review__c gained Acquisition_PSA / Disposition_PSA. The two share one stage sequence
 * and differ in the PERMISSION GATE, which RecordStageAdvanceService picks off the record type
 * (selectStageRequiredById), and in the NEGOTIATION VOCABULARY, which PsaVersionService picks off
 * it (selectNegotiationContextById). Dropping the field degrades every disposition PSA to the
 * acquisitions answer SILENTLY in the first case and loudly in the second. Full reasoning at each
 * method. Exactly the shape LoiSelector carries for the LOI half of the same inversion.
 *
 * selectLatestByOpportunityId returns a List (0 or 1 rows) so the caller's
 * `for (Contract_Review__c cr : ...)` loop is preserved byte-for-byte — the
 * original inline query was consumed by a for-loop, not a single assignment.
 * selectOpportunityIdRequiredById uses a single-row assignment that throws native
 * System.QueryException on a miss, matching the original resolveDealId query.
 *
 * @see agent-output/p4-selector-design.md (§3 #11, §5)
 */
public with sharing class ContractReviewSelector {

    /**
     * The most recently created Contract Review related to an Opportunity.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return A list of 0 or 1 Contract Reviews (ORDER BY CreatedDate DESC LIMIT 1);
     *         empty when the input is null or the Opportunity has none.
     */
    public static List<Contract_Review__c> selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return new List<Contract_Review__c>();
        }
        return [
            SELECT Id, Stage__c, Contract_Value__c, PSA_Date__c, Execution_Date__c
            FROM Contract_Review__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    /**
     * Loads a Contract Review for parent-deal resolution — backs
     * OpportunityApprovalController.resolveDealId.
     *
     * FETCH-FOR-USE: the caller dereferenced `.Opportunity__c` off a single-row
     * assignment, so a miss is an error. Preserved via a single-row SOQL
     * assignment that throws native System.QueryException.
     *
     * @param contractReviewId Contract_Review__c Id; must reference an existing row.
     * @return The Contract Review with Id and Opportunity__c populated.
     * @throws System.QueryException when no Contract Review matches the Id.
     */
    public static Contract_Review__c selectOpportunityIdRequiredById(Id contractReviewId) {
        return [
            SELECT Id, Opportunity__c
            FROM Contract_Review__c
            WHERE Id = :contractReviewId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Contract Reviews related to a set of Opportunities — backs
     * OpportunityReviewService.createReviewRecords idempotency (drop any deal that
     * already has a Contract Review so entering the PSA stage never opens a second).
     * Added by Module A2: the A2 service repoint needs a bulk, set-based existence
     * read that A1's single-record methods do not provide. Bulk-safe.
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return Contract Reviews with Id and Opportunity__c populated; empty when the
     *         input is null or empty.
     */
    public static List<Contract_Review__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Contract_Review__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM Contract_Review__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * The Contract Review's Id and NEGOTIATION STATUS, for RecordStageAdvanceService's stage-advance
     * quick action.
     *
     * 🔴 IT SELECTS Negotiation_Status__c, NOT Stage__c, AND THAT IS THE WHOLE POINT.
     * On this object Stage__c is a DERIVED PROJECTION, not an independently writable field: the
     * active before-save flow Contract_Review_Stage_Sync recomputes it from Negotiation_Status__c on
     * EVERY create and update (Initial Draft -> PSA Drafting, Revised / Ready for Execution ->
     * Review, either Counter -> Counter, Executed -> Contract Execution). Writing Stage__c therefore
     * appears to succeed — the DML commits, LastModifiedDate moves, the quick action toasts success —
     * and the value is silently replaced before it is ever stored. Measured 2026-08-05 on CTR-0000.
     *
     * The same is true of the Path's native "Mark Stage as Complete", which is why that button is
     * hidden on this page rather than merely superseded: it was never functional here either.
     *
     * Field list is deliberately MINIMAL (Id + Negotiation_Status__c + RecordTypeId): widening it
     * further would let an unrelated FLS gap break the stage action. `RecordTypeId` is a STANDARD,
     * always-readable field, so adding it widens the field list without widening the FLS denial
     * surface.
     *
     * ── 🔴 RecordTypeId WAS ADDED 2026-08-09 (Tranche 3C) AND IS NOT OPTIONAL — "DO NOT NARROW" ──
     * `Contract_Review__c` gained an Acquisition_PSA / Disposition_PSA pair whose four
     * `Negotiation_Status__c` values are IDENTICAL, so — unlike NDA__c and LOI__c — the record type
     * changes NOTHING about the stage SEQUENCE. It changes the PERMISSION GATE:
     * RecordStageAdvanceService routes `Acquisition_PSA` to DEAL_DRIVER and `Disposition_PSA` to
     * DISPOSITION_DRIVER, because a sale's PSA must not be drivable by an acquisitions deal driver
     * merely because the two share a table.
     *
     * ⚠ SHARING A SEQUENCE IS NOT SHARING A GATE. That distinction is the entire reason this field
     * is here, and it is the thing a reader who checks only the picklists will miss: the record
     * type files themselves state that both types expose the same four values, which is TRUE and
     * is NOT a reason to omit RecordTypeId.
     *
     * ⚠ Dropping it does NOT fail loudly. RecordStageAdvanceService reads it through
     * getPopulatedFieldsAsMap(), which cannot tell "not selected" from "selected and null", so
     * both degrade to the ACQUISITION default — silently gating every DISPOSITION PSA behind the
     * ACQUISITIONS persona, i.e. no disposition user could advance a sale's PSA and no error would
     * say why. Same contract NdaSelector (3A) and LoiSelector (3B) carry.
     *
     * @param contractReviewId Contract_Review__c Id; must reference an existing row.
     * @return The Contract Review with Id, Negotiation_Status__c and RecordTypeId populated.
     * @throws System.QueryException when no Contract Review matches the Id.
     */
    public static Contract_Review__c selectStageRequiredById(Id contractReviewId) {
        return [
            SELECT Id, Negotiation_Status__c, RecordTypeId
            FROM Contract_Review__c
            WHERE Id = :contractReviewId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Loads a Contract Review for the PSA version-log write — backs PsaVersionService.saveVersion.
     *
     * 🔴 IT EXISTS TO ANSWER ONE QUESTION: IS THIS A PURCHASE OR A SALE? The PSA negotiation
     * vocabulary INVERTS between the two — `Ball_In_Court__c = 'Seller'` names the counterparty on
     * a purchase and names DPEG on a sale — so the label written to `Ball_In_Court__c` and to
     * `PSA_Version__c.Direction__c` must be derived from the parent's side of the deal and never
     * supplied by the caller. Before this method existed saveVersion read nothing at all and
     * hardcoded 'Us' / 'Seller'.
     *
     * ⚠ IT IS DELIBERATELY A SEPARATE METHOD FROM selectStageRequiredById, WHICH ALREADY SELECTS
     * RecordTypeId. Merging them would give the version-log write a dependency on
     * `Negotiation_Status__c` — a field it neither reads nor should be able to break on — and would
     * give the stage action a dependency on `Disposition__c`, a Tranche 3C field whose FLS
     * acquisitions personas deliberately lack. The two callers want the record type for opposite
     * reasons and pay different FLS prices for the rest of the field list, so they get one method
     * each. Same split LoiSelector makes between selectStageRequiredById and
     * selectNegotiationContextById.
     *
     * BOTH FIELDS ARE LOAD-BEARING AND NEITHER IS REDUNDANT:
     *   - RecordTypeId is the AUTHORITATIVE discriminator — but it is null on a Master-type row,
     *     which is every Contract Review in the org until post-deploy gates T-A1/T-B run.
     *   - Disposition__c is the FALLBACK for exactly that window: a sell-side PSA hangs off a
     *     Disposition, so a populated lookup identifies the side with no record type at all.
     * See PsaVersionService.isSaleSide for the precedence rule between them.
     *
     * FETCH-FOR-USE: the caller derives a picklist value from the result and then writes the
     * record, so a miss is an error. Single-row SOQL assignment -> native System.QueryException,
     * matching selectOpportunityIdRequiredById / selectStageRequiredById.
     *
     * ⚠ It deliberately does NOT select the fields the service writes (`Ball_In_Court__c`,
     * `Latest_Version__c`). Those are blind writes on an Id-only stamp record, exactly as before;
     * reading them back would add nothing and would invite a read-modify-write where none is wanted.
     *
     * ── 🔴 WITH SYSTEM_MODE — THE AUTOMATION-PATH EXCEPTION, ON THE SAME THREE GROUNDS AS
     *    LoiSelector.selectNegotiationContextById ──────────────────────────────
     *  1. THE USER DID NOT ASK FOR THIS DATA. They asked to log a PSA version. This read exists so
     *     the SERVICE can decide whether the counterparty is called Seller or Buyer, and nothing it
     *     returns is shown to anyone. USER_MODE therefore protects nothing observable while being
     *     able to fail the whole save.
     *  2. MEASURED ON THE SIBLING FIELD, NOT ANTICIPATED. `Contract_Review__c.Disposition__c` is a
     *     NEW field in this tranche, and a Metadata-API-deployed custom field arrives with NO field
     *     permissions for ANY profile, System Administrator included. The identical read on
     *     `LOI__c.Disposition__c` reproduced exactly that on 2026-08-09 —
     *     `System.QueryException: No such column 'Disposition__c' on entity 'LOI__c'`, which is how
     *     the platform reports an FLS denial — and it took down the LIVE ACQUISITION counter-offer
     *     path, which has nothing to do with dispositions. This method is one field rename away
     *     from being that same query, on the LIVE acquisition Log Version path.
     *  3. THE GRANT IS FRAGILE IN A WAY THIS REPO HAS BEEN BURNED BY TWICE. A PermissionSet deploy
     *     REPLACES its entire <fieldPermissions> set, so one unrelated redeploy of
     *     DPEG_Acquisition_Edit that happens to drop this line would silently break every PSA
     *     version log, on both sides, behind PsaVersionController's fixed generic message.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND IS DELIBERATELY LEFT ALONE. SYSTEM_MODE lifts CRUD and
     * FLS, NOT sharing, and this class stays `with sharing`: the caller is logging a version on
     * this very Contract Review, so they demonstrably have the record, and a sharing denial here
     * should still fail. No `without sharing` inner class is warranted — contrast
     * InboundEmailStagingSelector.RoutingReads, where the automation runs as a principal that does
     * NOT own the rows. ⚠ And contrast the SIBLING residual D25 records on
     * PsaVersionSelector.countByContractReviewId, where sharing genuinely does corrupt a derived
     * value: that is a COUNT, which degrades silently; this is a single-row fetch-for-use, which
     * throws.
     *
     * @param contractReviewId Contract_Review__c Id; must reference an existing row.
     * @return The Contract Review with Id, RecordTypeId and Disposition__c populated.
     * @throws System.QueryException when no Contract Review matches the Id or the running user
     *         cannot see it.
     */
    public static Contract_Review__c selectNegotiationContextById(Id contractReviewId) {
        return [
            SELECT Id, RecordTypeId, Disposition__c
            FROM Contract_Review__c
            WHERE Id = :contractReviewId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    /**
     * The most recently created Contract Review related to a DISPOSITION — backs the PSA row of
     * the disposition Deal Summary card (`DispositionDealSummaryService` ->
     * `c/dispositionDealSummary`). Added 2026-08-20, Tranche 2 Workstream C (design D5).
     *
     * ⚠ IT RETURNS THE RECORD-OR-NULL, WHERE ITS OPPORTUNITY SIBLING RETURNS A LIST OF 0 OR 1.
     * That is a deliberate difference, not an inconsistency: `selectLatestByOpportunityId` returns
     * a List only to preserve, byte-for-byte, a caller whose original inline query was consumed by
     * a `for` loop (see this class's header). This method has no such history, so it takes the
     * shape every other "latest child of a Disposition" read in the codebase takes —
     * `NdaSelector.selectLatestByDispositionId`, `LoiSelector.selectLatestByDispositionId`,
     * `DispositionSelector.selectMostRecentByPropertyAssetId`.
     *
     * 🔴 IT SELECTS `Negotiation_Status__c`, NOT `Stage__c` — the same contract
     * `selectStageRequiredById` carries, for a different reason. There, writing `Stage__c` is
     * silently discarded by the active before-save flow `Contract_Review_Stage_Sync`. Here the
     * concern is READ fidelity: `Stage__c` is a DERIVED PROJECTION of `Negotiation_Status__c`
     * (Initial Draft -> PSA Drafting, Revised / Ready for Execution -> Review, either Counter ->
     * Counter, Executed -> Contract Execution), so it collapses four negotiation states into
     * three and cannot distinguish "Revised" from "Ready for Execution" — precisely the
     * distinction a seller watching a PSA wants. Read the source field, not its projection.
     *
     * `Latest_Version__c` is itself derived — `PsaVersionService` maintains it from the
     * `PSA_Version__c` log — so the card shows the version count without a second query or a
     * second FLS surface. `Execution_Date__c` is null until the PSA is executed, which the card
     * renders as an absent line rather than an em-dash.
     *
     * READ-FOR-DISPLAY, null on miss: most dispositions have no PSA for most of their life, so
     * "no Contract Review" is a normal state the card renders as an empty state, never an error.
     * Deliberately NOT the throwing fetch-for-use contract of the two `...RequiredById` methods.
     *
     * ⚠ ORDER BY carries an `Id DESC` TIE-BREAK. `CreatedDate` is second-granular; two Contract
     * Reviews created under one Disposition inside the same second would otherwise make the card
     * non-deterministic between refreshes. Full reasoning on
     * `NdaSelector.selectLatestByDispositionId`. The Opportunity sibling above has no tie-break —
     * that is a preserved P4 refactor artefact, not a precedent.
     *
     * ── FLS: `WITH USER_MODE`, unlike the two SYSTEM_MODE methods either side of it ──
     * A human asked for this by opening the record page, so ARCHITECTURE.md §2's automation-path
     * exception does not apply and the fix for any denial is a permission set. `USER_MODE`
     * enforces FLS on the `WHERE` field as well, so `Contract_Review__c.Disposition__c` must stay
     * granted alongside `Negotiation_Status__c`, `Execution_Date__c` and `Latest_Version__c` — all
     * four verified present in `DPEG_Disposition_View` and `DPEG_Disposition_Edit` on 2026-08-20.
     * `USER_MODE` throws rather than degrades, which is why the caller wraps this in a narrow
     * fail-soft try/catch; the grant and the catch are both required.
     *
     * @param dispositionId Parent Disposition__c Id; null-safe.
     * @return The latest related Contract Review with Id, Negotiation_Status__c, Execution_Date__c
     *         and Latest_Version__c populated (ORDER BY CreatedDate DESC, Id DESC LIMIT 1), or
     *         null when the input is null or the Disposition has none. ⚠ `Id` IS CONSUMED — since
     *         2026-08-21 it becomes `DealSummary.psaId` and backs the card's click-through link on
     *         the PSA row label. It costs no FLS and SOQL returns it regardless of the SELECT list.
     * @example
     * Contract_Review__c psa = ContractReviewSelector.selectLatestByDispositionId(dispositionId);
     */
    public static Contract_Review__c selectLatestByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<Contract_Review__c> rows = [
            SELECT Id, Negotiation_Status__c, Execution_Date__c, Latest_Version__c
            FROM Contract_Review__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Contract Reviews related to a set of DISPOSITIONS — backs DispositionStageEntryService's
     * idempotency on the `PSA` stage ("never a second disposition PSA on one disposition").
     * Bulk-safe: one query for the whole set, called once per trigger chunk.
     *
     * 🔴 `WITH SYSTEM_MODE`, AND IT IS THE ONLY MODE THAT IS CORRECT HERE — the same
     * automation-path argument NdaSelector.selectByDispositionIds carries, with the same
     * consequence. The running user asked to move a disposition to the PSA stage, not to read
     * Contract Reviews. Under `WITH USER_MODE` a principal lacking FLS on `Disposition__c` — brand
     * new in this tranche, so no profile has it, System Administrator included — makes the query
     * THROW rather than degrade. That throw happens inside an AFTER-UPDATE trigger, so it does not
     * merely disable auto-create: it ROLLS BACK THE USER'S OWN STAGE CHANGE with
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY. That is the reproduced production failure
     * ARCHITECTURE.md records for TaskSelector.selectByTransactionDealIds.
     *
     * ⚠ SYSTEM_MODE lifts CRUD/FLS ONLY — it does NOT lift sharing, and that is deliberate rather
     * than an oversight. The class stays `with sharing`: every disposition in the set was just
     * edited by the running user, so they can already see it. This is NOT the shape that needed a
     * `private without sharing` inner class (contrast InboundEmailStagingSelector.RoutingReads,
     * whose rows are owned by a DIFFERENT principal than the one running the automation).
     *
     * ⚠ THE QUERY IS DELIBERATELY NOT SCOPED TO THE Disposition_PSA RECORD TYPE. In the window
     * between the record-type deploy and post-deploy gate T-A1 a disposition PSA can legitimately
     * sit on MASTER, and suppressing on record type would then mint a second one. The
     * `Disposition__c` lookup is the whole key — a Contract Review parented to a Disposition IS a
     * disposition PSA regardless of what record type landed on it.
     *
     * @param dispositionIds Parent Disposition__c Ids; null/empty-safe.
     * @return Contract Reviews with Id and Disposition__c populated; empty when the input is null
     *         or empty.
     */
    public static List<Contract_Review__c> selectByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<Contract_Review__c>();
        }
        return [
            SELECT Id, Disposition__c
            FROM Contract_Review__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }
}
