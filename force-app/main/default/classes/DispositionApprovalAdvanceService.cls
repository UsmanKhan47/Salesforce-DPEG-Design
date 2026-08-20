/**
 * Moves a Disposition to its next stage AFTER one of the three Disposition-target approvals is
 * approved — the server half of design decision D-1, added 2026-08-19 with the flow redesign
 * (DEV-3).
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS SHAPE. THREE MECHANISMS WERE AVAILABLE AND TWO ARE FORBIDDEN.
 * ══════════════════════════════════════════════════════════════════════════════
 * The requirement is "approving the Sale Decision moves the disposition to BOV Outreach (on-market)
 * or Broker Selection (off-market)". The obvious implementations are both wrong, and each is wrong
 * for a reason this org has already paid for once:
 *
 *   (a) A DIRECT `finalApprovalActions` FIELD UPDATE ON `Disposition_Stage__c` — REJECTED.
 *       A workflow field update writes the field and DOES NOT EVALUATE VALIDATION RULES on the
 *       same save the way a user edit does; the redesigned
 *       `All_NDAs_Signed_Before_Progression` gate and the wire backstop would both be bypassed by
 *       the one actor most able to do damage with them. That reasoning is already recorded in the
 *       existing approval XMLs and in `Wire_Complete_Before_Completed`'s own comment; this class
 *       exists so it can stay true.
 *
 *   (b) AN APPROVAL-TRIGGERED FLOW — REJECTED, AND IT IS A MEASURED ORG INCIDENT, NOT A THEORY.
 *       A record-triggered flow with no `<runInMode>` runs in USER CONTEXT — as the APPROVER. A
 *       principal approver is a read-only persona on `Disposition__c`, so its DML fails on CRUD
 *       with a `TypeException` that escapes a `DmlException`-only fault path AND ROLLS BACK THE
 *       APPROVAL ITSELF. The approver clicks Approve and is told the approval failed.
 *
 *   (c) A SEMAPHORE + TRIGGER + QUEUEABLE — CHOSEN, and the only one that clears all three
 *       obstacles at once:
 *         • the approval's `finalApprovalActions` writes ONLY the boolean
 *           `Approval_Advance_Pending__c`, a field with NO FLS for anyone and no rule attached;
 *         • that write re-fires `DispositionTrigger`, whose after-update handler detects
 *           false -> true and enqueues `DispositionApprovalAdvanceQueueable`;
 *         • the Queueable writes the stage with ORDINARY `Database.update(..., SYSTEM_MODE)`, so
 *           VALIDATION RULES STILL EVALUATE (SYSTEM_MODE lifts CRUD and FLS and NEVER a rule), the
 *           approver's own CRUD is irrelevant, and — the third obstacle — the
 *           `recordEditability = AdminOnly` APPROVAL LOCK has definitively released, because
 *           `finalApprovalRecordLock = false` releases it when the approving transaction COMMITS,
 *           which is exactly when a Queueable runs.
 *
 * 🔴 THE THIRD BULLET IS THE ONE THAT MAKES THE ASYNC HOP NON-NEGOTIABLE, AND IT IS THE OPPOSITE OF
 * THE `DispositionNdaStampQueueable` CASE. There, review D20/W1 established that a Queueable does
 * NOT fix the lock, because the triggering transaction was NOT the one releasing the approval, so a
 * pending approval OUTLIVED the job. Here the triggering transaction IS the final approval — it is
 * the transaction that releases the lock — so the job runs into an unlocked record. Same mechanism,
 * opposite conclusion, and the difference is WHO releases the lock. Do not transplant either
 * verdict onto the other.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 A REFUSAL LEAVES THE SEMAPHORE TRUE. THAT IS THE DESIGN, NOT A LEAK.
 * ══════════════════════════════════════════════════════════════════════════════
 * The stage write and the semaphore clear are ONE `Database.update`. So any refusal — a validation
 * rule, a row the principal cannot see, an unmapped stage, an exhausted queueable budget — leaves
 * `Approval_Advance_Pending__c = true` and the stage where it was. That state is VISIBLE (an admin
 * can list every disposition with the flag set), RECOVERABLE (clear the blocker and re-set the
 * flag) and HONEST. The alternative — clearing the flag on a write that did not happen — produces
 * a disposition that has been approved, has not advanced, and looks completely normal. Silence is
 * the failure mode this module keeps paying for; see
 * `ContractExecutionService.advanceDispositionsToClosing`'s identical trade.
 *
 * ⚠ SO DO NOT "TIDY" THE CLEAR INTO ITS OWN DML. Splitting them would let the flag be cleared while
 * the stage write failed, which is precisely the invisible state above.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * LAYERING / TESTABILITY
 * ══════════════════════════════════════════════════════════════════════════════
 * Service (ARCHITECTURE.md §2). ZERO inline SOQL — the re-read goes to
 * `DispositionSelector.selectStageAndTypeByIds`.
 *
 * ⚠ THE MAPPING AND THE WRITE LIVE HERE, NOT IN THE QUEUEABLE, AND THAT IS DELIBERATE. The
 * Queueable is a five-line async shell that calls `advance()`. Putting the stage map inside the
 * Queueable (which is where the design sketch put it) would make every assertion about the map
 * require an async execution to reach — `Test.startTest()`/`stopTest()` around every case, and no
 * way at all to assert the unmapped-pair behaviour without contriving an approval. Here the map is
 * directly callable and directly falsifiable. `DispositionNdaStampQueueable` holds its own DML
 * because that DML is one statement with no branches; this one has a five-entry decision table.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * TRIGGER-DRIVEN, so the `.claude/rules/bulk-test-rule.md` 251-record mandate DOES apply and there
 * is no exemption to claim. Budget is ONE selector query, ONE `Database.update` and AT MOST ONE
 * enqueue per trigger chunk — CONSTANT in the number of dispositions, which is the property the
 * bulk test should assert rather than merely that 251 rows produced 251 advances. A chunk in which
 * no row's semaphore went false -> true — the overwhelmingly common Disposition save — costs zero
 * queries, zero DML and zero enqueues.
 *
 * @see force-app/main/default/classes/DispositionApprovalAdvanceQueueable.cls (the async shell)
 * @see force-app/main/default/classes/DispositionTriggerHandler.cls (the detection hook)
 * @see force-app/main/default/classes/DispositionApprovalService.cls (what SUBMITS the approvals)
 */
