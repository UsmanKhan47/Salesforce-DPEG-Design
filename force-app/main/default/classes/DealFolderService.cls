/**
 * Creates the SharePoint deal folder — and its six lifecycle subfolders — when an acquisition deal
 * ENTERS `Closed Won`. The orchestration half of the feature: it owns stage-entry detection, folder
 * naming, the callout budget, the result stamp and every skip decision. The single `Http.send`
 * lives in `SharePointCalloutService`; every SOQL statement lives in `PropertySelector`.
 *
 * Design: `agent-output/design-requirements-sharepoint-deal-folder.md`, with three Gate-1 decisions
 * that OVERRIDE that document's recommended defaults (recorded here because the document still
 * reads the other way):
 *   (i)   VENUE — a QUEUEABLE chained from the trigger (D1 **Option A**), not the work-queue +
 *         sweeper-only shape of Option B. The sweeper still exists, and under Option A it is MORE
 *         load-bearing rather than less — see `DealFolderSweepBatch`.
 *   (ii)  STRUCTURE — the six-subfolder LIFECYCLE TREE (D2 recommended flat). This is the decision
 *         that reshapes the whole build: it multiplies the callout cost per deal by SEVEN.
 *   (iii) LOCATION — the LIBRARY ROOT. `SharePoint_Config__c.Parent_Folder_ID__c` is honoured when
 *         populated but is expected blank.
 *
 * ── 🔴 WHY IT HANGS OFF THE OPPORTUNITY TRIGGER ──
 * Same argument `PropertyAssetService` won, and it is not reused loosely: `StageAdvanceService
 * .NEXT_STAGE` maps **both** `PSA ⇒ Closed Won` and `About to Close ⇒ Closed Won`, so a deal driver
 * reaches Closed Won with no `Transaction__c` in the picture at all. Building this into the
 * `Transaction_Complete_Close` flow would have missed half the closes, invisibly. Keying on the
 * OPPORTUNITY STAGE catches every route by construction. ⚠ Note this argument does NOT rule Flow
 * out on its own (a record-triggered Flow on Opportunity would catch both routes too) — what rules
 * Flow out is that a per-record interview would attempt 251 × 7 = 1,757 HTTP Callout actions
 * against a hard limit of 100 per transaction, and Flow's callout action has no `HttpCalloutMock`
 * seam at all.
 *
 * ═══ 🔴 THE NEVER-THROW RULE — THE HARDEST CONSTRAINT IN THIS CLASS ═══
 * `ensureOnClosedWon` MUST NOT THROW A CATCHABLE EXCEPTION, under any input, ever. A SharePoint
 * problem rolling back a Closed Won is strictly worse than a missing folder: the folder is
 * recoverable by a sweep, the deal close is a human's work.
 *
 * ⚠ **READ THAT CLAIM EXACTLY AS FAR AS IT GOES — "cannot throw" would be an overstatement.** Apex
 * has failure modes a `catch (Exception)` demonstrably does not intercept: SP-R1 measured a
 * `LimitException` escaping a catch positioned directly around the failing statement (the finding
 * that produced `RoutingFailureFinalizer`). EVERY governed statement on the synchronous path is of
 * that family — the SOQL in `claimFolders` (query 101), the `Database.update` in `stampAll` (DML
 * 151) and `System.enqueueJob` (job 51) all raise the same uncatchable `LimitException`. Only ONE
 * of the three carries an explicit guard — the enqueue, bounded by `Limits.getQueueableJobs() <
 * Limits.getLimitQueueableJobs()`.
 *
 * 🔴 THAT ASYMMETRY IS DELIBERATE. DO NOT "HARMONISE" IT BY ADDING MATCHING GUARDS TO THE SOQL OR
 * THE DML. Skipping the enqueue is safe precisely because the rows were stamped `Pending` FIRST, so
 * the work is already in `DealFolderSweepBatch`'s queue and the cost is latency. Skipping the read
 * or the stamp has no such backstop: it loses the claim outright and leaves a NULL
 * `SharePoint_Folder_Status__c`, which `PropertySelector.folderSweepLocator` cannot see — the
 * silent, permanently-invisible R5 population, reached by a new door. A guard is only safe where
 * the skipped work is already durably owed. A future reader must not infer from the rule above that
 * any statement added here is automatically safe, nor that a guard is automatically an improvement.
 *
 * ⚠ **Placing this call LAST in the trigger handler does not achieve that either, and must never be
 * mistaken for it.** A throw from anywhere in a trigger rolls back the whole transaction regardless
 * of statement order. Only the ABSENCE of throwing paths achieves it, which is why:
 *   - the synchronous entry point wraps ALL of its work in `catch (Exception)`, and a swallowed
 *     failure leaves rows at `Pending` for the sweep;
 *   - the one statement that catch cannot cover — the enqueue — carries its own limit guard;
 *   - `SharePointCalloutService` returns failures as values and never throws;
 *   - `SharePointConfig` degrades to DISABLED rather than propagating;
 *   - every stamp is `allOrNone = false`, so one bad row cannot take the others;
 *   - the synchronous path makes **ZERO callouts** — a callout with uncommitted DML pending is not
 *     merely discouraged here, it is impossible by construction.
 * This is deliberately the OPPOSITE of `PropertyAssetService`, which is `allOrNone = true` and
 * throws on purpose because its silent absence WAS the bug. Do not harmonise the two.
 *
 * ═══ 🔴 THE CALLOUT ARITHMETIC — WHY ONE JOB CANNOT CLOSE 251 DEALS ═══
 * Decision (ii) costs **7 callouts per deal**: one parent folder plus six subfolders. Against the
 * platform's limits:
 *
 *   callouts per transaction        100  ->  floor(100 / 7) = 14 deals is the HARD ceiling
 *   cumulative callout time         120 s ->  at ~1.5 s per Graph call, 70 calls ≈ 105 s
 *   queueable enqueues, SYNC txn     50  ->  ONE per trigger chunk, never one per deal
 *   queueable enqueues, ASYNC txn     1  ->  self-chaining must be EXACTLY one call
 *
 * `MAX_PROPERTIES_PER_TRANSACTION = 10` (70 callouts, 70 % of the count limit) is chosen against
 * the SECOND row, not the first: the count limit permits 14, but 14 × 7 = 98 calls at a pessimistic
 * 1.5 s each is 147 s and blows the CUMULATIVE TIME limit — which, like the count limit, throws an
 * UNCATCHABLE `LimitException` that takes the whole job with it. 10 leaves 30 spare callouts and
 * ~15 s of slack, which is the margin a first production run should be measured against.
 *
 * ⚠ **N IS A PLANNING NUMBER, NOT THE ONLY PROTECTION.** `hasBudgetForOneProperty` re-checks BOTH
 * limits before every property and defers the remainder rather than dying, so a tenant slower than
 * the estimate degrades into more chained links instead of an uncatchable failure. Anyone raising N
 * must re-read that method as well as this paragraph.
 *
 * A 251-deal bulk close is therefore: 2 trigger chunks -> 2 enqueues -> each job walks 10 properties
 * per link and RE-ENQUEUES ITSELF for the remainder. Chaining is not subject to the 50-enqueue cap
 * because each link is its own transaction — but `Limits.getLimitQueueableJobs()` is **1** inside an
 * async transaction, so the self-chain must be exactly ONE call, which is why the deferred list is
 * returned to the queueable rather than enqueued from here. `RoutingRetrySweepBatch`'s header
 * records that same constraint.
 *
 * ═══ IDEMPOTENCY — ONE FOLDER PER PROPERTY, FOREVER ═══
 * The guard is `Property__c.SharePoint_Folder_ID__c`: non-blank means **zero callouts**, on every
 * path — the trigger, the chained job and the sweep. It is keyed on the PROPERTY, matching
 * `PropertyAssetService`, so two deals against one property share one folder. It is read through
 * `PropertySelector.selectFolderStateByIds`, which is `WITH SYSTEM_MODE` inside a `without sharing`
 * inner class precisely because a sharing-filtered guard read would not disable this feature — it
 * would INVERT it and mint a duplicate folder (ARCHITECTURE.md §2; the argument is at the selector).
 *
 * ⚠ `conflictBehavior: rename` guarantees a duplicate SUCCEEDS rather than colliding, which is what
 * makes an under-read guard silent. That is the whole reason the guard read escapes sharing.
 *
 * ═══ ⚠ RESIDUALS, STATED RATHER THAN HIDDEN ═══
 *  R1. **A deal with a null `Property__c` gets no folder and nothing says so.** Identical decision
 *      and identical residual to `PropertyAssetService`: throwing would make a manually created
 *      deal unclosable, and the result fields live on `Property__c`, so a Property-less deal has
 *      nowhere to record a folder. Counted on `runSkippedNoProperty`; recovery query is
 *      `SELECT Id FROM Opportunity WHERE StageName = 'Closed Won' AND Property__c = null`.
 *  R2. **A partial subfolder failure is TERMINAL, not retried.** If the parent folder is created
 *      and a subfolder is refused, the row is stamped `Created` with the missing names in
 *      `SharePoint_Folder_Error__c`. It cannot be auto-retried: the parent id is populated, which
 *      is the idempotency guard, and re-running the six creates under `rename` would produce
 *      "01 - NDA 1". A human creates the missing subfolder by hand from the stored URL.
 *  R3. **If the stamp DML itself fails after a successful callout, the folder exists and Salesforce
 *      does not know its id** — the next sweep creates "Name 1". Unavoidable without a pre-flight
 *      GET by PATH, which re-opens the `EncodingUtil.urlEncode` trap (see the callout service).
 *      Bounded by stamping in the same transaction as the callouts and by `allOrNone = false`.
 *  R4. **A `webUrl` longer than 255 characters is not stored** (the field is `Url`, 255). The id is
 *      still stored, the folder is still `Created`, and the omission is named in the error field.
 *  R5. 🔴 **EVERY DEAL ALREADY AT `Closed Won` ON DEPLOY DAY GETS NO FOLDER — PERMANENTLY, FROM
 *      BOTH PATHS, WITH NOTHING ERRORING. USER DECISION 2026-08-11: OUT OF SCOPE, DOCUMENTED.**
 *      This is the one residual that is invisible from inside the feature, which is why it is
 *      stated at this length rather than in a clause. Two independent mechanisms exclude those
 *      deals and each would be sufficient on its own:
 *        • the TRIGGER keys on stage ENTRY (`prior == null || !CLOSED_WON.equals(prior.StageName)`),
 *          so a deal that was already Closed Won before the deploy never "enters" it again — no
 *          later save of that Opportunity, for any reason, will ever claim its folder;
 *        • the SWEEPER's locator is `SharePoint_Folder_Status__c IN ('Pending','Failed')`
 *          (`PropertySelector.queryFolderSweep`), and only this class writes that field — so a
 *          Property no trigger ever claimed has a NULL status and is not in the sweeper's queue.
 *      The feature therefore applies to deals closing FROM THE DEPLOY FORWARD, and historical
 *      deals are deliberately excluded rather than merely unhandled. There is no error, no counter
 *      and no `Skipped` stamp to find them by: the population is silent by construction, and the
 *      only way to see it is to go looking for it.
 *      **REMEDY, if it is ever wanted — a ONE-OFF anonymous-Apex stamp, never a code change.**
 *      Stamping the backlog `Pending` puts it into the sweeper's existing queue, after which the
 *      deployed batch does the work with no new class and no re-close:
 *        `List<Property__c> backlog = [SELECT Id FROM Property__c WHERE SharePoint_Folder_ID__c = null`
 *        `  AND SharePoint_Folder_Status__c = null AND Id IN`
 *        `  (SELECT Property__c FROM Opportunity WHERE StageName = 'Closed Won' AND Property__c != null)];`
 *        `for (Property__c p : backlog) { p.SharePoint_Folder_Status__c = 'Pending'; }`
 *        `Database.update(backlog, false, AccessLevel.SYSTEM_MODE);`
 *      ⚠ Do it in bounded batches and expect the sweep to take several daily runs to drain: the
 *      sweeper processes `SCOPE` (= `MAX_PROPERTIES_PER_TRANSACTION`) properties per transaction at
 *      seven callouts each, so the backlog's size in properties is the number of transactions it
 *      costs. ⚠ Run it only AFTER `SharePoint_Config__c` is populated — stamping `Pending` while
 *      the integration is disabled just converts the whole backlog to `Skipped` on the next sweep.
 *
 * ⚠ **ONE ASYMMETRY IN `applyStatus` WORTH KNOWING BEFORE ANYONE DEACTIVATES A PICKLIST VALUE.**
 * `applyStatus` writes `SharePoint_Folder_Status__c` only when the value is live on the restricted
 * picklist, so deactivating one silently suppresses that status rather than failing the row. On the
 * ASYNC path that is the right trade and is safe — the folder id and URL are still stamped, so the
 * feature stays idempotent and no folder is ever created twice. On the SYNCHRONOUS path it is NOT
 * safe: `Pending` is the only thing that puts a claimed property into `PropertySelector
 * .queryFolderSweep`'s work queue, so a suppressed `Pending` leaves the row with a null status,
 * invisible to the sweeper FOREVER, with the folder never created and nothing erroring. Deactivating
 * `Pending` or `Failed` therefore disables recovery, not merely reporting.
 *
 * ═══ GOVERNOR BUDGET ═══
 *   SYNCHRONOUS (per trigger chunk):  0 callouts · 1 SOQL · <= 1 DML · <= 1 enqueue,
 *                                     CONSTANT in deal count.
 *                                     A chunk closing nothing costs ZERO of all four.
 *                                     A re-save of already-foldered deals costs 1 SOQL and
 *                                     nothing else — no DML, no enqueue. That is the
 *                                     duplicate-folder falsifier.
 *   ASYNC (per job link):             <= 70 callouts · 1 SOQL · <= 1 DML.
 *
 * @see SharePointCalloutService.cls (the ONLY Http.send; owns the endpoint and conflictBehavior)
 * @see SharePointConfig.cls         (zero-SOQL config; no fallback, ever)
 * @see DealFolderQueueable.cls      (the async venue and the self-chain)
 * @see DealFolderSweepBatch.cls     (recovery — and the credential-grant gap it exists to absorb)
 * @see PropertyAssetService.cls     (the stage-entry precedent, and the deliberate never-throw contrast)
 */
