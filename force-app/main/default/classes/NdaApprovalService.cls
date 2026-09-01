/**
 * Submits a DISPOSITION NDA into the `NDA_Issue_Approval` approval process. Backs
 * `DispositionApprovalController.submitNdaForApproval` -> `c/ndaSubmitForApproval` ->
 * `quickActions/NDA__c.Submit_NDA_Approval`. Built 2026-08-31 (Tranche 3 item 2d, design D-9).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A SUBMIT ROUTE HAD TO BE BUILT AT ALL, RATHER THAN USING THE PLATFORM'S OWN BUTTON
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * `flexipages/NDA_Record_Page` carries `enableActionsConfiguration = true`. Turning Dynamic Actions
 * on DISCARDS the page's inherited `platformActionList` entirely (measured on this project), so the
 * generic "Submit for Approval" button is not on that page and cannot be inherited onto it. Every
 * action there is enumerated explicitly.
 * ⚠ AND EVEN IF IT WERE INHERITED, DESIGN D-9 REJECTED IT. The platform button routes around every
 * pre-check below and surfaces an unmet entry criterion as *"no applicable approval process was
 * found"* — a sentence that names nothing the user can act on. The whole value of this class is
 * that it refuses in words: which status is required, and which one the record is actually at.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT SUBMITS WITH `setObjectId` ALONE — NO `setProcessDefinitionNameOrId` — AND THAT IS A RULE
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The one-argument form lets the PLATFORM pick the process by evaluating entry criteria, exactly as
 * all five sibling approvals are submitted (`DispositionApprovalService.submit`). Naming the process
 * explicitly would put a SECOND copy of the entry criteria in Apex — one in
 * `approvalProcesses/NDA__c.NDA_Issue_Approval` and one here — and the two would drift the first
 * time a criterion changed in Setup. There is no `setProcessDefinitionNameOrId` anywhere in this
 * repo and there must not be one now.
 * ⚠ THE CONSEQUENCE, STATED: THIS CLASS CANNOT GUARANTEE **WHICH** PROCESS ACCEPTED THE RECORD. The
 * pre-checks below mirror the entry criteria closely enough that a mismatch is the interesting
 * signal, not a silent wrong answer — if `NDA_Issue_Approval` is not deployed, `Approval.process`
 * throws and the user is told the submission failed, rather than being told it succeeded.
 *
 * ── THE PRE-CHECK TABLE, AND WHY EACH ONE EARNS ITS PLACE ─────────────────────────────────────
 *   1. `DispositionActionPermissionService.assertDispositionActionAccess()` — FIRST STATEMENT.
 *      🔴 DO NOT MODIFY THAT CLASS. Its header states *"THE TWO CLASSES ARE ONE DESIGN ON TWO
 *      MODULES — CHANGE BOTH OR NEITHER"* against its `OpportunityActionPermissionService` twin.
 *      Call it; do not touch it. It is the same `Disposition_Deal_Actions` gate the retired
 *      `Move_to_Approved` quick action answered to, so this route is held by exactly the persona
 *      that route was — no authorization was widened or narrowed by moving the transition behind
 *      an approval; only WHO DECIDES changed, from the analyst to the principal.
 *   2. null Id — an authored refusal rather than a null dereference three lines later.
 *   3. RECORD TYPE must be `Disposition_NDA`. Mirrors the process's second entry criterion
 *      (`Is_Disposition_NDA__c = True`). ⚠ IT IS RESOLVED FROM `RecordTypeId` THROUGH A DESCRIBE,
 *      NOT BY READING `Is_Disposition_NDA__c`: that field is a FORMULA whose value in an in-memory
 *      row is not a guarantee this code should lean on, and `RecordTypeId` is a standard system
 *      field with no FLS surface, so it cannot be denied to a persona. Same argument
 *      `DispositionStageEntryService.ON_MARKET_RECORD_TYPE` makes against `Is_On_Market__c`.
 *      🔴 IT FAILS **CLOSED** on a Master / unset / unresolvable record type — the same polarity as
 *      the formula the entry criterion reads, which is BLANK (false) on a Master row. A
 *      disposition-only gate that failed open would offer the button on an acquisition NDA and then
 *      hand the user the platform's opaque refusal.
 *   4. STATUS must be `Prepare`. Mirrors the first entry criterion. ⚠ THIS IS ALSO THE HOP THAT WAS
 *      RETIRED FROM `RecordStageAdvanceService.NDA_DISPOSITION_NEXT_STAGE` on the same day
 *      (decision D-7): `'Prepare' => 'Approved'` was a one-click bypass of this very approval, held
 *      by the ANALYST persona. This method is its replacement, and the two must not both exist.
 *   5. NO PENDING INSTANCE. `Approval.process` on an already-pending record throws a platform
 *      exception whose text is not something to show a user; `ProcessInstanceSelector
 *      .selectPendingByTargetId` lets this refuse in a sentence instead. ⚠ IT IS NOT A LOCK — two
 *      simultaneous clicks could still both pass this check; the platform is the real backstop and
 *      its refusal is caught by the controller. This exists for the message, not for the race.
 *
 * ── ⚠ WHAT SUBMITTING DOES TO THE RECORD, WHICH THE USER MUST BE WARNED ABOUT ────────────────
 * `NDA_Issue_Approval` sets `recordEditability = AdminOnly`, so a submitted NDA LOCKS. `allowRecall`
 * is true, and Recall is reachable ONLY from the approval-history related list that
 * `NDA_Record_Page` and `NDA__c-NDA Layout` gained in this same wave — two files, neither of which
 * works alone. 🔴 THIS COMPONENT MUST NEVER BE THE ONLY ROUTE BACK, and it deliberately offers no
 * recall of its own: a Recall affordance here would be a second, weaker copy of the one the
 * platform already renders with the correct permissions attached.
 * ⚠ AND `Mark Declined` STILL RENDERS DURING THE PENDING WINDOW and will throw `ENTITY_IS_LOCKED`
 * if clicked. That is a KNOWN, ACCEPTED and NOISY refusal (decision D-10 declined the
 * `Approval_Pending__c` flag and the four-action clear pattern that would hide it). It is named
 * here so the first person to hit it does not read it as a defect in this class.
 *
 * ── ⚠ `allowedSubmitters = owner` ────────────────────────────────────────────────────────────
 * Disposition NDAs are auto-created by `DispositionStageEntryService`, so the OWNER is whoever
 * advanced the Disposition into the NDA stage — not necessarily whoever is now working the deal. A
 * different analyst holding `Disposition_Deal_Actions` passes every check in this class and is then
 * refused by the PLATFORM at `Approval.process`. That is consistent with all five sibling approvals
 * and is accepted; it is recorded here because this class's authored refusals stop at the platform
 * boundary and that one arrives in the platform's own words.
 *
 * ── LAYERING ──────────────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO SOQL of its own — two selector calls. The one
 * write is `Approval.process`, which is not DML and needs no Unit of Work.
 *
 * @see force-app/main/default/classes/DispositionApprovalController.cls (the `@AuraEnabled` boundary)
 * @see force-app/main/default/classes/DispositionApprovalService.cls (the shape this copies)
 * @see force-app/main/default/lwc/ndaSubmitForApproval/ndaSubmitForApproval.js
 * @see force-app/main/default/approvalProcesses/NDA__c.NDA_Issue_Approval.approvalProcess-meta.xml
 */