public with sharing class DispositionApprovalAdvanceService {

    /**
     * Record type developer names — ALIASES of the canonical pair on `DispositionDomain`, not
     * literals (code review C-2, 2026-08-19). Case must match objects/Disposition__c/recordTypes/
     * exactly: they are half of every key in ADVANCE_TARGET below, and Apex Map<String, …> keys are
     * case-SENSITIVE, so a mis-cased constant would silently map nothing and strand every
     * semaphore at true. Deriving from one source is what makes that unexpressible here.
     */
    @TestVisible
    private static final String RT_ON_MARKET = DispositionDomain.RT_ON_MARKET;
    @TestVisible
    private static final String RT_OFF_MARKET = DispositionDomain.RT_OFF_MARKET;

    /**
     * `<recordTypeDeveloperName>|<currentStage>` -> the stage an APPROVAL moves it to.
     *
     * 🔴 IT IS KEYED ON BOTH BECAUSE ONE APPROVAL HAS TWO DIFFERENT TARGETS. `Sale_Decision_Approval`
     * fires at `Disposition Readiness` on BOTH record types and must land an on-market sale on
     * `BOV Outreach` (go get broker opinions) and an off-market one on `Broker Selection` (the
     * broker is picked directly — there is no BOV round). A stage-only map cannot express that, and
     * a record-type-only map cannot express `Closing`.
     *
     * 🔴 THE ABSENT ENTRY IS AS LOAD-BEARING AS THE PRESENT ONES:
     *   'On_Market|Broker Selection' IS DELIBERATELY MISSING. On-market reaches `NDA` through the
     *   Advance to NDA quick action, a MANUAL hop owned by `RecordStageAdvanceService`; only the
     *   off-market path gets there by approval (`Broker_Selection_Approval`'s entry criteria are
     *   `Broker Selection` AND record type Off Market). Adding it would let an approval that cannot
     *   fire on that record type move it anyway, the moment anything else set the semaphore.
     *
     * ⚠ THE OTHER TWO DISPOSITION-TARGET TRANSITIONS ARE NOT HERE AND MUST NOT BE ADDED:
     *   `BOV Outreach -> Broker Selection` belongs to `BovSubmissionTriggerHandler` — that approval
     *       runs on the `BOV_Submission__c`, so no Disposition semaphore is ever set for it.
     *   `Offer Selection -> LOI` belongs to `DispositionOfferTriggerHandler`, for the same reason.
     *   Both child approvals update the parent SYNCHRONOUSLY, because the parent is not the locked
     *   record. Duplicating them here would advance the stage twice.
     *
     * ⚠ AN UNMAPPED PAIR IS NOT AN ERROR AND IS NOT SILENTLY CLEARED — the row is simply left
     * alone, semaphore and all. See the class header: a stuck flag is the visible, recoverable
     * outcome, and it is exactly what an approval firing at an unexpected stage SHOULD produce.
     */
    @TestVisible
    private static final Map<String, String> ADVANCE_TARGET = new Map<String, String>{
        RT_ON_MARKET + '|Disposition Readiness' => 'BOV Outreach',
        RT_OFF_MARKET + '|Disposition Readiness' => 'Broker Selection',
        RT_OFF_MARKET + '|Broker Selection' => 'NDA',
        RT_ON_MARKET + '|Closing' => 'Sale Closes',
        RT_OFF_MARKET + '|Closing' => 'Sale Closes'
    };

    /**
     * AFTER INSERT / AFTER UPDATE. Detects `Approval_Advance_Pending__c` going false -> true and
     * enqueues the advance for those rows.
     *
     * ── 🔴 THE TRANSITION, NOT THE VALUE ─────────────────────────────────────
     * A row that ALREADY had the flag true and is saved again for any other reason must not
     * re-enqueue: the previous advance either succeeded (and cleared it) or refused (and the flag
     * is a stuck marker awaiting a human), and re-running it on every unrelated save would turn one
     * stuck record into an enqueue on every edit. `prior == null` on insert, so a row CREATED with
     * the flag already true does count as a transition — a data load can legitimately arrive that
     * way, and treating it as one costs nothing.
     *
     * ── 🔴 THE QUEUEABLE-BUDGET GUARD, AND ITS DOCUMENTED RESIDUAL ───────────
     * Copied deliberately from `DispositionStageEntryService.openBuyerNdas`, including its residual.
     * This trigger can fire inside an async context that has already spent its chained-job budget
     * (the async cap is 1), and an uncaught `LimitException` here would roll back THE APPROVAL it
     * is riding on — the approver would be told their approval failed.
     *
     * ⚠ RESIDUAL, STATED RATHER THAN HIDDEN: when the budget IS exhausted the advance is SKIPPED
     * and `Approval_Advance_Pending__c` stays true. That is the same visible, recoverable state
     * every other refusal on this path produces (class header), and it is the correct trade — the
     * approval itself is the irreplaceable half, the stage is derivable. It is also risk 8 in the
     * redesign's own register, accepted there.
     *
     * @param newDispositions Trigger.new
     * @param oldMap          Trigger.oldMap on update; null on insert
     */
    public static void enqueuePendingAdvances(
        List<Disposition__c> newDispositions,
        Map<Id, Disposition__c> oldMap
    ) {
        if (newDispositions == null || newDispositions.isEmpty()) {
            return;
        }
        Set<Id> pending = new Set<Id>();
        for (Disposition__c d : newDispositions) {
            if (d.Approval_Advance_Pending__c != true) {
                continue;
            }
            Disposition__c prior = (oldMap == null) ? null : oldMap.get(d.Id);
            if (prior != null && prior.Approval_Advance_Pending__c == true) {
                continue; // already true before this save — not a transition
            }
            pending.add(d.Id);
        }
        if (pending.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DispositionApprovalAdvanceQueueable(pending));
        }
    }

    /**
     * Re-reads the dispositions and writes each one's approval-derived next stage, clearing the
     * semaphore in the SAME statement.
     *
     * ⚠ IT RE-READS RATHER THAN TRUSTING `Trigger.new`. Two reasons, and the second is the real one:
     *   1. the Queueable carries only Ids across the async boundary (an SObject snapshot would be
     *      stale by construction);
     *   2. 🔴 THE STAGE MAY HAVE MOVED BETWEEN THE APPROVAL AND THIS JOB. Reading it fresh means
     *      an already-advanced row finds no mapping for its NEW stage and is left alone, rather
     *      than being pushed a second hop by a semaphore set for the first.
     *
     * ⚠ A ROW ABSENT FROM THE RE-READ (deleted, or invisible to the principal running the job under
     * `with sharing`) IS SKIPPED. The write is driven by what came BACK, never by what went in, so
     * an unreadable row cannot be written wrongly — it just keeps its flag. See the selector.
     *
     * ── allOrNone = false, SYSTEM_MODE, AND NEITHER COVERS THE OTHER'S OBSTACLE ──
     * SYSTEM_MODE: this runs as the APPROVER, a read-only persona on `Disposition__c` — CRUD and
     * FLS would refuse the write outright. It does NOT bypass validation rules, which is the whole
     * point of choosing DML over a field update (class header, option (a)).
     * allOrNone = false: one blocked disposition must not roll back the advance of the other 250 in
     * the chunk. The results are deliberately NOT inspected — there is no recovery action available
     * in an async job, and the residual is visible ON THE RECORD as a stuck semaphore, which is
     * strictly more useful than a log line nobody reads.
     *
     * Bulk-safe and CONSTANT in the number of dispositions: ONE query, ONE `Database.update`, no
     * SOQL or DML in a loop.
     *
     * @param dispositionIds the rows whose semaphore just went true; null/empty-safe.
     */
    public static void advance(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return;
        }
        List<Disposition__c> updates = new List<Disposition__c>();
        for (Disposition__c d : DispositionSelector.selectStageAndTypeByIds(dispositionIds)) {
            String target = ADVANCE_TARGET.get(
                DispositionDomain.recordTypeNameOf(d) + '|' + d.Disposition_Stage__c);
            if (target == null) {
                continue; // unmapped pair — leave the row and its semaphore exactly as they are
            }
            updates.add(new Disposition__c(
                Id = d.Id,
                Disposition_Stage__c = target,
                // 🔴 SAME STATEMENT AS THE STAGE, DELIBERATELY. See the class header: separating
                // them would let the flag clear on a write that did not happen.
                Approval_Advance_Pending__c = false
            ));
        }
        if (updates.isEmpty()) {
            return;
        }
        Database.update(updates, false, AccessLevel.SYSTEM_MODE);
    }

    // ⚠ THE PRIVATE `recordTypeNameOf` THAT USED TO LIVE HERE MOVED TO `DispositionDomain` ON
    // 2026-08-19 (code review C-2). Its behaviour is unchanged — Master / unset still answers
    // `On_Market`, still by DESCRIBE and still at zero SOQL. What changed is that
    // `DispositionApprovalService` no longer has a SECOND copy answering `null` to the same
    // question. Do not restore a local copy: the two copies agreeing was asserted in a comment and
    // was false, which is the entire finding.
}
