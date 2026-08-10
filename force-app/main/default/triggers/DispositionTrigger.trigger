/**
 * Fires on Disposition insert and update. The ONLY Disposition__c trigger in this org
 * (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md — one trigger per object); any future
 * Disposition automation belongs in DispositionTriggerHandler, never in a second trigger file.
 *
 * All it does is delegate. The stage-entry rules, the idempotency read and every DML live in
 * DispositionStageEntryService.
 *
 * ── ⚠ THE BEFORE CONTEXTS WERE ADDED 2026-08-10 (Tranche 5B) AND ARE NOT DECORATION ──
 * The Active Listing block stamps `Disposition__c.Listing_Date__c` — a field on the record BEING
 * SAVED. Doing that in a BEFORE context is an in-memory assignment that rides the user's own save:
 * no second DML, and therefore nothing an approval lock can refuse. `Disposition__c` is the entry
 * object of three approvals, all `recordEditability = AdminOnly`, so a second DML against it from
 * inside this trigger is exactly the ENTITY_IS_LOCKED shape that forced
 * `DispositionNdaStampQueueable` into existence — and that Queueable does NOT close the hole here
 * (review D20/W1: `finalApprovalRecordLock = false` releases on FINAL APPROVAL, so a pending
 * approval outlives the job). The before context sidesteps the whole class of failure. The full
 * argument is at `DispositionStageEntryService.stampListingDates`.
 *
 * ⚠ The before path performs ZERO SOQL, ZERO DML and ZERO enqueues and returns immediately unless
 * the stage transitioned into Active Listing — the same "an ordinary Disposition save costs
 * nothing" contract the after path already carries.
 */
trigger DispositionTrigger on Disposition__c (before insert, before update, after insert, after update) {
    new DispositionTriggerHandler().run();
}