public with sharing class DealFolderService {

    /** The terminal stage that files a deal's documents. Matches `PropertyAssetService.CLOSED_WON`
     *  exactly — stage-ENTRY semantics must not drift between two services on one trigger. */
    @TestVisible private static final String CLOSED_WON = 'Closed Won';

    // ── `Property__c.SharePoint_Folder_Status__c` — a RESTRICTED picklist ────────────────────────
    // Public because `PropertySelector.queryFolderSweep` builds its work queue from two of them;
    // one definition, so the sweeper's queue and the writer's states cannot drift apart.
    /** Owed: the trigger has claimed this property but no folder exists yet. The sweeper's queue. */
    public static final String STATUS_PENDING = 'Pending';
    /** Terminal success: `SharePoint_Folder_ID__c` is populated and authoritative. */
    public static final String STATUS_CREATED = 'Created';
    /** Owed after a failed attempt. Also the sweeper's queue. See the sweep batch for why this
     *  state is the one that absorbs the `DPEG_Transaction_Team` credential gap. */
    public static final String STATUS_FAILED = 'Failed';
    /** Terminal by decision, not by failure: nothing was attempted and nothing will be. */
    public static final String STATUS_SKIPPED = 'Skipped';

    /**
     * 🔴 THE LIFECYCLE SUBFOLDER TREE — Gate-1 decision (ii), overriding design D2's flat
     * recommendation. ORDER IS PART OF THE DECISION: the numeric prefixes are what make SharePoint's
     * alphabetical sort show the deal lifecycle in lifecycle order, so the prefixes are not
     * decoration and must not be dropped "because the list is already ordered here".
     *
     * ⚠ ADDING ONE COSTS A CALLOUT PER DEAL. `CALLOUTS_PER_PROPERTY` is derived from this list's
     * size, so the budget arithmetic follows automatically — but `MAX_PROPERTIES_PER_TRANSACTION`
     * does NOT, and must be re-derived by hand against the class header if this list grows.
     */
    @TestVisible
    private static final List<String> SUBFOLDERS = new List<String>{
        '01 - NDA',
        '02 - LOI',
        '03 - Underwriting',
        '04 - PSA',
        '05 - Due Diligence',
        '06 - Closing'
    };

    /** One parent folder plus one call per subfolder. DERIVED, never hardcoded, so the budget
     *  guard cannot fall out of step with the tree above. */
    @TestVisible private static final Integer CALLOUTS_PER_PROPERTY = 1 + SUBFOLDERS.size();

    /**
     * 🔴 THE CHUNK SIZE — see the class header for the full arithmetic. 10 properties = 70 callouts
     * = 70 % of the 100-per-transaction limit, and ~105 s of the 120 s cumulative callout budget at
     * a pessimistic 1.5 s per Graph call. The count limit alone would permit 14; the TIME limit is
     * what makes 14 unsafe.
     *
     * Shared with `DealFolderSweepBatch.SCOPE` so the batch and the queueable cannot drift into two
     * different budgets for the same seven-callout unit of work.
     */
    public static final Integer MAX_PROPERTIES_PER_TRANSACTION = 10;

    /**
     * Wall-clock ceiling on one transaction's callouts, checked before each property.
     *
     * 90 s of the platform's 120 s cumulative limit. It exists because the callout COUNT is a
     * reliable predictor and the callout TIME is not: a slow tenant, a throttled app registration
     * or a transient Graph incident all consume time without consuming count. Exceeding the
     * platform limit throws an UNCATCHABLE `LimitException`; deferring at 90 s converts that
     * outcome into one more chained link.
     *
     * 🔴 THE 30 s IT LEAVES IS NOT SLACK — IT IS EXACTLY ONE PROPERTY'S WORST CASE, AND
     * `SharePointCalloutService.TIMEOUT_MS` IS DERIVED FROM IT. A property admitted at 89 999 ms
     * runs all seven of its callouts with NO further time check (`createTree` deliberately has no
     * mid-tree guard — abandoning halfway strands an unretriable parent), so the worst case is
     * 7 × TIMEOUT_MS and it must fit inside 120 000 - 90 000. That is why the timeout is 4 000 ms
     * and not a round 15 000: 7 × 15 000 = 105 000 would have overrun the cumulative ceiling by
     * ~75 s. Raising THIS constant shrinks that headroom and requires re-deriving the timeout.
     */
    @TestVisible private static final Integer CALLOUT_TIME_BUDGET_MS = 90000;

    /** `Property__c.SharePoint_Folder_ID__c` is Text(255). */
    private static final Integer MAX_ID_CHARS = 255;
    /** `Property__c.SharePoint_Folder_URL__c` is a `Url` field — 255 characters, no more. A longer
     *  URL is OMITTED rather than truncated: half a URL is worse than none (residual R4). */
    private static final Integer MAX_URL_CHARS = 255;
    /** `Property__c.SharePoint_Folder_Error__c` is Long Text(4096); leave headroom. */
    private static final Integer MAX_ERROR_CHARS = 4000;

    /**
     * Ceiling on a folder name. The REAL bound today is `Property__c.Name`, which is Text(80), so
     * this can never bind — it is a guard against a future widening of that field, and against
     * SharePoint's 400-character full-path ceiling once the longest subfolder segment
     * ("05 - Due Diligence") is appended.
     *
     * ⚠ THE CLAMP RUNS **BEFORE** THE TRAILING-DOT STRIP, deliberately: clamping afterwards could
     * re-introduce a trailing dot at the cut point and produce a name SharePoint rejects.
     */
    @TestVisible private static final Integer MAX_NAME_CHARS = 200;

    /**
     * Names SharePoint/Windows refuse outright. A property whose sanitized name lands on one of
     * these is stamped `Skipped` rather than silently renamed — an invented name would be a folder
     * nobody can find from the property it belongs to.
     */
    private static final Set<String> RESERVED_NAMES = new Set<String>{
        '.', '..', '.LOCK', 'DESKTOP.INI', 'CON', 'PRN', 'AUX', 'NUL',
        'COM0', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT0', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    };

    /**
     * Stamped when the property's name cannot yield a usable folder name at all.
     *
     * 🔴 THE RECOVERY SENTENCE NAMES THE ONLY ACTION THAT WORKS, AND IT IS NEITHER OF THE TWO A
     * READER WOULD REACH FOR FIRST. The sweeper's locator is `SharePoint_Folder_Status__c IN
     * ('Pending','Failed')` (`PropertySelector.folderSweepLocator`), so `Skipped` and NULL are both
     * permanently OUTSIDE it — clearing the status moves the row from one excluded state to another
     * and hides it forever. And re-saving the deal is dead too: the trigger keys on stage ENTRY, so
     * a deal already at `Closed Won` never enters it again (residual R5, above). Setting the status
     * to `Pending` is the one action that puts the row back in the queue.
     */
    @TestVisible private static final String REASON_UNNAMABLE =
        'SKIPPED: this property\'s Name contains nothing SharePoint accepts as a folder name '
        + '(after removing " * : < > ? / \\ | and control characters, trimming, and rejecting '
        + 'reserved names, nothing usable remained). TO RECOVER: rename the property, then set '
        + 'SharePoint_Folder_Status__c to Pending on this record — that is the ONLY action that '
        + 'returns it to the daily sweep. Re-saving the closed deal will NOT retry it (the trigger '
        + 'fires on stage entry only), and CLEARING this status hides the record from the sweep '
        + 'permanently.';

    /**
     * 🔴 THE CREDENTIAL-GRANT HINT, APPENDED TO EVERY AUTHENTICATION-SHAPED FAILURE.
     *
     * This is not generic helpfulness — it names a KNOWN, PRESENT gap. External Credential
     * Principal Access is evaluated against the ENQUEUING user (measured live: a Queueable reports
     * `RAN AS USERNAME: usman.khan.dpeg@...`, not Automated Process), and
     * `SharePoint_Integration_Access` has been granted to `DPEG_Junior_Analyst_PSG` ONLY. The
     * `Transaction_Complete_Close` flow writes `StageName = 'Closed Won'` with no `<runInMode>`,
     * i.e. as the TRANSACTIONS persona — so every deal closed by that route runs this job as a user
     * with no grant, and every callout is refused. Those deals are SUPPOSED to land here, visibly,
     * and be recovered by the sweep running as a granted principal.
     */
    @TestVisible private static final String HINT_CREDENTIAL =
        ' | LIKELY CAUSE: the user whose save closed this deal has no access to the SharePoint '
        + 'external credential. SharePoint_Integration_Access is granted to '
        + 'DPEG_Junior_Analyst_PSG only, and a deal closed through the Transaction_Complete_Close '
        + 'flow runs as the Transactions persona. This is EXPECTED and RECOVERABLE: the scheduled '
        + 'DealFolderSweepBatch retries this row as its own (granted) scheduling principal. If the '
        + 'sweep is not scheduled, nothing will retry it.';

    /** Header line on the durable failure text, so a human reading `Property__c` knows what failed
     *  without opening a log. */
    @TestVisible private static final String PREFIX_FAILED =
        'FAILED to create the SharePoint deal folder: ';

    /** Copy for residual R2 — the parent exists, some subfolders do not, and nothing will retry. */
    @TestVisible private static final String PREFIX_PARTIAL =
        'The deal folder was created, but these subfolders were NOT (create them by hand from the '
        + 'folder URL — an automatic retry would produce duplicates such as "01 - NDA 1"): ';

    // ═════════════════════════════════════════════════════════════════════════════════════════════
    // RUN COUNTERS — test instrumentation, following `PropertyAssetService`.
    //
    // They record MEASURED limit consumption (`Limits` deltas) rather than a hand-maintained tally
    // of the statements written here: a hand tally asserts the code back to itself and cannot see a
    // query added inside a selector. Cumulative across every invocation in the transaction, so a
    // 251-record bulk close — TWO trigger chunks — is expected to read `runInvocations = 2`,
    // `runQueryCount = 2`, `runEnqueueCount = 2`.
    //
    // ⚠ `runCalloutCount` is incremented INSIDE the async transaction on purpose. Asserting callout
    // counts on `Limits.*` after `Test.stopTest()` is silently vacuous — stopTest restores the
    // pre-test counters (the `ExtractAddressQueueable.lastRunQueryCount` precedent).
    // ═════════════════════════════════════════════════════════════════════════════════════════════

    /** Times either entry point was called, including no-op chunks. */
    @TestVisible private static Integer runInvocations = 0;
    /** SOQL queries actually consumed, measured via `Limits`. */
    @TestVisible private static Integer runQueryCount = 0;
    /** DML statements actually consumed, measured via `Limits`. */
    @TestVisible private static Integer runDmlCount = 0;
    /** Async jobs enqueued by the SYNCHRONOUS path. Must be one per trigger chunk, never per deal. */
    @TestVisible private static Integer runEnqueueCount = 0;
    /** HTTP callouts made. 🔴 The duplicate-folder falsifier asserts this is ZERO on a re-run. */
    @TestVisible private static Integer runCalloutCount = 0;
    /** Deals that entered Closed Won carrying no `Property__c` (residual R1). */
    @TestVisible private static Integer runSkippedNoProperty = 0;
    /** Properties whose Name could not yield a usable folder name. */
    @TestVisible private static Integer runSkippedUnnamable = 0;
    /** Properties skipped because the integration is off or unconfigured. */
    @TestVisible private static Integer runSkippedDisabled = 0;
    /** Parent folders successfully created. */
    @TestVisible private static Integer runFoldersCreated = 0;
    /** Subfolders successfully created. Expected to be 6 × runFoldersCreated. */
    @TestVisible private static Integer runSubfoldersCreated = 0;
    /** Properties whose PARENT folder callout failed. */
    @TestVisible private static Integer runFailures = 0;
    /** Properties left for the next chained link or the next sweep because the budget ran out. */
    @TestVisible private static Integer runDeferred = 0;

    /** Active `SharePoint_Folder_Status__c` values, cached per transaction — the picklist cannot
     *  change inside one, and a describe per stamp would be pointless work. */
    private static Set<String> activeStatusesCache;

    /** Zeroes every counter. Test-only; each test asserting a budget calls it first. */
    @TestVisible
    private static void resetRunCounters() {
        runInvocations = 0;
        runQueryCount = 0;
        runDmlCount = 0;
        runEnqueueCount = 0;
        runCalloutCount = 0;
        runSkippedNoProperty = 0;
        runSkippedUnnamable = 0;
        runSkippedDisabled = 0;
        runFoldersCreated = 0;
        runSubfoldersCreated = 0;
        runFailures = 0;
        runDeferred = 0;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════
    // SYNCHRONOUS PATH — called from OpportunityReviewTriggerHandler. ZERO CALLOUTS.
    // ═════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Claim a SharePoint deal folder for every deal that just ENTERED `Closed Won`, and enqueue the
     * ONE job that creates them.
     *
     * Stage-ENTRY, not stage-IS: a deal already at Closed Won that is re-saved for any other reason
     * does nothing. On insert (`oldMap == null`) a record created directly at Closed Won counts as
     * entering — the same reading `PropertyAssetService.ensureOnClosedWon` and
     * `ContractExecutionService.openTransactionsOnAboutToClose` use, and the shape data loads and
     * migrations arrive in.
     *
     * 🔴 IT CANNOT THROW A CATCHABLE EXCEPTION. Every path is inside the catch below; the ONE
     * uncatchable path — `System.enqueueJob`'s `LimitException` — is bounded by an explicit limit
     * guard at the enqueue site instead (see the class header). A swallowed failure and a skipped
     * enqueue are both survivable for the same reason: the `Pending` stamp is written BEFORE the
     * enqueue, so the scheduled sweep recovers anything this transaction failed to start. See the
     * class header for why "place it last in the handler" is not a substitute for this.
     *
     * @param newOpps Trigger.new.
     * @param oldMap  Trigger.oldMap on update; null on insert.
     * @example
     * DealFolderService.ensureOnClosedWon(opps, priorById);
     */
    public static void ensureOnClosedWon(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        runInvocations++;
        try {
            claimFolders(newOpps, oldMap);
        } catch (Exception e) {
            // 🔴 The whole point of this class. A SharePoint problem must never cost a deal close.
            System.debug(LoggingLevel.ERROR,
                'DealFolderService.ensureOnClosedWon: swallowed ' + e.getTypeName() + ' | '
                + e.getMessage() + ' | any claimed property stays Pending for DealFolderSweepBatch.');
        }
        runQueryCount += Limits.getQueries() - queriesBefore;
        runDmlCount += Limits.getDmlStatements() - dmlBefore;
    }

    /**
     * The synchronous work: detect, guard, read, stamp, enqueue. Bulk-safe and CONSTANT in deal
     * count — one selector call, one bulk DML, one enqueue, nothing inside a loop.
     *
     * 🔴 A DEAL WITH A NULL `Property__c` IS SKIPPED (residual R1). Only `LeadConvertService`
     * creates a `Property__c`, so a manually built deal has none. Throwing would make such a deal
     * unclosable — an existing legitimate workflow made impossible, which is worse than a missing
     * folder — and there is nowhere to record the result, because all four result fields live on
     * `Property__c`.
     *
     * @param newOpps Trigger.new.
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    private static void claimFolders(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> propertyIds = enteringPropertyIds(newOpps, oldMap);
        if (propertyIds.isEmpty()) {
            return; // zero SOQL, zero DML, zero enqueues — the cost of an unrelated Opportunity save
        }

        // SOQL 1 of 1. The idempotency guard, read once for the whole chunk.
        List<Property__c> rows = PropertySelector.selectFolderStateByIds(propertyIds);
        Boolean ready = SharePointConfig.isReady();
        String targetStatus = ready ? STATUS_PENDING : STATUS_SKIPPED;
        String disabledReason = ready ? null : SharePointConfig.unavailableReason();

        List<Property__c> stamps = new List<Property__c>();
        List<Id> owed = new List<Id>();
        for (Property__c p : rows) {
            if (String.isNotBlank(p.SharePoint_Folder_ID__c)) {
                // Already has a folder. Converge a stale status, but never re-claim it: this is the
                // branch that makes a re-close of an already-foldered deal cost zero callouts and
                // zero enqueues.
                if (!STATUS_CREATED.equals(p.SharePoint_Folder_Status__c)) {
                    stamps.add(statusOnly(p.Id, STATUS_CREATED, null));
                }
                continue;
            }
            if (!ready) {
                runSkippedDisabled++;
                if (!STATUS_SKIPPED.equals(p.SharePoint_Folder_Status__c)) {
                    stamps.add(statusOnly(p.Id, targetStatus, disabledReason));
                }
                continue;
            }
            owed.add(p.Id);
            if (!STATUS_PENDING.equals(p.SharePoint_Folder_Status__c)) {
                stamps.add(statusOnly(p.Id, STATUS_PENDING, null));
            }
        }

        // DML 1 of 1, and only when something actually changes.
        stampAll(stamps);

        if (owed.isEmpty()) {
            return; // nothing owed -> no job. The duplicate-folder falsifier lands here.
        }
        // ONE enqueue per trigger chunk. NEVER one per deal: a 200-deal chunk enqueuing per record
        // would throw at the 50-job limit and roll back the close.
        //
        // 🔴 THE GUARD IS LOAD-BEARING, NOT DEFENSIVE BOILERPLATE — it is the ONLY thing standing
        // between this feature and a rolled-back deal close. `System.enqueueJob` raises
        // `System.LimitException` at the 50-per-transaction cap, and SP-R1 measured that an Apex
        // limit exception of that family is NOT caught by `catch (Exception)` — so the try/catch in
        // `ensureOnClosedWon` above does NOT cover this statement, and an unconditional enqueue
        // would take the whole Closed Won transaction down with it. This chunk contributes only one
        // enqueue, but nothing guarantees it is the first: unrelated automation on the same
        // transaction (Broker Protection, the EAC pipeline, a future stage-entry service) may have
        // consumed the slots before this line is reached.
        //
        // 🔴 SKIPPING IS SAFE; THROWING NEVER IS. Every owed property was stamped `Pending` by
        // `stampAll` ABOVE this line, and `Pending` is `DealFolderSweepBatch`'s work queue — so a
        // skipped enqueue costs the folder its latency, not its existence, and the scheduled sweep
        // creates it on the next run with no human involvement and no re-close. This is the same
        // trade `EmailMessageTriggerHandler` records for the EAC pipeline and ARCHITECTURE.md §2
        // states for it: "skipping is always safe because the guard is self-healing; throwing never
        // is." Do not "tighten" this into an unconditional enqueue.
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DealFolderQueueable(owed));
            runEnqueueCount++;
        }
    }

    /**
     * The distinct Property Ids of every deal in this chunk that JUST ENTERED `Closed Won`.
     *
     * Keying on distinct properties DEDUPES for free: two Opportunities closing against one property
     * yield one Id, which is what makes "two deals on one property share one folder" fall out of the
     * collection rather than out of a later check.
     *
     * @param newOpps Trigger.new.
     * @param oldMap  Trigger.oldMap on update; null on insert.
     * @return The property Ids to claim; empty when nothing entered the stage.
     */
    private static Set<Id> enteringPropertyIds(
        List<Opportunity> newOpps,
        Map<Id, Opportunity> oldMap
    ) {
        Set<Id> propertyIds = new Set<Id>();
        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            Boolean justEntered = CLOSED_WON.equals(o.StageName)
                && (prior == null || !CLOSED_WON.equals(prior.StageName));
            if (!justEntered) {
                continue;
            }
            if (o.Property__c == null) {
                runSkippedNoProperty++;   // residual R1 — no folder, and nothing says so
                continue;
            }
            propertyIds.add(o.Property__c);
        }
        return propertyIds;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════
    // ASYNCHRONOUS PATH — called from DealFolderQueueable and DealFolderSweepBatch ONLY.
    // ═════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Create the folder tree for up to `MAX_PROPERTIES_PER_TRANSACTION` properties and stamp the
     * results, returning whatever the transaction's callout budget could not reach.
     *
     * 🔴 CALL THIS FROM AN ASYNC CONTEXT ONLY. It makes up to 70 HTTP callouts; invoking it from a
     * trigger would both exceed the synchronous budget and attempt a callout with uncommitted DML.
     *
     * The idempotency guard is re-evaluated HERE, in the same transaction as the callouts, which is
     * what makes a concurrent second close, a chained continuation and a sweep retry all converge on
     * one folder.
     *
     * ⚠ IT IS FAIL-SOFT PER PROPERTY, NOT PER TRANSACTION. One property's failure is stamped and the
     * loop continues; an unexpected structural failure is deliberately NOT swallowed, so the
     * queueable's Finalizer records it and the sweep recovers the rows.
     *
     * @param propertyIds The properties owed a folder, in the order they should be served; null and
     *                    empty are safe.
     * @return The Ids NOT attempted in this transaction, in order — hand these to the next chained
     *         link. Empty when everything was reached. Never null.
     * @example
     * List<Id> remaining = DealFolderService.createFolders(propertyIds);
     */
    public static List<Id> createFolders(List<Id> propertyIds) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        runInvocations++;
        List<Id> deferred = new List<Id>();
        try {
            deferred = buildFolderTrees(propertyIds);
        } finally {
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
        return deferred;
    }

    /**
     * The async work. One selector read, a bounded callout loop, one bulk stamp.
     *
     * @param propertyIds The properties owed a folder.
     * @return The Ids left for the next link.
     */
    private static List<Id> buildFolderTrees(List<Id> propertyIds) {
        List<Id> deferred = new List<Id>();
        if (propertyIds == null || propertyIds.isEmpty()) {
            return deferred;
        }
        if (!SharePointConfig.isReady()) {
            // Config was switched off between the claim and the job. Stamp Skipped and stop —
            // never guess a site id (design D7).
            skipAllAsDisabled(propertyIds);
            return deferred;
        }

        // SOQL 1 of 1 — the idempotency guard, evaluated in the callout transaction.
        Map<Id, Property__c> rowsById = new Map<Id, Property__c>(
            PropertySelector.selectFolderStateByIds(new Set<Id>(propertyIds)));

        LibraryTarget target = new LibraryTarget();
        Long startedMs = System.currentTimeMillis();

        List<Property__c> stamps = new List<Property__c>();
        Integer attempted = 0;
        for (Id propertyId : propertyIds) {
            Property__c p = rowsById.get(propertyId);
            if (p == null) {
                // Hard-deleted between the claim and the job. Nothing to stamp and nothing to name.
                continue;
            }
            if (String.isNotBlank(p.SharePoint_Folder_ID__c)) {
                // 🔴 ZERO CALLOUTS. This branch is what makes the sweep convergent and re-running
                // free, and it is why a Failed row that actually succeeded settles to Created.
                if (!STATUS_CREATED.equals(p.SharePoint_Folder_Status__c)) {
                    stamps.add(statusOnly(p.Id, STATUS_CREATED, null));
                }
                continue;
            }
            String safeName = sanitizeFolderName(p.Name);
            if (String.isBlank(safeName)) {
                runSkippedUnnamable++;
                stamps.add(statusOnly(p.Id, STATUS_SKIPPED, REASON_UNNAMABLE));
                continue;
            }
            if (attempted >= MAX_PROPERTIES_PER_TRANSACTION || !hasBudgetForOneProperty(startedMs)) {
                // Leave it exactly as it is — Pending — and hand it to the next link.
                runDeferred++;
                deferred.add(propertyId);
                continue;
            }
            attempted++;
            try {
                stamps.add(createTree(target, p, safeName));
            } catch (Exception e) {
                // Per-property fail-soft: one bad property must not cost the other nine their
                // stamps, and their folders may already exist in SharePoint by now.
                runFailures++;
                stamps.add(statusOnly(p.Id, STATUS_FAILED,
                    PREFIX_FAILED + e.getTypeName() + ' | ' + e.getMessage()));
            }
        }

        // DML 1 of 1. SYSTEM_MODE because no persona reaching Closed Won necessarily holds Edit on
        // Property__c and the four fields have no FLS for anyone; allOrNone = false because a
        // failed stamp must never take down the stamps of properties whose folders DID get created.
        stampAll(stamps);
        return deferred;
    }

    /**
     * Create one property's folder tree: the parent, then the six lifecycle subfolders beneath it.
     * Exactly `CALLOUTS_PER_PROPERTY` callouts on the success path, one on the parent-failure path.
     *
     * ⚠ THE SUBFOLDER LOOP HAS NO BUDGET GUARD, AND THAT IS CORRECT. `hasBudgetForOneProperty`
     * reserved all seven callouts BEFORE the parent was created; abandoning halfway would leave a
     * parent folder that can never be completed (its id is the idempotency guard, so nothing retries
     * it) — strictly worse than one extra second of callout time.
     *
     * @param target   The resolved library destination and its callout service.
     * @param p        The property row, carrying Id and the current status.
     * @param safeName The sanitized folder name.
     * @return The stamp record for this property — `Created` (possibly with a partial-failure note)
     *         or `Failed`.
     */
    private static Property__c createTree(LibraryTarget target, Property__c p, String safeName) {
        SharePointCalloutService.FolderResult parent = target.createRoot(safeName);
        runCalloutCount++;
        if (!parent.isSuccess()) {
            runFailures++;
            return statusOnly(p.Id, STATUS_FAILED, failureText(parent));
        }
        runFoldersCreated++;

        List<String> missing = new List<String>();
        for (String subfolder : SUBFOLDERS) {
            SharePointCalloutService.FolderResult child =
                target.createChild(parent.itemId, subfolder);
            runCalloutCount++;
            if (child.isSuccess()) {
                runSubfoldersCreated++;
            } else {
                missing.add(subfolder + ' [HTTP ' + child.statusCode + ': '
                    + child.errorMessage + ']');
            }
        }

        Property__c stamp = new Property__c(Id = p.Id);
        stamp.SharePoint_Folder_ID__c = clip(parent.itemId, MAX_ID_CHARS);
        // Residual R4 — a Url field is 255 characters and a truncated URL is worse than none.
        List<String> notes = new List<String>();
        if (String.isNotBlank(parent.webUrl) && parent.webUrl.length() <= MAX_URL_CHARS) {
            stamp.SharePoint_Folder_URL__c = parent.webUrl;
        } else if (String.isNotBlank(parent.webUrl)) {
            notes.add('The folder URL was too long for the 255-character URL field and was not '
                + 'stored. Locate the folder by its id: ' + parent.itemId);
        }
        if (!missing.isEmpty()) {
            notes.add(PREFIX_PARTIAL + String.join(missing, '; '));
        }
        applyStatus(stamp, STATUS_CREATED);
        stamp.SharePoint_Folder_Error__c =
            notes.isEmpty() ? null : clip(String.join(notes, ' — '), MAX_ERROR_CHARS);
        return stamp;
    }

    /**
     * Record a failure against a set of properties that were mid-flight when their job died.
     * Called by `DealFolderFinalizer` from its OWN transaction, after the parent's DML has already
     * rolled back.
     *
     * 🔴 IT RE-READS BEFORE IT WRITES, and that is not caution. The Finalizer receives the job's
     * whole payload, but an earlier chained LINK may already have committed a folder id for some of
     * those properties. Stamping `Failed` over a committed `Created` would put a property that
     * already has a folder back into the sweep's work queue — where the guard would find the id,
     * find nothing to do, and settle it to `Created` again. Reading first skips the pointless
     * round trip and keeps the durable error text on the rows it actually describes.
     *
     * Fail-soft: a failure to record a failure must never become a second failure (the
     * `AttachmentPersistFinalizer` / `RoutingFailureFinalizer` contract).
     *
     * @param propertyIds The job's payload; null/empty-safe.
     * @param message     Human-readable failure text, already naming the exception and the job Id.
     * @example
     * DealFolderService.markFailed(propertyIds, 'Job died: ' + ctx.getException().getMessage());
     */
    public static void markFailed(List<Id> propertyIds, String message) {
        if (propertyIds == null || propertyIds.isEmpty()) {
            return;
        }
        try {
            List<Property__c> stamps = new List<Property__c>();
            for (Property__c p : PropertySelector.selectFolderStateByIds(new Set<Id>(propertyIds))) {
                if (String.isNotBlank(p.SharePoint_Folder_ID__c)) {
                    if (!STATUS_CREATED.equals(p.SharePoint_Folder_Status__c)) {
                        stamps.add(statusOnly(p.Id, STATUS_CREATED, null));
                    }
                    continue;
                }
                stamps.add(statusOnly(p.Id, STATUS_FAILED, PREFIX_FAILED + message));
            }
            stampAll(stamps);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'DealFolderService.markFailed: could not record the failure: '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * Stamp every property `Skipped` because the integration is off or unconfigured, and make no
     * callout at all.
     *
     * 🔴 It is reachable from the ASYNC path even when the synchronous claim found the config
     * healthy — an admin can disable the setting between the close and the job, or between the
     * claim and a sweep days later. The response is the same in both places and for the same
     * reason: NEVER guess a site id (design D7). A `Skipped` row is recoverable — by re-enabling
     * the setting AND THEN SETTING `SharePoint_Folder_Status__c` BACK TO `Pending`; a folder
     * written to a guessed library is not.
     *
     * ⚠ THAT SECOND STEP IS NOT OPTIONAL AND IS NOT "CLEARING THE STATUS". `PropertySelector
     * .folderSweepLocator` reads `SharePoint_Folder_Status__c IN ('Pending','Failed')`, so `Skipped`
     * and NULL are both permanently outside the sweeper's queue: blanking the field moves the row
     * from one excluded state to another and it is never seen again. `Pending` is the only value
     * that re-queues it, which is why `SharePointConfig.REASON_DISABLED` / `REASON_NO_SITE` — the
     * copy this method stamps — say so explicitly.
     *
     * @param propertyIds The properties to stand down; never null/empty (the caller guards it).
     */
    private static void skipAllAsDisabled(List<Id> propertyIds) {
        List<Property__c> stamps = new List<Property__c>();
        String reason = SharePointConfig.unavailableReason();
        for (Id propertyId : propertyIds) {
            runSkippedDisabled++;
            stamps.add(statusOnly(propertyId, STATUS_SKIPPED, reason));
        }
        stampAll(stamps);
    }

    /**
     * The resolved SharePoint destination for this transaction, plus the callout service that
     * writes to it.
     *
     * It exists so the three configuration values are read ONCE per transaction rather than
     * threaded through every method as parameters, and so the call sites read as
     * `createRoot(name)` / `createChild(parentId, name)` — which is the distinction that actually
     * matters when auditing the callout budget, rather than "which of these six arguments is the
     * parent?".
     *
     * ⚠ It holds no per-property state, so one instance serves the whole chunk.
     */
    private class LibraryTarget {
        private final String siteId;
        private final String driveId;
        private final String rootParentId;
        private final SharePointCalloutService callouts;

        /** Resolve the destination once. Zero SOQL — see `SharePointConfig`. */
        private LibraryTarget() {
            this.siteId = SharePointConfig.siteId();
            this.driveId = SharePointConfig.driveId();
            this.rootParentId = SharePointConfig.parentFolderId();
            this.callouts = new SharePointCalloutService();
        }

        /**
         * Create a deal folder at the configured top level — the library ROOT unless
         * `Parent_Folder_ID__c` is populated.
         *
         * @param name The sanitized folder name.
         * @return The typed callout outcome; never null, never thrown.
         */
        private SharePointCalloutService.FolderResult createRoot(String name) {
            return callouts.createFolder(siteId, driveId, rootParentId, name);
        }

        /**
         * Create one lifecycle subfolder beneath a deal folder, addressed BY ITEM ID (never by
         * path — see `SharePointCalloutService`'s header for the encoding trap that avoids).
         *
         * @param parentItemId The deal folder's Graph item id.
         * @param name         The subfolder name.
         * @return The typed callout outcome; never null, never thrown.
         */
        private SharePointCalloutService.FolderResult createChild(String parentItemId, String name) {
            return callouts.createFolder(siteId, driveId, parentItemId, name);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════
    // FOLDER NAMING — a PURE function. No SOQL, no DML, no describe, no clock.
    // ═════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Turn a `Property__c.Name` into a name SharePoint will accept, or return '' when it cannot.
     *
     * 🔴 THIS IS REACHABLE, NOT HYPOTHETICAL. `LeadConvertService` builds `Property__c.Name` from
     * LLM-extracted MARKETING TEXT — "1400 Royal Ln / Suite B", "Portfolio: 3 Assets", "N/A" — so
     * an illegal character is an ordinary Tuesday, not an attack. The seeded DPEG names are benign,
     * which is exactly why this is easy to under-test.
     *
     * ORDER MATTERS AND IS DELIBERATE:
     *   1. control characters (0x00-0x1F, 0x7F) -> space  (invisible, and SharePoint refuses them)
     *   2. the illegal set " * : &lt; &gt; ? / \ |         -> space  (replaced, not deleted, so
     *      "Royal Ln/Suite B" reads as two words rather than one)
     *   3. collapse whitespace runs and trim              (steps 1-2 create runs)
     *   4. strip a leading "~$"                           (SharePoint refuses that prefix outright)
     *   5. clamp to MAX_NAME_CHARS
     *   6. strip trailing dots and spaces                 (AFTER the clamp — see MAX_NAME_CHARS)
     *   7. reject reserved names                          (CON, NUL, .lock, desktop.ini, ...)
     *
     * A name that reduces to nothing is NOT invented: the caller stamps `Skipped` with a reason, so
     * a human renames the property. A fabricated name would be a folder nobody could trace back.
     *
     * @param rawName The property name; null/blank-safe.
     * @return A SharePoint-legal folder name, or '' when no usable name survives. Never null.
     * @example
     * String safe = DealFolderService.sanitizeFolderName('  1400 Royal Ln / Suite B... ');
     * // -> '1400 Royal Ln Suite B'
     */
    public static String sanitizeFolderName(String rawName) {
        if (String.isBlank(rawName)) {
            return '';
        }
        String cleaned = rawName.replaceAll('[\\x00-\\x1F\\x7F]', ' ');
        cleaned = cleaned.replaceAll('["*:<>?/\\\\|]', ' ');
        cleaned = cleaned.replaceAll('\\s+', ' ').trim();

        while (cleaned.startsWith('~$')) {
            cleaned = cleaned.substring(2).trim();
        }
        if (cleaned.length() > MAX_NAME_CHARS) {
            cleaned = cleaned.substring(0, MAX_NAME_CHARS).trim();
        }
        while (cleaned.length() > 0 && (cleaned.endsWith('.') || cleaned.endsWith(' '))) {
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }
        if (String.isBlank(cleaned) || RESERVED_NAMES.contains(cleaned.toUpperCase())) {
            return '';
        }
        if (cleaned.toLowerCase().startsWith('_vti_')) {
            return '';
        }
        return cleaned;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════
    // INTERNALS
    // ═════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Whether this transaction can still afford one whole property (seven callouts).
     *
     * BOTH limits are checked because they fail differently and neither predicts the other: the
     * COUNT is deterministic, the TIME is a property of the tenant. Each throws an UNCATCHABLE
     * `LimitException` when breached, so both are checked BEFORE the parent folder is created
     * rather than between subfolders.
     *
     * @param startedMs `System.currentTimeMillis()` captured before the first callout.
     * @return true when both the callout count and the wall clock leave room for a whole property.
     */
    private static Boolean hasBudgetForOneProperty(Long startedMs) {
        if (Limits.getLimitCallouts() - Limits.getCallouts() < CALLOUTS_PER_PROPERTY) {
            return false;
        }
        return (System.currentTimeMillis() - startedMs) < CALLOUT_TIME_BUDGET_MS;
    }

    /**
     * A status-and-reason-only stamp record.
     *
     * @param propertyId The property to stamp.
     * @param status     One of the four `STATUS_*` values.
     * @param reason     Durable human-readable text, or null to clear the field.
     * @return The unsaved stamp record.
     */
    private static Property__c statusOnly(Id propertyId, String status, String reason) {
        Property__c stamp = new Property__c(Id = propertyId);
        applyStatus(stamp, status);
        stamp.SharePoint_Folder_Error__c = clip(reason, MAX_ERROR_CHARS);
        return stamp;
    }

    /**
     * Write the status only when it is a LIVE value on the restricted picklist.
     *
     * ⚠ `SharePoint_Folder_Status__c` is `<restricted>true</restricted>`, so an off-list value
     * raises `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` and FAILS THAT ROW's update — which, on the
     * async path, would silently discard the folder id of a folder that was just created. Guarding
     * at the source is the same discipline `LeadConvertService` applies to its restricted-picklist
     * writes and `PropertyAssetService` applies to `Property_Type__c`; a `getDescribe()` is a
     * describe, not a query, so it costs no SOQL.
     *
     * If the value is not live the record still carries its id, url and error text — losing the
     * status is far better than losing the id.
     *
     * @param stamp  The stamp record to modify in place.
     * @param status The desired status.
     */
    private static void applyStatus(Property__c stamp, String status) {
        if (String.isNotBlank(status) && activeStatusValues().contains(status)) {
            stamp.SharePoint_Folder_Status__c = status;
        }
    }

    /**
     * The live, active values of `SharePoint_Folder_Status__c`, cached for the transaction.
     *
     * ⚠ THERE IS NO try/catch HERE ON PURPOSE, AND THE JAVADOC USED TO CLAIM OTHERWISE. A field
     * token's `getDescribe()` is resolved at COMPILE time and does not throw at runtime, so a
     * "describe failure" is not a state this method can be in — a catch would be unreachable code
     * and an unreachable branch cannot be honestly tested. The set is therefore empty only if the
     * picklist itself has no active values, in which case `applyStatus` becomes a no-op (the row
     * keeps its id, url and error text and loses only its status) rather than a row-level
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` failure. The consequences of that suppression are
     * in the class header — they are NOT symmetric between the async and synchronous paths.
     *
     * @return The active picklist values; never null. Empty only when the picklist has no active
     *         values at all.
     */
    private static Set<String> activeStatusValues() {
        if (activeStatusesCache != null) {
            return activeStatusesCache;
        }
        Set<String> live = new Set<String>();
        for (Schema.PicklistEntry entry
                : Property__c.SharePoint_Folder_Status__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                live.add(entry.getValue());
            }
        }
        activeStatusesCache = live;
        return activeStatusesCache;
    }

    /**
     * The durable failure text for a refused parent-folder callout, with the credential hint
     * appended for the authentication-shaped statuses.
     *
     * Status 0 means no HTTP exchange completed at all, which is what a missing External Credential
     * Principal Access looks like from Apex; 401/403 are the same class of problem one layer out.
     *
     * @param result The failed callout result.
     * @return Text bounded to the Long Text field's capacity.
     */
    private static String failureText(SharePointCalloutService.FolderResult result) {
        String text = PREFIX_FAILED + 'HTTP ' + result.statusCode + ' — ' + result.errorMessage;
        Integer status = (result.statusCode == null) ? 0 : result.statusCode;
        if (status == 0 || status == 401 || status == 403) {
            text += HINT_CREDENTIAL;
        }
        return clip(text, MAX_ERROR_CHARS);
    }

    /**
     * The one stamp statement. `AccessLevel.SYSTEM_MODE` because the personas that reach Closed Won
     * may hold no Edit on `Property__c` and the four fields have no FLS for anyone;
     * `allOrNone = false` because a failed stamp must never take anything else down.
     *
     * A no-op when nothing changed, which is what keeps the re-save path at zero DML.
     *
     * 🔴 THE PER-ROW FAILURES ARE LOGGED BECAUSE A LOST STAMP IS RESIDUAL R3 VERBATIM, NOT MERELY
     * A MISSED FIELD WRITE. `allOrNone = false` means one refused row is dropped silently; on the
     * ASYNC path that row's folder ALREADY EXISTS in SharePoint, so losing its `Created` stamp
     * leaves Salesforce unable to name a folder it just made — and the next sweep, running under
     * `conflictBehavior: rename`, mints "<Name> 1", the outcome this feature treats as the worst
     * available. Without this loop there is no trace of it anywhere.
     *
     * ⚠ It logs and does not throw, and does not tighten `allOrNone`: both would trade a diagnosable
     * duplicate for a rolled-back Closed Won, which the never-throw rule in the class header forbids.
     * Diagnostics only.
     *
     * @param stamps The records to write; null/empty-safe.
     */
    private static void stampAll(List<Property__c> stamps) {
        if (stamps == null || stamps.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results =
            Database.update(stamps, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<Database.Error> errors = results[i].getErrors();
            String detail = errors.isEmpty()
                ? 'no error detail returned'
                : errors[0].getStatusCode() + ' | ' + errors[0].getMessage();
            System.debug(LoggingLevel.ERROR,
                'DealFolderService.stampAll: LOST STAMP on Property__c ' + stamps[i].Id + ' -> '
                + detail + ' | if this row\'s folder was just created, its id is now unrecorded '
                + '(residual R3) and the next sweep will mint a renamed duplicate.');
        }
    }

    /**
     * Bound a string to a field's capacity.
     *
     * @param value The text; null-safe.
     * @param max   Maximum length.
     * @return The bounded value, or null when the input was null (so a caller can clear a field).
     */
    private static String clip(String value, Integer max) {
        if (value == null) {
            return null;
        }
        return (value.length() <= max) ? value : value.substring(0, max);
    }
}