public with sharing class NdaApprovalService {

    /**
     * A user-actionable refusal. The controller surfaces its message VERBATIM — that is the whole
     * point of pre-checking here rather than letting `Approval.process` answer.
     * ⚠ Deliberately a SEPARATE type from `DispositionApprovalService.ApprovalException` rather
     * than a reuse: the controller catches them in two different methods and a shared type would
     * let a refusal authored for one object surface on the other's button.
     */
    public class ApprovalException extends Exception {}

    /**
     * The record type this approval — and this button — exist for.
     * ⚠ CASE MUST MATCH `objects/NDA__c/recordTypes/` EXACTLY. It is compared against
     * `getRecordTypeInfosById()`'s developer name, which is case-sensitive; a mis-cased literal
     * matches nothing and refuses every NDA, which at least fails loudly and closed.
     */
    @TestVisible
    private static final String RT_DISPOSITION_NDA = 'Disposition_NDA';

    /**
     * The only status the approval accepts, mirroring `NDA_Issue_Approval`'s first entry criterion
     * and `DispositionStageEntryService.DISPOSITION_NDA_INITIAL_STATUS` — the value every
     * auto-created disposition NDA is seeded at.
     */
    @TestVisible
    private static final String STATUS_PREPARE = 'Prepare';

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';

    private static final String NOT_DISPOSITION_NDA_MESSAGE =
        'Only a disposition NDA can be submitted for the NDA Issue approval.';

    private static final String ALREADY_PENDING_MESSAGE =
        'This NDA is already pending approval.';

    /**
     * ⚠ IT NAMES WHICH APPROVAL, unlike a generic "submitted" toast. The user has just pressed a
     * button labelled only "Submit for Approval"; telling them what it was submitted FOR is what
     * lets them confirm they pressed the right thing on a record page carrying four other actions.
     */
    private static final String SUBMITTED_MESSAGE =
        'The NDA has been submitted for the NDA Issue approval.';

    /**
     * Submits one disposition NDA into `NDA_Issue_Approval`.
     *
     * @param ndaId The NDA__c the quick action was launched from.
     * @return An authored confirmation naming the approval.
     * @throws DispositionActionPermissionService.AccessDeniedException when the running user does
     *         not hold `Disposition_Deal_Actions` (or Modify All Data).
     * @throws ApprovalException when the Id is null, the record is not a disposition NDA, its
     *         status is not `Prepare`, or an approval is already pending. Every message is authored
     *         to be shown to the user.
     * @throws System.QueryException when `ndaId` matches no visible NDA — a wiring or sharing
     *         fault rather than a user-correctable state, masked by the controller as a generic
     *         failure. Same contract as `RecordStageAdvanceService.advance`.
     */
    public static String submitForApproval(Id ndaId) {
        // FIRST STATEMENT, ALWAYS. Every refusal below leaks information about the record
        // (its status, its record type), so authorization has to be settled before any of them can
        // be reached.
        DispositionActionPermissionService.assertDispositionActionAccess();

        if (ndaId == null) {
            throw new ApprovalException(NO_RECORD_MESSAGE);
        }

        NDA__c nda = NdaSelector.selectStageRequiredById(ndaId);

        if (!RT_DISPOSITION_NDA.equals(recordTypeNameOf(nda))) {
            throw new ApprovalException(NOT_DISPOSITION_NDA_MESSAGE);
        }
        if (!STATUS_PREPARE.equals(nda.Status__c)) {
            throw new ApprovalException(wrongStatusMessage(nda.Status__c));
        }
        if (!ProcessInstanceSelector.selectPendingByTargetId(ndaId).isEmpty()) {
            throw new ApprovalException(ALREADY_PENDING_MESSAGE);
        }

        // ONE ARGUMENT. The platform matches the entry criteria — see the class header for why
        // naming the process here would be a second copy of them.
        Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
        request.setObjectId(ndaId);
        Approval.process(request);

        return SUBMITTED_MESSAGE;
    }

    /**
     * The record type developer name of a LOADED NDA, or null for a Master / unset / unresolvable
     * row.
     *
     * A DESCRIBE, not a query — `getRecordTypeInfosById()` is a platform-held map, so this costs no
     * SOQL.
     *
     * ⚠ IT RETURNS **NULL** FOR MASTER, NOT A DEFAULT, WHICH IS THE OPPOSITE OF
     * `DispositionDomain.recordTypeNameOf` AND IS DELIBERATE. That helper defaults a Master
     * Disposition to `On_Market` because every consumer there must agree on ONE answer for a
     * branch that has to be taken. Here there is no branch to take: the only question is "is this
     * the disposition record type?", and a Master row is not. Defaulting would answer YES for a row
     * that has no record type at all, offering a disposition approval on an untyped NDA.
     * 🔴 DO NOT "HARMONISE" THIS WITH `DispositionDomain`. Two different questions; the shared
     * helper is typed to `Disposition__c` and could not be called here anyway.
     *
     * @param nda An NDA whose SELECT included `RecordTypeId`. Null-safe.
     * @return The developer name, or null.
     */
    private static String recordTypeNameOf(NDA__c nda) {
        if (nda == null || nda.RecordTypeId == null) {
            return null;
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosById()
            .get(nda.RecordTypeId);
        return (info == null || info.isMaster()) ? null : info.getDeveloperName();
    }

    /**
     * Wording for a Submit click at the wrong status. It NAMES the required status AND the actual
     * one, so the refusal reads as a rule rather than as a defect — the same choice
     * `RecordStageAdvanceService.NO_NEXT_STEP_HINTS` and
     * `DispositionApprovalService.noApprovalAtStageMessage` both make.
     *
     * ⚠ A BLANK STATUS GETS ITS OWN CLAUSE. `NDA__c.Status__c` has NO record-type default on
     * `Disposition_NDA` (the user cleared it on 2026-08-25), so a UI-created NDA arrives BLANK and
     * this is a reachable state, not a defensive branch. "This NDA is at ." would read as a
     * rendering bug.
     *
     * @param actual The record's current status, possibly blank.
     * @return The refusal message.
     */
    private static String wrongStatusMessage(String actual) {
        String base = 'An NDA can only be submitted for the NDA Issue approval from the '
            + STATUS_PREPARE + ' status. ';
        return String.isBlank(actual)
            ? base + 'This NDA has no status set.'
            : base + 'This NDA is at ' + actual + '.';
    }
}
