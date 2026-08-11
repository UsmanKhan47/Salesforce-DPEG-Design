/**
 * The RETRY / RECOVERY engine for SharePoint deal folders. Selects every `Property__c` whose
 * `SharePoint_Folder_Status__c` is `Pending` or `Failed` and re-runs the identical creation path.
 *
 * ═══ 🔴 UNDER GATE-1 DECISION (i) THIS IS **MORE** LOAD-BEARING THAN THE DESIGN ANTICIPATED ═══
 * The design treated the sweeper as Option B's primary venue and, under Option A, as a safety net.
 * That reading is wrong for THIS org, and the reason is a measured provisioning fact rather than a
 * hypothetical:
 *
 *   • A Queueable runs as the ENQUEUING USER — measured live (`RAN AS USERNAME:
 *     usman.khan.dpeg@...`, callout 200), NOT as Automated Process. So per-user External Credential
 *     Principal Access applies to `DealFolderQueueable`.
 *   • `SharePoint_Integration_Access` was granted to **`DPEG_Junior_Analyst_PSG` ONLY** — NOT to
 *     `DPEG_Transaction_Team`.
 *   • The `Transaction_Complete_Close` flow writes `StageName = 'Closed Won'` with **no
 *     `<runInMode>`**, i.e. as the TRANSACTIONS persona.
 *
 * Therefore **every deal closed through the Transactions route runs the folder job as a user with
 * no credential grant, and its callouts WILL be refused.** That is not an edge case to be defended
 * against — it is a whole, ordinary closing route, and it is expected to land here. Those deals
 * must fail VISIBLY (`Failed`, with `DealFolderService.HINT_CREDENTIAL` naming this exact gap in
 * `SharePoint_Folder_Error__c`) and must be recovered by THIS batch running as a granted scheduling
 * principal. This job is the only thing in the design that closes that gap.
 *
 * 🔴 **A DEPLOY THAT DOES NOT SCHEDULE `DealFolderSweepSchedule` THEREFORE DOES NOT SHIP A DEGRADED
 * FEATURE — IT SHIPS A FEATURE THAT DOES NOT WORK FOR AN ENTIRE PERSONA**, while nothing errors and
 * the rows sit in a status that reads as tracked. Verified post-deploy gate; see that class.
 *
 * ═══ WHY `Pending` **AND** `Failed`, AND WHY NEITHER IS ENOUGH ALONE ═══
 *   `Pending`  written SYNCHRONOUSLY by the trigger, before any callout exists. It catches a job
 *              that died uncatchably, was never enqueued (the enqueue is inside the never-throw
 *              catch), or ran out of budget and lost its chain.
 *   `Failed`   written by `DealFolderFinalizer` or by the service's own per-property error branch.
 *              It catches the credential gap above, and every transient Graph failure.
 *   `Created` / `Skipped` are TERMINAL and excluded BY THE QUERY — which is what makes re-running
 *              this batch free.
 *
 * ═══ IDEMPOTENT AND CONVERGENT ═══
 * A populated `SharePoint_Folder_ID__c` means **ZERO CALLOUTS**: `DealFolderService` re-evaluates
 * that guard inside the callout transaction and simply settles the row to `Created`. So a row that
 * succeeded but failed to stamp, or that a Finalizer marked `Failed` after an earlier link had
 * already committed its id, converges on the next pass at no external cost. Every pass strictly
 * shrinks the queue: success -> `Created`, an unusable name -> `Skipped`, a disabled config ->
 * `Skipped`, a refused callout -> `Failed` (still queued, but with fresh diagnostics).
 *
 * ⚠ THERE IS DELIBERATELY NO ATTEMPT CAP AND NO AGE CAP — a deliberate divergence from
 * `RoutingRetrySweepBatch`, which has both. There, a replay could mint a second Lead or corrupt an
 * adjudication trail, so an unbounded retry is dangerous. Here a retry is guarded by an idempotency
 * key that makes it a no-op once it has succeeded, and the failure being retried is very often an
 * ADMIN ACTION AWAY (grant the credential, enable the config, fix the site id) — abandoning such a
 * row would silently cancel a folder the moment the admin fixed the cause. The cost of no cap is a
 * permanently failing row consuming 1 callout per pass; the cost of a cap is a deal whose documents
 * quietly never got a home. ⚠ If a large population of permanently-failing rows ever appears, add
 * a cap THEN, with the population as evidence — do not pre-empt it.
 *
 * ═══ 🔴 SCOPE = 10 IS THE CALLOUT BUDGET, NOT A THROUGHPUT KNOB ═══
 * The lifecycle-subfolder decision costs **7 callouts per property**, and a batch `execute()` is
 * one transaction with the same 100-callout and 120-second cumulative limits as any other. Scope is
 * taken from `DealFolderService.MAX_PROPERTIES_PER_TRANSACTION` so the batch and the queueable
 * cannot drift into two different budgets for one unit of work; the arithmetic (and why the TIME
 * limit binds before the COUNT limit) is in that class's header. Raising it here without raising it
 * there — or without re-reading that arithmetic — re-opens an UNCATCHABLE `LimitException`.
 *
 * ⚠ The service ALSO re-checks both limits before every property and defers the remainder, so a
 * slow tenant degrades into "fewer per chunk, picked up next pass" rather than a dead chunk. A
 * deferred row is untouched, so it is still `Pending`/`Failed` and still in this queue.
 *
 * ═══ LAYER ═══
 * Batch. It holds NO SOQL of its own (`start()` delegates to `PropertySelector.queryFolderSweep()`,
 * per `.claude/rules/apex-layering-rule.md`) and NO DML of its own — every write goes through
 * `DealFolderService`. `Database.AllowsCallouts` because the service it calls makes them;
 * `Database.Stateful` only to carry the summary counters across chunks.
 *
 * ⚠ BULK TESTING — `.claude/rules/bulk-test-rule.md`'s 251-row mandate applies (this is a batch, and
 * `Property__c` rows consume no `ContentPublication`, so the content rule's 20-row ceiling does
 * not). Note what 251 can prove: a test method executes only ONE chunk, so at SCOPE = 10 a 251-row
 * fixture proves the LOCATOR selects and orders 251 rows and that one chunk of 10 behaves — it does
 * not drive 26 `execute()` calls, and driving 251 rows through one `execute()` would measure a shape
 * this batch can never be in (it would demand 1,757 callouts).
 *
 * @see DealFolderService.cls        (the work, the budget arithmetic, the credential hint)
 * @see DealFolderSweepSchedule.cls  (🔴 the post-deploy scheduling gate)
 * @see PropertySelector.queryFolderSweep (the work queue — SYSTEM_MODE, without sharing)
 * @see RoutingRetrySweepBatch.cls   (the precedent, and the deliberate divergence on retry caps)
 */
