/**
 * The single Opportunity trigger (ARCHITECTURE.md §2, one trigger per object). One line: it
 * delegates every context to OpportunityReviewTriggerHandler and holds no logic of its own.
 *
 * ⚠ WIDENED 2026-08-31 — IT IS NO LONGER AFTER-ONLY, AND THE NAME NO LONGER DESCRIBES IT.
 * It was `(after insert, after update)` and routed review/handoff concerns only. It now also
 * carries the BEFORE contexts for `OpportunityStageEntryService.stampStageEntryDates`, which
 * stamps `Stage_Entry_Date__c` on a genuine stage transition (design §2 ITEM 2). The file keeps
 * its name because renaming a trigger is a delete-and-create against a live org for no functional
 * gain — read the handler's header, not this file name, for what runs.
 *
 * 🔴 WHY ADDING THE BEFORE CONTEXTS HERE IS SAFE, AND WHAT WOULD MAKE IT UNSAFE.
 * This trigger's after contexts already route FIVE service calls, several of which query and
 * write. The one thing that keeps the before contexts free is that
 * `OpportunityStageEntryService` is a PURE IN-MEMORY ASSIGNMENT — zero SOQL and zero DML at any
 * record count, asserted by in-context governor counters in its test class. Adding a second
 * before-context service that queries or writes would cost `ceil(rows/200)` of each on EVERY
 * Opportunity save in the org; that is the shape of a recorded incident on this project. Do not
 * add one without re-deriving that arithmetic.
 *
 * @see force-app/main/default/classes/OpportunityReviewTriggerHandler.cls
 * @see force-app/main/default/classes/OpportunityStageEntryService.cls
 */
trigger OpportunityReviewTrigger on Opportunity (
    before insert,
    before update,
    after insert,
    after update
) {
    new OpportunityReviewTriggerHandler().run();
}
