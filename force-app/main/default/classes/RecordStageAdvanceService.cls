/**
 * RecordStageAdvanceService — ONE generic stage-advance service for the five acquisitions
 * CHILD objects whose Lightning Path is a straight line:
 *
 *   NDA__c                              (Status__c)  Pending -> Sent -> Signed
 *   LOI__c                              (Stage__c)   Draft -> Prepare/Review -> Sent -> Counter -> Completed
 *   Underwriting__c                     (Stage__c)   Requested -> In Progress -> [approval] -> Approved -> Completed
 *   Construction_Feasibility_Review__c  (Stage__c)   Requested -> Site Visit -> Condition Assessment
 *                                                    -> Cost Estimate -> Share Opinion -> Completed
 *   Development_Feasibility_Review__c   (Stage__c)   Requested -> Feasibility analysis
 *                                                    -> Vendor proposals -> Share Opinion -> Completed
 *
 * It exists so the Path's "Mark Status as Complete" button can be removed from these record pages
 * and every stage change routed through Apex, where the transition is derived (never supplied),
 * the permission is asserted server-side, and any future validation rule's message is surfaced to
 * the user instead of being swallowed.
 *
 * ── ⚠ THERE ARE TWO STAGE SERVICES. KNOW WHICH ONE YOU ARE EDITING ────────────
 *   StageAdvanceService        — OPPORTUNITY only. Its advance() BRANCHES into an approval
 *                                submission, and its advanceTo() exists because Opportunity has
 *                                parallel record-type branches (Land / Commercial) and an off-ramp;
 *                                that is why it carries ALLOWED_EXPLICIT_TARGETS.
 *   RecordStageAdvanceService  — THIS CLASS. The five child objects above. Every path is LINEAR,
 *                                so there is no branch, no off-ramp, and no explicit target.
 * They are deliberately NOT merged: folding a live, gated, deployed feature into a new one buys
 * tidiness and costs a re-test of the Opportunity approval hand-off. They DO share the permission
 * service (OpportunityActionPermissionService) and the confirm/guard shape on the client. Same
 * "know which one you are editing" convention as the three LeadConvert* classes.
 *
 * ── 🔴 EXPOSES advance(recordId) ONLY — NO GENERIC advanceTo ──────────────────
 * A generic explicit-target write across five objects would re-open exactly the hole
 * StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close: any holder of class access
 * could write any stage on any of five objects, skipping every hop. advance() derives the target
 * from the map, so it CANNOT skip a hop. All five paths are linear, so an explicit target would
 * serve nothing. Add one only when an object gains a branch or an off-ramp — and give it an
 * allow-list on day one.
 *
 * ── WHY THE MAPS ARE APEX AND NOT CUSTOM METADATA ────────────────────────────
 * A Stage_Map__mdt would let an admin change a stage map with no deploy and no review, which is the
 * SAME class of hole as the Path button this program removes. It also costs a getAll() per
 * transaction, is not compile-checked against its callers, and — recorded org defect — CMDT *record*
 * deploys fail in this org with UNKNOWN_EXCEPTION and need an Apex loader. A stage change already
 * requires touching the picklist, the pathAssistant and the quick action, all metadata deploys, so
 * the map is not the bottleneck. The Opportunity precedent (StageAdvanceService.NEXT_STAGE) is an
 * Apex map; matching it keeps one pattern.
 *
 * ── LAYERING ─────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds ZERO SOQL: every read
 * goes to the object's own selector via selectStageRequiredById. There is deliberately NO dynamic
 * SOQL — a generic Database.query() over five objects would violate the selector rule, skip
 * WITH USER_MODE and add an injection surface. The cost is a five-branch dispatch in load(), which
 * is two lines per object and compile-checked.
 *
 * ── WRITE MODE (design decision D1): plain `update`, i.e. SYSTEM MODE ─────────
 * Matches StageAdvanceService.setStage exactly. The control here is the permission gate plus the
 * (future) validation rule, not FLS; and a silent divergence between two sibling services is itself
 * a defect source. RESIDUAL, accepted and documented: a user with the deal-driver gate but WITHOUT
 * FLS edit on the stage field can still drive the button. Switching to
 * Database.update(record, AccessLevel.USER_MODE) is a one-line change, but FLS truth is not in
 * source control (profiles are .forceignore'd), so it cannot be regression-tested from this repo.
 *
 * ── BULKIFICATION ────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. advance() is a
 * per-transaction-singleton @AuraEnabled operation invoked once per quick-action click: one record,
 * one selector read, one update, no loop over records and no collection DML. Same shape and same
 * exemption as StageAdvanceService and OpportunityActionPermissionService.
 *
 * @see force-app/main/default/classes/StageAdvanceService.cls (the Opportunity sibling)
 * @see force-app/main/default/classes/RecordStageAdvanceController.cls (the LWC boundary)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the gate)
 */
