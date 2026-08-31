/**
 * The trigger for `StageDelayAlertBatch` — the daily stalled-deal reminder (design §2 ITEM 4).
 *
 * ═══ 🔴 SCHEDULING THIS IS A POST-DEPLOY GATE, AND MISSING IT FAILS COMPLETELY SILENTLY ═══
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves the
 * class present, compiled, tested, covered and **completely inert**: zero reminders, zero errors,
 * zero failed `AsyncApexJob` rows, and a feature that looks shipped from every angle a deploy log
 * or a test run can see. It is post-deploy step **P2**, and it is why P2 asks for the cron
 * expression AND the owning user to be recorded.
 *
 *   System.schedule('DPEG Stage Delay Alert', '0 30 7 * * ?', new StageDelayAlertSchedule());
 *
 * ⚠ THE FAILURE IS AS BAD HERE AS IT IS FOR THE OTHER TWO ALERT JOBS AND FOR THE SAME REASON: an
 * unscheduled SWEEPER (`DealFolderSweepBatch`, `RoutingRetrySweepBatch`) leaves rows on a `Failed`
 * status a human can list. An unscheduled ALERT job leaves **no trace at all** — a deal simply sits
 * in Underwriting for three months without anyone being told, and "no reminder arrived" is
 * indistinguishable from "no deal was stalled". There is no queue to inspect and no status to
 * filter. Verify it in Setup.
 *
 * ⚠ VERIFY THE OTHER TWO IN THE SAME PASS. `CallForOffersAlertSchedule` and `NdaExpiryAlertSchedule`
 * carry the identical gate and may still be unscheduled. Three jobs, one habit.
 *
 * ⚠ AND RUN `scripts/load-stage-threshold-defs.apex` (post-deploy step P3) — Custom Metadata
 * RECORDS are not deployable in this repo. Skipping it does NOT kill this feature
 * (`StageDelayService` falls back to a flat 14-day threshold and WARNs, and
 * `StageDelayAlertBatch.finish()` prints the org's row count so an empty load is visible), but the
 * thresholds are not tunable in Setup until the rows exist.
 *
 * ═══ WHO OWNS THE SCHEDULE — LESS FRAUGHT HERE THAN FOR THE NDA JOB, AND THE REASON IS MEASURED ═══
 * `NdaExpiryAlertSchedule`'s header makes a point of the owning principal because `NDA__c` is
 * `sharingModel = Private` with no acquisition sharing rule, so an ungranted owner produces an
 * all-zeros summary indistinguishable from a healthy pipeline. **That does not apply here.**
 * `Opportunity` internal OWD is `ReadWrite` — measured on `usman-dpeg` 2026-08-31 via the Tooling
 * API (`EntityDefinition.InternalSharingModel`) — so every internal principal already sees every
 * deal, and the locator cannot be narrowed by whoever owns the schedule. `StageDelayAlertBatch`'s
 * header §4 argues both halves (read and write) in full.
 *
 * ⚠ THE RESIDUAL IS STILL WORTH ONE LINE: OWD is ORG state and standard-object OWD is UI-only, so
 * nothing in this repo pins it. If `Opportunity` is ever narrowed to Private, the owner of this
 * schedule suddenly matters a great deal and the failure is silent. Re-measure before assuming.
 *
 * ═══ CADENCE — DAILY, AND EARLY ═══
 * Daily is the design's own cadence. The suppression marker is per stage OCCUPANCY, not per day, so
 * the cadence is a quality-of-service choice and not a correctness one: a missed day simply delays
 * a reminder by a day, and it is not skipped.
 *
 * ⚠ RE-RUNNING IS FREE AND SCHEDULING IT MORE OFTEN IS HARMLESS — the marker makes a second run in
 * the same day a genuine no-op (zero notifications, zero DML). Scheduling it LESS often delays
 * every reminder; not scheduling it at all disables the feature entirely.
 *
 * ⚠ THE HALF-HOUR OFFSET FROM THE OTHER TWO JOBS IS DELIBERATE. `NdaExpiryAlertSchedule` documents
 * `0 0 7 * * ?`. Three alert batches starting in the same minute would contend for the org's
 * concurrent-batch slots for no benefit, and would arrive in the same bell as one undifferentiated
 * clump. Any offset works; the point is that the three are not identical.
 *
 * ⚠ SCOPE IS TAKEN FROM `StageDelayAlertBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE — hardcoding a
 * number would put the budget in two places. That constant is itself INHERITED from
 * `CallForOffersAlertBatch` with a citation rather than re-measured; the arithmetic lives in the
 * batch header §1 and nowhere else.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see StageDelayAlertBatch.cls         (the work, the inherited SCOPE and the sharing measurement)
 * @see StageDelayService.cls            (the thresholds and the suppression marker)
 * @see NdaExpiryAlertSchedule.cls       (the precedent — and why its owner rule is STRONGER than this one)
 */
public with sharing class StageDelayAlertSchedule implements Schedulable {

    /**
     * Start one stalled-deal reminder pass.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new StageDelayAlertBatch(), StageDelayAlertBatch.SCOPE);
    }
}
