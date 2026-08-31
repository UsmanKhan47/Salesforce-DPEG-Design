/**
 * Stamps `Transaction__c.Stage_Entry_Date__c` with the date a deal ENTERED the stage it is now in.
 *
 * layer=service. Called from ONE place: `TransactionTriggerHandler.beforeInsert` / `.beforeUpdate`.
 * No selector, no `@AuraEnabled` surface, no other caller.
 *
 * ⚠ THE NAME IS NOT A CHOICE. `Stage_Entry_Date__c` and `OpportunityStageEntryService` already exist
 * in this org for exactly this concept, with a working precedent stack (the before-context stamp,
 * the `Stage_Entry_Date__c != NULL` selector read, and a `LastModifiedDate` backfill script).
 * Inventing a second name for the same idea in the same org is how two half-populated fields end up
 * feeding two disagreeing reports. This class deliberately mirrors that shape rather than improving
 * on it. `DispositionStageEntryService.stampListingDates` is the third member of the family.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 ZERO SOQL AND ZERO DML AT ANY RECORD COUNT - THE REASON IT IS SAFE TO PUT THIS ON A
 *    BRAND-NEW TRIGGER ON `Transaction__c`.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Transaction__c` had NO Apex trigger before Phase 2, and the object sits in the middle of the
 * Day-0 chain (Opportunity 'About to Close' -> ContractExecutionService inserts the Transaction ->
 * the fan-out flow -> a Queueable -> 82 child rows -> rollups that update the Transaction again).
 * Adding a trigger to that object is the exact move this repo has a recorded incident for: routing a
 * new parent into an existing trigger cost `ceil(rows/200)` SOQL *and* DML at production scale. A
 * pure in-memory assignment cannot do that - it costs one `Date.today()` per chunk and one field
 * write per TRANSITIONING record, and nothing else, forever. Every non-transitioning save (and that
 * includes every rollup write the fan-out and `ChecklistRollupService` perform) leaves through the
 * `continue` having spent nothing.
 *
 * ── ⚠ UNCONDITIONAL, NOT FILL-IF-BLANK - THE ONE DELIBERATE DIVERGENCE FROM `stampListingDates` ──
 * THE SEMANTIC IS **ENTRY**, NOT PRESENCE. A deal that leaves a stage and comes back has entered
 * that stage again and any days-in-stage clock must restart. A `if (field == null)` guard would
 * report a revived deal as having sat in its stage since the first time it was there - and
 * `OpportunityStageEntryService.cls:212` records that such a guard silently reintroduces the very
 * bug the field exists to avoid. So on a GENUINE TRANSITION the field is overwritten
 * unconditionally, including over a hand-entered value; on anything that is not a transition it is
 * not touched at all.
 *
 * ── WHAT COUNTS AS A TRANSITION ────────────────────────────────────────────────────────────────
 *   INSERT - `oldMap` is null, so every inserted deal is treated as ENTERING the stage it was
 *            created at. Same test `stampListingDates` and `OpportunityStageEntryService` make, so
 *            the three cannot disagree about which saves are a stage entry.
 *   UPDATE - the prior stage differs from the new stage. A save that changes a counter, a flag, a
 *            date or an owner while the stage stands still is NOT an entry.
 *
 * ── WHY A BEFORE-TRIGGER AND NOT A THIRD BEFORE-SAVE FLOW ──────────────────────────────────────
 * `flows/Transaction_Stage_Closed_Sets_Status` is a RecordBeforeSave flow on this same object.
 * Before-save Flows run BEFORE Apex before-triggers, so this method observes the FINAL `Stage__c`
 * while `Trigger.oldMap` still holds the true prior DATABASE value. A third before-save Flow would
 * have no defined ordering against the one that already exists. Do not "simplify" this into a Flow.
 *
 * ── FLS ────────────────────────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation, not a DML payload, and is
 * therefore not FLS-checked - measured in this org on 2026-08-31 for `Opportunity.Stage_Entry_Date__c`,
 * a field that had FieldPermissions rows for NOBODY, System Administrator included, and was still
 * stamped correctly by its own before-trigger. So this class needs no `isCreateable` guard even
 * though `Transaction__c.Stage_Entry_Date__c` deploys with zero grants. The grant controls only
 * whether a human can SEE the value, and it is still part of the permission pass.
 *
 * @see force-app/main/default/classes/OpportunityStageEntryService.cls (the shape being mirrored)
 * @see scripts/backfill-transaction-stage-entry-date.apex
 * @see agent-output/design-transaction-fsd-gaps.md §2.11, §5.4
 */
