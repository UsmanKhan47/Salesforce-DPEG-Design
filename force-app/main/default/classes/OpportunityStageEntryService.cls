/**
 * Stamps `Opportunity.Stage_Entry_Date__c` with the date a deal ENTERED the stage it is now in.
 *
 * Layer = SERVICE (.claude/rules/apex-layering-rule.md). Called from ONE place:
 * `OpportunityReviewTriggerHandler.beforeInsert` / `.beforeUpdate`. It has no other caller, no
 * selector, and no @AuraEnabled surface. Feeds the formula field `Days_In_Stage__c` and, through
 * it, the Item 4 stalled-deal reminder (agent-output/design-requirements.md §2, ITEM 2).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 ZERO SOQL AND ZERO DML AT ANY RECORD COUNT. THAT IS NOT A STYLE PREFERENCE — IT IS THE
 *    ENTIRE REASON IT IS SAFE TO PUT THIS ON `OpportunityReviewTrigger`.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * That trigger already routes FIVE service calls in its after contexts (OpportunityReviewService
 * twice, ContractExecutionService, PropertyAssetService, DealFolderService), several of which
 * query and write. Widening it to the before contexts adds this method to every single
 * Opportunity save in the org, at up to 200 records per chunk. This repo has a recorded incident
 * where routing a NEW PARENT into an existing trigger cost `ceil(rows/200)` SOQL *and*
 * `ceil(rows/200)` DML at production scale (23 each at 4,500 rows). A pure in-memory assignment
 * cannot do that: it costs one `Date.today()` per chunk and one field write per transitioning
 * record, and nothing else, forever.
 *
 * The shape is deliberately copied from `DispositionStageEntryService.stampListingDates`, which
 * reached the same conclusion for `Disposition__c.Listing_Date__c` and records the full argument
 * for why a before-save in-memory assignment beats an inline `update` in the AFTER context and
 * beats a Queueable (no second DML statement means no ENTITY_IS_LOCKED exposure when an approval
 * process holds the record).
 *
 * ── ⚠ ONE DELIBERATE DIFFERENCE FROM `stampListingDates`: UNCONDITIONAL, NOT FILL-IF-BLANK ──
 * `stampListingDates` writes only when `Listing_Date__c` is null, for three reasons its header
 * spells out (idempotency of the marketing clock, a factory that pre-seeds the field, and keeping
 * the parent in step with a child copy). NONE of those apply here, and the requirement is the
 * OPPOSITE:
 *
 *   THE SEMANTIC IS **ENTRY**, NOT PRESENCE. A deal that leaves a stage and comes back has
 *   entered that stage again, and the stalled-deal clock must restart. A fill-if-blank stamp
 *   would report a revived deal as having sat in its stage since the first time it was there —
 *   for the LOI-rejection path (`LOI` -> `Underwriting`, carve-out 1 of
 *   No_Backward_Stage_Movement) and the Dead/Pass revival path, that is the exact population
 *   Item 4 exists to chase, reported with a date that is months wrong.
 *
 * So: on a GENUINE TRANSITION the field is overwritten unconditionally, including over a
 * hand-entered value. On anything that is not a transition it is not touched at all.
 *
 * ── WHAT COUNTS AS A TRANSITION ────────────────────────────────────────────────────────────
 *   INSERT  — `oldMap` is null, so the prior stage is null and every inserted deal is treated as
 *             ENTERING whatever stage it was created at. `prior == null` counts as an entry; this
 *             is the same test `stampListingDates` and `OpportunityReviewService.createReviewRecords`
 *             make, so the three cannot disagree about which saves are a stage entry.
 *   UPDATE  — the prior stage differs from the new stage. A save that changes Amount, Close Date,
 *             an owner, a flag or anything else while the stage stands still is NOT an entry and
 *             leaves the existing date alone.
 *
 * ── WHY A BEFORE-TRIGGER AND NOT A THIRD BEFORE-SAVE FLOW ──────────────────────────────────
 * Before-save Flows run BEFORE Apex before-triggers. So this method observes the FINAL
 * `StageName` — after `Opportunity_Initiate_Underwriting` (a RecordBeforeSave flow) has rewritten
 * it to `Underwriting` — while `Trigger.oldMap` still holds the true prior DATABASE value. A
 * third before-save Flow would have no defined ordering against the two that already exist, and
 * could read a stage that is about to change. Do not "simplify" this into a Flow.
 *
 * ── IT COVERS EVERY WAY A STAGE CAN CHANGE, BECAUSE NONE OF THEM SKIPS DML ─────────────────
 * Verified against the repo on 2026-08-31 (design §2 ITEM 2's table, re-checked file by file):
 *   1. Manual UI / Path / list-view inline edit                                        — DML
 *   2. `StageAdvanceService.setStage` (Advance Stage action, `advanceDealStage` LWC)    — DML
 *   3. `Opportunity_Initiate_Underwriting` RecordBeforeSave Flow (ACTIVE, -> Underwriting)
 *      — runs BEFORE this trigger, so the value it wrote is what is read here
 *   4. `workflows/Opportunity.workflow-meta.xml` -> `Set_Stage_Underwriting`, fired by the ACTIVE
 *      `Opportunity.LOI_Approval` process on final rejection (`LOI` -> `Underwriting`)   — DML
 *   5. `workflows/Opportunity.workflow-meta.xml` -> `UW_Set_Stage_Initiate_LOI`
 *      ⚠ **INERT since 2026-08-28** — see the amendment note below.
 *   6. `flows/Transaction_Complete_Close.flow-meta.xml`, a RecordAfterSave flow on
 *      **`Transaction__c`**, whose `Close_Opportunity` element does a RecordUpdate through
 *      `$Record.Opportunity__r` setting `StageName = 'Closed Won'`. This is the path a reader
 *      misses, because the trigger point is on a DIFFERENT OBJECT. It is still an Opportunity
 *      DML, so this before-trigger still fires and still stamps.                        — DML
 *   7. `LeadConvertService` / `Database.convertLead` — the Opportunity is INSERTED, so the
 *      before-insert context stamps it at its creation stage.                           — DML
 *   8. `scripts/*.apex` seed and migration scripts (18 of them write `StageName`).       — DML
 * No path changes `StageName` without DML, so a before-trigger is EXHAUSTIVE. If a future change
 * introduces a path that does not (there is no such mechanism on the platform today), this
 * statement is the thing that becomes false.
 *
 * ── FLS ────────────────────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation, not a DML payload, and is
 * therefore not FLS-checked. A persona with no EDIT grant on `Stage_Entry_Date__c` still gets the
 * stamp; the grant only controls whether they can SEE it. That is the intended outcome and is the
 * same trade `DispositionStageEntryService.stampListingDates` and `LeadConvertService` record for
 * their own stamps. It is ALSO why this class needs no `Schema.isCreateable()` guard even though
 * the field ships with zero `FieldPermissions` rows: nothing here puts the field into a DML
 * payload, which is the construct that raises `fields being inaccessible`.
 *
 * 🔴 MEASURED, NOT ASSUMED (2026-08-31, usman-dpeg, deploy 0Afiw000000TnF3CAK). At the time of
 * writing `Stage_Entry_Date__c` had FieldPermissions rows for NOBODY except the platform's own
 * `sfdc_slack` set (read-only) — no profile, no persona, not System Administrator. A plain,
 * unqualified 251-record `insert` through this trigger ran clean, the stamp persisted, and no
 * other Opportunity test class was affected. That is the evidence for the paragraph above, and
 * it is recorded here because the general rule in this org points the other way: a field the
 * CALLER puts into a DML payload with no grant fails the whole statement with
 * `fields being inaccessible`. The distinction is WHO put the field in — a before-trigger
 * mutation of `Trigger.new` is not a payload, and that is the whole difference.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (`stampListingDates`)
 * @see force-app/main/default/triggers/OpportunityReviewTrigger.trigger
 * @see agent-output/design-requirements.md §2 ITEM 2
 */
