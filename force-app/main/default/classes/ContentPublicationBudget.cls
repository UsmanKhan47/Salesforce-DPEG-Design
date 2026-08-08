/**
 * ContentPublication quota BACKSTOP for the inbound broker-email file pipeline — the L4
 * (reactive circuit breaker) and L5 (predictive daily budget) layers of design §6.
 *
 * ═══ READ THIS FIRST: WHAT THIS CLASS IS AND IS NOT ═══
 * It is NOT the answer to the 2026-08-06 outage. The answer to that is STRUCTURAL and lives in
 * `AttachmentPersistQueueable`'s existence: a `ContentVersion` insert must never sit in a
 * transaction whose rollback would lose something irreplaceable. Once that holds, hitting the
 * quota costs a DEFERRED FILE — the bytes stay on the staging row as a classic `Attachment` and
 * the sweeper retries them — rather than an email, a Lead or a registry claim.
 *
 * This class only makes hitting the quota LESS LIKELY and its aftermath quieter. It cannot make
 * it impossible, and it must never be described as if it could:
 *
 *   • Apex `Limits` exposes NO `ContentPublicationLimit` (measured, M4) — there is no counter to
 *     read.
 *   • 🔴 The REST `/limits` reading for this limit is MEASURABLY STALE AND NON-MONOTONIC
 *     (SP-6): one insert's cost was invisible across four consecutive settled reads, and two
 *     reads once moved UPWARD with no publish in between. So even an advisory check would be
 *     actively misleading, on top of being prohibited by ARCHITECTURE.md §3.1 (ASB-only) and
 *     `.claude/rules/content-publication-rule.md`. **Do not add one.**
 *   • The quota is org-wide and shared with every test run and every deploy's `RunLocalTests`,
 *     and test rollback does NOT refund it (M7). A self-maintained counter cannot see any of
 *     that and will therefore ALWAYS undercount.
 *
 * That permanent undercount is exactly why `DAILY_PUBLICATION_BUDGET` sits 1,500 below the cap
 * rather than at it.
 *
 * ═══ 🔴 IT DEGRADES TO "PERMITTED", DELIBERATELY ═══
 * Every public method swallows its own failures and every read failure resolves to "publishing
 * is allowed". A backstop that BLOCKS the feature when the backstop itself malfunctions is
 * strictly worse than no backstop, because layers L1 (isolation) and L2 (recoverability) have
 * already made a quota hit non-fatal. Fail-open here, never fail-closed.
 *
 * ═══ STORAGE — the FIRST hierarchy Custom Setting in this repo ═══
 * `Content_Publication_Budget__c` is a hierarchy Custom Setting rather than a custom object for
 * one reason: `getOrgDefaults()` reads the platform cache and costs **ZERO SOQL**, so consulting
 * the budget does not move `AttachmentPersistQueueable`'s pinned 3-query budget at all.
 *
 * ⚠ CUSTOM-SETTING **DATA** IS NOT DEPLOYABLE METADATA. There is no org-default row in source
 * control and there never will be; this class creates it on first use (the first successful
 * publish, or the first breaker trip). Do not hand-create it and do not treat its absence as a
 * deployment defect.
 *
 * ⚠ ONLY THE ORG DEFAULT IS EVER READ (`getOrgDefaults()`, not `getInstance()`). A per-user or
 * per-profile override would split one org-wide counter into several partial ones, which is
 * worse than not counting at all.
 *
 * ═══ CONCURRENCY — last-write-wins, ACCEPTED ═══
 * Two concurrent file jobs will undercount. That is a deliberate, stated trade: the line sits
 * 1,500 below the cap precisely so the undercount cannot matter. 🔴 **Do NOT "fix" it with a
 * `FOR UPDATE` lock** — a row lock is held to commit, and this one would serialise the file
 * jobs of wholly unrelated broker emails behind each other.
 *
 * ═══ LAYER ═══
 * Service. It owns all `Content_Publication_Budget__c` DML and holds NO SOQL (the custom-setting
 * read is a cache lookup, not a query). `with sharing` per ARCHITECTURE.md §2; it is functionally
 * a no-op because hierarchy custom settings are not sharing-controlled records.
 *
 * @see AttachmentPersistQueueable.cls (checks before converting, records after)
 * @see AttachmentPersistFinalizer.cls (the ONLY caller of trip())
 * @see AttachmentCarrierSweepBatch.cls (honours both, so a sweep cannot hammer an exhausted quota)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §6.5, §6.6, §11.6
 * @see .claude/rules/content-publication-rule.md
 */
