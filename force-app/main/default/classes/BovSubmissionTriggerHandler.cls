/**
 * Trigger handler for BOV_Submission__c. Added 2026-08-19 with the disposition flow redesign
 * (DEV-4).
 *
 * ⚠ CORRECTED 2026-08-20 (BOV broker-contact lookup, design C-2/D-3). This header opened
 * *"ONE context, ONE job"*. That is retracted in place rather than deleted, because the sentence
 * it introduced is still an accurate description of the after-update job below — only the count
 * changed. THERE ARE NOW THREE CONTEXTS AND THREE JOBS (⚠ this line said "TWO JOBS" until
 * 2026-08-20; the single-Selected guard is the third — corrected in place, not deleted, because the
 * retraction above is about the CONTEXT count and stays true):
 *
 *   before insert -> (1) derive `Broker_Firm__c` and `Contact_Name__c` from the `Broker__c` Contact
 *   before update        lookup, via `BovSubmissionBrokerStampService`. See LAYERING below.
 *                    (2) 🔴 REFUSE any save that would leave the parent Disposition with more than
 *                        ONE `Submission_Status__c = 'Selected'` submission, via
 *                        `BovSubmissionSelectionGuardService` (added 2026-08-20, Tranche 2 A2).
 *                        ⚠ SO THE COUNT ABOVE IS NOW THREE CONTEXTS AND **THREE** JOBS. Both before
 *                        jobs are keyed on a CHANGE and both return at zero query cost when it did
 *                        not happen, so an ordinary save still costs nothing.
 *
 *   after update  -> when `Approval_Status__c` becomes 'Approved' on a submission whose
 *                   `Submission_Status__c` is 'Selected', move the PARENT Disposition from
 *                   `BOV Outreach` to `Broker Selection` and stamp `Selected_Broker__c` from the
 *                   submission's `Broker_Firm__c`.
 *
 * This is the on-market half of the broker appointment: `Broker_Finalize_Approval` runs on the
 * SUBMISSION, and its `finalApprovalActions` field update writes `Approval_Status__c`, which
 * re-fires this trigger. Off-market has no BOV round at all and reaches `Broker Selection` straight
 * from `Disposition Readiness` via the Sale Decision approval (see
 * `DispositionApprovalAdvanceService`).
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THE PARENT WRITE IS SYNCHRONOUS HERE AND ASYNC ON `Disposition__c`
 * ══════════════════════════════════════════════════════════════════════════════
 * `Disposition__c` is the entry object of three approval processes, all
 * `recordEditability = AdminOnly`, so a write to a Disposition WHILE ONE OF ITS OWN APPROVALS IS
 * PENDING throws ENTITY_IS_LOCKED — and `AccessLevel.SYSTEM_MODE` does not lift a lock. That is
 * what forced `DispositionApprovalAdvanceQueueable` into existence for the Disposition-target
 * approvals.
 *
 * NONE OF THAT APPLIES TO THIS PATH, AND THE REASON IS THE POINT OF DESIGN DECISION 3:
 *   1. THE LOCKED RECORD IS THE SUBMISSION, NOT THE DISPOSITION. `Broker_Finalize_Approval`'s
 *      entry object is `BOV_Submission__c`. A PARENT of a locked record is not itself locked.
 *   2. NO DISPOSITION APPROVAL CAN BE PENDING AT `BOV Outreach`. Read off the three approval
 *      files: `Sale_Decision_Approval` enters at `Disposition Readiness` (and released its lock
 *      when it completed, `finalApprovalRecordLock = false`), `Broker_Selection_Approval` at
 *      `Broker Selection` AND record type Off Market, `Closing_Approval` at `Closing`. There is no
 *      process whose entry stage is `BOV Outreach`.
 *      ⚠ THAT SECOND CLAUSE IS NEW AS OF THIS REDESIGN AND USED TO BE FALSE:
 *      `Broker_Selection_Approval` DID enter at `BOV Outreach` before 2026-08-19. Anyone reading an
 *      older comment in this repo (they exist, and several are corrected in the same change) will
 *      find the opposite statement. The redesign moved it, which is what makes this synchronous
 *      write available at all.
 * ⇒ So the write is safe synchronously, and a Queueable here would assert a hazard that has been
 *   designed out rather than one that is present. Same shape and same reasoning as
 *   `ContractExecutionService.advanceDispositionsToClosing`.
 *
 * 🔴 AMENDED 2026-08-21. BOTH NUMBERED CLAIMS ABOVE SURVIVE UNCHANGED — NO LOCK APPLIES HERE. What
 * did NOT survive is the unwritten premise underneath them: that "not locked" means "writable".
 * `Disposition__c` is OWD **Private**, this runs as the APPROVER, and the parent is owned by the
 * SUBMITTER — so the write is refused for lack of record-level EDIT with nothing locked at all. That
 * exact failure was MEASURED in production on the sibling path (`DispositionOfferTriggerHandler`,
 * `DISP-0011` / `OFFER-0007`, 2026-08-21: `HasReadAccess = true, HasEditAccess = false` for the
 * approver). ⚠ THIS SITE WAS FIXED ON THE STRENGTH OF THAT MEASUREMENT RATHER THAN ITS OWN INCIDENT
 * REPORT — stated plainly so nobody looks for a `BOV-xxxx` ticket that does not exist. The two
 * handlers are structurally identical on the point that matters (approver-run after-update DML
 * against a Private parent it does not own), and waiting for the second UAT cycle to prove it
 * separately would have been a choice, not a rigour. See `handleApprovedSelections`.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 THE CURRENT-STAGE GUARD IS THE REPLACE-BROKER FEATURE, NOT A SAFETY NET
 * ══════════════════════════════════════════════════════════════════════════════
 * The stage moves ONLY IF the parent is still on `BOV Outreach`. `BovSubmissionService
 * .replaceSelectedBroker` deliberately clears the new submission's `Approval_Status__c` so the
 * replacement broker must be approved afresh — and that approval fires this handler again, on a
 * disposition that has long since moved to `NDA`, `Release Materials` or beyond. Without the guard,
 * approving a replacement broker would DRAG THE SALE BACKWARDS to `Broker Selection`, undoing
 * signed NDAs and released materials. With it, the re-approval does exactly what it should: it
 * re-legitimises the broker and stamps the new name, and the stage does not move.
 *
 * ⚠ THE BROKER STAMP IS UNCONDITIONAL AND THE STAGE MOVE IS NOT. That asymmetry is deliberate:
 * `Selected_Broker__c` must always name the currently approved broker (the Active Listing
 * auto-create copies it onto `Broker_Listing__c.Broker_Firm__c`), whereas the stage is a position
 * in a path that only ever moves forward.
 *
 * ── ⚠ `Selected_Broker__c` HAS A SECOND WRITER SINCE 2026-08-20, AND THE TWO CANNOT COLLIDE ──
 * `DispositionBrokerStampService` stamps the same field on the OFF-MARKET path, in a before-trigger
 * on `Disposition__c`, from the new `Disposition__c.Broker__c` Contact lookup. It cannot fight this
 * handler, and the guarantee is structural rather than a matter of timing: that service fires ONLY
 * when `Broker__c` CHANGES, and nothing in the on-market chain ever touches `Broker__c`. So the
 * parent update below re-enters it and is skipped, leaving the firm string written here intact.
 *
 * 🔴 BUT THE FORMAT NOW DIFFERS BY PATH, AND NOTHING MAY PARSE THIS FIELD. This handler stamps the
 * FIRM alone (`BOV_Submission__c.Broker_Firm__c`); the off-market service stamps `Person - Firm`.
 * One field, two formats, deliberately — the two paths approve two different things (a firm's BOV
 * response vs. a named individual). Treat `Selected_Broker__c` as a DISPLAY STRING ONLY: a parser
 * would work on whichever path its author tested and fail silently on the other. Nothing parses it
 * today; keep it that way.
 *
 * ── ⚠ WHERE `Broker_Firm__c` COMES FROM CHANGED ON 2026-08-20, AND NOTHING HERE CHANGED ──
 * The value this handler copies onto the parent used to be TYPED BY AN ANALYST. It is now DERIVED
 * by `BovSubmissionBrokerStampService` from the submission's new `Broker__c` Contact lookup, in the
 * before contexts of this same trigger. That is deliberately invisible to the code below: the field
 * is still a stored Text(255) on the submission and is still populated by the time `afterUpdate`
 * reads it, so this handler, `BovSubmissionService.replaceSelectedBroker` and every LWC consumer
 * keep working with ZERO change (design §1.3, decision D-d — the change is ADDITIVE; neither Text
 * field is retired). Recorded here only so a reader who finds a firm nobody typed is not surprised.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * ⚠ THIS HANDLER CARRIES ITS OWN LOGIC AND DML RATHER THAN ROUTING TO A SERVICE, which is a
 * DEPARTURE from `DispositionTriggerHandler` / `ContractReviewTriggerHandler` and is stated rather
 * than hidden. The whole behaviour is one detection loop and one bulk update over ONE object, with
 * no cross-object orchestration to own; a `BovApprovalService` holding twelve lines called from
 * exactly one place would add a file without adding a seam. ⚠ THE LIMIT IS EXPLICIT: the moment
 * this needs a second object, a callout, or a caller other than the trigger, it moves to a service.
 * ZERO inline SOQL either way — the parent read goes to `DispositionSelector.selectStagesByIds`.
 * (`BovSubmissionService` DOES exist, and owns the broker REPLACEMENT, which is user-driven
 * cross-object work; that is the line.)
 * ⚠ SHARING: the class is `with sharing` and stays that way. EXACTLY ONE statement escapes it — the
 * parent `Database.update`, in the `private without sharing ParentAdvanceWrites` inner class, whose
 * declaration carries the full justification (ARCHITECTURE.md §2's prescribed shape). The escape is
 * not inherited by anything else in this file.
 *
 * 🔴 THE BEFORE CONTEXTS ROUTE TO A SERVICE, AND THAT IS CONSISTENT WITH THE PARAGRAPH ABOVE
 * RATHER THAN A VIOLATION OF IT (design D-3). The precedent that keeps `handleApprovedSelections`
 * in this file is CONDITIONED on the logic having *"ZERO inline SOQL"* — the sentence is right
 * there, and it is load-bearing. The broker stamp needs a CONTACT SOQL READ, and
 * `.claude/rules/apex-layering-rule.md` prohibits SOQL in a TriggerHandler and in a Domain, so it
 * cannot live here on any reading of the rule. Hence `BovSubmissionBrokerStampService` — a Service
 * calling `ContactSelector`, which is the only conforming home. The two halves of this class now
 * sit on OPPOSITE SIDES of the same stated line, which is what a stated line is for.
 * ⚠ `BovSubmissionSelectionGuardService` (2026-08-20) lands on the SAME side and for the same
 * reason: it needs a SIBLING SOQL READ, which the rule forbids in a handler AND in a domain. It is
 * the second instance of the line, not an exception to it.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Trigger-driven, so `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES and there is no
 * exemption to claim. ⚠ THE BUDGET BELOW WAS WRITTEN FOR THE AFTER-UPDATE JOB ALONE AND IS AMENDED
 * 2026-08-20 RATHER THAN REPLACED, because each job's own budget is unchanged:
 *   afterUpdate  ONE selector query + ONE `Database.update` per chunk (this file).
 *   before*      AT MOST ONE query EACH per chunk, ZERO DML — the broker stamp and the
 *                single-Selected guard, both keyed on a change and both free when it did not occur.
 * Every one of them is CONSTANT in the number of submissions, which is the property the bulk tests
 * assert. A chunk in which no submission changed broker, became Selected, or became
 * Approved-and-Selected costs ZERO queries and ZERO DML in all three.
 *
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (the Disposition-target
 *      approvals, which cannot be synchronous)
 * @see force-app/main/default/classes/BovSubmissionService.cls (the broker replacement)
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (the sibling child
 *      approval — same shape, one extra wrinkle)
 */
