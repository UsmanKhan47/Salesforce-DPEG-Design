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
trigger DispositionOfferTrigger on Disposition_Offer__c (before insert, before update, after update) {
    new DispositionOfferTriggerHandler().run();
}
