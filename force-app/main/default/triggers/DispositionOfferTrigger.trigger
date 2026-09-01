// Offer acceptance: when Offer_Selection_Approval approves the selected offer, mark the offer
// Accepted, move the PARENT Disposition from Offer Selection to LOI, and stamp the accepted price.
//
// The ONLY Disposition_Offer__c trigger in this org (ARCHITECTURE.md §2 /
// .claude/rules/apex-layering-rule.md — one trigger per object); any future offer automation
// belongs in DispositionOfferTriggerHandler, never in a second trigger file.
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 CORRECTED 2026-08-20 (Tranche 2 Workstream A2 — the single-Selected guard). THE ORIGINAL
//    HEADER OPENED "⚠ BOTH CONTEXTS" AND DESCRIBED A TWO-CONTEXT SPLIT. THERE ARE NOW THREE.
//    The original is RETRACTED IN PLACE rather than deleted, because everything it said about the
//    two contexts it described is still exactly true:
//
//        RETRACTED HEADING ONLY: "⚠ BOTH CONTEXTS, AND THE SPLIT IS THE SAME ONE DispositionTrigger
//        MAKES, FOR THE SAME REASON."
//
//    WHAT WAS RIGHT AND STAYS RIGHT: the before/after split itself, and both reasons for it. The
//    word that went stale is "BOTH" — a COUNT, which is exactly the kind of claim that decays.
// ══════════════════════════════════════════════════════════════════════════════════════════
//
//   BEFORE INSERT  🔴 NEW. The single-Selected guard (`DispositionOfferSelectionGuardService`),
//                  routed through the handler's new `beforeInsert`. It refuses an insert that would
//                  leave a Disposition with two `Is_Selected__c = true` offers. The
//                  `Offer_Status__c` stamp does NOT run here — an insert cannot be an approval
//                  TRANSITION, so it has nothing to detect.
//                  ⚠ PLUS, SINCE LATER THE SAME DAY (Workstream D), the buyer-name stamp
//                  (`DispositionOfferBuyerStampService`) — which DOES belong on insert, because an
//                  offer CREATED naming a buyer Contact needs its `Buyer_Name__c` derived
//                  immediately. That is a genuine difference from the guard/stamp split above, not
//                  an inconsistency: one detects a TRANSITION, the other detects a VALUE.
//   BEFORE UPDATE  the offer's OWN `Offer_Status__c = 'Accepted'` — a field on the record being
//                  saved, and the record the approval LOCKS. Writing it in memory makes it part of
//                  the approval's own save, so no second DML exists for ENTITY_IS_LOCKED to refuse.
//                  PLUS the same single-Selected guard, for the changed-to-selected half, PLUS the
//                  buyer-name stamp.
//   AFTER UPDATE   the PARENT Disposition's stage and accepted price — a different record, which
//                  needs the child's committed values and is not itself locked.
// Do not "harmonise" them into one context: see the handler's header for why neither half can move.
//
// ⚠ WHY `before insert` HAD TO BE ADDED RATHER THAN GUARDING UPDATES ONLY. The residual this guard
// closes is API / data-loader / anonymous-Apex writes (`Is_Selected__c` is read-only FLS on both
// disposition permission sets), and the most likely shape of that residual is a LOADED ROW THAT
// ARRIVES ALREADY SELECTED. A before-update-only guard never sees it.
//
// 🔴 THE BLAST RADIUS, STATED PLAINLY: this trigger now fires on EVERY `Disposition_Offer__c`
// INSERT IN THE ORG, where previously NOTHING fired on insert at all. That is safe because the
// guard has a ZERO-QUERY FAST PATH — a chunk in which no incoming row is selected returns after one
// in-memory pass, before any SOQL. `TestDataFactory.createDispositionOffers` leaves `Is_Selected__c`
// unset, which is why every existing offer fixture in the suite stays free. This is the same
// expansion, with the same justification, that `BovSubmissionTrigger` made on 2026-08-20.
//
// ⚠ THE BUYER-NAME STAMP ADDED LATER THAT DAY RIDES THE SAME EXPANSION AND WIDENS NOTHING FURTHER.
// It has its OWN zero-query fast path — CHANGE-KEYED on `Buyer__c`, so a chunk in which no row
// changed its buyer returns after one in-memory pass before any SOQL — and
// `TestDataFactory.createDispositionOffers` sets `Buyer_Name__c` but never `Buyer__c`, which is why
// every existing offer fixture stays green by construction here too. Full argument in
// `DispositionOfferBuyerStampService`'s header.
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 CORRECTED AGAIN 2026-08-31 (Disposition BA gap closure, Tranche 1 item 7 — the
//    `Offers_Received__c` counter). THE 2026-08-20 CORRECTION ABOVE SAID "THERE ARE NOW THREE".
//    THERE ARE NOW SIX. It is retracted in place, exactly as it retracted the one before it,
//    because the same word went stale for the same reason:
//
//        RETRACTED, HEADING ONLY: "THE ORIGINAL HEADER OPENED '⚠ BOTH CONTEXTS' AND DESCRIBED A
//        TWO-CONTEXT SPLIT. THERE ARE NOW THREE."
//
//    WHAT WAS RIGHT AND STAYS RIGHT: everything either correction said about the before/after
//    SPLIT and its two reasons. What decayed, twice now, is a COUNT. This file should stop
//    writing one down.
//
//   AFTER INSERT    🔴 NEW. `Disposition__c.Offers_Received__c`, via
//   AFTER DELETE    `DispositionCounterRollupService`. Neither child link on `Disposition__c` is
//   AFTER UNDELETE  a master-detail, so no roll-up summary is possible and this trigger is the
//                   substitute. The service RECOMPUTES from a single aggregate per chunk and
//                   never increments — an incrementing counter cannot survive a reparent, a
//                   partial rollback or a restore, and can never self-heal.
//                   `after delete` reads `Trigger.old`, the only place the parent Id survives.
//                   `after update` also routes the recompute, but ONLY for a reparent.
//
// 🔴 THE BLAST RADIUS GREW AGAIN, AND THIS TIME IT IS NOT FREE. The 2026-08-20 expansion was
// safe because both new jobs have zero-query fast paths; the counter does NOT have one on
// insert / delete / undelete, because a row appearing or disappearing IS the event. Every
// `Disposition_Offer__c` insert, delete and undelete in the org now costs ONE aggregate query
// and ONE `Database.update` PER CHUNK (never per record). The `after update` half is still
// free unless `Disposition__c` actually moved. That cost is asserted at 251 rows in
// `DispositionCounterRollupServiceTest`, not merely described here.
//
// ══════════════════════════════════════════════════════════════════════════════════════════
// ⚠ AND IT MOVED OTHER SUITES' NUMBERS — **ELEVEN** ASSERTIONS ACROSS **SEVEN** TEST METHODS IN
// TWO CLASSES. RECOUNTED FROM THE DIFF 2026-08-31 (Tranche 1 code review, W-7).
// ══════════════════════════════════════════════════════════════════════════════════════════
//     RETRACTED: "⚠ AND IT MEASURABLY MOVED OTHER SUITES' NUMBERS. Four exact governor
//     assertions in `BovAutoSelectionServiceTest` and `BovPreferredBrokerServiceTest` bracket a
//     real DML and were re-derived in the same commit. If a fifth turns up red with an
//     off-by-one-per-chunk, this is why."
//
// Three things were wrong with it and the CONCLUSION — do not fix a red by removing the counter
// from a context — survives all three.
//   (a) THE COUNT. Four was low, and three different figures were in circulation before this
//       recount (4 here, 7 in the build brief, 10 in the review). The diff against HEAD says:
//         5 EXACT  (`Assert.areEqual`): 4 on `dmlUsed`, 1 on `queriesUsed`
//         6 BOUNDS (`Assert.isTrue(x <= N)`): 2 on `dmlUsed`, 4 on `queriesUsed`
//         = 11 changed assertions, in 7 methods:
//           BovAutoSelectionServiceTest.everyScoreNull_appointsNobodyAndWritesNothing
//           BovAutoSelectionServiceTest.deletingALosingResponse_leavesTheAppointmentAlone
//           BovAutoSelectionServiceTest.theSwapDoesNotReEnterItself                 (2 assertions)
//           BovAutoSelectionServiceTest.bulk251Insert_appointsTheGlobalWinnerAtConstantCost
//                                                                                   (2 assertions)
//           BovAutoSelectionServiceTest.bulk251AcrossManyDispositions_appointsOnePerSaleAt...
//           BovAutoSelectionServiceTest.bulk251PreferredOnOneDisposition_retiresAllButTheNewest
//                                                                                   (2 assertions)
//           BovPreferredBrokerServiceTest.bulk251PreferredRows_retireAtConstantCostPerChunk
//                                                                                   (2 assertions)
//   (b) "EXACT" described all of them; only 5 are exact. The other 6 are UPPER BOUNDS, and the
//       distinction is the point of the warning: an exact assertion goes red when the budget
//       moves, a `<=` bound does NOT — it absorbs the change silently. So "if a twelfth turns up
//       red" is only half the risk; the other half is a bound that quietly stops meaning
//       anything. See W-8's correction inside the two `bulk251Preferred*` methods.
//   (c) "MEASURABLY". Nothing in this tranche has been compiled, deployed or run. Every figure
//       in it — here and in all 11 assertions — is DERIVED FROM SOURCE. A validate-only deploy
//       will settle them; until then no comment in this tranche may call a number measured,
//       verified or confirmed.
//
// 🔴 If any of the 11 turns up red with an off-by-one-per-chunk, this trigger is why — do not
// "fix" it by removing the counter from a context, and do not raise a `<=` bound without deriving
// the new term.
trigger DispositionOfferTrigger on Disposition_Offer__c (
    before insert, before update, after insert, after update, after delete, after undelete
) {
    new DispositionOfferTriggerHandler().run();
}
