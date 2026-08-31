/**
 * The trigger for `BrokerCounterRecalcBatch` — the nightly broker counter recalculation
 * (design §2 ITEM 6.2/6.4).
 *
 * ═══ 🔴 SCHEDULING THIS IS A POST-DEPLOY GATE, AND MISSING IT FAILS COMPLETELY SILENTLY ═══
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves the
 * class present, compiled, tested, covered and **completely inert**: zero recalculations, zero
 * errors, zero failed `AsyncApexJob` rows, and a feature that looks shipped from every angle a
 * deploy log or a test run can see.
 *
 *   System.schedule('DPEG Broker Counter Recalc', '0 0 2 * * ?', new BrokerCounterRecalcSchedule());
 *
 * 🔴 **AND THE SYMPTOM OF MISSING IT IS THE EXACT SYMPTOM THIS WHOLE FEATURE EXISTS TO FIX.**
 * That is what makes this gate nastier than its two siblings. `Contact.Deals_Submitted__c` and
 * `Deals_Won__c` have rendered permanent zeroes since the day they were created, because nothing
 * wrote them. An unscheduled recalculation job leaves them rendering permanent zeroes — so the
 * bug report that motivated the work stays open, the code that fixes it is present and green, and
 * nothing anywhere connects the two. Verify the job exists in Setup > Scheduled Jobs, then verify
 * a broker Contact's counters are non-zero the following morning. **The test suite passing is not
 * evidence this feature is running.**
 *
 * ═══ 🔴 WHO OWNS THE SCHEDULE IS PART OF THE GATE, AND IT MATTERS MORE HERE THAN FOR THE ALERT
 *     JOBS THIS CLASS RESEMBLES ═══
 * `CallForOffersAlertSchedule` can afford to be relaxed about its owner because `Opportunity`
 * internal OWD is `ReadWrite`. `NdaExpiryAlertSchedule` cannot, because `NDA__c` is Private.
 * **This job is the third case again**, and the reason is not an OWD at all:
 *
 *   • `Contact` internal OWD measures **`ReadWrite`** (Tooling API, `usman-dpeg`, 2026-08-31) —
 *     which reads like "any owner will do" and is **misleading**. A Contact with **no
 *     `AccountId` is a private contact, visible only to its owner, whatever the OWD says**, and
 *     **4 of this org's 18 broker Contacts (22%) have a null `AccountId`.**
 *   • `Lead` internal OWD measures **`Private`**, and the first-submission aggregate reads it.
 *
 * The job is built to survive both: the locator lives in `ContactSelector.CounterTargetReads`,
 * the Lead aggregate in `LeadSelector.BrokerFirstSeenReads` and the write in
 * `BrokerCounterRecalcBatch.CounterWrites` — all three `without sharing`, all three SYSTEM_MODE,
 * so neither CRUD, FLS nor sharing can bite whoever owns the schedule.
 *
 * ⚠ THAT REMEDY IS THE THING TO VERIFY RATHER THAN ASSUME — post-deploy gate. Confirm, AS THE
 * SCHEDULING PRINCIPAL, that a pass actually recalculates an ACCOUNT-LESS broker Contact that
 * principal does not own. If any of the three escapes were watered down in review, an ungranted
 * owner produces a `finish()` summary that is **indistinguishable from a healthy quiet night** —
 * because a healthy quiet night legitimately writes nothing (batch header §2b). Re-verify when
 * that user is deactivated.
 *
 * ═══ CADENCE — NIGHTLY, AND IN THE SMALL HOURS ═══
 * Nightly is the design's own cadence. `02:00` puts the recalculation after the day's deal
 * activity has settled and before anyone opens a Contact page, and well clear of the 07:00 alert
 * jobs so the two are not competing for async slots.
 *
 * ⚠ RE-RUNNING IS FREE AND SCHEDULING IT MORE OFTEN IS HARMLESS. The job is fully idempotent and
 * skips any broker whose stored counters already match, so a second pass on the same day is a
 * genuine no-op: zero DML rows (batch header §2b). Scheduling it LESS often just means the
 * counters lag; not scheduling it at all disables the feature entirely.
 *
 * ⚠ A MISSED NIGHT COSTS NOTHING AND NEEDS NO CATCH-UP. Unlike the alert ladders — where a
 * skipped day risks skipping a rung — this job recomputes absolute state from scratch every pass.
 * There is no marker, no monotonicity requirement and nothing to replay.
 *
 * ⚠ SCOPE IS TAKEN FROM `BrokerCounterRecalcBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE —
 * hardcoding a number would put the budget in two places. 🔴 That constant is **100, DERIVED from
 * the 2,000-row `AggregateResult` cliff — NOT the 200 the sibling batches inherit.** The
 * arithmetic lives in the batch header §2a and nowhere else; do not "align" it with the siblings.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see BrokerCounterRecalcBatch.cls   (the work, the derived SCOPE, and the three sharing escapes)
 * @see BrokerLeaderboardService.cls   (🔴 the AUTHORITATIVE broker population — batch header §0)
 * @see NdaExpiryAlertSchedule.cls     (the precedent — and why its owner rule differs from this one)
 */
public with sharing class BrokerCounterRecalcSchedule implements Schedulable {

    /**
     * Start one broker counter recalculation pass.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new BrokerCounterRecalcBatch(), BrokerCounterRecalcBatch.SCOPE);
    }
}