public with sharing class RecordStageAdvanceService {

    /**
     * Raised when a record cannot advance and the reason is user-safe and surfaced verbatim:
     * no record supplied, an unsupported object, no stage set, no next step from the current
     * stage, or a platform save block whose validation message is surfaced. Distinct from an
     * unexpected QueryException (missing/inaccessible record), which the controller maps to a
     * fixed generic message instead.
     */
    public class RecordStageAdvanceException extends Exception {}

    /**
     * Raised when the running user may not drive this record's stage action. Owned by THIS class
     * rather than re-thrown from the gate's own type so that adding a second gate (e.g. a Property
     * Management persona on a future object) changes nothing at the controller boundary.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * Which permission gate an object's stage action answers to. An enum, not a String, so a new
     * object cannot be wired to a gate that does not exist (.claude/rules — "use enums over string
     * constants").
     *
     * DEAL_DRIVER is the TWO-FACTOR Opportunity gate: FLS read on `User.Deal_Driver__c` (granted
     * only by the `Acquisition_Deal_Driver` permission set) AND that flag true on the running user.
     * All five objects here are acquisitions deal children sharing that persona, and the LOI and
     * Underwriting record pages already carry the identical `{!$User.Deal_Driver__c} EQUAL true`
     * Dynamic Actions visibility rule — so this choice costs zero new permission machinery.
     *
     * ⚠ It is deliberately NOT a permission-set MEMBERSHIP check. Membership and the flag are
     * DIFFERENT QUESTIONS: a user holding `Acquisition_Deal_Driver` with `Deal_Driver__c = false` is
     * denied today and would be GRANTED by a membership check — a silent widening of a live
     * authorization boundary. See OpportunityActionPermissionService's header.
     */
    public enum StageActionGate {
        DEAL_DRIVER
    }

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';
    private static final String UNSUPPORTED_OBJECT_MESSAGE =
        'This action is not available on this record.';
    private static final String NO_STAGE_MESSAGE =
        'This record has no stage set, so it cannot be advanced.';

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE MAPS — current stage -> the single next stage.
    // Each map is the object's Path, minus its terminal stage (which has no entry and therefore
    // yields the "no next step available" message). Values are the DECODED runtime picklist
    // strings; 'Prepare/Review' carries a literal slash, which is why the future validation rules
    // must use TEXT(...) compares rather than ISPICKVAL.
    // ─────────────────────────────────────────────────────────────────────────

    /** NDA__c.Status__c — Pending -> Sent -> Signed. 'Signed' is terminal. */
    private static final Map<String, String> NDA_NEXT_STAGE = new Map<String, String>{
        'Pending' => 'Sent',
        'Sent' => 'Signed'
    };

    /** LOI__c.Stage__c — Draft -> Prepare/Review -> Sent -> Counter -> Completed. */
    private static final Map<String, String> LOI_NEXT_STAGE = new Map<String, String>{
        'Draft' => 'Prepare/Review',
        'Prepare/Review' => 'Sent',
        'Sent' => 'Counter',
        'Counter' => 'Completed'
    };

    /**
     * Contract_Review__c.Negotiation_Status__c — Initial Draft -> Revised -> Ready for Execution
     * -> Executed. 'Executed' is terminal.
     *
     * 🔴 THIS OBJECT'S STAGE FIELD IS Negotiation_Status__c, NOT Stage__c — THE ONLY EXCEPTION
     * BESIDES THE NDA, AND FOR A COMPLETELY DIFFERENT REASON.
     * The NDA simply names its field Status__c. Here, Stage__c is a DERIVED PROJECTION that CANNOT
     * be written at all: the active before-save flow Contract_Review_Stage_Sync recomputes it from
     * Negotiation_Status__c on every create and update. A first attempt at this object mapped
     * Stage__c directly and produced a button that reported SUCCESS and changed nothing — the DML
     * committed, LastModifiedDate moved, and the flow had already replaced the value (measured
     * 2026-08-05 on CTR-0000). Driving the status is what makes the Path move, as a consequence:
     *
     *   Initial Draft        -> Path shows 'PSA Drafting'
     *   Revised              -> Path shows 'Review'
     *   Ready for Execution  -> Path shows 'Review'   (same stage; the Path does not move here)
     *   Executed             -> Path shows 'Contract Execution'
     *   Seller/Buyer Counter -> Path shows 'Counter'  (set by inline edit, not by this action)
     *
     * ⚠ TWO CONSEQUENCES WORTH KNOWING BEFORE EDITING THIS MAP.
     * 1. Revised -> Ready for Execution leaves the PATH UNCHANGED (both project to 'Review'), so the
     *    user sees a success toast and a stationary Path. That is correct, not a repeat of the
     *    defect above — the status genuinely advanced.
     * 2. The final hop, Ready for Execution -> Executed, is NOT just a status write. It fires
     *    ContractReviewTrigger -> ContractExecutionService, which stamps the Opportunity (Contract
     *    Signed, Day 0) and CREATES THE Transaction__c. Adding or reordering entries around
     *    'Executed' changes when that handoff fires.
     *
     * Seller Counter and Buyer Counter are deliberately absent: they are branch states, and the
     * user chose (2026-08-05) to record them by editing the field rather than with named buttons.
     * Adding them later means an explicit-target allow-list, exactly as the LOI has.
     */
    private static final Map<String, String> CONTRACT_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Initial Draft' => 'Revised',
        'Revised' => 'Ready for Execution',
        'Ready for Execution' => 'Executed'
    };

    /**
     * 🔴 THE LOI PATH IS NO LONGER LINEAR (2026-08-05) — the ONLY object here that branches.
     *
     * At 'Sent' a broker either counters or accepts, so the deal driver gets two named buttons
     * instead of one generic Advance Stage: Counter and Completed. 'Completed' cannot be reached by
     * advance() from 'Sent' — LOI_NEXT_STAGE derives 'Counter' — so it needs an explicit target.
     *
     * This is the allow-list the class header demanded on day one, and it is deliberately PER
     * OBJECT: the other four configs pass no explicit targets at all, so advanceTo() is structurally
     * unreachable for them. Membership is limited to the two stages that legitimately have no single
     * derivable predecessor from 'Sent'. 'Prepare/Review' and 'Sent' are deliberately EXCLUDED —
     * they are derivable forward hops belonging to advance(), and listing them would let a direct
     * Apex call skip the approval gate the LOI page enforces at Prepare/Review.
     */
    private static final Set<String> LOI_EXPLICIT_TARGETS = new Set<String>{
        'Counter',
        'Completed'
    };

    /**
     * Underwriting__c.Stage__c.
     *
     * 🔴 THE 'In Progress' -> 'Approved' HOP IS DELIBERATELY ABSENT. IT IS NOT AN OVERSIGHT.
     *
     * 'Approved' is owned by the PRINCIPAL APPROVAL PROCESS. A naive "same as the other objects"
     * copy would put Approved one button-click away and bypass the approval entirely — the deal
     * would show a principal-approved underwriting that no principal ever saw. The already-deployed
     * `Underwriting__c.Submit_for_Approval` quick action (OpportunityApprovalController ->
     * OpportunityApprovalService) is the route from 'In Progress', and ApprovalAuditService stamps
     * Stage__c = 'Approved' on principal sign-off.
     *
     * From 'In Progress' this service therefore refuses, with wording that NAMES the real route
     * (see NO_NEXT_STEP_HINTS) so the omission reads as a rule rather than a bug.
     *
     * Exactly the same shape as StageAdvanceService.NEXT_STAGE deliberately omitting 'Underwriting'
     * for exactly the same reason.
     *
     * ⚠ ApprovalAuditService's stamp is Apex DML inside a try/catch that SWALLOWS the DmlException,
     * so any future validation rule on Underwriting__c.Stage__c MUST explicitly permit the
     * transition into 'Approved' — a rule that blocks it fails silently and the Path simply never
     * reaches Approved (design doc §7.3).
     */
    private static final Map<String, String> UNDERWRITING_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'In Progress',
        // 'In Progress' => (no entry) — reaching 'Approved' is the approval process's job.
        'Approved' => 'Completed'
    };

    /**
     * Construction_Feasibility_Review__c.Stage__c —
     * Requested -> Site Visit -> Condition Assessment -> Cost Estimate -> Share Opinion -> Completed.
     */
    private static final Map<String, String> CONSTRUCTION_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Site Visit',
        'Site Visit' => 'Condition Assessment',
        'Condition Assessment' => 'Cost Estimate',
        'Cost Estimate' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Development_Feasibility_Review__c.Stage__c —
     * Requested -> Feasibility analysis -> Vendor proposals -> Share Opinion -> Completed.
     * ⚠ 'Feasibility analysis' and 'Vendor proposals' are lower-cased on their second word in the
     * picklist metadata. The literals here match the org exactly; "correcting" the casing yields a
     * map that silently never matches.
     */
    private static final Map<String, String> DEVELOPMENT_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Feasibility analysis',
        'Feasibility analysis' => 'Vendor proposals',
        'Vendor proposals' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Stage-specific wording for a refused advance, keyed `<StageConfig.label>|<currentStage>`.
     *
     * Keyed on the config's own label rather than on the SObjectType so no key depends on
     * SObjectType.toString(), which is undocumented.
     *
     * Only populated where the absence of a hop is a RULE rather than the end of the path. Without
     * this, the Underwriting refusal reads exactly like a terminal stage and looks like a defect;
     * with it, the message names the action that actually performs the transition.
     */
    private static final Map<String, String> NO_NEXT_STEP_HINTS = new Map<String, String>{
        'Underwriting|In Progress' =>
            'Underwriting moves to Approved through the principal approval, not this action. '
            + 'Use Submit for Approval.'
    };

    /** Per-object configuration: display label, stage field API name, stage map, permission gate. */
    private class StageConfig {
        private final String label;
        private final String stageField;
        private final Map<String, String> nextStage;
        private final StageActionGate gate;
        /**
         * The ONLY stages advanceTo() will write for this object. Empty for an object whose path is
         * still linear, which makes advanceTo() unreachable there — the allow-list is per object
         * precisely so a branch on one object cannot open explicit writes on the other four.
         */
        private final Set<String> explicitTargets;

        /** Linear path: no branch, so no explicit target is permitted at all. */
        private StageConfig(
            String label,
            String stageField,
            Map<String, String> nextStage,
            StageActionGate gate
        ) {
            this(label, stageField, nextStage, gate, new Set<String>());
        }

        private StageConfig(
            String label,
            String stageField,
            Map<String, String> nextStage,
            StageActionGate gate,
            Set<String> explicitTargets
        ) {
            this.explicitTargets = explicitTargets;
            this.label = label;
            this.stageField = stageField;
            this.nextStage = nextStage;
            this.gate = gate;
        }
    }

    /**
     * The whole feature's configuration, keyed by SObjectType TOKEN (not by name String) so every
     * key is compile-checked and a renamed object breaks the build instead of silently disabling
     * the action.
     *
     * ⚠ NDA__c's stage field is `Status__c`; the other four use `Stage__c`. That difference is the
     * reason this config carries the field name per object rather than hardcoding `Stage__c`.
     */
    private static final Map<Schema.SObjectType, StageConfig> CONFIG_BY_TYPE =
        new Map<Schema.SObjectType, StageConfig>{
            NDA__c.SObjectType => new StageConfig(
                'NDA', 'Status__c', NDA_NEXT_STAGE, StageActionGate.DEAL_DRIVER),
            LOI__c.SObjectType => new StageConfig(
                'LOI', 'Stage__c', LOI_NEXT_STAGE, StageActionGate.DEAL_DRIVER,
                LOI_EXPLICIT_TARGETS),
            // ⚠ 'Negotiation_Status__c', NOT 'Stage__c' — Stage__c is derived and unwritable here.
            // See CONTRACT_REVIEW_NEXT_STAGE above before changing this.
            Contract_Review__c.SObjectType => new StageConfig(
                'Contract Review', 'Negotiation_Status__c', CONTRACT_REVIEW_NEXT_STAGE,
                StageActionGate.DEAL_DRIVER),
            Underwriting__c.SObjectType => new StageConfig(
                'Underwriting', 'Stage__c', UNDERWRITING_NEXT_STAGE, StageActionGate.DEAL_DRIVER),
            Construction_Feasibility_Review__c.SObjectType => new StageConfig(
                'Construction Feasibility Review', 'Stage__c',
                CONSTRUCTION_REVIEW_NEXT_STAGE, StageActionGate.DEAL_DRIVER),
            Development_Feasibility_Review__c.SObjectType => new StageConfig(
                'Development Feasibility Review', 'Stage__c',
                DEVELOPMENT_REVIEW_NEXT_STAGE, StageActionGate.DEAL_DRIVER)
        };

    /**
     * Moves the record to the single next stage for its current stage.
     *
     * The target is DERIVED from the object's map and can never be supplied by the caller, so this
     * method cannot skip a hop.
     *
     * @param recordId the NDA / LOI / Underwriting / Construction or Development Feasibility Review
     *                 record to advance (required)
     * @return a user-facing confirmation message, e.g. 'LOI moved to Sent.'
     * @throws RecordStageAdvanceException when recordId is null, the object is not stage-controlled,
     *         the record has no stage set, there is no next step from the current stage, or the
     *         write is blocked (the block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advance(loiId);
     */
    public static String advance(Id recordId) {
        StageConfig config = configFor(recordId);
        SObject record = load(recordId);

        String currentStage = (String) record.get(config.stageField);
        if (String.isBlank(currentStage)) {
            throw new RecordStageAdvanceException(NO_STAGE_MESSAGE);
        }

        String target = config.nextStage.get(currentStage);
        if (target == null) {
            throw new RecordStageAdvanceException(noNextStepMessage(config, currentStage));
        }
        return setStage(record, config, target);
    }

    /**
     * Moves the record to an EXPLICIT stage, which must be on that object's allow-list.
     *
     * Added 2026-08-05 for the LOI 'Sent' branch — a broker either counters or accepts, so the deal
     * driver needs two named buttons where advance() can only derive one. It mirrors
     * StageAdvanceService.advanceTo, including the reason that method exists at all.
     *
     * 🔴 THE ALLOW-LIST IS THE WHOLE POINT AND IS PER OBJECT. Without it, any holder of controller
     * access could write ANY stage on ANY of five objects, skipping every hop and every gate — the
     * exact hole StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close. Four of the five
     * objects supply no explicit targets, so this method cannot write to them at all. Adding a
     * branch action means adding its stage to that object's set; do NOT add derivable forward hops,
     * which belong to advance() and therefore cannot skip a step.
     *
     * The rejection message deliberately does NOT echo the supplied value back: a legitimate caller
     * can never reach that branch (each bundle passes a hardcoded constant), so the only way in is a
     * hand-crafted call, and reflecting attacker-supplied text into a toast has no upside. Same
     * wording choice as StageAdvanceService.
     *
     * @param recordId the stage-controlled record to move (required)
     * @param target   the destination stage; must be on this object's allow-list
     * @return a user-facing confirmation message, e.g. 'LOI moved to Completed.'
     * @throws RecordStageAdvanceException when recordId is null, target is blank, target is not an
     *         allowed explicit target for this object, the object is not stage-controlled, or the
     *         write is blocked (the block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advanceTo(loiId, 'Completed');
     */
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw new RecordStageAdvanceException('No target stage was provided.');
        }
        StageConfig config = configFor(recordId);
        if (!config.explicitTargets.contains(target)) {
            throw new RecordStageAdvanceException('That stage is not available from this action.');
        }
        return setStage(load(recordId), config, target);
    }

    /**
     * Whether the running user may drive the stage action on this record. The UX gate behind
     * RecordStageAdvanceController.hasStageActionAccess.
     *
     * DISPATCHES to the object's configured gate; it does NOT merge gates. Today all five objects
     * answer to DEAL_DRIVER, but the dispatch is what makes adding a differently-personed object a
     * config line rather than a rewrite.
     *
     * @param recordId the record whose object decides which gate applies (required)
     * @return true when the running user passes that object's gate
     * @throws RecordStageAdvanceException when recordId is null or the object is not stage-controlled
     * @throws System.QueryException when the permission machinery itself fails unexpectedly.
     *         Deliberately NOT swallowed — a fault must not read as a denial. The controller masks
     *         and logs it; the LWC treats a thrown check exactly like false, so the gate still fails
     *         CLOSED end to end.
     * @example
     * if (!RecordStageAdvanceService.hasStageActionAccess(loiId)) { return; }
     */
    public static Boolean hasStageActionAccess(Id recordId) {
        return passesGate(configFor(recordId).gate);
    }

    /**
     * Server-side guard. Called as the first statement of every @AuraEnabled entry point so the
     * declarative Dynamic Actions visibility rule — a UX affordance only — cannot be bypassed by
     * invoking the @AuraEnabled method directly.
     *
     * @param recordId the record whose object decides which gate applies (required)
     * @throws AccessDeniedException carrying the shared denial wording when the user lacks access
     * @throws RecordStageAdvanceException when recordId is null or the object is not stage-controlled
     * @throws System.QueryException when the permission lookup itself fails unexpectedly
     * @example
     * RecordStageAdvanceService.assertStageActionAccess(recordId);
     */
    public static void assertStageActionAccess(Id recordId) {
        if (hasStageActionAccess(recordId)) {
            return;
        }
        // One wording for the client gate, the server assert, and both stage features — the user
        // must never see two phrasings for one condition.
        throw new AccessDeniedException(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE);
    }

    /**
     * Whether an object is stage-controlled by this service. Lets a caller ask without provoking an
     * exception.
     *
     * @param recordId any record Id; null-safe
     * @return true when the record's object has a stage map here
     */
    public static Boolean isSupported(Id recordId) {
        return recordId != null && CONFIG_BY_TYPE.containsKey(recordId.getSObjectType());
    }

    private static StageConfig configFor(Id recordId) {
        if (recordId == null) {
            throw new RecordStageAdvanceException(NO_RECORD_MESSAGE);
        }
        StageConfig config = CONFIG_BY_TYPE.get(recordId.getSObjectType());
        if (config == null) {
            throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
        }
        return config;
    }

    /**
     * Loads the record through its own selector.
     *
     * Deliberately a chain of SObjectType TOKEN comparisons rather than an Apex `switch on`: Apex's
     * switch accepts a String or an enum but not a Schema.SObjectType, so a switch here would have
     * to key on the object's API NAME as a string literal — trading compile-checking for five
     * stringly-typed keys, for no benefit. Every branch is a static, fully-literal, WITH USER_MODE
     * selector call: zero dynamic SOQL and zero string-built queries.
     *
     * FETCH-FOR-USE: each selector method throws System.QueryException on a miss (repo contract).
     */
    private static SObject load(Id recordId) {
        Schema.SObjectType recordType = recordId.getSObjectType();
        if (recordType == NDA__c.SObjectType) {
            return NdaSelector.selectStageRequiredById(recordId);
        }
        if (recordType == LOI__c.SObjectType) {
            return LoiSelector.selectStageRequiredById(recordId);
        }
        if (recordType == Underwriting__c.SObjectType) {
            return UnderwritingSelector.selectStageRequiredById(recordId);
        }
        if (recordType == Construction_Feasibility_Review__c.SObjectType) {
            return ConstructionFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (recordType == Development_Feasibility_Review__c.SObjectType) {
            return DevelopmentFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (recordType == Contract_Review__c.SObjectType) {
            return ContractReviewSelector.selectStageRequiredById(recordId);
        }
        // Unreachable in practice — configFor() already rejected every unsupported type before this
        // is called. Kept so a new CONFIG_BY_TYPE entry without a matching selector branch fails
        // loudly and immediately instead of returning null.
        throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
    }

    /**
     * Asks the object's configured gate. A gate with no branch here denies — an unwired gate must
     * never read as a grant.
     */
    private static Boolean passesGate(StageActionGate gate) {
        Boolean allowed = false;
        switch on gate {
            when DEAL_DRIVER {
                allowed = OpportunityActionPermissionService.hasDealActionAccess();
            }
            when else {
                allowed = false;
            }
        }
        return allowed;
    }

    private static String noNextStepMessage(StageConfig config, String currentStage) {
        // ⚠ Do NOT name this local `hint` — that identifier is RESERVED in Apex and fails to
        // compile with "Identifier name is reserved: hint" (same trap as `bulk`).
        String specificMessage = NO_NEXT_STEP_HINTS.get(config.label + '|' + currentStage);
        if (String.isNotBlank(specificMessage)) {
            return specificMessage;
        }
        return 'There is no next step available from the ' + currentStage + ' stage.';
    }

    private static String setStage(SObject record, StageConfig config, String target) {
        try {
            record.put(config.stageField, target);
            update record;
            return config.label + ' moved to ' + target + '.';
        } catch (DmlException e) {
            // A validation rule, a required-field rule, or a picklist restriction. Surfacing the
            // platform message verbatim is the POINT of routing these writes through Apex — on the
            // LDS route the rule text lands in body.output.errors[] where the shared guard never
            // reads it, and the rule would ship invisible (design doc §5).
            //
            // ⚠ The getNumDml() guard is load-bearing, not defensive noise. A DmlException with NO
            // row detail is a real shape (MIXED_DML_OPERATION, LIMIT_EXCEEDED); on those,
            // getDmlMessage(0) itself throws, which would escape this catch, land in the
            // controller's GENERIC clause and mask a genuine save block as "refresh the page".
            // StageAdvanceService.setStage calls getDmlMessage(0) unguarded — that is a latent
            // difference, not an oversight here.
            throw new RecordStageAdvanceException(
                e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }
    }
}
