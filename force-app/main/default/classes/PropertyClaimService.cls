/**
 * Broker-Protection claim writer (CHUNK 2). Owns ALL DML for the first-broker-wins
 * ledger: it either registers a brand-new winner (Property_Registry__c +
 * winning Competing_Broker_Submission__c) or records a losing broker as a non-winning
 * Competing_Broker_Submission__c against that winner. One inbound broker email = one
 * call to claim(...), driven by CHUNK 3's queueable.
 *
 * ═══ NO LEAD IS FLAGGED, AND NO LEAD IS TOUCHED (changed 2026-07-31) ═══
 * markDuplicate used to ALSO stamp Lead.Is_Duplicate_Property__c / Duplicate_Of_Lead__c on
 * the losing broker's Lead. That write is gone, and this class now performs no Lead DML at
 * all, for two independent reasons:
 *   1. LEAD-TABLE POLLUTION — a competing broker no longer gets a Lead of their own, so
 *      there is nothing left to flag. One junk duplicate-flagged Lead per competing broker
 *      per property was polluting the Lead table for no reporting benefit; the
 *      Competing_Broker_Submission__c row already carries the whole competing claim.
 *   2. DUPLICATES_DETECTED / SAVEPOINT ROLLBACK — orgs commonly run Lead duplicate rules on
 *      Email. Inserting a second Lead carrying the same broker address throws
 *      DUPLICATES_DETECTED, the surrounding Savepoint rolls back the ENTIRE transaction, and
 *      the inbound email's Task is silently lost. Not inserting competing Leads removes that
 *      failure class structurally rather than defending against it.
 * The two Lead fields are retained as LEGACY for historical rows; nothing writes them.
 *
 * ═══ 🔴 THE WINNER ANCHOR — EXACTLY ONE OF TWO LOOKUPS, NEVER BOTH, NEVER NEITHER ═══
 * Added 2026-08-03 after a production failure on `usman-dpeg` (staging row a0aiw000000OCckAAG).
 * Every Competing_Broker_Submission__c must name the record that holds the property claim, and
 * that record changes identity when the deal becomes real:
 *
 *   • winner Lead is OPEN      -> `Winning_Lead__c`        = the Lead    (`Source_Lead__c` as before)
 *   • winner Lead is CONVERTED -> `Winning_Opportunity__c` = its Opportunity, BOTH Lead lookups null
 *
 * WHY, AND IT IS A PLATFORM RULE RATHER THAN A PREFERENCE: **at runtime, a Lead lookup cannot be
 * SET to a converted Lead.** The platform rejects the insert with a DmlException, so a repeat or a
 * competing submission arriving AFTER the winner was
 * converted threw, the property's whole routing branch was abandoned, and the
 * inbound email landed with no Task target and no audit row.
 *
 * ⚠ TWO HONEST CAVEATS, BOTH ESTABLISHED 2026-08-03 — do not restate this rule more confidently
 * than the evidence supports:
 *   1. THE EXACT StatusCode WAS NEVER CAPTURED. `Error__c` was NULL on the incident row (the gap
 *      the defect-2 change closes), so the cause is established by ELIMINATION — the only DML on
 *      that path, every other field clipped or sanitized, the VR satisfied, record access ruled
 *      out because the running user owned the Lead, and the identical write succeeding a day
 *      earlier while the Lead was still open. `CANNOT_UPDATE_CONVERTED_LEAD` is the expected code
 *      but has NOT been observed here; do not assert it anywhere.
 *   2. THE RESTRICTION IS NOT ENFORCED IN `@isTest`. The same insert SUCCEEDS in test context, so
 *      no Apex test in this org can falsify this rule — see
 *      PropertyClaimServiceTest.platform_lookupToAConvertedLead_isNotEnforcedInTestContext, which
 *      pins that quirk. Genuine falsification needs anonymous Apex in a scratch org.
 *
 * Note the shape of that bug: the
 * winning row inserted at claim time is always safe (the Lead was created seconds earlier and
 * cannot be converted yet), so the failure only appears on the SECOND email about a property —
 * which is exactly when the audit trail matters most and exactly why no test caught it.
 *
 * 🔴 CONSEQUENCES FOR ANY FUTURE READER OF THIS OBJECT — DO NOT ASSUME `Winning_Lead__c`:
 *   • `CompetingBrokerSubmissionSelector.selectRecentByBrokerEmail` admits BOTH anchors. If it
 *     ever filters on `Winning_Lead__c != null` alone again, every follow-up on a converted
 *     winner's property stops matching as a REPEAT and is re-filed as a COMPETING claim — the
 *     winning broker recorded as a competitor against themselves, silently.
 *   • The row is written by ONE method (`buildSubmission`) so the rule has one home. Callers pass
 *     the ALREADY-RESOLVED live record rather than a flag, which keeps the SOQL count flat — see
 *     that method and `resolveWinnerRecord`.
 *
 * This closes the W3 residual carried since 2026-07-31 (docs/2026-07-31-competing-broker-no-lead.md,
 * docs/2026-07-31-llm-field-extraction.md).
 *
 * ⚠ claim() IS NOW CALLED N TIMES PER TRANSACTION (2026-07-31, D1 multi-property). One
 * inbound email can pitch several properties, and ExtractAddressQueueable loops over them —
 * so the old "exactly one email = exactly one claim per transaction" premise is gone, and
 * with it this class's share of the per-transaction-singleton bulk-test exemption (see
 * `.claude/rules/bulk-test-rule.md`, narrowed the same day).
 *
 * 🔴 WHAT KEEPS THAT SAFE IS THE CALLER'S ITERATION ORDER, NOT ANYTHING IN THIS CLASS.
 * Apex cannot release a row lock before commit, so a job claiming N properties holds N
 * `Property_Claim_Lock__c` locks at once, and two concurrent multi-property emails sharing
 * two properties would be an AB-BA deadlock. Salesforce does not report deadlocks — it
 * reports UNABLE_TO_LOCK_ROW, which acquireClusterLock already swallows into
 * ClaimOutcome.UNCLAIMED with only a System.debug, so the failure would be SILENT. The fix
 * lives in ExtractAddressQueueable.buildWorkList: properties are visited in ascending
 * deriveClusterKey order, so every transaction takes shared locks in the same relative order
 * and no wait-for cycle can form. Do not "optimise" that sort away, and do not add a
 * batch-locking method here — sorted lazy acquisition already removes the cycle at zero
 * extra hold time.
 *
 * LAYER — Service (write side). All reads go through PropertyMatchingService /
 * PropertyRegistrySelector / LeadSelector — this class contains NO SOQL. Its DML is deliberately
 * single-record-shaped: each call claims exactly ONE property, and the insert/update
 * statements are never inside a loop within this class, so the layering "no DML in loops"
 * rule holds even though the CALLER now loops. The project has no UnitOfWork class (verified 2026-07-24), so direct
 * insert/update is the established repo pattern (cf. ContractExecutionService,
 * LeadConvertService).
 *
 * RACE MODEL (W4) — claim() SERIALISES concurrent same-property claims behind a
 * pessimistic FOR UPDATE row lock BEFORE it decides a winner, so the fuzzy
 * match-then-insert is atomic. At the top of claim() it: (a) derives a COARSE cluster
 * key (PropertyMatchingService.deriveClusterKey) that co-locates fuzzy-equivalent
 * addresses; (b) get-or-creates that cluster's Property_Claim_Lock__c row idempotently;
 * (c) acquires a FOR UPDATE lock on it via PropertyClaimLockSelector — this BLOCKS a
 * concurrent same-cluster transaction until the first commits; (d) only THEN runs
 * findMatchingRegistry (now the authoritative arbiter, because the lock guarantees the
 * loser sees the winner's committed registry) and either markDuplicate or registerWinner.
 * The unique index on Property_Key__c is still the innermost backstop: registerWinner
 * optimistically inserts and, on a duplicate-value DmlException, reconciles as a duplicate
 * or adopts an orphaned (winner-deleted, SetNull) row — under serialization this path now
 * fires only for the orphan-key case. If the FOR UPDATE lock cannot be acquired (~10s
 * lock-wait timeout, even after one retry) the claim FAILS SAFE: the record is left a
 * normal, unclaimed Lead and logged, never crashing the queueable. See
 * PropertyMatchingService's race note for the closed-race mechanism and its bounded residual.
 *
 * @see PropertyMatchingService.cls (the read/decision side + deriveClusterKey)
 * @see PropertyClaimLockSelector.cls (the FOR UPDATE lock query)
 * @see PropertyRegistrySelector.cls / CompetingBrokerSubmissionSelector.cls
 */