public with sharing class ContentPublicationBudget {

    /**
     * The self-imposed line, well short of the org's real 2,500-per-rolling-24h cap.
     *
     * THE ARITHMETIC: the platform's window is ROLLING 24 h while this counter's window is
     * anchored at its own start, so two adjacent windows can overlap inside one rolling window.
     * A per-window budget of 1,000 therefore bounds ANY rolling 24 h at <= 2,000 < 2,500,
     * leaving >= 500 for test runs and deploys — which is the headroom that absorbs the
     * structural undercount described in the class header.
     *
     * At `InboundEmailAttachmentService.MAX_ATTACHMENTS` = 3 this is ~333 attachment-bearing
     * emails a day, far above real volume. That is the point: it is a BACKSTOP, not a throttle.
     */
    @TestVisible private static final Integer DAILY_PUBLICATION_BUDGET = 1000;

    /**
     * How long the breaker stays tripped once a real `ContentPublication Limit exceeded` has
     * been observed. Matched to the org's ROLLING QUOTA WINDOW so a single trip cannot expire
     * back into the same exhausted window. It clears automatically at expiry — no job, no
     * scheduled reset — and an admin can clear it early by editing the setting.
     */
    @TestVisible private static final Integer BREAKER_SUSPEND_HOURS = 24;

    /** Length of this counter's own budget window. Rolls lazily, inside record(). */
    @TestVisible private static final Integer WINDOW_HOURS = 24;

    /**
     * §7 copy for the breaker mode. 🔴 It must say "not yet saved" and name the retry, because
     * the whole point of the carrier is that this state is RECOVERABLE, not terminal.
     */
    @TestVisible private static final String NOTE_SUSPENDED_PREFIX =
        'not yet saved: ContentPublication limit reached, persistence suspended until ';
    @TestVisible private static final String NOTE_RETRY_SUFFIX =
        '; the file is still attached to this staging row and will be retried';

    /** §7 copy for the daily-budget mode. Same "recoverable" contract as above. */
    @TestVisible private static final String NOTE_BUDGET_PREFIX =
        'not yet saved: daily publication budget reached (';

    /**
     * Whether `count` more publications are permitted right now. ZERO SOQL and ZERO DML — the
     * hierarchy custom-setting read is a platform cache lookup, which is why this can be called
     * from inside a pinned governor budget without moving it.
     *
     * Returns false when the breaker is tripped OR the window's remaining allowance is smaller
     * than `count`. Never throws: any internal failure degrades to `true` (see the class header
     * — fail-open is the deliberate choice).
     *
     * @param count How many publications the caller is about to make; null or <= 0 is treated
     *              as a bare "is publishing permitted at all?" question.
     * @return true when the caller may proceed.
     * @example
     * if (!ContentPublicationBudget.canPublish(chosen.size())) { defer(); }
     */
    public static Boolean canPublish(Integer count) {
        Integer requested = (count == null || count < 1) ? 1 : count;
        return allowance() >= requested;
    }

    /**
     * How many more publications this window permits, right now. ZERO SOQL, ZERO DML.
     *
     * Returns 0 while the breaker is tripped — which is what lets a caller cap a chosen subset
     * rather than abandoning the whole run — and never returns a negative number.
     *
     * @return The remaining allowance (>= 0); `DAILY_PUBLICATION_BUDGET` when the setting cannot
     *         be read at all (fail-open).
     * @example
     * Integer room = ContentPublicationBudget.allowance();
     */
    public static Integer allowance() {
        try {
            if (isSuspended()) {
                return 0;
            }
            Integer used = usedInCurrentWindow(settings());
            Integer remaining = DAILY_PUBLICATION_BUDGET - used;
            return (remaining < 0) ? 0 : remaining;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContentPublicationBudget.allowance: degrading to PERMITTED after '
                + e.getTypeName() + ' | ' + e.getMessage());
            return DAILY_PUBLICATION_BUDGET;
        }
    }

    /**
     * Whether the reactive circuit breaker is currently tripped. ZERO SOQL, ZERO DML.
     *
     * A tripped breaker whose `Suspended_Until_DateTime__c` has passed reports false — the
     * breaker clears by the passage of time rather than by a reset job, so nothing can leave the
     * feature permanently disabled by forgetting to run something.
     *
     * @return true while publication is suspended; false on expiry and on any read failure.
     * @example
     * if (ContentPublicationBudget.isSuspended()) { recordSuspension(); return; }
     */
    public static Boolean isSuspended() {
        try {
            Content_Publication_Budget__c budget = settings();
            if (budget == null || budget.Is_Suspended__c != true) {
                return false;
            }
            Datetime until = budget.Suspended_Until_DateTime__c;
            return (until == null) || (Datetime.now() < until);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContentPublicationBudget.isSuspended: degrading to NOT SUSPENDED after '
                + e.getTypeName() + ' | ' + e.getMessage());
            return false;
        }
    }

    /**
     * Increment the counter AFTER a successful publish. Exactly 1 DML (the custom-setting
     * upsert), which is why it appears in `AttachmentPersistQueueable`'s pinned DML budget.
     *
     * ⚠ CALL IT AFTER, NEVER BEFORE. A count incremented before the insert would over-count a
     * refused publish and, worse, would still be wrong if the transaction rolled back — whereas
     * counting after means the increment lives or dies with the publications it describes.
     *
     * This is also where the window ROLLS: a window older than `WINDOW_HOURS` is restarted
     * rather than accumulated. Rolling lazily here (instead of in `canPublish`) is what keeps
     * the read path at zero DML.
     *
     * Fail-soft: a failure to count must never cost a file that was genuinely saved.
     *
     * @param count How many publications were actually made; null or <= 0 is a no-op.
     * @example
     * ContentPublicationBudget.record(convertedCount);
     */
    public static void record(Integer count) {
        if (count == null || count < 1) {
            return;
        }
        try {
            Content_Publication_Budget__c budget = settings();
            if (budget == null) {
                return;
            }
            Integer used = usedInCurrentWindow(budget);
            if (used == 0) {
                // Window expired (or never started) — restart it at this moment.
                budget.Window_Start_DateTime__c = Datetime.now();
            }
            budget.Publication_Count__c = used + count;
            Database.upsert(budget, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContentPublicationBudget.record: could not record ' + count
                + ' publication(s): ' + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * Trip the reactive circuit breaker for `BREAKER_SUSPEND_HOURS`.
     *
     * 🔴 CALLED ONLY FROM `AttachmentPersistFinalizer`, i.e. from a transaction that SURVIVED
     * the failure it is reporting. Calling it from inside the failing transaction would be
     * pointless — that transaction's DML is about to roll back, taking the trip with it. SP-3
     * measured the Finalizer's own DML committing durably and independently of the parent's
     * rollback; that is the mechanism this method depends on.
     *
     * Fail-soft: a failure to record a failure must never become a second failure.
     *
     * @example
     * if (isPublicationLimitFailure(message)) { ContentPublicationBudget.trip(); }
     */
    public static void trip() {
        try {
            Content_Publication_Budget__c budget = settings();
            if (budget == null) {
                return;
            }
            budget.Is_Suspended__c = true;
            budget.Suspended_Until_DateTime__c =
                Datetime.now().addHours(BREAKER_SUSPEND_HOURS);
            Database.upsert(budget, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContentPublicationBudget.trip: could not trip the breaker: '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * The §7 note text for the BREAKER mode, naming the moment persistence resumes.
     *
     * @return The human-readable line for `Dropped_Attachment_Notes__c`.
     * @example
     * InboundEmailStagingService.markAttachmentStatus(
     *     stagingId, InboundEmailStagingService.ATTACHMENT_STATUS_FAILED,
     *     ContentPublicationBudget.suspensionNote());
     */
    public static String suspensionNote() {
        Datetime until;
        try {
            Content_Publication_Budget__c budget = settings();
            until = (budget == null) ? null : budget.Suspended_Until_DateTime__c;
        } catch (Exception e) {
            until = null;
        }
        return NOTE_SUSPENDED_PREFIX
            + ((until == null) ? 'the breaker is cleared' : String.valueOf(until))
            + NOTE_RETRY_SUFFIX;
    }

    /**
     * The §7 note text for the DAILY BUDGET mode, naming both numbers so a human can see how
     * close the org actually ran.
     *
     * @param requested How many publications the caller wanted to make.
     * @return The human-readable line for `Dropped_Attachment_Notes__c`.
     * @example
     * String note = ContentPublicationBudget.budgetNote(chosen.size());
     */
    public static String budgetNote(Integer requested) {
        Integer used;
        try {
            used = usedInCurrentWindow(settings());
        } catch (Exception e) {
            used = DAILY_PUBLICATION_BUDGET;
        }
        return NOTE_BUDGET_PREFIX + used + ' of ' + DAILY_PUBLICATION_BUDGET + ')'
            + NOTE_RETRY_SUFFIX;
    }

    /**
     * The org-default custom-setting row, created in memory when it does not exist yet.
     *
     * `getOrgDefaults()` returns an empty instance rather than null when no row has ever been
     * written, and `Database.upsert` on that instance is what actually creates it — which is why
     * the org-default row is a RUNTIME artefact and not deployable metadata.
     *
     * @return The org-default settings row; never queried, always cache-read (0 SOQL).
     */
    private static Content_Publication_Budget__c settings() {
        Content_Publication_Budget__c budget = Content_Publication_Budget__c.getOrgDefaults();
        return (budget == null) ? new Content_Publication_Budget__c() : budget;
    }

    /**
     * Publications consumed inside the CURRENT window, treating an expired or never-started
     * window as zero. Pure — no read, no write.
     *
     * @param budget The settings row; null yields 0.
     * @return The count in the current window (>= 0).
     */
    private static Integer usedInCurrentWindow(Content_Publication_Budget__c budget) {
        if (budget == null || budget.Publication_Count__c == null) {
            return 0;
        }
        Datetime started = budget.Window_Start_DateTime__c;
        if (started == null || started.addHours(WINDOW_HOURS) <= Datetime.now()) {
            return 0;
        }
        Integer used = Integer.valueOf(budget.Publication_Count__c);
        return (used < 0) ? 0 : used;
    }
}
