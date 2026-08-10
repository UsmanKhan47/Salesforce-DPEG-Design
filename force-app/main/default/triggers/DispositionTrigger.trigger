/**
 * Fires after a Disposition is inserted or updated. The ONLY Disposition__c trigger in this org
 * (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md — one trigger per object); any future
 * Disposition automation belongs in DispositionTriggerHandler, never in a second trigger file.
 *
 * All it does is delegate. The stage-entry rules, the idempotency read and every DML live in
 * DispositionStageEntryService.
 */
trigger DispositionTrigger on Disposition__c (after insert, after update) {
    new DispositionTriggerHandler().run();
}
