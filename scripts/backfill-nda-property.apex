// Backfill: NDA__c.Property__c on every ACQUISITION NDA that has none, from its deal.
// Design: agent-output/nda-property-and-dead-offramp.md item A. Written 2026-09-02.
//
// WHY IT IS NEEDED. Nothing in this repo had EVER written NDA__c.Property__c - it is an
// omission, not a regression - so every NDA that existed before the Apex fix is blank. The
// fix (OpportunityReviewService.ensureNda + .syncNdaProperty) only stamps NDAs from the
// moment it deploys.
//
// RUN IT AFTER THE APEX, NEVER BEFORE. Every deal converted between a pre-Apex backfill and
// the Apex deploy would land unstamped and need a second run.
//
// RUN IT AS AN ADMINISTRATOR (Modify All Data). NDA__c is Private OWD and acquisition NDAs
// are covered by NO sharing rule - both rules in sharingRules/NDA__c are Disposition_NDA
// scoped. Anonymous Apex runs `without sharing` by default, but the RECORDS still have to be
// visible to the running user for the DML to be accepted; an admin sidesteps that entirely.
// This is also what sweeps the one residual the live fix deliberately does not cover: a deal
// created by user A whose Property is later set by user B, where the trigger's sharing-
// filtered read sees no NDA.
//
// SCOPE: acquisition NDAs only (Opportunity__c != null). Disposition NDAs are created with no
// Opportunity at all (DispositionStageEntryService.openBuyerNdas), so there is no deal to
// source a Property from; that is a different design and is deliberately out of scope.
//
// FILL BLANKS ONLY, matching the live behaviour exactly. An NDA deliberately repointed at a
// different property must not be reverted by a sweep any more than by a parent edit. Both
// halves of the WHERE clause below are load-bearing:
//   Property__c = null                  -> never overwrite
//   Opportunity__r.Property__c != null   -> nothing to copy otherwise; skipping these keeps
//                                           the DML list to rows that actually change.
//
// SAFETY - MEASURED, NOT ASSUMED:
//   - NDA__c has ZERO validation rules (objects/NDA__c/validationRules/ does not exist), so
//     nothing can refuse the save.
//   - Re-entry is nearly free: NdaTrigger is before insert/update only and NdaBuyerStampService
//     is CHANGE-KEYED on Buyer__c (untouched here, so it returns after one in-memory pass with
//     zero queries and zero DML); NDA_Signed_Status_Sync is a RecordBeforeSave flow (in-memory);
//     NDA_Signed_Rollup is RecordAfterSave but its entry filter is `Disposition__c IsNull =
//     false`, so an acquisition NDA never enters it.
//   - Property__c has trackHistory=false, so this writes NO NDA__c history rows even though the
//     object has enableHistory=true.
//   - No ContentVersion/ContentNote anywhere near this, so
//     .claude/rules/content-publication-rule.md does not apply.
//   - No seed script in scripts/ writes NDA__c.Property__c, so re-running the seeds will neither
//     fight this backfill nor undo it.
//
// IDEMPOTENT - safe to re-run. A second run selects zero rows.
//
// POPULATION, MEASURED ON usman-dpeg 2026-09-02 (the org had just been data-reset):
//   NDA__c total                                                        = 1
//   ... WHERE Opportunity__c != null                                    = 1
//   ... AND Property__c = null                                          = 1
//   ... AND Opportunity__r.Property__c != null  <- what this fixes      = 1
//   ... WHERE Property__c != null                                       = 0
// Re-measure before running. That "1" is a fact about a wiped org on one day, not a property
// of the backfill; in a populated org it is every acquisition NDA ever created.

// SOQL is inline here ON PURPOSE and is NOT a layering violation. Anonymous Apex in scripts/
// is not compiled or deployed as part of the package (nothing in force-app references it), so
// ARCHITECTURE.md's selector rule has no file to route through, and importing the selector
// would be wrong anyway: NdaSelector.selectPropertyStampTargetsByOpportunityIds is keyed by a
// known Opportunity set, which is precisely what a whole-org sweep does not have.
List<NDA__c> blanks = [
    SELECT Id, Opportunity__c, Opportunity__r.Property__c
    FROM NDA__c
    WHERE Opportunity__c != null
      AND Property__c = null
      AND Opportunity__r.Property__c != null
];

List<NDA__c> toUpdate = new List<NDA__c>();
for (NDA__c n : blanks) {
    toUpdate.add(new NDA__c(Id = n.Id, Property__c = n.Opportunity__r.Property__c));
}

Integer failed = 0;
String firstError = null;
if (!toUpdate.isEmpty()) {
    // allOrNone = false, matching OpportunityReviewService.syncNdaProperty. A sweep must not
    // abandon 900 good rows because one is locked or refused; the failures are counted and the
    // first message is printed, so a partial run is visible rather than silent.
    //
    // 🔴 NO `AccessLevel.SYSTEM_MODE` ARGUMENT HERE, AND IT MUST NOT BE ADDED BACK. This file
    // carried one until 2026-09-02 and the backfill FAILED ON ITS FIRST REAL RUN with:
    //     System.SecurityException: Cannot use SYSTEM_MODE access level in anonymous execution
    //                               of Apex.
    // Anonymous Apex refuses SYSTEM_MODE outright. MEASURED on usman-dpeg 2026-09-02, all three
    // forms throwing that same SecurityException in one run, against a passing control:
    //     Database.query(q, AccessLevel.SYSTEM_MODE)            -> THREW
    //     Database.update(EMPTY_LIST, false, SYSTEM_MODE)       -> THREW (it is not list-size
    //                                                              dependent; an empty list does
    //                                                              not short-circuit the check)
    //     Database.update(one real row, false, SYSTEM_MODE)     -> THREW
    //     Database.update(one real row, false)   <- THIS FORM   -> OK
    // The static-SOQL clause form `[SELECT ... WITH SYSTEM_MODE]` is refused too. There is also
    // no `without sharing` to reach for in an anonymous block.
    //
    // ⚠ THE CODEBASE CONVENTION IS SYSTEM_MODE EVERYWHERE, AND THAT CONVENTION IS CORRECT — in
    // COMPILED classes and triggers, where ARCHITECTURE.md §2 mandates it for automation-path
    // writes. It is simply not expressible here. Anyone tidying this script toward the house
    // style will reach for that argument; this block is why they must not.
    //
    // NOTHING IS LOST BY DROPPING IT. SYSTEM_MODE lifts CRUD/FLS and NEVER sharing, and the
    // elevated posture it was reaching for is already a stated precondition of this script: the
    // header requires a System Administrator with Modify All Data, which clears FLS and sharing
    // both. If this ever has to run unattended or as a non-admin, it becomes a DEPLOYED class
    // (where SYSTEM_MODE is legal) — that is a different change, not a flag on this line.
    for (Database.SaveResult sr : Database.update(toUpdate, false)) {
        if (!sr.isSuccess()) {
            failed++;
            if (firstError == null && !sr.getErrors().isEmpty()) {
                firstError = sr.getErrors()[0].getMessage();
            }
        }
    }
}

System.debug(LoggingLevel.ERROR, 'NDA Property backfill: '
    + blanks.size() + ' blank acquisition NDAs whose deal HAS a property; '
    + (toUpdate.size() - failed) + ' stamped; '
    + failed + ' failed'
    + (firstError == null ? '.' : ('. First error: ' + firstError)));

// Verification query to run afterwards - it must return 0:
//   SELECT COUNT() FROM NDA__c
//   WHERE Opportunity__c != null AND Property__c = null
//     AND Opportunity__r.Property__c != null
