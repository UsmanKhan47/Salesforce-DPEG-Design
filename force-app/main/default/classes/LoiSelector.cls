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
 *
 * LOI__c is a custom object — USER_MODE (P3 custom-field FLS gap = 0) on four of the six methods.
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
     * RecordStageAdvanceService picks THREE things: the stage sequence (Draft -> … -> Completed vs
     * Received -> … -> Executed), the explicit-target allow-list, and the permission gate
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