public with sharing class OpportunityStageEntryService {

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // IN-CONTEXT GOVERNOR INSTRUMENTATION
    //
    // 🔴 THESE EXIST BECAUSE THE OBVIOUS TEST IS SILENTLY VACUOUS. `Test.stopTest()` RESTORES
    // the pre-test governor counters, so `Limits.getQueries()` read after a bulk DML measures
    // nothing about what happened inside the trigger. And a reading taken in the test BEFORE
    // stopTest measures all FIVE of the other services this trigger routes, not this one.
    //
    // The only way to make "zero SOQL, zero DML at any record count" a FALSIFIABLE claim is to
    // measure the delta ACROSS THIS METHOD'S OWN BODY, from inside the trigger context. Same
    // device as `ExtractAddressQueueable.lastRunQueryCount` / `.lastRunDmlCount`, with one
    // difference: those record an ABSOLUTE count in a fresh async transaction, whereas this
    // method runs inside the caller's transaction and can be invoked several times (once per
    // 200-record DML chunk, plus once more for every cascaded update the after-context services
    // perform). So these ACCUMULATE a delta rather than snapshotting a total.
    //
    // In-transaction only. Not a monitoring surface, not read by production code, never reset by
    // production code. Tests call resetRunCounters() immediately before the DML they measure.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /** SOQL queries consumed by this method's own body, summed over every invocation. Must be 0. */
    @TestVisible
    private static Integer runQueryCount = 0;

    /** DML statements consumed by this method's own body, summed over every invocation. Must be 0. */
    @TestVisible
    private static Integer runDmlCount = 0;

    /**
     * How many times the method has been entered. A 251-record DML must produce at least 2 (the
     * platform chunks trigger batches at 200), which is what makes a 251-record test different
     * from a 200-record one.
     */
    @TestVisible
    private static Integer runChunkCount = 0;

    /** Records actually stamped, summed over every invocation. Lets a test prove that a chunk
     *  containing non-transitioning rows left them alone without re-querying. */
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
     * @param newOpps Trigger.new. Null or empty is a no-op (a caller outside a trigger context).
     * @param oldMap  Trigger.oldMap on update; NULL on insert, where every record counts as
     *                entering the stage it is being created at.
     */
    public static void stampStageEntryDates(
        List<Opportunity> newOpps,
        Map<Id, Opportunity> oldMap
    ) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            stampChunk(newOpps, oldMap);
        } finally {
            // In a finally so an unexpected throw cannot leave the counters reading zero and make
            // a budget assertion pass for the wrong reason.
            runChunkCount++;
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The stamp itself. Separated from the public method purely so the instrumentation above can
     * wrap the whole body, including the early return.
     *
     * @param newOpps Trigger.new.
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    private static void stampChunk(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (newOpps == null || newOpps.isEmpty()) {
            return;
        }
        // Resolved ONCE for the whole chunk rather than per record. Date.today() is stable within
        // a transaction, but hoisting it also guarantees every row stamped by one save carries an
        // identical date instead of relying on that, and keeps a 200-record chunk to one call.
        Date today = Date.today();
        for (Opportunity o : newOpps) {
            // The `o.Id == null` half matters on before-INSERT, where oldMap is null anyway, and
            // guards a caller that passes a stale map alongside unsaved records. Mirrors
            // stampListingDates.
            Opportunity prior = (oldMap == null || o.Id == null) ? null : oldMap.get(o.Id);
            String priorStage = (prior == null) ? null : prior.StageName;
            // ENTRY, not presence. Equal stages (including both null) is NOT a transition, so a
            // save that touches any other field leaves the existing date untouched.
            if (priorStage == o.StageName) {
                continue;
            }
            // 🔴 UNCONDITIONAL — see the header. Re-entering a stage RESTARTS the clock; this is
            // the one place this method deliberately diverges from stampListingDates, and a
            // `if (o.Stage_Entry_Date__c == null)` guard here would silently reintroduce the bug
            // Item 4 exists to avoid.
            o.Stage_Entry_Date__c = today;
            runStampCount++;
        }
    }
}