public with sharing class DealFolderSweepBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    /**
     * 🔴 Properties per transaction = 10 × 7 callouts = 70 of 100. Taken from the service so the two
     * venues share ONE budget. See the class header and `DealFolderService`'s.
     */
    public static final Integer SCOPE = DealFolderService.MAX_PROPERTIES_PER_TRANSACTION;

    /** Rows this pass handed to the service, across chunks (hence `Database.Stateful`). */
    private Integer processed = 0;
    /** Chunks whose work threw before the service could stamp — recorded, then the pass continues. */
    private Integer failedChunks = 0;

    /**
     * The work queue: every property still owed a folder, oldest first.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over the `Pending` / `Failed` rows.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return PropertySelector.queryFolderSweep();
    }

    /**
     * Re-run folder creation for one chunk of at most `SCOPE` properties.
     *
     * It hands IDS to the service rather than acting on the locator's rows, deliberately: the
     * service re-reads them through `PropertySelector.selectFolderStateByIds` so the idempotency
     * guard is evaluated in the SAME transaction as the callouts. A locator row can be minutes old
     * by the time its chunk runs, and acting on a stale `SharePoint_Folder_ID__c` is precisely how a
     * duplicate folder gets created.
     *
     * FAIL-SOFT PER CHUNK: a batch has no Finalizer, so — unlike the queueable this rescues — a
     * failure here is recorded here or nowhere. The rows are untouched by a failed chunk, so they
     * remain in this queue and are retried on the next pass; the catch exists so one bad chunk
     * cannot abort the remaining ones.
     *
     * @param ctx   The batch context (unused).
     * @param scope The properties to process; at most `SCOPE`.
     */
    public void execute(Database.BatchableContext ctx, List<Property__c> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        List<Id> propertyIds = new List<Id>();
        for (Property__c p : scope) {
            if (p != null && p.Id != null) {
                propertyIds.add(p.Id);
            }
        }
        if (propertyIds.isEmpty()) {
            return;
        }
        try {
            // A returned "deferred" list needs no handling: a deferred row was not touched, so it is
            // still Pending/Failed and is still in this locator's population on the next pass.
            DealFolderService.createFolders(propertyIds);
            processed += propertyIds.size();
        } catch (Exception e) {
            failedChunks++;
            System.debug(LoggingLevel.ERROR,
                'DealFolderSweepBatch: chunk of ' + propertyIds.size() + ' failed: '
                + e.getTypeName() + ' | ' + e.getMessage()
                + ' | the rows are untouched and stay in the queue for the next pass.');
        }
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of every
     * outcome already lives on each `Property__c`'s own `SharePoint_Folder_Status__c` and
     * `SharePoint_Folder_Error__c`, which are queryable and reportable — unlike a static or a log.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'DealFolderSweepBatch finished: processed=' + processed
            + ' failedChunks=' + failedChunks);
    }
}