public with sharing class TransactionStageEntryService {

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // IN-CONTEXT GOVERNOR INSTRUMENTATION
    // 🔴 THE OBVIOUS TEST IS SILENTLY VACUOUS WITHOUT THIS. `Test.stopTest()` restores the pre-test
    // governor counters, so `Limits.getQueries()` read after a bulk DML measures nothing about what
    // happened inside the trigger; and a reading taken before `stopTest` measures every other
    // service the trigger routes, not this one. The only falsifiable form of "zero SOQL, zero DML at
    // any record count" is a delta across THIS METHOD'S OWN BODY. Same device as
    // `OpportunityStageEntryService`.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /** SOQL consumed by this method's own body, summed over every invocation. Must be 0. */
    @TestVisible
    private static Integer runQueryCount = 0;

    /** DML consumed by this method's own body, summed over every invocation. Must be 0. */
    @TestVisible
    private static Integer runDmlCount = 0;

    /** Times the method was entered. A 251-record DML must produce at least 2 (200-row chunks). */
    @TestVisible
    private static Integer runChunkCount = 0;

    /** Records actually stamped, so a test can prove non-transitioning rows were left alone. */
    @TestVisible
    private static Integer runStampCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        runQueryCount = 0;
        runDmlCount = 0;
        runChunkCount = 0;
        runStampCount = 0;
    }

    /**
     * Stamps `Stage_Entry_Date__c` on every record whose stage this save is CHANGING.
     *
     * Bulk-safe by construction: one pass over the collection, no query, no DML, no describe, no
     * nested loop. Cost is O(n) in-memory assignments.
     *
     * @param newDeals Trigger.new. Null or empty is a no-op (a caller outside a trigger context).
     * @param oldMap   Trigger.oldMap on update; NULL on insert, where every record counts as
     *                 entering the stage it is being created at.
     * @example
     * TransactionStageEntryService.stampStageEntryDates(newList, oldMap);
     */
    public static void stampStageEntryDates(
        List<Transaction__c> newDeals,
        Map<Id, Transaction__c> oldMap
    ) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            stampChunk(newDeals, oldMap);
        } finally {
            // In a `finally` so an unexpected throw cannot leave the counters reading zero and make
            // a budget assertion pass for the wrong reason.
            runChunkCount++;
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The stamp itself. Separated purely so the instrumentation can wrap the whole body, including
     * the early return.
     *
     * @param newDeals Trigger.new.
     * @param oldMap   Trigger.oldMap on update; null on insert.
     */
    private static void stampChunk(List<Transaction__c> newDeals, Map<Id, Transaction__c> oldMap) {
        if (newDeals == null || newDeals.isEmpty()) {
            return;
        }
        // Resolved ONCE for the whole chunk. `Date.today()` is stable within a transaction, but
        // hoisting also guarantees every row stamped by one save carries an identical date instead
        // of relying on that.
        Date today = Date.today();
        for (Transaction__c deal : newDeals) {
            // The `deal.Id == null` half matters on before-INSERT, where `oldMap` is null anyway,
            // and guards a caller passing a stale map alongside unsaved records.
            Transaction__c prior = (oldMap == null || deal.Id == null) ? null : oldMap.get(deal.Id);
            String priorStage = (prior == null) ? null : prior.Stage__c;
            // ENTRY, not presence. Equal stages (including both null) is NOT a transition, so a save
            // that touches any other field leaves the existing date untouched.
            if (priorStage == deal.Stage__c) {
                continue;
            }
            // 🔴 UNCONDITIONAL - see the header. Re-entering a stage RESTARTS the clock, and a
            // `if (deal.Stage_Entry_Date__c == null)` guard here would silently reintroduce the bug
            // the field exists to avoid.
            deal.Stage_Entry_Date__c = today;
            runStampCount++;
        }
    }
}
