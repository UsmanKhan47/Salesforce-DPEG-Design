/**
 * Stamps `Disposition__c.Primary_LOI__c` / `Disposition__c.Primary_PSA__c` AFTER the transaction
 * that created the child has committed.
 *
 * 🔴 ADDED 2026-08-25, DELETED LATER THAT DAY, RESTORED 2026-08-26 (user decision, option A).
 * THE BODY IS THE 2026-08-25 ORIGINAL, UNCHANGED. The header below is too, except for this
 * paragraph — and one sentence in it is now wrong in a way worth naming rather than editing away:
 * the deferral was originally argued so a set of FORMULA MIRROR FIELDS on `Disposition__c` could
 * span these lookups. THOSE FIFTEEN FORMULAS STAY DELETED. The three Details sections on
 * `Disposition_Record_Page` are now SPANNING field items (`Record.Primary_LOI__r.Stage__c` and
 * friends) reading straight through the lookups, so the lookup is the whole dependency.
 * ⚠ NOTHING ABOUT THIS CLASS CHANGES AS A RESULT, WHICH IS THE POINT. Both reasons to defer (the
 * approval lock, re-entrancy) are properties of writing to `Disposition__c` from its own AFTER
 * UPDATE context, not of what reads the result. And the consequence of a missed stamp is
 * identical: the section renders BLANK rather than erroring.
 *
 * ADDED 2026-08-25 (native LOI/PSA Details). The sibling of `DispositionNdaStampQueueable`, and
 * deliberately a SIBLING rather than an extension of it: that class's name, its entire header and
 * its single `Map<Id, Id>` are NDA-specific, and widening it into a three-lookup carrier would have
 * meant either renaming a class three other files reference or bolting two unrelated maps onto a
 * constructor whose documentation argues only about NDAs. One class per lookup FAMILY, one enum to
 * pick the column.
 *
 * -- 🔴 WHY THIS IS ASYNC AT ALL, RE-ARGUED FROM SCRATCH ---------------------
 * IT IS RE-ARGUED BECAUSE `DispositionStageEntryService` SPENT FOUR PARAGRAPHS ARGUING THE
 * OPPOSITE, AND THAT ARGUMENT IS NOW RETRACTED RATHER THAN QUIETLY OVERWRITTEN. Verbatim, from
 * the LOI block's point 3(a) as it stood this morning: "THERE IS NO PARENT WRITE AT ALL.
 * `Disposition__c` has no `Primary_LOI__c` ... With nothing to write back, there is nothing to
 * defer: a Queueable here would be a job that does nothing, and a reader would take its existence
 * as evidence of a hazard that is not present." Both premises were TRUE when written.
 * `Primary_LOI__c` and `Primary_PSA__c` exist as of this change, so there IS now a parent write,
 * and the conclusion that followed from their absence dies with them. There was also a test
 * asserting the old behaviour (`loiAndPsaAutoCreateEnqueueNothing`); it has been INVERTED in this
 * same change, not deleted, so the new claim has a falsifier where the old one did.
 *
 * TWO INDEPENDENT REASONS TO DEFER, EITHER SUFFICIENT:
 *
 * 1. THE APPROVAL LOCK. `Disposition__c` is the entry object of THREE approval processes
 *    (`Sale_Decision_Approval` at `Disposition Readiness`, `Broker_Selection_Approval` at
 *    `Broker Selection` AND record type Off Market, `Closing_Approval` at `Closing` AND
 *    wire-verified). None of the three keys on `LOI` or `PSA` - so the COMMON path is unlocked -
 *    but all three declare `recordEditability = AdminOnly`, which PERMITS an administrator to
 *    re-stage a record while an approval on it is pending. On that path a synchronous write back
 *    fails with `ENTITY_IS_LOCKED`, and `AccessLevel.SYSTEM_MODE` does not help: it lifts CRUD and
 *    FLS and never a lock (measured on the LOI path - see `LoiPrimaryStampQueueable`'s header for
 *    the two failed attempts). A Queueable runs after that lock has been released.
 *
 * 2. RE-ENTRANCY. The caller is in `Disposition__c`'s own AFTER UPDATE context. A synchronous
 *    `Database.update` on the very rows being saved re-enters `DispositionTrigger` inside the
 *    original save rather than after it, which is a strictly worse place for it to happen.
 *
 * ⚠ THE RE-FIRE IS SAFE BY CONSTRUCTION, exactly as the NDA stamp's is: this update changes
 * `Primary_LOI__c` / `Primary_PSA__c` and nothing else, so `Disposition_Stage__c` is unchanged,
 * `DispositionStageEntryService`'s ENTRY test (`priorStage == d.Disposition_Stage__c`) fails
 * immediately, and no second child is opened. Even if that test were removed, the per-block
 * idempotency reads (`LoiSelector` / `ContractReviewSelector` by disposition) would suppress a
 * duplicate. That is why there is no recursion flag anywhere in this feature.
 *
 * -- 🔴 SHARING - AND THIS IS WHERE IT DIVERGES FROM `DispositionNdaStampQueueable` ----
 * That class is `with sharing` and relies on `AccessLevel.SYSTEM_MODE` alone. Per ARCHITECTURE.md
 * section 2, "SYSTEM_MODE bypasses CRUD/FLS ONLY - it does NOT bypass sharing", and
 * `Disposition__c` is OWD **Private** (`sharingModel` in the object file). That gap is not
 * hypothetical here: a disposition reaches the `LOI` stage on a path NO HUMAN EDIT drives -
 * `Offer_Selection_Approval` on the CHILD `Disposition_Offer__c`, whose approver moves the parent
 * through `DispositionOfferTriggerHandler` - so this Queueable can run as a user who has never
 * owned, and may not be able to edit, the disposition it is stamping. That is the exact defect
 * `DispositionOfferTriggerHandler.ParentAdvanceWrites` was created to fix: SYSTEM_MODE removed the
 * OBJECT-level refusal and left the RECORD-level one standing, and it presented as a silent no-op.
 *
 * So the write escapes sharing in the narrow shape ARCHITECTURE.md section 2 prescribes - "a narrow
 * `private without sharing` inner class holding only that query... never `without sharing` on a
 * whole selector" - see `ParentStampWrites` at the bottom of this file. The OUTER class stays
 * `with sharing`.
 *
 * ⚠ THIS IS NOT A CLAIM THAT `DispositionNdaStampQueueable` IS CORRECT. It carries the same gap on
 * a narrower path (nothing but a human edit or `DispositionApprovalAdvanceQueueable` enters `NDA`,
 * and the latter runs SYSTEM_MODE from a job the approver does not own). Changing it was OUT OF
 * SCOPE for this change and is flagged rather than done - do not read this class's shape as
 * evidence that the NDA one was reviewed and passed.
 *
 * ⚠ THE ESCAPE CANNOT WIDEN. This class holds ONE statement against a map the CALLER built out of
 * rows it had just inserted itself. It issues no query, chooses no rows, and can write nothing but
 * the one lookup column named by `lookup`.
 *
 * allOrNone = true, matching both stamp twins: a failure here must surface as a failed
 * `AsyncApexJob` rather than vanish. A silent miss leaves the lookup null, and the LOI/PSA Details
 * section then renders BLANK - not an error - which is the silent-null failure shape this module
 * keeps paying for.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (enqueues this)
 * @see force-app/main/default/classes/DispositionNdaStampQueueable.cls (the NDA twin)
 * @see force-app/main/default/classes/LoiPrimaryStampQueueable.cls (the acquisitions twin)
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (ParentAdvanceWrites)
 */
