// Three jobs, in three different context families:
//
//   before insert / before update -> derive Broker_Firm__c and Contact_Name__c from the
//                                    Broker__c Contact lookup (BovSubmissionBrokerStampService),
//                                    and REFUSE a second Selected row on one Disposition
//                                    (BovSubmissionSelectionGuardService).
//   after insert  / after update  -> AUTOMATIC BROKER APPOINTMENT: the highest-scoring,
//                                    non-preferred, unlocked submission becomes the Selected one
//                                    (BovAutoSelectionService, 2026-08-24).
//   after update                  -> when Broker_Finalize_Approval approves the Selected BOV
//                                    submission, move the PARENT Disposition from BOV Outreach to
//                                    Broker Selection and stamp its Selected Broker.
//
// The ONLY BOV_Submission__c trigger in this org (ARCHITECTURE.md §2 /
// .claude/rules/apex-layering-rule.md — one trigger per object); any future BOV automation belongs
// in BovSubmissionTriggerHandler, never in a second trigger file.
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 CORRECTED 2026-08-20 (BOV broker-contact lookup, design C-2). THE ORIGINAL HEADER ARGUED
//    THAT THIS TRIGGER *SHOULD* BE AFTER-UPDATE-ONLY. THAT ARGUMENT IS NOW FALSE AND IS
//    RETRACTED IN PLACE — not deleted, because it was correct about the LOCK and a reader who
//    finds only the new text would not know that half of it still holds:
//
//        RETRACTED: "⚠ AFTER UPDATE ONLY, AND THAT IS A CONSEQUENCE OF WHICH RECORD IS LOCKED.
//        The approval locks the SUBMISSION (`recordEditability = AdminOnly`), not the
//        Disposition — which is the whole reason design decision 3 put this approval on the
//        child. So the parent write is safe SYNCHRONOUSLY and needs no before-context trick and
//        no Queueable. Contrast DispositionTrigger, whose before contexts exist precisely
//        because ITS object is the locked one."
//
// WHAT WAS RIGHT AND STAYS RIGHT: the sentence's actual subject — the PARENT write. The parent
// Disposition is not the record `Broker_Finalize_Approval` locks, so `afterUpdate` can still
// update it synchronously, and nothing below has changed about that.
//
// WHAT WAS WRONG: the sentence generalised "the parent write needs no before context" into "this
// TRIGGER needs no before context", and those are different claims. The before contexts added
// here are not a trick for reaching the parent at all — they exist to write THIS record, the
// submission, DURING THE SAVE THE USER ALREADY MADE.
//
// 🔴 AND THE LOCK ARGUMENT NOW CUTS THE OTHER WAY, WHICH IS THE POINT. It is precisely because
// `Broker_Finalize_Approval` locks the SUBMISSION (`recordEditability = AdminOnly`) that the
// broker stamp MUST be before-context: any post-save second DML against a submission with a
// pending approval throws ENTITY_IS_LOCKED, and a Queueable does not fix it (a pending approval
// outlives the job). An in-memory assignment inside a save the user was already permitted to make
// costs zero DML and no lock can refuse it. So DispositionTrigger's before contexts and this
// trigger's before contexts now exist for the SAME reason, not opposite ones.
// ══════════════════════════════════════════════════════════════════════════════════════════
//
// ⚠ THE BEFORE CONTEXTS FIRE ON EVERY BOV_Submission__c INSERT AND UPDATE IN THE ORG, where
// previously nothing fired on insert at all. That is safe because the stamp is keyed on
// `Broker__c` CHANGING and returns after one in-memory pass with ZERO queries when it did not —
// see BovSubmissionBrokerStampService's class header and its bulk cost tests.
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 RETRACTED IN PLACE 2026-08-24 (BOV auto-selection). The claim below is quoted rather than
//    deleted because HALF OF IT IS STILL TRUE and a reader who found only the new context list
//    would not know which half:
//
//        RETRACTED: "⚠ NO `after insert`. Nothing needs it: the approval transition this file's
//        afterUpdate detects requires `Approval_Status__c` to CHANGE to Approved, which cannot
//        happen on an insert."
//
// WHAT WAS RIGHT AND STAYS RIGHT: the sentence's actual subject — the APPROVAL transition.
// `handleApprovedSelections` still cannot fire on an insert, and `afterInsert` does not call it.
//
// WHAT WAS WRONG: "nothing needs it" generalised one job's requirements into the whole trigger's.
// `BovAutoSelectionService` needs it, because a NEW submission arriving is exactly the event that
// can change which broker is highest-scoring — and it must run in an AFTER context, because it
// promotes one row and demotes another in ONE `Database.update` and that is the only shape
// `BovSubmissionSelectionGuardService` (this same trigger, before contexts) does not refuse.
// See BovAutoSelectionService's class header for the traced arithmetic.
// ══════════════════════════════════════════════════════════════════════════════════════════
// ⚠ `after delete` ADDED 2026-08-24 (preferred-broker-wins). Deleting the appointed submission —
// the normal way a user withdraws a preferred broker — must re-rank the sale, and there was no
// delete context at all, so the broker simply vanished with nothing to notice it. 🔴 STILL NO
// `after undelete`: see BovAutoSelectionService.reselectForDeleted for the three things that
// depend on the undelete duplicate remaining REACHABLE rather than silently self-healed.
trigger BovSubmissionTrigger on BOV_Submission__c (
    before insert, before update, after insert, after update, after delete
) {
    new BovSubmissionTriggerHandler().run();
}
