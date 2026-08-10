/**
 * Selector for NDA__c. Encapsulates ALL SOQL against NDA__c per ARCHITECTURE.md §2
 * and .claude/rules/apex-layering-rule.md.
 *
 * P4 Module A1 (Acquisitions — Deal Core). Consumer: OpportunityDocStatusController
 * (the Deal Summary card's NDA row). NDA__c is a custom object — USER_MODE (P3
 * custom-field FLS gap = 0).
 *
 * ⚠ THE MODE IS A PROPERTY OF THE METHOD, NOT OF THIS CLASS — amended 2026-08-09 (Tranche 3A).
 * The A1-era claim "No SYSTEM_MODE / guest path" is now FALSE and has been removed rather than
 * left to mislead. `selectByDispositionIds` is `WITH SYSTEM_MODE` because it is an AUTOMATION
 * -PATH read behind the disposition NDA auto-create trigger; every other method here stays
 * `WITH USER_MODE` because each backs a read a human explicitly asked for. Read the method's own
 * Javadoc, which is where the justification lives (ARCHITECTURE.md §2). Same shape as
 * TaskSelector and InboundEmailStagingSelector.
 *
 * ⚠ NDA__c IS DUAL-PARENTED (Opportunity__c and Disposition__c), so this selector now
 * serves BOTH modules: selectLatestByOpportunityId for Acquisitions and
 * selectLatestByDispositionId for the Disposition BOV Outreach pill. They are separate
 * methods over separate lookups, not one parameterised query — the two parents are
 * different fields and a caller must not be able to pass the wrong one.
 *
 * NOT-FOUND CONTRACT — read-for-display: both consumer lookups (designated
 * Primary_NDA__c, else most-recent related NDA) treat "no NDA" as a normal state,
 * so both methods return SObject-or-null.
 *
 * DESIGN DEVIATION (noted in the A1 hand-off report): the P4 design §4 Skeleton C
 * proposed one dynamic `selectOneByClause(String tail, Id pid)` fed an allow-listed
 * WHERE fragment from the controller. That is replaced here by two static, named
 * methods. Rationale: (1) apex-layering-rule (non-negotiable) requires the selector
 * to own its full query text — passing a WHERE fragment from the controller is the
 * controller "writing its own query"; (2) it removes an avoidable dynamic-SOQL
 * string concatenation the analyzer flags as injection surface. Behavior
 * (primary-else-latest, null-on-empty) is preserved byte-for-byte.
 *
 * @see agent-output/p4-selector-design.md (§3 #8, §5)
 */