public with sharing class DispositionPrimaryChildStampQueueable implements Queueable {

    /**
     * Which lookup on `Disposition__c` this job writes.
     *
     * An enum rather than a String field name, per `.claude/rules` ("use enums over string
     * constants whenever possible"), and it buys something concrete: the assignment below is a
     * COMPILE-TIME field reference, so renaming or deleting either lookup fails the deploy here
     * instead of failing at runtime the way `SObject.put('Primary_LOI__c', ...)` would.
     */
    public enum PrimaryLookup { PRIMARY_LOI, PRIMARY_PSA }

    private final Map<Id, Id> childByDisposition;
    private final PrimaryLookup lookup;

    /**
     * @param childByDisposition Disposition__c Id -> the child Id to stamp onto it. Never null in
     *                           production; the null/empty case is handled anyway so a future
     *                           caller cannot turn an empty batch into a NullPointerException in
     *                           an async context, where the only symptom is a failed AsyncApexJob.
     * @param lookup             Which Disposition__c lookup to write.
     */
    public DispositionPrimaryChildStampQueueable(
        Map<Id, Id> childByDisposition,
        PrimaryLookup lookup
    ) {
        this.childByDisposition = childByDisposition;
        this.lookup = lookup;
    }

    public void execute(QueueableContext context) {
        if (childByDisposition == null || childByDisposition.isEmpty() || lookup == null) {
            return;
        }
        List<Disposition__c> stamps = new List<Disposition__c>();
        for (Id dispositionId : childByDisposition.keySet()) {
            Id childId = childByDisposition.get(dispositionId);
            if (lookup == PrimaryLookup.PRIMARY_LOI) {
                stamps.add(new Disposition__c(Id = dispositionId, Primary_LOI__c = childId));
            } else {
                stamps.add(new Disposition__c(Id = dispositionId, Primary_PSA__c = childId));
            }
        }
        new ParentStampWrites().apply(stamps);
    }

    /**
     * The one statement that must escape sharing. See the class header for why `SYSTEM_MODE` alone
     * is insufficient on a Private-OWD parent written by a principal who may not own it, and why
     * this stays an inner class rather than being promoted to the outer one.
     */
    private without sharing class ParentStampWrites {
        /**
         * @param stamps Two-field Disposition__c shells built by `execute` from a map the CALLER
         *               populated with rows it had just inserted; never null, never empty.
         */
        private void apply(List<Disposition__c> stamps) {
            Database.update(stamps, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