public with sharing class PropertyClaimService {

    /**
     * What a claim attempt actually did. Returned by claim() so the caller can report the
     * TRUE result instead of assuming it: claim() decides winner-vs-duplicate internally,
     * under the cluster lock, and a lock-wait timeout produces neither. Before this enum
     * existed the caller had to guess from its own pre-claim read, which is stale by
     * definition — the whole point of the lock is that the winner can change between that
     * read and the claim.
     *
     * WINNER         — this Lead now holds the property registration.
     * DUPLICATE_RACE — another Lead already held the property, discovered only AFTER the
     *                  caller had already created a Lead and asked to claim. A competing
     *                  submission was logged against the real winner. The caller is expected
     *                  to DELETE the Lead it created (a losing broker gets no Lead), which is
     *                  why this is a distinct outcome and not merely "duplicate": it is the
     *                  only signal that a Lead exists which should not.
     * UNCLAIMED      — no claim was recorded (lock-wait timeout, or a duplicate key with
     *                  neither a live winner nor an adoptable orphan). The Lead survives as a
     *                  normal, unclaimed Lead and the situation is hand-recoverable.
     * DUPLICATE      — RESERVED; no path returns it today. Every duplicate reached THROUGH
     *                  claim() is by definition a LOST RACE, because the caller only calls
     *                  claim() after its own read said the property was free — so both
     *                  duplicate paths below return DUPLICATE_RACE instead. Retained rather
     *                  than deleted because removing a member of a public enum is a breaking
     *                  change for any future caller that claims WITHOUT a pre-read (for which
     *                  "duplicate, but nothing to clean up" would be the correct answer), and
     *                  because ExtractAddressQueueable.toOutcomeLabel still maps it so the
     *                  enum-to-label mapping stays total.
     */
    public enum ClaimOutcome { WINNER, DUPLICATE, DUPLICATE_RACE, UNCLAIMED }

    /** Competing_Broker_Submission__c destination field lengths. */
    private static final Integer LEN_TEXT = 255;

    /**
     * Per-transaction answer for Property_Registry__c.Protection_Window_Days__c; null until
     * first asked. See stampResolvedWindow.
     *
     * 🔴 `@TestVisible` IS THE ONLY WAY THE STAMP CAN BE PROVEN IN THIS ORG TODAY, AND THAT IS
     * MEASURED, NOT ASSUMED. The field is brand-new and Metadata-API-deployed, so it has
     * FieldPermissions for nobody — including the deploy-time test runner. Measured on
     * `usman-dpeg` 2026-08-30 (validation 0Afiw000000TlrZCAS): both end-to-end claim tests
     * passed, and the stamp assertion inside each was SKIPPED, leaving the assignment in
     * stampResolvedWindow as the only uncovered line in the method. A guard whose guarded
     * branch no test can enter is a guard nobody has read. Pre-seeding this cache lets a test
     * enter that branch and assert the RESOLVED value on an in-memory row — no DML, so no FLS
     * is involved and no grant is needed. The end-to-end tests still exist and still assert
     * the same thing through real DML; they simply start proving it the day the grant lands.
     */
    @TestVisible
    private static Boolean windowStampWritableCache;

    /**
     * 🔴 GATE A MITIGATION (b) — THE DURABLE AUDIT TRAIL. REQUIRED, NOT DIAGNOSTIC. DO NOT DELETE.
     *
     * Stamp the protection window that was in force onto the registry row itself, at the
     * moment the claim is decided. `BrokerProtectionConfig`'s GATE A block is the full
     * decision record; the short version is that the user accepted a Setup-editable
     * protection window — a value that can retroactively release live claims with no deploy —
     * ON CONDITION that the window applied to a disputed claim stays recoverable.
     *
     * ═══ WHY A FIELD AND NOT (ONLY) THE WARN LOG — UPGRADED 2026-08-30 (WS8 review, W6) ═══
     * That condition was originally discharged by `PropertyMatchingService.logResolvedWindow`,
     * a `System.debug(WARN)`. A debug log is captured ONLY while a trace flag is active on the
     * EXECUTING principal and expires (24h retention, 20MB per flag). This code runs inside an
     * async queueable as the Email Service context user — the principal least likely to be
     * traced — so in practice the promised audit trail usually would not exist at all, and its
     * absence would only be discovered by the person who needed it. The log is KEPT (it costs
     * nothing and is genuinely useful when a flag IS active); it is now the secondary half.
     *
     * ═══ IT RIDES THE EXISTING DML: ZERO NEW SOQL, ZERO NEW DML ═══
     * Every caller passes a row that is about to be inserted or updated by a statement that
     * already exists. `ExtractAddressQueueable`'s QUERY_BUDGET and DML_BUDGET are EQUALITY
     * assertions at N=10, so anything else here would have to be argued as a budget change.
     * `BrokerProtectionConfig.protectionWindowDays()` is a cached CMDT accessor, measured at
     * `Limits.getQueries() == 0` (see that class's LAYER note), so it is free at any N.
     *
     * ═══ 🔴 GUARDED ON isCreateable(), FOR A REASON MEASURED TWICE IN THIS BUILD ═══
     * `Protection_Window_Days__c` is a brand-new Metadata-API-deployed field, which arrives
     * with FLS for NOBODY — System Administrator included (ARCHITECTURE.md §2). An
     * unconditional write would not cost the audit value, it would throw
     * `System.DmlException: Operation failed due to fields being inaccessible` and abort the
     * whole claim: no registry row, no submission, no Lead retained, for every inbound broker
     * email until a permission set caught up. Both halves of that were measured on
     * `usman-dpeg` on 2026-08-30 — 42 of 45 tests on `Lead`, and an org-wide lead-conversion
     * failure on `Opportunity`. The guard makes a missing grant cost the AUDIT VALUE and
     * nothing else, which is the correct trade: the claim is the product, the stamp is
     * evidence about it.
     *
     * ⚠ `isCreateable()` IS THE RIGHT QUESTION ON BOTH PATHS, including the two adoptions,
     * which are updates. It is the same permission bit in practice for a plain custom Number
     * field, and asking one question keeps the two paths from diverging into "stamped on
     * insert, silently not stamped on adoption" — which is the shape that would make the
     * audit trail wrong rather than merely absent.
     *
     * 🔴 PROVISIONING IS THE REAL FIX, AND IT IS DECLARED, NOT MADE HERE. Read + Edit on
     * `Property_Registry__c.Protection_Window_Days__c` for the intake principal
     * (`Broker_Protection_Access`), or this mitigation is silently OFF. No permission set is
     * edited by this change. Verify with `FieldPermissions`, never with a green deploy.
     *
     * @param registry The row about to be written by an EXISTING insert or update statement.
     */
    @TestVisible
    private static void stampResolvedWindow(Property_Registry__c registry) {
        if (!windowStampWritable()) {
            return;
        }
        registry.Protection_Window_Days__c = BrokerProtectionConfig.protectionWindowDays();
    }

    /**
     * Can the running principal WRITE `Property_Registry__c.Protection_Window_Days__c`? See
     * stampResolvedWindow for the decision and the measurement behind it.
     *
     * ⚠ CACHED PER TRANSACTION, NOT PER CALL. This is reached once per property, up to
     * `ExtractAddressQueueable.MAX_PROPERTIES` times. A describe is a schema read rather than
     * SOQL, so the pinned QUERY_BUDGET and DML_BUDGET are untouched at any N either way — the
     * cache is about CPU, matching `EmailToLeadService.brokerLinkWritable()`'s reasoning.
     *
     * @return True when the field may be written by the running principal.
     */
    private static Boolean windowStampWritable() {
        if (windowStampWritableCache == null) {
            windowStampWritableCache =
                Schema.SObjectType.Property_Registry__c.fields.Protection_Window_Days__c.isCreateable();
        }
        return windowStampWritableCache;
    }

    /**
     * Claim `normalized` for `sourceLeadId`, race-safe against concurrent same-property
     * submissions. The winner decision is made while HOLDING a pessimistic FOR UPDATE lock
     * on the address cluster, so a competing claim for the same property is serialised behind
     * this one and correctly reconciled as a duplicate rather than a second winner.
     *
     * Flow: derive the coarse cluster key -> get-or-create + FOR UPDATE-lock that cluster's
     * Property_Claim_Lock__c row -> (holding the lock) findMatchingRegistry: if a winner
     * already exists, markDuplicate; otherwise registerWinner (insert the registry winner +
     * winning submission, with orphan adoption on the unique-key backstop). On a lock-wait
     * timeout the claim fails safe (the Lead is left unclaimed and logged). `normalized` must
     * be non-blank — ExtractAddressQueueable guards that before calling.
     *
     * Everything stays single-record-per-transaction: the lock adds at most one SOQL and one
     * insert per claim, none in a loop.
     *
     * @param sourceLeadId    The Lead created for this inbound email (the claimant).
     * @param normalized      Normalized property address; the unique Property_Key__c. Non-blank.
     * @param extracted       LLM-extracted fields (broker_name, broker_email,
     *                        property_address, ...); stamped onto the submission.
     * @param submittedOn     The email's original send time (Submitted_DateTime__c).
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     * @return What the claim actually did — WINNER, DUPLICATE_RACE, or UNCLAIMED.
     *         ExtractAddressQueueable uses it to record the true outcome on the staging row
     *         AND, on DUPLICATE_RACE, to delete the Lead it had already created: a broker who
     *         loses the race gets no Lead, only a competing submission against the winner.
     *         Callers must NOT treat UNCLAIMED as a loss — the Lead is legitimate there.
     */
    public static ClaimOutcome claim(Id sourceLeadId, String normalized, Map<String, String> extracted,
                                     Datetime submittedOn, String forwardedByEmail, String emailSubject) {
        // (a) Coarse cluster key that co-locates fuzzy-equivalent addresses in one lock partition.
        String clusterKey = PropertyMatchingService.deriveClusterKey(normalized);

        // (b+c) Serialise same-cluster claims behind a pessimistic FOR UPDATE row lock.
        if (!acquireClusterLock(clusterKey)) {
            // Lock-wait timed out even after one retry. FAIL SAFE: leave the record a normal,
            // unclaimed Lead and log — a missed auto-claim is hand-recoverable; a crashed
            // queueable or an unserialised dual-winner is not.
            System.debug(LoggingLevel.WARN,
                'PropertyClaimService.claim: could not acquire cluster lock "' + clusterKey
                + '" (normalized "' + normalized + '"); leaving Lead ' + sourceLeadId
                + ' unclaimed.');
            return ClaimOutcome.UNCLAIMED;
        }

        // (d) Holding the lock, the winner decision is authoritative: a concurrent same-cluster
        // claim is blocked until this commits, so findMatchingRegistry sees any winner it has
        // already registered (exact OR fuzzy) and this claimant becomes that winner's duplicate.
        Property_Registry__c winner = PropertyMatchingService.findMatchingRegistry(normalized);
        if (isLostRaceAgainst(winner, sourceLeadId)) {
            // A winner exists that the caller's own pre-read did not see => this claimant LOST
            // the race. Report DUPLICATE_RACE, not DUPLICATE: the caller has already created a
            // Lead for a broker who is not entitled to one, and that outcome is its only cue
            // to remove it. `sourceLeadId` is still stamped on the submission because that
            // Lead genuinely exists at this instant — deleting it is the CALLER's policy
            // decision, not this claim engine's, and the lookup's SetNull delete constraint
            // clears it the moment the caller acts.
            markDuplicate(winner, sourceLeadId, resolveWinnerRecord(winner.Winning_Lead__c),
                extracted, submittedOn, forwardedByEmail, emailSubject);
            return ClaimOutcome.DUPLICATE_RACE;
        }
        return registerWinner(
            sourceLeadId, normalized, extracted, submittedOn, forwardedByEmail, emailSubject);
    }

    /**
     * Register `sourceLeadId` as the winning claimant: insert a Property_Registry__c winner
     * row (Registered_DateTime__c = claim time, NOT the email's submitted time) and a winning
     * Competing_Broker_Submission__c. Called only while the cluster lock is held and after
     * findMatchingRegistry found no live winner.
     *
     * ═══ 🔴 WHY Property_Registry__c IS NOT EXPOSED TO THE CONVERTED-LEAD DEFECT — AND HOW TO
     *     KEEP IT THAT WAY (investigated 2026-08-03) ═══
     * `Property_Registry__c.Winning_Lead__c` is a Lead lookup exactly like the submission's, and
     * in steady state it FREQUENTLY holds a CONVERTED Lead — that is the normal end state of a
     * won property, and live rows on `usman-dpeg` are already in it. It is nonetheless safe,
     * because of WHICH rows the module writes, not because of anything about the field:
     *
     *   • THE INSERT below always names a Lead created milliseconds earlier by the caller's
     *     branch (e). Nothing in that transaction converts it, so it cannot be converted yet.
     *   • THE ORPHAN UPDATE below always targets a row whose `Winning_Lead__c` is NULL —
     *     `PropertyRegistrySelector.selectOrphanByPropertyKey` filters `Winning_Lead__c = null`
     *     by construction — and re-points it at the same freshly created Lead.
     *   • THE EXPIRED-ADOPTION UPDATE (added 2026-08-17) always targets a row whose
     *     `Winning_Lead__c` holds an **OPEN** Lead —
     *     `PropertyRegistrySelector.selectExpiredByPropertyKey` filters
     *     `Winning_Lead__r.IsConverted = false` by construction — and re-points it at the
     *     freshly created Lead.
     *
     * These three statements are the ONLY DML against this object in the entire codebase.
     *
     * ═══ 🔴 THE PROHIBITION — AMENDED 2026-08-17, NOT REPEALED. READ THE WHOLE THING ═══
     * This paragraph used to read "there are exactly TWO statements; DO NOT ADD A THIRD."
     * There are now three, and leaving the old text standing would have been worse than
     * deleting it: the next reader would have believed a rule the code no longer follows.
     *
     * (i)   The third statement is the adoption of an **EXPIRED** registration — the FSD
     *       tranche 3 broker-protection window (see `PropertyMatchingService`'s header).
     * (ii)  It is admissible for ONE reason and one reason only: its read is filtered to
     *       `Winning_Lead__r.IsConverted = false`, so the row it updates provably holds an
     *       OPEN Lead in `Winning_Lead__c`. That is why "a converted winner's claim never
     *       expires" is a STRUCTURAL discharge of this prohibition rather than a policy
     *       preference — under the opposite reading the registry would need the same split
     *       anchor the submission received (a `Winning_Opportunity__c` field, a rewritten
     *       `Winning_Lead_Required` VR, and an audit of every existing reader of
     *       `Winning_Lead__c`), which is a tranche of work, not a leg in a catch block.
     * (iii) 🔴 THE PROHIBITION STILL STANDS, UNCHANGED, FOR ANY UPDATE NOT CARRYING THAT
     *       FILTER. A "last touched" stamp, a status field, a re-key, a merge/cleanup tool,
     *       a "superseded" marker, or a sweep job that writes anything at all would be
     *       updating a row whose lookup MAY hold a converted Lead — and the platform may
     *       reject the whole DML over a lookup the update never touched. That fails on
     *       exactly the long-running, successful properties, which is the population least
     *       likely to appear in a test fixture. Raise it as its own change.
     * (iv)  ⚠ NO APEX TEST IN THIS ORG CAN FALSIFY ANY OF THIS.
     *       `platform_lookupToAConvertedLead_isNotEnforcedInTestContext` pins that test
     *       context does not enforce the converted-Lead restriction, so a green suite
     *       proves the DECISION (we refuse to adopt a converted winner's row), never that
     *       the platform would have thrown had we tried.
     *
     * ═══ THE HANDOVER: WHAT MOVES AND WHAT DELIBERATELY DOES NOT (2026-08-17) ═══
     *   • The previous winner's LEAD is untouched. Nothing deletes it. This module deletes
     *     a Lead on exactly one path (`DUPLICATE_RACE`, a Lead created seconds earlier),
     *     and an expiry handover is not it. That Lead keeps its address, its extraction and
     *     its Tasks; it is simply no longer the registry winner.
     *   • The previous winner's `Competing_Broker_Submission__c` TRAIL is untouched and
     *     MUST stay so — ARCHITECTURE.md §1: the object is deliberately not master-detail
     *     precisely because a cascade delete would silently wipe it.
     *   • Two rows now carry `Is_Winning_Submission__c = true` for one property. That is
     *     CORRECT, not a defect: they are anchored on DIFFERENT Leads, each was true when
     *     written, and the object is append-only by definition.
     *   • There is NO "this claim was superseded" marker, deliberately — it would be a
     *     fourth registry write and falls squarely under (iii). The handover is
     *     reconstructible from the moved `Winning_Lead__c` plus the two submission rows.
     *
     * 🔴 RESIDUAL R1 — THE SUPERSEDED BROKER'S FOLLOW-UPS DO NOT BECOME COMPETING CLAIMS,
     * FOR UP TO `LOOKBACK_DAYS`. `ExtractAddressQueueable`'s branch (b) REPEAT runs BEFORE
     * branch (d) COMPETING and never consults the registry. So after a handover, if the
     * superseded broker emails again within the repeat window, `findBrokerSubmission` still
     * matches their own prior row and the email is filed as a Repeat on their own — now
     * claimless — Lead: no competing submission against the new winner, no error, nothing
     * in the UI. ACCEPTED (design §1.5): the email is still captured, logged and auditable,
     * and "fixing" it means making the highest-traffic branch in the pipeline
     * registry-aware. Recorded here rather than in the queueable to avoid colliding with
     * concurrent work on that class; move this note there when convenient.
     *
     * ⚠ OPERATIONAL ESCAPE HATCH — A CONVERTED-THEN-DEAD DEAL PROTECTS ITS PROPERTY FOR
     * EVER. A Lead converted into an Opportunity that later went `Dead/Pass` still reads
     * `IsConverted = true`, so its claim never expires. The remedy needs NO new code and is
     * already tested: DELETE the registry row by hand. `Winning_Lead__c` is SetNull, so the
     * key becomes an ORPHAN and the existing orphan-adoption leg below re-opens it to the
     * next broker.
     *
     * The unique index on Property_Key__c remains the innermost backstop: if the exact key
     * already exists — which, under W4 serialization, means an ORPHANED row whose winner was
     * deleted via SetNull (a live winner would have been caught in claim()) — the insert
     * throws a duplicate-value DmlException and the orphan is adopted so the key is not
     * unclaimable forever. A duplicate key with neither a live winner nor an orphan is logged
     * and skipped. Any non-duplicate DmlException is rethrown (full transaction rollback).
     *
     * @param sourceLeadId    The winning Lead.
     * @param normalized      Normalized property address; the unique Property_Key__c.
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     * @return WINNER when the registration succeeded, or when an ORPHANED or EXPIRED row was
     *         adopted; DUPLICATE_RACE when the key collision reconciled to an existing
     *         winner (the caller's Lead must then be deleted — see the ClaimOutcome doc);
     *         UNCLAIMED when the key exists but has no live winner, no adoptable orphan and
     *         no expired row.
     */
    private static ClaimOutcome registerWinner(Id sourceLeadId, String normalized, Map<String, String> extracted,
                                               Datetime submittedOn, String forwardedByEmail, String emailSubject) {
        try {
            Property_Registry__c registry = new Property_Registry__c(
                Property_Key__c = normalized,
                Normalized_Address__c = normalized,
                Winning_Lead__c = sourceLeadId,
                Registered_DateTime__c = Datetime.now()
            );
            // GATE A durable audit trail. Rides this insert — no new statement, no new query.
            stampResolvedWindow(registry);
            insert registry;
            // The winner anchor is the Lead itself, with NO resolve query: this Lead was
            // inserted by the caller seconds ago and cannot have been converted yet, so passing
            // it as its own live record is both correct and free. See buildSubmission.
            insertSubmission(buildSubmission(
                sourceLeadId, sourceLeadId, sourceLeadId, extracted, submittedOn,
                forwardedByEmail, emailSubject, true
            ));
            return ClaimOutcome.WINNER;
        } catch (DmlException de) {
            if (!isDuplicateValue(de)) {
                // Not a duplicate-key collision — a genuine failure. Rethrow so the whole
                // transaction rolls back rather than half-registering.
                throw de;
            }
            // The exact unique key already exists. Under the cluster lock a live winner was
            // already handled in claim(), so this is the ORPHAN case; re-check defensively,
            // then adopt the orphan.
            Property_Registry__c winner = PropertyMatchingService.findMatchingRegistry(normalized);
            if (isLostRaceAgainst(winner, sourceLeadId)) {
                // Same reasoning as claim()'s in-lock check: a winner that is SOMEONE ELSE'S
                // means the caller's pre-read was stale, so this is a LOST RACE and the
                // caller's Lead must go. See the ClaimOutcome doc for why that is a distinct
                // outcome — and see isLostRaceAgainst for why a SELF-match must not land here.
                markDuplicate(winner, sourceLeadId, resolveWinnerRecord(winner.Winning_Lead__c),
                    extracted, submittedOn, forwardedByEmail, emailSubject);
                return ClaimOutcome.DUPLICATE_RACE;
            }
            Property_Registry__c orphan = PropertyMatchingService.findOrphanedRegistry(normalized);
            if (orphan != null) {
                // The unique key exists but its winner was deleted (SetNull). Adopt it,
                // else the key is unclaimable forever.
                adopt(orphan, sourceLeadId, normalized, extracted, submittedOn,
                    forwardedByEmail, emailSubject);
                return ClaimOutcome.WINNER;
            }
            // The unique key exists, has a LIVE winner, and that winner is not someone else
            // racing us — so the row is one whose PROTECTION WINDOW HAS CLOSED (added
            // 2026-08-17). findMatchingRegistry already declined it above, which is what let
            // this claim proceed to the insert that collided.
            //
            // 🔴 THIS LEG IS NOT OPTIONAL AND IS NOT A REFINEMENT OF THE WHERE CLAUSE. Without
            // it, an expired key falls through to the UNCLAIMED return below: the new broker
            // gets a Lead with no claim, the expired row still occupies the unique key, and the
            // property becomes unclaimable BY ANYONE, for ever, with no error anywhere.
            //
            // Ordering: AFTER the orphan leg. The two populations are DISJOINT (an orphan has a
            // null winner; an expired row has a non-null, unconverted one), so this is about not
            // disturbing tested behaviour rather than about correctness.
            Property_Registry__c expired = PropertyMatchingService.findExpiredRegistry(normalized);
            if (expired != null) {
                adopt(expired, sourceLeadId, normalized, extracted, submittedOn,
                    forwardedByEmail, emailSubject);
                return ClaimOutcome.WINNER;
            }
            // Duplicate key but no live winner, no orphan and no expired row — nothing safe to
            // attach this submission to. Log and drop it.
            System.debug(LoggingLevel.WARN,
                'PropertyClaimService.registerWinner: duplicate key "' + normalized + '" but no '
                + 'live winner, no orphan row and no expired row found; skipping. sourceLeadId='
                + sourceLeadId);
            return ClaimOutcome.UNCLAIMED;
        }
    }

    /**
     * ADOPT an existing registry row for `sourceLeadId`: re-point its winner, re-stamp its
     * normalized address and RESET `Registered_DateTime__c` to now, then log the winning
     * submission. The single implementation behind BOTH adoption legs in
     * registerWinner — orphan (winner deleted) and expired (protection window closed).
     *
     * 🔴 THE TWO LEGS SHARE THIS METHOD RATHER THAN BEING "BYTE-IDENTICAL COPIES", AND THAT
     * IS THE POINT. The design mandated byte-identical field writes; one implementation is
     * the stronger form of the same guarantee, because copies drift and a shared method
     * cannot. What must not drift is the meaning of `Registered_DateTime__c`: it means
     * "when the CURRENT winner claimed this property", and BOTH the fuzzy lookback
     * (`selectRecentWithWinner`) and the whole protection window read it that way. Two
     * adoption paths writing two different field sets is exactly how that field would
     * acquire two meanings — at which point a re-claimed property would silently keep its
     * ORIGINAL expiry date and release again immediately.
     *
     * ⚠ RESETTING THE CLOCK IS NOT A NEW DECISION MADE FOR EXPIRY. The orphan leg has
     * written `Registered_DateTime__c = Datetime.now()` since the module shipped; expiry
     * inherits the already-working answer rather than inventing one.
     *
     * ═══ 🔴 WHY THE GATE A WINDOW STAMP IS RE-WRITTEN HERE (WS8, 2026-08-30) ═══
     * Because this method resets `Registered_DateTime__c`, an adoption IS a fresh claim, and
     * the window that decided it is the window in force NOW. Leaving the original stamp
     * standing would produce the one outcome worse than no audit trail: a row whose
     * "registered" date and whose "window" came from two different claims, reading as
     * authoritative and being wrong. This matters most on the EXPIRED leg, which is the exact
     * scenario GATE A was opened for — an admin lowering the window is what MAKES a row
     * expired, so the adopted row must record the lowered value, not the one it replaced.
     *
     * 🔴 THIS CONTRADICTS THE FIELD'S OWN `description`, WHICH SAYS "copied once ... and never
     * updated afterward". THE CODE IS RIGHT AND THE DESCRIPTION NEEDS AMENDING — it was
     * written by a concurrent agent that owned the field file (which this workstream was
     * forbidden to edit) and that saw only the new-winner INSERT path. The same description's
     * FIRST clause is the one that governs: "the window that was IN FORCE WHEN THIS CLAIM WAS
     * REGISTERED". An adoption re-registers the row — that is what resetting
     * `Registered_DateTime__c` MEANS — so honouring "never updated" would make the two fields
     * describe two different claims. The amendment owed is one sentence: written on every
     * path that sets `Registered_DateTime__c`, which is this method and the new-winner insert.
     *
     * ⚠ IT IS NOT A BREACH OF THE PROHIBITION IN registerWinner's HEADER, clause (iii). That
     * clause forbids a registry UPDATE that does not carry the `Winning_Lead__r.IsConverted =
     * false` filter — because such a row may hold a converted Lead and the platform may reject
     * the whole DML over a lookup the update never touched. This adds a Number field to the
     * TWO EXISTING, ALREADY-FILTERED update statements; it introduces no statement and reaches
     * no new row. Clause (iii)'s example of "a 'last touched' stamp" refers to a stamp written
     * by a sweep over ARBITRARY rows, which this is not.
     *
     * ⚠ THE WINNER ANCHOR IS THE LEAD ITSELF, WITH NO RESOLVE QUERY, on both legs: the Lead
     * was inserted by the caller seconds ago and cannot have been converted yet. See
     * buildSubmission.
     *
     * @param registry        The row to adopt (orphan or expired). Mutated and updated.
     * @param sourceLeadId    The new winning Lead.
     * @param normalized      Normalized property address (the unique Property_Key__c).
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     */
    private static void adopt(Property_Registry__c registry, Id sourceLeadId, String normalized,
                              Map<String, String> extracted, Datetime submittedOn,
                              String forwardedByEmail, String emailSubject) {
        registry.Winning_Lead__c = sourceLeadId;
        registry.Normalized_Address__c = normalized;
        registry.Registered_DateTime__c = Datetime.now();
        // GATE A durable audit trail, RE-stamped because this IS a new claim decision — see
        // stampResolvedWindow, and the paragraph directly below for why re-stamping is not
        // optional here. Rides the existing update: no new statement, no new query.
        stampResolvedWindow(registry);
        update registry;
        insertSubmission(buildSubmission(
            sourceLeadId, sourceLeadId, sourceLeadId, extracted, submittedOn,
            forwardedByEmail, emailSubject, true
        ));
    }

    /**
     * True only when `winner` is a registration held by SOMEONE ELSE — i.e. a genuine lost
     * race. The sole gate on returning ClaimOutcome.DUPLICATE_RACE, which is the sole trigger
     * for the caller DELETING a Lead, so this predicate guards a destructive path and is
     * deliberately conservative: when in doubt it answers "not a lost race", and the worst
     * outcome is a Lead that survives when it could have been cleaned up.
     *
     * A SELF-MATCH IS NEVER A LOST RACE, and treating it as one destroys data. Two paths can
     * hand this method a registration this very claimant already owns:
     *
     *   1. registerWinner's duplicate catch. There is NO Savepoint around the try block, so a
     *      DmlException on the SUBMISSION insert does not roll back the REGISTRY row inserted
     *      one statement earlier. The catch then re-runs findMatchingRegistry, which now finds
     *      OUR OWN just-committed row. Without this guard the method would report a lost race,
     *      the caller would delete the Lead that had in fact just WON, and the registry row
     *      would be left orphaned — pointing at a deleted Lead, with the property key
     *      unclaimable until someone adopts it by hand.
     *   2. claim()'s in-lock check, via FUZZY matching. findMatchingRegistry falls back to
     *      Jaccard similarity, so a claimant re-submitting a differently-worded variant of a
     *      property they already registered ('123 main street' then '123 main street suite
     *      100') matches their own row on a DIFFERENT exact key. Unreachable through
     *      ExtractAddressQueueable today (branch (e) always claims with a freshly created
     *      Lead), but claim() is public and this is the cheaper place to be safe than to rely
     *      on every future caller minting a new Lead.
     *
     * Both callers fall through to the ordinary non-race handling when this returns false: a
     * self-match in claim() proceeds to registerWinner (registering the new key is correct —
     * the same broker may legitimately hold both), and in registerWinner's catch it continues
     * to the orphan-adoption check and ultimately the logged UNCLAIMED fall-through, which
     * leaves the Lead intact.
     *
     * @param winner       The registration findMatchingRegistry returned; null is not a race.
     * @param sourceLeadId The Lead attempting this claim.
     * @return true only when a DIFFERENT Lead holds the registration.
     */
    private static Boolean isLostRaceAgainst(Property_Registry__c winner, Id sourceLeadId) {
        return winner != null && winner.Winning_Lead__c != sourceLeadId;
    }

    /**
     * Get-or-create the Property_Claim_Lock__c row for `clusterKey`, then acquire a
     * pessimistic FOR UPDATE lock on it — the primitive that serialises concurrent
     * same-cluster claims. Acquiring the lock BLOCKS any concurrent transaction trying to
     * lock the same cluster row until this transaction commits. Retries ONCE on a lock-wait
     * timeout (~10s), then gives up so the caller can fail safe rather than crash.
     *
     * A blank cluster key (only when `normalized` itself was blank — the queueable guards
     * against that) is unlockable and returns false.
     *
     * @param clusterKey The coarse cluster partition key (from deriveClusterKey).
     * @return true when the lock was acquired; false on a blank key or a repeated lock-wait timeout.
     */
    private static Boolean acquireClusterLock(String clusterKey) {
        if (String.isBlank(clusterKey)) {
            return false;
        }
        for (Integer attempt = 0; attempt < 2; attempt++) {
            ensureLockRow(clusterKey);
            try {
                if (!PropertyClaimLockSelector.selectByClusterKeyForUpdate(clusterKey).isEmpty()) {
                    return true;
                }
                // Row absent right after ensureLockRow (e.g. a concurrent rollback removed it):
                // loop once more to recreate + re-lock.
            } catch (QueryException qe) {
                // FOR UPDATE lock-wait timeout (UNABLE_TO_LOCK_ROW): another same-cluster claim
                // holds the lock. Retry once; a second timeout returns false (caller fails safe).
                System.debug(LoggingLevel.WARN,
                    'PropertyClaimService.acquireClusterLock: lock-wait on cluster "' + clusterKey
                    + '" (attempt ' + (attempt + 1) + '): ' + qe.getMessage());
            }
        }
        return false;
    }

    /**
     * Ensure a Property_Claim_Lock__c row exists for `clusterKey` without introducing a new
     * race: read first (via the selector) and insert only when absent. A concurrent creator
     * that wins the unique Cluster_Key__c index is treated as success — that row is the one
     * this transaction will lock. This is the ONLY place a lock row is inserted; a single
     * insert, never in a loop.
     *
     * @param clusterKey The coarse cluster partition key.
     */
    private static void ensureLockRow(String clusterKey) {
        if (!PropertyClaimLockSelector.selectByClusterKey(clusterKey).isEmpty()) {
            return;
        }
        try {
            insert new Property_Claim_Lock__c(Cluster_Key__c = clusterKey);
        } catch (DmlException de) {
            // A concurrent transaction inserted the same cluster row first — fine, we lock
            // theirs. Any other DML error is a genuine failure and propagates.
            if (!isDuplicateValue(de)) {
                throw de;
            }
        }
    }

    /**
     * Record a COMPETING SUBMISSION against an existing winner: one non-winning
     * Competing_Broker_Submission__c rolled up under `winner.Winning_Lead__c`. Public so the
     * queueable can log a competing claim directly when its own read already found the winner
     * (i.e. without racing the insert).
     *
     * NO LEAD IS WRITTEN — changed 2026-07-31. This method used to also stamp
     * Is_Duplicate_Property__c / Duplicate_Of_Lead__c on the losing Lead; it performs no Lead
     * DML at all now. See the class header for the two reasons (Lead-table pollution, and the
     * DUPLICATES_DETECTED-rolls-back-the-Savepoint failure class). The submission row is the
     * complete record of a competing claim.
     *
     * `sourceLeadId` IS OPTIONAL, AND NULL IS THE NORMAL COMPETING-BROKER SHAPE. A competing
     * broker no longer receives a Lead, so their submission has no source Lead to point at —
     * ExtractAddressQueueable's competing branch passes null deliberately, and the
     * competingBrokerSubmissions LWC on the winning Lead renders those rows from
     * Broker_Email__c / Broker_Name__c instead. A non-null value is passed only from the
     * lost-race paths inside this class, where a Lead really does exist at that instant (the
     * caller then deletes it, and Source_Lead__c's SetNull delete constraint clears the
     * lookup). Because the submission may be the ONLY record of who the broker was,
     * `extracted` must already carry a usable broker_email — the queueable backfills it from
     * the envelope From address when the LLM returned nothing.
     *
     * ⚠ THE WINNER ANCHOR IS THE CALLER'S TO SUPPLY (2026-08-03). `winner.Winning_Lead__c` may
     * by now be a CONVERTED Lead — the winning broker's deal went live between their claim and
     * this competing email — and a Lead lookup cannot be set to one. `winningRecordId` carries
     * what that Lead resolves to today, which the queueable has ALREADY computed for the Task
     * target, so the rule costs no extra query on the branch that fires most. See the class
     * header's WINNER ANCHOR note and buildSubmission.
     *
     * @param winner          The current winning Property_Registry__c row.
     * @param sourceLeadId    The Lead this inbound email produced, or NULL when no Lead was
     *                        created for it (the normal competing-broker case).
     * @param winningRecordId What `winner.Winning_Lead__c` resolves to NOW — itself when the Lead
     *                        is still open, its Opportunity/Contact once converted
     *                        (PropertyMatchingService.resolveLiveRecord).
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     */
    public static void markDuplicate(Property_Registry__c winner, Id sourceLeadId,
                                     Id winningRecordId, Map<String, String> extracted,
                                     Datetime submittedOn, String forwardedByEmail,
                                     String emailSubject) {
        insertSubmission(buildSubmission(
            winner.Winning_Lead__c, sourceLeadId, winningRecordId, extracted, submittedOn,
            forwardedByEmail, emailSubject, false
        ));
    }

    /**
     * Log a REPEAT submission: the same broker emailing again about a property they have
     * already submitted. Inserts an audit row ONLY — no registry write, no duplicate flag
     * on the Lead.
     *
     * This is deliberately NOT markDuplicate, even though neither writes to a Lead any more.
     * The distinction is the OUTCOME LABEL and the routing target, not the DML: a repeat is
     * filed on the record the broker's earlier email already produced, whereas a competing
     * submission is filed on someone else's winning Lead. Nor is a repeat a claim: re-running
     * claim() would take the cluster lock and re-derive a winner that has not changed. All
     * that is genuinely new is the fact that another email arrived, which is exactly one
     * append-only audit row.
     *
     * BOTH BROKERS' REPEATS LAND HERE, and `sourceLeadId` is what distinguishes them. The
     * WINNER re-emailing passes their own Lead. A COMPETING broker re-emailing passes NULL —
     * they never received a Lead, so their follow-up appends a source-less row under the same
     * winner their first submission was filed under, and the email itself is logged on the
     * winning Lead. Suppressing that row instead would be simpler but wrong:
     * ARCHITECTURE.md §1 defines Competing_Broker_Submission__c as the append-only trail of
     * EVERY inbound broker email that matched a property, and dropping the second one would
     * erase the evidence that the broker chased the property twice.
     *
     * The routing DECISION (that this email is a repeat) belongs to
     * ExtractAddressQueueable; this method exists so the resulting DML still lands in the
     * class that owns Competing_Broker_Submission__c writes.
     *
     * ⚠ THIS IS THE METHOD THE 2026-08-03 PRODUCTION FAILURE THREW FROM, and the reason is
     * structural rather than unlucky: a repeat is BY DEFINITION a second email about a property
     * someone already won, so it is the first write whose winner Lead has had time to be
     * converted — and a Lead lookup cannot be set to a converted Lead. `winningRecordId` is what
     * that Lead resolves to now; the queueable computes it once and uses it for both this row and
     * the Task target. See the class header's WINNER ANCHOR note.
     *
     * @param winningLeadId   The Lead that holds the property claim (from the prior
     *                        submission); falls back to `sourceLeadId` when null.
     * @param sourceLeadId    The existing Lead this repeat email is filed against, or NULL
     *                        when the repeating broker has none (a competing broker).
     * @param winningRecordId What the winning Lead resolves to NOW — itself when still open, its
     *                        Opportunity/Contact once converted
     *                        (PropertyMatchingService.resolveLiveRecord).
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     * @example
     * PropertyClaimService.logRepeatSubmission(prior.Winning_Lead__c, prior.Source_Lead__c,
     *     liveWinnerId, extracted, submittedOn, fwd, subject);
     */
    public static void logRepeatSubmission(Id winningLeadId, Id sourceLeadId, Id winningRecordId,
                                           Map<String, String> extracted, Datetime submittedOn,
                                           String forwardedByEmail, String emailSubject) {
        Id anchorLeadId = winningLeadId;
        Id anchorRecordId = winningRecordId;
        if (anchorLeadId == null && anchorRecordId == null) {
            // NEITHER anchor supplied — the pre-2026-08-03 "fall back to the Lead this repeat is
            // filed against" behaviour, preserved for direct callers. ⚠ The null-winningLeadId
            // test alone is NOT sufficient any more: a prior row anchored on an OPPORTUNITY also
            // has a null winningLeadId, and falling back to sourceLeadId there would discard a
            // perfectly good anchor and write a Lead-shaped row instead.
            anchorLeadId = sourceLeadId;
            anchorRecordId = resolveWinnerRecord(sourceLeadId);
        }
        insertSubmission(buildSubmission(
            anchorLeadId, sourceLeadId, anchorRecordId,
            extracted, submittedOn, forwardedByEmail, emailSubject, false
        ));
    }

    /**
     * Build (not insert) a Competing_Broker_Submission__c from the extracted fields.
     * `extracted` is null-coalesced so a missing map never NPEs on .get(); a missing key
     * simply yields null on its field.
     *
     * FIELD SAFETY IS LOAD-BEARING HERE, not decoration. Every value below originates from
     * an LLM extraction or a raw email header — neither respects Salesforce field limits.
     * Broker_Name__c / Property_Address_Raw__c / Email_Subject__c are Text(255) and the two
     * address fields are Email(80) with a format check, so an over-long address or a
     * "broker_email" that came back as a display name would throw on insert and roll back
     * the ENTIRE claim for an otherwise valid email. Clipping and sanitizing here means the
     * worst case is a blank field on the audit row instead of a lost registration.
     *
     * ═══ 🔴 THE WINNER ANCHOR IS DECIDED HERE, AND ONLY HERE ═══
     * `winningRecordId` is what `winningLeadId` resolves to NOW. Comparing the two is the whole
     * conversion test — no extra query, no IsConverted flag threaded through four signatures:
     *
     *   • equal (or `winningRecordId` null)  -> the Lead is OPEN. Write `Winning_Lead__c` and
     *                                           `Source_Lead__c` exactly as before this change.
     *   • different, and an Opportunity      -> the Lead is CONVERTED. Write
     *                                           `Winning_Opportunity__c` and leave BOTH Lead
     *                                           lookups null, because the platform rejects a
     *                                           lookup SET to a converted Lead
     *                                           (CANNOT_UPDATE_CONVERTED_LEAD).
     *   • different, and NOT an Opportunity  -> converted to a Contact only. There is nowhere to
     *                                           anchor the row; returns null (see below).
     *
     * ⚠ `Source_Lead__c` IS NULLED TOO ON THE CONVERTED PATH, AND IT COSTS NOTHING. Per the
     * field's own description a persisted `Source_Lead__c` is either null or EQUAL to
     * `Winning_Lead__c`, so on the converted path it is the same converted Lead and equally
     * unwritable. The one shape where they genuinely differ is the lost-race path, where the
     * source Lead is deleted moments later and SetNull would blank the lookup anyway.
     *
     * ⚠ RETURNING NULL IS A DELIBERATE, NARROW DEGRADATION — a Lead converted to a Contact with
     * NO Opportunity. Neither lookup can be populated, so the row would fail the
     * Winning_Lead_Required validation rule; inserting it anyway would throw and abandon the
     * whole property's routing, which is the exact failure this change exists to remove. Losing
     * one audit row is strictly better than losing the email, and the caller logs it. It is also
     * close to unreachable here: LeadConvertService always produces an Opportunity in this org
     * (Database.LeadConvert.setDoNotCreateOpportunity(true) throws on it).
     *
     * @param winningLeadId   The Lead that holds the property claim.
     * @param sourceLeadId    The lead this specific email produced, or null when it produced
     *                        none (a competing broker gets no Lead).
     * @param winningRecordId What `winningLeadId` resolves to now (itself / Opportunity / Contact).
     * @param extracted       LLM-extracted field map (may be null).
     * @param submittedOn     Submitted_DateTime__c — the email's original send time.
     * @param forwardedByEmail Forwarded_By_Email__c — internal forwarder.
     * @param emailSubject    Email_Subject__c — the inbound email subject.
     * @param isWinner        Is_Winning_Submission__c — true for the winning submission.
     * @return The unsaved Competing_Broker_Submission__c, or NULL when the winner can be
     *         anchored to neither a Lead nor an Opportunity.
     */
    private static Competing_Broker_Submission__c buildSubmission(
            Id winningLeadId, Id sourceLeadId, Id winningRecordId, Map<String, String> extracted,
            Datetime submittedOn, String forwardedByEmail, String emailSubject, Boolean isWinner) {
        Map<String, String> fields = (extracted == null) ? new Map<String, String>() : extracted;
        Competing_Broker_Submission__c row = new Competing_Broker_Submission__c(
            Broker_Name__c = InboundEmailFieldUtil.clip(fields.get('broker_name'), LEN_TEXT),
            Broker_Email__c = InboundEmailFieldUtil.sanitizeEmail(fields.get('broker_email')),
            Forwarded_By_Email__c = InboundEmailFieldUtil.sanitizeEmail(forwardedByEmail),
            Property_Address_Raw__c = InboundEmailFieldUtil.clip(fields.get('property_address'), LEN_TEXT),
            Submitted_DateTime__c = submittedOn,
            Email_Subject__c = InboundEmailFieldUtil.clip(emailSubject, LEN_TEXT),
            Is_Winning_Submission__c = isWinner
        );

        if (winningRecordId == null || winningRecordId == winningLeadId) {
            row.Winning_Lead__c = winningLeadId;
            row.Source_Lead__c = sourceLeadId;
            return row;
        }
        if (winningRecordId.getSObjectType() == Opportunity.SObjectType) {
            row.Winning_Opportunity__c = winningRecordId;
            return row;
        }
        System.debug(LoggingLevel.WARN,
            'PropertyClaimService.buildSubmission: winning Lead ' + winningLeadId
            + ' is converted with no Opportunity (resolved to ' + winningRecordId
            + '); the submission row has nothing to anchor to and is skipped.');
        return null;
    }

    /**
     * Insert a submission row, tolerating the one case buildSubmission cannot build.
     *
     * A null row means "the winner could be anchored to neither a Lead nor an Opportunity" — see
     * buildSubmission. Skipping is the data-preserving answer: the alternative is a validation
     * failure that aborts the property's whole routing branch and costs the email its Task.
     *
     * @param row The row to insert; null is a deliberate no-op.
     */
    private static void insertSubmission(Competing_Broker_Submission__c row) {
        if (row == null) {
            return;
        }
        insert row;
    }

    /**
     * What a winning Lead resolves to today — itself while open, its Opportunity/Contact once
     * converted. A thin, named delegation to PropertyMatchingService.resolveLiveRecord so the
     * conversion question has ONE answer across the module.
     *
     * ⚠ ONE SOQL. Call it only where the caller does not already hold the answer:
     * ExtractAddressQueueable's branches (b) and (d) resolve the live record for the Task target
     * anyway and PASS IT IN, which is what keeps this fix flat on the per-property query budget
     * the queueable asserts. The two call sites here are the lost-race paths, which are rare and
     * have no pre-resolved value to reuse.
     *
     * @param winningLeadId The winning Lead; null returns null.
     * @return The live record Id, or null.
     */
    private static Id resolveWinnerRecord(Id winningLeadId) {
        return PropertyMatchingService.resolveLiveRecord(winningLeadId);
    }

    /**
     * True when a DmlException is a unique-key / external-id collision — i.e. this claim
     * lost the race for Property_Key__c. Checks every failed row's StatusCode for
     * DUPLICATE_VALUE / DUPLICATE_EXTERNAL_ID, then falls back to a message scan for
     * 'DUPLICATE_VALUE' (covers wrappers that do not surface a per-row StatusCode).
     *
     * @param de The caught DmlException.
     * @return true if the failure is a duplicate-value collision.
     */
    private static Boolean isDuplicateValue(DmlException de) {
        for (Integer i = 0; i < de.getNumDml(); i++) {
            StatusCode code = de.getDmlType(i);
            if (code == StatusCode.DUPLICATE_VALUE || code == StatusCode.DUPLICATE_EXTERNAL_ID) {
                return true;
            }
        }
        return de.getMessage() != null && de.getMessage().contains('DUPLICATE_VALUE');
    }
}
