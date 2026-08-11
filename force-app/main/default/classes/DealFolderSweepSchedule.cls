/**
 * The trigger for `DealFolderSweepBatch` — the SharePoint deal-folder recovery engine.
 *
 * ═══ 🔴 SCHEDULING THIS IS A DEPLOY GATE, AND HERE IT IS NOT MERELY A SAFETY NET ═══
 * A scheduled-job INSTANCE is not deployable metadata, so a deploy that skips this step leaves the
 * class present, compiled and inert. For most sweepers that costs a retry. Here it costs an entire
 * closing route:
 *
 *   `SharePoint_Integration_Access` is granted to `DPEG_Junior_Analyst_PSG` **only**, not to
 *   `DPEG_Transaction_Team`. A Queueable runs as the ENQUEUING USER (measured live), and the
 *   `Transaction_Complete_Close` flow writes `StageName = 'Closed Won'` with no `<runInMode>` —
 *   i.e. as the TRANSACTIONS persona. **Every deal closed through that route will have its
 *   SharePoint callouts refused and will land on `Failed`.** This sweep, running as a granted
 *   scheduling principal, is the ONLY thing that then creates those folders.
 *
 * Unscheduled, those rows sit on `Failed` with a fully explanatory `SharePoint_Folder_Error__c`
 * forever — which is a WORSE state than a bare `Pending`, because the row LOOKS handled. Same class
 * of hazard, and the same remedy, as `RoutingRetrySweepSchedule` and `AttachmentCarrierSweepSchedule`
 * record for their own engines.
 *
 * ═══ 🔴 WHO SCHEDULES IT IS PART OF THE GATE — NOT ONLY THAT IT IS SCHEDULED ═══
 * **The schedule must be owned by a principal that holds `SharePoint_Integration_Access`** (External
 * Credential Principal Access on `SharePoint_Credential-SharePoint_Principal`, plus
 * `UserExternalCredential` read — see ARCHITECTURE.md §3.4). A batch's callouts run as the user who
 * scheduled it, so a schedule owned by an ungranted user reproduces the exact failure this job
 * exists to absorb, and reproduces it on EVERY deal rather than only the Transactions ones.
 *
 * Record the owning user in the deployment log alongside the cron expression, and re-verify it
 * whenever that user is deactivated. ⚠ The reads and writes themselves are safe regardless —
 * `PropertySelector.queryFolderSweep` is `WITH SYSTEM_MODE` inside a `without sharing` inner class,
 * and the stamp is `AccessLevel.SYSTEM_MODE` — so the exposure is confined to the CALLOUT leg. That
 * is deliberate: it means a mis-owned schedule fails loudly on every row rather than returning an
 * all-zero summary indistinguishable from a healthy pipeline.
 *
 * ═══ CADENCE — DAILY, NOT HOURLY, AND THE CONTRAST IS DELIBERATE ═══
 * `RoutingRetrySweepSchedule` is HOURLY because a broker's registry claim is TIME-ORDERED and retry
 * latency is paid by a real broker losing a property. Nothing here is time-ordered: a deal folder
 * that appears the morning after the close is merely late, and the deal is already won. Off-peak
 * also keeps 70-callout transactions away from the working day.
 *
 *   System.schedule('DPEG SharePoint Deal Folder Sweep', '0 0 2 * * ?', new DealFolderSweepSchedule());
 *
 * ⚠ RE-RUNNING IS FREE, so scheduling it MORE often is harmless: the sweep is convergent and a
 * property that already carries a `SharePoint_Folder_ID__c` costs ZERO callouts. There is real harm
 * in scheduling it less often, and total harm in not scheduling it at all.
 *
 * ⚠ SCOPE IS TAKEN FROM `DealFolderSweepBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE. It is 10
 * because the lifecycle-subfolder tree costs 7 callouts per property against a 100-callout,
 * 120-second transaction; hardcoding a number here would put the budget in two places.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see DealFolderSweepBatch.cls     (what it runs, and why SCOPE is 10)
 * @see DealFolderService.cls        (the callout arithmetic and the credential hint)
 * @see RoutingRetrySweepSchedule.cls (the precedent — HOURLY, deliberately, for the opposite reason)
 */
public with sharing class DealFolderSweepSchedule implements Schedulable {

    /**
     * Start one SharePoint deal-folder sweep.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new DealFolderSweepBatch(), DealFolderSweepBatch.SCOPE);
    }
}
