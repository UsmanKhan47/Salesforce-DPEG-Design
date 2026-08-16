/**
 * The trigger for `CallForOffersAlertBatch` — the daily call-for-offers deadline alert.
 *
 * ═══ 🔴 SCHEDULING THIS IS A POST-DEPLOY GATE, AND MISSING IT FAILS COMPLETELY SILENTLY ═══
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves the
 * class present, compiled, tested, covered and **completely inert**: zero alerts, zero errors, zero
 * failed `AsyncApexJob` rows, and a feature that looks shipped from every angle a deploy log or a
 * test run can see. It is requirements gate **G1**, and it is the reason G1 asks for the cron
 * expression AND the owning user to be recorded.
 *
 *   System.schedule('DPEG Call For Offers Alert', '0 0 7 * * ?', new CallForOffersAlertSchedule());
 *
 * ⚠ THE FAILURE IS WORSE HERE THAN FOR THE SWEEPERS THIS CLASS RESEMBLES. `DealFolderSweepBatch`
 * unscheduled leaves rows on a `Failed` status a human can list; `RoutingRetrySweepBatch`
 * unscheduled leaves rows on `Failed` likewise. An unscheduled alert job leaves **no trace at all** —
 * a deal simply never gets alerted, and "no alert arrived" is indistinguishable from "no deadline
 * was near". There is no queue to inspect and no status to filter. Verify it in Setup.
 *
 * ═══ WHO OWNS THE SCHEDULE — MUCH LESS LOAD-BEARING HERE THAN FOR THE SHAREPOINT SWEEP ═══
 * `DealFolderSweepSchedule`'s header makes the owning principal part of its gate, because that
 * batch's CALLOUTS run as the scheduling user and an ungranted user reproduces the exact failure the
 * job exists to absorb. **This job makes no callouts**, its reads are `WITH SYSTEM_MODE` and its
 * writes are `AccessLevel.SYSTEM_MODE`, so FLS and CRUD cannot bite it whoever owns it.
 *
 * 🔴 ONE THING STILL DEPENDS ON THE OWNER, AND IT IS THE JOB'S SILENT-FAILURE MODE: SHARING.
 * `SYSTEM_MODE` lifts CRUD and FLS and **never** sharing. `Opportunity` internal OWD is `ReadWrite`
 * (measured against `usman-dpeg` 2026-08-14), so today every principal sees every deal and the owner
 * is genuinely free. If Opportunity is ever narrowed to Private, the locator returns zero rows for a
 * scheduling principal who owns no deals and `finish()` logs an all-zeros summary that is
 * indistinguishable from a quiet week. The residual, and the remedy, are recorded at
 * `OpportunitySelector.queryCallForOffersAlerts`.
 *
 * ═══ CADENCE — DAILY, AND EARLY ═══
 * Daily is the design's own word, and the alert ladder assumes it: `CallForOffersService`'s marker
 * is MONOTONE precisely so a missed day catches up on the next run rather than skipping a rung
 * forever, so the cadence is a quality-of-service choice and not a correctness one. Early morning
 * puts the alert in front of the team at the start of the day it is about.
 *
 * ⚠ RE-RUNNING IS FREE AND SCHEDULING IT MORE OFTEN IS HARMLESS — the marker makes a second run in
 * the same day a genuine no-op (zero notifications, zero DML). Scheduling it LESS often delays every
 * rung; not scheduling it at all disables the feature entirely.
 *
 * ⚠ SCOPE IS TAKEN FROM `CallForOffersAlertBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE. That
 * constant is derived from a measured `6.0 ms + 0.22 ms x |recipients|` per notification against
 * the async CPU budget; hardcoding a number here would put the budget in two places. ⚠ The bare
 * "6.20 ms" this line used to quote was the ONE-RECIPIENT case and is not a constant — the
 * recipient count is a multiplier, which matters here because the alerting population is a QUEUE
 * that post-deploy gate G2 expands. The arithmetic lives in the batch header §1 and nowhere else.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see CallForOffersAlertBatch.cls   (the work, and the SCOPE measurement)
 * @see CallForOffersService.cls      (the ladder and the idempotency marker)
 * @see DealFolderSweepSchedule.cls   (the precedent — and why its owner rule is stronger than this one)
 */
public with sharing class CallForOffersAlertSchedule implements Schedulable {

    /**
     * Start one call-for-offers alert pass.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new CallForOffersAlertBatch(), CallForOffersAlertBatch.SCOPE);
    }
}
