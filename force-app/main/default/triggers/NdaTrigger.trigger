// 🔴 THE FIRST AND ONLY `NDA__c` TRIGGER IN THIS ORG. Created 2026-08-20 (Tranche 2 Workstream D,
// `agent-output/disposition-tranche-2-requirements.md` §3 D6.2).
//
// Before this file, `NDA__c` HAD NO TRIGGER AT ALL — verified 2026-08-20: `triggers/` contained no
// `NDA`-named file and no trigger declared `on NDA__c`. Every automation this object carries today
// is a Flow (`NDA_Signed_Status_Sync`, `NDA_Signed_Rollup`) or an external writer
// (`DispositionStageEntryService`, `RecordStageAdvanceService`, `NdaExpiryAlertBatch`). Any FUTURE
// `NDA__c` automation belongs in `NdaTriggerHandler`, never in a second trigger file
// (ARCHITECTURE.md §2 / `.claude/rules/apex-layering-rule.md` — one trigger per object).
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 THE BLAST RADIUS, STATED PLAINLY: THIS FIRES ON **EVERY** `NDA__c` INSERT AND UPDATE IN THE
//    ORG — **INCLUDING EVERY ACQUISITION NDA** — WHERE PREVIOUSLY NOTHING FIRED AT ALL.
// ══════════════════════════════════════════════════════════════════════════════════════════
// `NDA__c` is a DUAL-MODULE object: it serves Acquisitions (`Acquisition_NDA`) and Dispositions
// (`Disposition_NDA`), and a large population still sits on MASTER pending post-deploy gate T-A1.
// This trigger is scoped by NEITHER record type NOR parent lookup, on purpose — a record-type filter
// would be inert during the migration window (the exact trap `NdaSelector.queryExpiryAlerts`
// documents at length for its own discriminator choice).
//
// 🔴 THAT IS SAFE FOR ONE REASON AND ONE REASON ONLY, AND IT IS STRUCTURAL RATHER THAN INCIDENTAL:
// the stamp is CHANGE-KEYED on `NDA__c.Buyer__c`. When `Buyer__c` did not change — which is EVERY
// acquisition save, every Flow re-entry, every status advance, every expiry-marker write and every
// existing test fixture — `NdaBuyerStampService.stampBuyerName` returns after ONE IN-MEMORY PASS
// with **ZERO QUERIES AND ZERO DML**. The full writer-by-writer table is in that service's header.
// `Buyer__c` is granted on NEITHER acquisition permission set, so no acquisition surface can even
// set it. **NOTHING ABOUT ACQUISITION BEHAVIOUR CHANGES.**
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 WHY `before insert, before update` AND NOTHING ELSE
// ══════════════════════════════════════════════════════════════════════════════════════════
// BEFORE, so the stamp rides the user's own save: an in-memory assignment inside a save the user was
// already permitted to make costs zero extra DML and NO RECORD LOCK CAN REFUSE IT. A post-save
// second `update` would cost one DML per chunk forever and would begin throwing `ENTITY_IS_LOCKED`
// the day anyone adds an approval process targeting `NDA__c` — silently, in a place nobody would
// look. `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS and NEVER a lock, and a Queueable does not help
// either (a pending approval outlives the job — review D20/W1). Identical shape and identical
// reasoning to `DispositionStageEntryService.stampListingDates`, `DispositionBrokerStampService` and
// `BovSubmissionBrokerStampService`.
//
// ⚠ NO `after` CONTEXT, AND NO `delete` / `undelete` CONTEXT. There is nothing for them to do: the
// only job here writes a field ON THE RECORD BEING SAVED, which is by definition available before
// the save. Adding an empty context would assert work that does not exist. `NDA__c.allowDelete` is
// false on both disposition permission sets by decision D20, so declined NDAs persist as audit
// evidence and there is no delete path to guard.
//
// ⚠ NO RECURSION FLAG, AND THAT IS DELIBERATE. An in-memory assignment during a save fires no
// additional trigger, and the change-key makes any re-entrant save a no-op (`Buyer__c` did not
// change on it). A static boolean would add a mechanism whose failure mode — a flag left true across
// a batch chunk, silently disabling the stamp for the rest of the transaction — is worse than the
// problem it solves. Same conclusion, same reasoning, as `DispositionTriggerHandler`'s header.
trigger NdaTrigger on NDA__c (before insert, before update) {
    new NdaTriggerHandler().run();
}
