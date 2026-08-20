/**
 * Runs the approval-driven stage advance AFTER the approving transaction has committed.
 *
 * 🔴 WHY THIS IS ASYNC — IT IS A RECORD LOCK, AND UNLIKE ITS SIBLING THE QUEUEABLE ACTUALLY FIXES
 * IT. `Disposition__c` is the entry object of three approval processes, all declaring
 * `recordEditability = AdminOnly`, so while one is pending the record is LOCKED and any write back
 * to it throws ENTITY_IS_LOCKED — and `AccessLevel.SYSTEM_MODE` does NOT lift a lock (measured on
 * the LOI path; see `LoiPrimaryStampQueueable`'s header for the two failed attempts).
 *
 * ⚠ AND THIS IS EXACTLY THE CASE REVIEW D20/W1 SAID A QUEUEABLE DOES **NOT** SOLVE — except that
 * it is the mirror image of it, so read the difference rather than the verdict.
 *   `DispositionNdaStampQueueable`  the triggering transaction is a STAGE CHANGE. It releases no
 *                                   approval, so a PENDING approval OUTLIVES the job and the async
 *                                   write throws anyway. Documented residual, still open.
 *   THIS CLASS                      the triggering transaction is THE FINAL APPROVAL ITSELF. All
 *                                   three processes set `finalApprovalRecordLock = false`, so the
 *                                   lock releases when that transaction COMMITS — which is
 *                                   precisely when a Queueable runs. The job runs into an unlocked
 *                                   record BY CONSTRUCTION, not by luck.
 * The mechanism is identical; WHO RELEASES THE LOCK is what differs. Do not transplant either
 * verdict onto the other class.
 *
 * ── WHY IT HOLDS Ids AND NOT RECORDS ────────────────────────────────────────
 * The stage may legitimately have moved between the approval and this job (an admin can edit a
 * record that `AdminOnly` locks), so a snapshot taken in the trigger would be stale by
 * construction. `DispositionApprovalAdvanceService.advance` re-reads through the selector and maps
 * from the CURRENT stage, which is what makes an already-advanced row a no-op instead of a second
 * hop.
 *
 * ── WHY THE LOGIC IS NOT IN HERE ────────────────────────────────────────────
 * This class is a five-line async shell on purpose. The (record type, stage) -> target decision
 * table and the write live in `DispositionApprovalAdvanceService`, where they are directly
 * callable and directly falsifiable without an async execution around every assertion. Contrast
 * `DispositionNdaStampQueueable`, which keeps its own DML because that DML is one statement with
 * no branches.
 *
 * ⚠ THIS JOB'S UPDATE RE-FIRES `DispositionTrigger`, AND THAT IS BOTH SAFE AND WANTED.
 *   WANTED: the stages it writes include `NDA`, whose ENTRY is what makes
 *     `DispositionStageEntryService` open the buyer's NDA. Advancing without re-firing the trigger
 *     would produce an off-market disposition sitting at `NDA` with nothing to sign.
 *   SAFE: the same update CLEARS `Approval_Advance_Pending__c` (true -> false), which is not the
 *     false -> true transition `enqueuePendingAdvances` looks for, so it cannot enqueue itself.
 *     There is no recursion flag anywhere in this feature and none is needed.
 *
 * ⚠ NO `System.Finalizer` IS ATTACHED, DELIBERATELY. A Finalizer's job is to observe an
 * UNHANDLED failure of the queueable — but this job's DML is `allOrNone = false` and never throws
 * on a business refusal; a refused row simply keeps `Approval_Advance_Pending__c = true`, which is
 * a durable, queryable marker ON THE RECORD that outlives any log a Finalizer could write. The
 * semaphore IS the failure channel.
 *
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (all logic)
 * @see force-app/main/default/classes/DispositionNdaStampQueueable.cls (the mirror-image case)
 */
public with sharing class DispositionApprovalAdvanceQueueable implements Queueable {

    private final Set<Id> dispositionIds;

    /**
     * @param dispositionIds Dispositions whose `Approval_Advance_Pending__c` just went false ->
     *                       true. Never null in production; the null/empty case is handled by the
     *                       service anyway so a future caller cannot turn an empty batch into a
     *                       NullPointerException in an async context, where the only symptom is a
     *                       failed AsyncApexJob nobody is watching.
     */
    public DispositionApprovalAdvanceQueueable(Set<Id> dispositionIds) {
        this.dispositionIds = dispositionIds;
    }

    public void execute(QueueableContext context) {
        DispositionApprovalAdvanceService.advance(dispositionIds);
    }
}
