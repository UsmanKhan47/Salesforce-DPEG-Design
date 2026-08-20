/**
 * Stamps Disposition__c.Primary_NDA__c AFTER the transaction that created the NDA has committed.
 *
 * WHY THIS IS ASYNC — it is a record LOCK, not a permission. The disposition twin of
 * LoiPrimaryStampQueueable, and the reasoning transfers wholesale; read that class's header for
 * the two failed attempts that produced the pattern:
 *
 *   attempt 1  bare DML                     -> System.TypeException (the actor has no Edit)
 *   attempt 2  AccessLevel.SYSTEM_MODE      -> ENTITY_IS_LOCKED (an approval lock, a DIFFERENT
 *                                              cause — SYSTEM_MODE lifts CRUD and FLS, never a
 *                                              lock)
 *   attempt 3  a Queueable, post-commit     -> the lock has already been released
 *
 * `Disposition__c` is the entry object of THREE approval processes — Sale_Decision_Approval (at
 * `Disposition Readiness`), Broker_Selection_Approval (at `Broker Selection` AND record type Off
 * Market) and Closing_Approval (at `Closing` AND `Wire_Verification_Completed__c = true`) — and all
 * three declare `recordEditability = AdminOnly`, so any write back to the
 * disposition from inside a transaction running under a pending approval fails. All three also
 * set `finalApprovalRecordLock = false`, so the record unlocks when that transaction commits,
 * which is exactly when a Queueable runs.
 *
 * ⚠ TWO OF THOSE ENTRY CRITERIA MOVED ON 2026-08-19 (disposition flow redesign) and the old text is
 * retracted verbatim so nobody re-derives it: "Broker_Selection_Approval (at BOV Outreach) and
 * Closing_Approval (at Closing)". Nothing about THIS class changes — `NDA` was not an entry stage
 * before and is not one now — but the residual below is affected, so read on.
 *
 * 🔴 THE D20/W1 RESIDUAL IS NOW REACHABLE FROM A NEW DIRECTION, AND IT IS WORTH KNOWING. Since the
 * redesign, an OFF-MARKET disposition enters `NDA` as the result of `Broker_Selection_Approval`
 * being APPROVED — through `Approval_Advance_Pending__c` and
 * `DispositionApprovalAdvanceQueueable`. On that path the lock has ALREADY released (the approving
 * transaction committed before that Queueable ran), so this stamp finds an unlocked record and the
 * residual does not bite. The residual still applies where it always did: a HUMAN or a data load
 * moving a record into `NDA` while some OTHER approval is pending on it, which `AdminOnly` permits
 * for an administrator. See `DispositionApprovalAdvanceQueueable`'s header for why that class is
 * the mirror image of this one — same mechanism, opposite conclusion, and the difference is WHO
 * releases the lock.
 *
 * The NDA itself is still inserted SYNCHRONOUSLY by DispositionStageEntryService: NDA__c is not
 * the record under approval and is not locked, so the user sees it immediately. Only the
 * back-reference is deferred, and only briefly.
 *
 * ⚠ THIS UPDATE RE-FIRES DispositionTrigger, AND THAT IS SAFE BY CONSTRUCTION, TWICE OVER. The
 * stamp changes `Primary_NDA__c` and nothing else, so `Disposition_Stage__c` is unchanged and
 * DispositionStageEntryService's stage-ENTRY test fails immediately; and even if it did not, the
 * Party_Role__c = 'Buyer' idempotency read would suppress a second NDA. That is why there is no
 * recursion flag anywhere in this feature. It is also why the update cannot trip
 * `All_NDAs_Signed_Before_Progression`, which is `ISCHANGED(Disposition_Stage__c)`-scoped.
 *
 * SYSTEM_MODE for the same reason the insert uses it: this can run as an APPROVER, or as a
 * disposition persona holding read-only FLS on Primary_NDA__c (the field ships read-only in every
 * permission set that carries it, because this class is its only writer).
 *
 * allOrNone = true on purpose: a failure here must surface as a failed AsyncApexJob rather than
 * vanish. A silent miss leaves Primary_NDA__c null, and anything resolving the disposition's NDA
 * through that lookup then finds nothing — the same silent-null failure shape
 * Opportunity.Primary_LOI__c was added to prevent, one module later.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (enqueues this)
 * @see force-app/main/default/classes/LoiPrimaryStampQueueable.cls (the acquisitions twin)
 */
public with sharing class DispositionNdaStampQueueable implements Queueable {

    private final Map<Id, Id> ndaByDisposition;

    /**
     * @param ndaByDisposition Disposition__c Id -> the NDA__c Id to stamp onto it. Never null in
     *                         production; the null/empty case is handled anyway so a future
     *                         caller cannot turn an empty batch into a NullPointerException in an
     *                         async context, where the only symptom is a failed AsyncApexJob.
     */
    public DispositionNdaStampQueueable(Map<Id, Id> ndaByDisposition) {
        this.ndaByDisposition = ndaByDisposition;
    }

    public void execute(QueueableContext context) {
        if (ndaByDisposition == null || ndaByDisposition.isEmpty()) {
            return;
        }
        List<Disposition__c> stamps = new List<Disposition__c>();
        for (Id dispositionId : ndaByDisposition.keySet()) {
            stamps.add(new Disposition__c(
                Id = dispositionId,
                Primary_NDA__c = ndaByDisposition.get(dispositionId)
            ));
        }
        Database.update(stamps, true, AccessLevel.SYSTEM_MODE);
    }
}
