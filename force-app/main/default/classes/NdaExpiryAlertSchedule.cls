/**
 * The trigger for `NdaExpiryAlertBatch` — the daily NDA expiry reminder (FSD Tranche 1, Item 2).
 *
 * ═══ 🔴 SCHEDULING THIS IS A POST-DEPLOY GATE, AND MISSING IT FAILS COMPLETELY SILENTLY ═══
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves the
 * class present, compiled, tested, covered and **completely inert**: zero reminders, zero errors,
 * zero failed `AsyncApexJob` rows, and a feature that looks shipped from every angle a deploy log
 * or a test run can see. It is requirements gate **G1**, and it is why G1 asks for the cron
 * expression AND the owning user to be recorded.
 *
 *   System.schedule('DPEG NDA Expiry Alert', '0 0 7 * * ?', new NdaExpiryAlertSchedule());
 *
 * ⚠ THE FAILURE IS WORSE HERE THAN FOR THE SWEEPERS THIS CLASS RESEMBLES. `DealFolderSweepBatch`
 * unscheduled leaves rows on a `Failed` status a human can list; `RoutingRetrySweepBatch`
 * unscheduled likewise. An unscheduled ALERT job leaves **no trace at all** — an NDA simply expires
 * without anyone being told, and "no reminder arrived" is indistinguishable from "no NDA was
 * expiring". There is no queue to inspect and no status to filter. Verify it in Setup.
 *
 * ═══ 🔴 WHO OWNS THE SCHEDULE IS PART OF THE GATE, AND IT MATTERS MORE HERE THAN IT DOES FOR THE
 *     CALL-FOR-OFFERS JOB THIS CLASS COPIES ═══
 * `CallForOffersAlertSchedule` can afford to be relaxed about its owner because `Opportunity`
 * internal OWD is `ReadWrite` (measured) — every principal already sees every deal.
 * 🔴 **THAT IS NOT TRUE HERE AND THE DIFFERENCE IS THE WHOLE POINT.** `NDA__c` is
 * `sharingModel = Private`, and its only two sharing rules are criteria-scoped to
 * `RecordTypeId = 'Disposition NDA'` — **no sharing rule covers an acquisition NDA at all**. This
 * job is built to survive that: the locator lives in `NdaSelector.ExpiryAlertReads` and the marker
 * write in `NdaExpiryAlertBatch.MarkerWrites`, both `private without sharing`, and both reads and
 * writes are SYSTEM_MODE so CRUD and FLS cannot bite whoever owns the schedule.
 *
 * ⚠ THAT REMEDY IS THE THING TO VERIFY RATHER THAN ASSUME — post-deploy gate **G2**. Confirm, AS
 * THE SCHEDULING PRINCIPAL, that a pass actually selects and stamps an acquisition NDA that
 * principal does not own. If the `without sharing` inner classes were ever watered down in review,
 * or if the platform re-applies the batch class's sharing context when chunking the locator, an
 * ungranted owner produces an **all-zeros `finish()` summary indistinguishable from a healthy
 * pipeline**. Re-verify when that user is deactivated.
 *
 * ═══ CADENCE — DAILY, AND EARLY ═══
 * Daily is the FSD's own cadence, and the ladder assumes it: `NdaExpiryService`'s marker is
 * MONOTONE precisely so a missed day CATCHES UP on the next run rather than skipping a rung
 * forever, so the cadence is a quality-of-service choice and not a correctness one. Early morning
 * puts the reminder in front of the team at the start of the day.
 *
 * ⚠ RE-RUNNING IS FREE AND SCHEDULING IT MORE OFTEN IS HARMLESS — the marker makes a second run in
 * the same day a genuine no-op (zero notifications, zero DML). Scheduling it LESS often delays
 * every rung; not scheduling it at all disables the feature entirely.
 *
 * ⚠ SCOPE IS TAKEN FROM `NdaExpiryAlertBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE — hardcoding a
 * number would put the budget in two places. That constant is itself INHERITED from
 * `CallForOffersAlertBatch` with a citation rather than re-measured; the arithmetic lives in the
 * batch header §1 and nowhere else.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see NdaExpiryAlertBatch.cls        (the work, and the inherited SCOPE)
 * @see NdaExpiryService.cls           (the ladder and the idempotency marker)
 * @see CallForOffersAlertSchedule.cls (the precedent — and why its owner rule is WEAKER than this one)
 */
public with sharing class NdaExpiryAlertSchedule implements Schedulable {

    /**
     * Start one NDA expiry reminder pass.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new NdaExpiryAlertBatch(), NdaExpiryAlertBatch.SCOPE);
    }
}