public with sharing class BovSubmissionTriggerHandler extends TriggerHandler {

    /** `Approval_Status__c` value written by `Broker_Finalize_Approval`'s finalApprovalActions. */
    @TestVisible
    private static final String APPROVAL_APPROVED = 'Approved';

    /**
     * The `Submission_Status__c` value marking the appointed broker. The picklist is RESTRICTED to
     * {Backup, Selected}, so this is half the value set.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /** The parent stage this handler advances OUT OF, and only out of. See the class header. */
    @TestVisible
    private static final String STAGE_BOV_OUTREACH = 'BOV Outreach';

    /** The parent stage it advances INTO. */
    @TestVisible
    private static final String STAGE_BROKER_SELECTION = 'Broker Selection';

    /**
     * Derives the two broker Text fields on the record being inserted, then refuses the insert if
     * it would give a Disposition a second Selected broker.
     *
     * `oldMap` is passed as NULL rather than as `this.oldMap` — on insert the base class captured
     * `Trigger.oldMap`, which the platform leaves null in that context, and both services' own
     * contracts document null-on-insert as the shape they expect. Passing the field would be
     * equivalent today and would break the moment anyone reused this method from another context.
     *
     * ⚠ ORDER IS NOT LOAD-BEARING AND THE TWO CALLS ARE INDEPENDENT. The guard reads
     * `Submission_Status__c` and `Disposition__c`; the stamp writes `Broker_Firm__c` and
     * `Contact_Name__c`. Neither reads what the other writes. The stamp runs first only so the diff
     * that added the guard is additive.
     */
    protected override void beforeInsert() {
        BovSubmissionBrokerStampService.stampBrokerFields(
            (List<BOV_Submission__c>) newList,
            null
        );
        BovSubmissionSelectionGuardService.enforceSingleSelected(
            (List<BOV_Submission__c>) newList,
            null
        );
    }

    /**
     * Derives the two broker Text fields whenever `Broker__c` changes on an existing submission.
     *
     * ⚠ This fires on EVERY `BOV_Submission__c` update in the org, including the workflow field
     * updates and `BovSubmissionService.replaceSelectedBroker`'s SYSTEM_MODE writes. None of them
     * touch `Broker__c`, so the service skips them at zero query cost — see its class header's
     * writer table, and the tests that pin the free path.
     *
     * 🔴 THE GUARD MUST NOT REFUSE `BovSubmissionService.replaceSelectedBroker`'S OWN SWAP, AND IT
     * DOES NOT — STRUCTURALLY. That service demotes the incumbent and promotes the challenger in ONE
     * bulk `Database.update`, so this context sees BOTH rows and the incumbent's in-memory 'Backup'
     * supersedes its committed 'Selected'. Splitting that service into two DML statements would
     * start being refused here. Read the guard's class header before changing either side.
     */
    protected override void beforeUpdate() {
        BovSubmissionBrokerStampService.stampBrokerFields(
            (List<BOV_Submission__c>) newList,
            (Map<Id, BOV_Submission__c>) oldMap
        );
        BovSubmissionSelectionGuardService.enforceSingleSelected(
            (List<BOV_Submission__c>) newList,
            (Map<Id, BOV_Submission__c>) oldMap
        );
    }

    protected override void afterUpdate() {
        handleApprovedSelections(
            (List<BOV_Submission__c>) newList,
            (Map<Id, BOV_Submission__c>) oldMap
        );
    }

    /**
     * Detects the approvals and applies both parent writes in one DML.
     *
     * ── 🔴 THE DETECTION IS A TRANSITION *AND* A STATE, AND BOTH HALVES ARE NEEDED ──
     * `Approval_Status__c` must have CHANGED to 'Approved' — an unrelated later save on an
     * already-approved submission must not re-stamp the parent — AND `Submission_Status__c` must be
     * 'Selected' NOW. The second test is not redundant with the approval's own entry criteria:
     * `Broker_Finalize_Approval` enters on `Submission_Status__c = 'Selected'`, but nothing stops a
     * submission being demoted to `Backup` between submission and approval (that is exactly what
     * `replaceSelectedBroker` does), and appointing a broker the business has since replaced is the
     * one outcome this handler must never produce.
     *
     * ── LAST-WRITER-WINS ON A CONTRIVED CHUNK, STATED HONESTLY ──────────────
     * If two submissions on the SAME disposition became Approved-and-Selected in one chunk, the map
     * keeps the last one. That state is already broken upstream (only one submission may be
     * Selected — `BovSubmissionService` enforces exclusivity in a single DML) and no ordering choice
     * here repairs it; picking deterministically and moving on beats a partial write or a throw
     * that would roll back the approval.
     *
     * @param submissions Trigger.new
     * @param priorById   Trigger.oldMap
     */
    private void handleApprovedSelections(
        List<BOV_Submission__c> submissions,
        Map<Id, BOV_Submission__c> priorById
    ) {
        Map<Id, String> brokerByDisposition = new Map<Id, String>();
        for (BOV_Submission__c submission : submissions) {
            if (submission.Disposition__c == null) {
                continue;
            }
            if (!APPROVAL_APPROVED.equals(submission.Approval_Status__c)) {
                continue;
            }
            BOV_Submission__c prior = (priorById == null) ? null : priorById.get(submission.Id);
            if (prior != null && APPROVAL_APPROVED.equals(prior.Approval_Status__c)) {
                continue; // already approved before this save — not a transition
            }
            if (!STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                continue; // approved, but no longer the appointed broker
            }
            brokerByDisposition.put(submission.Disposition__c, submission.Broker_Firm__c);
        }
        if (brokerByDisposition.isEmpty()) {
            return;
        }

        // ONE query for the whole chunk — never one per record. It answers only the idempotency
        // question: is this parent still on BOV Outreach?
        List<Disposition__c> parentUpdates = new List<Disposition__c>();
        for (Disposition__c parent
                : DispositionSelector.selectStagesByIds(brokerByDisposition.keySet())) {
            Disposition__c stamp = new Disposition__c(
                Id = parent.Id,
                Selected_Broker__c = brokerByDisposition.get(parent.Id)
            );
            if (STAGE_BOV_OUTREACH.equals(parent.Disposition_Stage__c)) {
                stamp.Disposition_Stage__c = STAGE_BROKER_SELECTION;
            }
            parentUpdates.add(stamp);
        }
        if (parentUpdates.isEmpty()) {
            return;
        }

        // ── THREE SEPARATE DECISIONS ON ONE STATEMENT. NONE COVERS ANOTHER'S OBSTACLE. ──
        // SYSTEM_MODE: this runs as the APPROVER, a read-only persona on `Disposition__c`; CRUD and
        //   FLS would refuse the write outright. It does NOT bypass validation rules, which is
        //   correct — the NDA gate and the wire backstop must still evaluate.
        // without sharing: ⚠ ADDED 2026-08-21 AND NOT INTERCHANGEABLE WITH THE LINE ABOVE. CRUD/FLS
        //   and RECORD-LEVEL access are two different refusals; SYSTEM_MODE lifts the first only.
        //   See `ParentAdvanceWrites` below for who runs this and why they lack the second.
        // allOrNone = false: an all-or-none failure would roll back THE APPROVAL ITSELF — the
        //   submission's own `Approved` status — to protect a stage advance. The approval is the
        //   irreplaceable half; the stage is derivable.
        //
        // 🔴 THE RESIDUAL IS REAL AND IS NOT HARMLESS, SO IT IS NAMED: the submission reads
        // Approved while the disposition still sits at `BOV Outreach` with no Selected Broker. What
        // makes it ACCEPTABLE is that it is VISIBLE — both records are on the same page, they
        // disagree, and a user can advance by hand once the block clears. Identical trade, identical
        // wording, to `ContractExecutionService.advanceDispositionsToClosing`.
        // ⚠ THE CLAUSE THAT USED TO END THIS PARAGRAPH — *"the results are deliberately NOT inspected
        // because there is no recovery action available inside an after-update trigger"* — IS
        // RETRACTED IN PLACE 2026-08-21. Its premise is still true (there IS no recovery action, and
        // nothing below rethrows or retries) but its CONCLUSION did not follow: "cannot recover" is
        // not "must not report". Un-inspected results are what let the sibling handler's identical
        // statement fail in production and look exactly like success. Now inspected — see
        // `recordParentWriteFailures`.
        recordParentWriteFailures(
            new ParentAdvanceWrites().apply(parentUpdates),
            parentUpdates
        );
    }

    /**
     * Every parent-write failure from the most recent `handleApprovedSelections` call, as
     * `<dispositionId> -> <STATUS_CODE> | <message>`. Empty on a clean run and reset at the top of
     * every `recordParentWriteFailures` call, so it describes ONE trigger chunk and not a session.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON. `BovSubmissionTriggerHandlerTest`'s non-owner approver test
     * asserts it is EMPTY, which is what makes a removed sharing escape fail with the actual
     * `StatusCode` rather than with an opaque "expected Broker Selection, was BOV Outreach".
     */
    @TestVisible
    private static List<String> lastRunParentWriteFailures = new List<String>();

    /**
     * Sends every refused row to the debug log at ERROR and to `lastRunParentWriteFailures`.
     *
     * Report, never recovery: nothing here rethrows or retries, because both would roll back the
     * approval this code is riding on. Shape copied from `DealFolderService.stampAll`; twin of
     * `DispositionOfferTriggerHandler.recordParentWriteFailures`.
     *
     * @param results   Parallel to `attempted`, in input order; never null.
     * @param attempted The rows handed to the DML, used only for their Ids.
     */
    private void recordParentWriteFailures(
        List<Database.SaveResult> results,
        List<Disposition__c> attempted
    ) {
        lastRunParentWriteFailures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<Database.Error> errors = results[i].getErrors();
            String detail = errors.isEmpty()
                ? 'no error detail returned'
                : errors[0].getStatusCode() + ' | ' + errors[0].getMessage();
            lastRunParentWriteFailures.add(attempted[i].Id + ' -> ' + detail);
            // NOT debug output — this is the failure channel; see lastRunParentWriteFailures.
            // `allOrNone = false` means a refused parent write throws nothing, so removing this
            // line restores the silent no-op this handler exists to close. A lint pass will flag
            // it; leave it.
            System.debug(LoggingLevel.ERROR,
                'BovSubmissionTriggerHandler.handleApprovedSelections: LOST BROKER APPOINTMENT on '
                + 'Disposition__c ' + attempted[i].Id + ' -> ' + detail
                + ' | the submission is Approved and its sale did NOT move to Broker Selection or '
                + 'take a Selected Broker. Running user: ' + UserInfo.getUserId() + '.');
        }
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT THAT ESCAPES SHARING, AND WHY IT HAS TO. ADDED 2026-08-21.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: the APPROVER of `Broker_Finalize_Approval`. This handler's after-update
     * context is reached by that approval's `finalApprovalActions` field update writing
     * `Approval_Status__c` on the SUBMISSION, so the running user is whoever clicked Approve.
     *
     * WHY THEY PREDICTABLY LACK RECORD-LEVEL EDIT ON THE TARGET — three composing facts:
     *   1. `Disposition__c` is OWD **Private** (`InternalSharingModel = Private`, measured via
     *      Tooling `EntityDefinition` 2026-08-21).
     *   2. The parent is owned by whoever created the sale, not by the approver. The object's only
     *      Edit-granting sharing rule is `Disposition_Team_RW` (Acquisitions_Analyst + subordinates
     *      -> `DPEG_Acquisitions_Team`), which an approving Principal is outside of.
     *   3. `DPEG_Disposition_View`, the set the Principal persona carries, grants
     *      `viewAllRecords = true` and NO `modifyAllRecords`. THAT COMBINATION IS THE TRAP: the
     *      idempotency read above returns the row (read access exists) and the write is then refused
     *      (edit access does not). A read that succeeds is not evidence a write will.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` WAS NOT SUFFICIENT AND COULD NEVER HAVE BEEN — and the comment at
     * the call site above shows the author believed otherwise, because it justifies SYSTEM_MODE by
     * naming the approver's read-only persona. Per ARCHITECTURE.md §2: *"🔴 `SYSTEM_MODE` bypasses
     * CRUD/FLS ONLY — it does NOT bypass sharing."* SYSTEM_MODE removes the OBJECT-level refusal and
     * leaves the RECORD-level one standing, which is why the sibling defect presented as a silent
     * no-op rather than a `TypeException`: the write reached a `SaveResult` and nobody read it.
     *
     * WHY THE ESCAPE IS BOUNDED TO THIS ONE WRITE: this class stays `with sharing`, the selector
     * stays `with sharing`, and this inner class holds ONE statement over a list the CALLER built.
     * It cannot query, cannot choose rows and cannot widen — every Id in `parentUpdates` came back
     * from a `with sharing` selector read, so a disposition the approver cannot SEE is still never
     * written. ARCHITECTURE.md §2 prescribes this exact shape; repo precedents are
     * `DispositionOfferSelector.TractionReads` (read) and `NdaExpiryAlertBatch.stampMarkers` (write).
     *
     * ⚠ DO NOT PROMOTE THIS TO THE OUTER CLASS. `BovSubmissionBrokerStampService` and
     * `BovSubmissionSelectionGuardService` are deliberately sharing-scoped and argue for it in their
     * own headers; `without sharing` on the handler would silently re-authorise both.
     */
    private without sharing class ParentAdvanceWrites {
        /**
         * @param parentUpdates Disposition shells built by `handleApprovedSelections` from rows a
         *                      `with sharing` selector returned; never null, never empty.
         * @return One `Database.SaveResult` per row, in input order. The caller inspects them.
         */
        private List<Database.SaveResult> apply(List<Disposition__c> parentUpdates) {
            return Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