public with sharing class NdaSelector {

    /**
     * The NDA designated as an Opportunity's primary NDA (Primary_NDA__c lookup).
     *
     * @param ndaId NDA__c Id (the deal's Primary_NDA__c); null-safe.
     * @return The NDA with the Deal Summary field set, or null when the input is
     *         null or the row does not exist.
     */
    public static NDA__c selectById(Id ndaId) {
        if (ndaId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created NDA related to an Opportunity — the fallback when
     * no primary NDA is designated.
     *
     * @param opportunityId Parent Opportunity Id; null-safe.
     * @return The latest related NDA (ORDER BY CreatedDate DESC LIMIT 1), or null
     *         when the input is null or the Opportunity has no NDA.
     */
    public static NDA__c selectLatestByOpportunityId(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c
            FROM NDA__c
            WHERE Opportunity__c = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The most recently created NDA related to a DISPOSITION — backs the NDA status pill
     * on the Disposition BOV Outreach tile (BovController.getOutreachSummary).
     *
     * READ-FOR-DISPLAY, null on miss: "no NDA yet" is a completely normal state for a
     * disposition (most never have one), which the caller renders as "No NDA". It must not
     * be an exception.
     *
     * ⚠ The field list is deliberately MINIMAL (Id + Status__c) — narrower than this
     * selector's Opportunity-side methods, on purpose. The pill renders Status__c and
     * nothing else, and under WITH USER_MODE every extra field is another way for this read
     * to throw for a persona that was granted NDA__c but not that particular field. The
     * caller wraps this call in a NARROW fail-soft try/catch for exactly that reason (Gate 1
     * Q7 — a QueryException reaching BovController's outer catch blanks the entire BOV
     * Outreach tile). ⚠ The grant and the catch are BOTH required; neither substitutes for
     * the other. Do not widen this field set without re-checking the FLS grants on
     * DPEG_Disposition_View and DPEG_Disposition_Edit.
     *
     * ⚠ Nothing about NDA__c itself changes with this method — no new values, no rename, no
     * Party_Role__c. The four-state model and the all-signed gate are a later change (D7).
     *
     * ⚠ ORDER BY carries an `Id DESC` TIE-BREAK, matching WireSelector.selectMostRecentByDispositionId.
     * CreatedDate is second-granular, so two NDAs created under one Disposition inside the same
     * second — routine in a test transaction and possible in a bulk load — leave `ORDER BY
     * CreatedDate DESC LIMIT 1` free to return either row. The pill would then be
     * non-deterministic. Do not drop the second sort key.
     *
     * @param dispositionId Parent Disposition__c Id; null-safe.
     * @return The latest related NDA with Id and Status__c populated (ORDER BY CreatedDate
     *         DESC, Id DESC LIMIT 1), or null when the input is null or the Disposition has
     *         no NDA.
     * @example
     * NDA__c nda = NdaSelector.selectLatestByDispositionId(dispositionId);
     * String status = (nda == null) ? null : nda.Status__c;
     */
    public static NDA__c selectLatestByDispositionId(Id dispositionId) {
        if (dispositionId == null) {
            return null;
        }
        List<NDA__c> rows = [
            SELECT Id, Status__c
            FROM NDA__c
            WHERE Disposition__c = :dispositionId
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * NDAs related to a set of Opportunities — backs OpportunityReviewService.ensureNda
     * idempotency (drop any deal that already has an NDA so a second is never opened).
     * Added by Module A2: the A2 OpportunityReviewService repoint needs a bulk,
     * set-based existence read that A1's single-record methods do not provide.
     * Bulk-safe (one query for the whole set).
     *
     * @param opportunityIds Parent Opportunity Ids; null/empty-safe.
     * @return NDAs with Id and Opportunity__c populated; empty when the input is
     *         null or empty.
     */
    public static List<NDA__c> selectByOpportunityIds(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<NDA__c>();
        }
        return [
            SELECT Id, Opportunity__c
            FROM NDA__c
            WHERE Opportunity__c IN :opportunityIds
            WITH USER_MODE
        ];
    }

    /**
     * NDAs related to a set of DISPOSITIONS — backs DispositionStageEntryService's idempotency
     * ("never a second buyer NDA on one disposition", D19.1). Bulk-safe: one query for the whole
     * set, called once per trigger chunk.
     *
     * 🔴 `WITH SYSTEM_MODE`, AND IT IS THE ONLY MODE THAT IS CORRECT HERE. This is an
     * AUTOMATION-PATH read (ARCHITECTURE.md §2, "the automation-path exception"): the running
     * user asked to move a disposition to the NDA stage, not to read NDAs. Under `WITH USER_MODE`
     * a principal lacking FLS on ANY selected field — and `Party_Role__c` is brand new in this
     * tranche, so a Metadata-API-deployed field arrives with NO field permissions for ANY
     * profile, System Administrator included — makes the query THROW rather than degrade. That
     * throw happens inside an AFTER-UPDATE trigger, so it does not merely disable auto-create:
     * it ROLLS BACK THE USER'S OWN STAGE CHANGE with
     * CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY. That is precisely the reproduced production failure
     * ARCHITECTURE.md records for TaskSelector.selectByTransactionDealIds, one module later.
     *
     * ⚠ SYSTEM_MODE lifts CRUD/FLS ONLY — it does NOT lift sharing, and that is deliberate here
     * rather than an oversight. The class stays `with sharing`: every disposition in the set was
     * just edited by the running user, so they can already see it, and the NDAs hanging off it
     * are theirs to see too. This is NOT the shape that needed a `private without sharing` inner
     * class (contrast InboundEmailStagingSelector.RoutingReads, whose rows are owned by a
     * DIFFERENT principal than the one running the automation).
     *
     * ⚠ The field list is a CONTRACT. `Party_Role__c` IS the idempotency key and `RecordTypeId`
     * is what lets the caller tell an auto-created buyer NDA from a hand-added broker one.
     * Narrowing either does not fail loudly — it makes auto-create fire a second time on a
     * disposition that already has its NDA.
     *
     * @param dispositionIds Parent Disposition__c Ids; null/empty-safe.
     * @return NDAs with Id, Disposition__c, Party_Role__c, Status__c and RecordTypeId populated;
     *         empty when the input is null or empty.
     */
    public static List<NDA__c> selectByDispositionIds(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return new List<NDA__c>();
        }
        return [
            SELECT Id, Disposition__c, Party_Role__c, Status__c, RecordTypeId
            FROM NDA__c
            WHERE Disposition__c IN :dispositionIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Loads an NDA for the generic stage-advance quick action — backs
     * RecordStageAdvanceService.advance.
     *
     * FETCH-FOR-USE: the caller reads the stage, derives the next one and writes it back, so a miss
     * is an error, not a normal state. A single-row SOQL assignment throws native
     * System.QueryException, matching OpportunitySelector.selectStageRequiredById.
     *
     * ⚠ NDA__c's stage field is `Status__c`, NOT `Stage__c` — it is one of only two of the six
     * stage-controlled deal children shaped that way (the other is
     * `Contract_Review__c.Negotiation_Status__c`), which is why RecordStageAdvanceService carries
     * the field name per object.
     *
     * 🔴 `RecordTypeId` IS SELECTED AND IS MANDATORY — added 2026-08-09 (Tranche 3A, D7 / D14.1).
     * `NDA__c` now carries `Acquisition_NDA` and `Disposition_NDA`, whose stage sequences DIVERGE
     * on a SHARED value: from `Sent` an acquisition NDA advances to `Received` and a disposition NDA
     * advances to `Signed`. RecordStageAdvanceService therefore cannot pick the right sequence from
     * `Status__c` alone. Dropping this field does not fail loudly — it silently routes every NDA to
     * the acquisition sequence, so treat the field list as a CONTRACT and do not narrow it.
     *
     * ⚠ This is the one widening that costs nothing under `WITH USER_MODE`. `RecordTypeId` is a
     * standard system field on which field-level security cannot be configured, so — unlike a custom
     * field — adding it creates no new FLS denial surface for a persona already able to read
     * `NDA__c`. The "deliberately minimal field list" philosophy in this class's other methods is
     * about FLS exposure, and this addition does not move it.
     *
     * ⚠ COMPILE ORDERING. A custom object with zero record types has NO `RecordTypeId` field at
     * all, so this query does not compile until `objects/NDA__c/recordTypes/` is deployed. Measured
     * on `usman-dpeg` 2026-08-09: `NDA__c` describes with only `Master` and no `RecordTypeId`.
     * Metadata (design §6 T1) must land before this class — the ordering is a COMPILE requirement
     * here, not merely a runtime one.
     *
     * Beyond that the field list stays MINIMAL (Id + the stage field + the record type) per this
     * selector's per-caller philosophy: the advance write touches nothing else.
     *
     * @param ndaId NDA__c Id; must reference an existing row.
     * @return The NDA with Id, Status__c and RecordTypeId populated.
     * @throws System.QueryException when no NDA matches the Id.
     */
    public static NDA__c selectStageRequiredById(Id ndaId) {
        return [
            SELECT Id, Status__c, RecordTypeId
            FROM NDA__c
            WHERE Id = :ndaId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
