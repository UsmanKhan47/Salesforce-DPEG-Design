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
 * PropertyRegistrySelector — this class contains NO SOQL. Its DML is deliberately
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
            markDuplicate(winner, sourceLeadId, extracted, submittedOn, forwardedByEmail, emailSubject);
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
     * @return WINNER when the registration (or orphan adoption) succeeded, DUPLICATE_RACE
     *         when the key collision reconciled to an existing winner (the caller's Lead must
     *         then be deleted — see the ClaimOutcome doc), UNCLAIMED when the key exists but
     *         has neither a live winner nor an adoptable orphan.
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
            insert registry;
            insert buildSubmission(
                sourceLeadId, sourceLeadId, extracted, submittedOn,
                forwardedByEmail, emailSubject, true
            );
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
                markDuplicate(winner, sourceLeadId, extracted, submittedOn, forwardedByEmail, emailSubject);
                return ClaimOutcome.DUPLICATE_RACE;
            }
            Property_Registry__c orphan = PropertyMatchingService.findOrphanedRegistry(normalized);
            if (orphan != null) {
                // The unique key exists but its winner was deleted (SetNull). Adopt it,
                // else the key is unclaimable forever.
                orphan.Winning_Lead__c = sourceLeadId;
                orphan.Normalized_Address__c = normalized;
                orphan.Registered_DateTime__c = Datetime.now();
                update orphan;
                insert buildSubmission(
                    sourceLeadId, sourceLeadId, extracted, submittedOn,
                    forwardedByEmail, emailSubject, true
                );
                return ClaimOutcome.WINNER;
            }
            // Duplicate key but neither a live winner nor an orphan row — nothing safe to
            // attach this submission to. Log and drop it.
            System.debug(LoggingLevel.WARN,
                'PropertyClaimService.registerWinner: duplicate key "' + normalized + '" but no '
                + 'live winner and no orphan row found; skipping. sourceLeadId=' + sourceLeadId);
            return ClaimOutcome.UNCLAIMED;
        }
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
     * @param winner          The current winning Property_Registry__c row.
     * @param sourceLeadId    The Lead this inbound email produced, or NULL when no Lead was
     *                        created for it (the normal competing-broker case).
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     */
    public static void markDuplicate(Property_Registry__c winner, Id sourceLeadId,
                                     Map<String, String> extracted, Datetime submittedOn,
                                     String forwardedByEmail, String emailSubject) {
        insert buildSubmission(
            winner.Winning_Lead__c, sourceLeadId, extracted, submittedOn,
            forwardedByEmail, emailSubject, false
        );
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
     * @param winningLeadId   The Lead that holds the property claim (from the prior
     *                        submission); falls back to `sourceLeadId` when null.
     * @param sourceLeadId    The existing Lead this repeat email is filed against, or NULL
     *                        when the repeating broker has none (a competing broker).
     * @param extracted       LLM-extracted fields stamped onto the submission.
     * @param submittedOn     The email's original send time.
     * @param forwardedByEmail Internal user who forwarded the broker email.
     * @param emailSubject    The inbound email subject.
     * @example
     * PropertyClaimService.logRepeatSubmission(
     *     prior.Winning_Lead__c, prior.Source_Lead__c, extracted, submittedOn, fwd, subject);
     */
    public static void logRepeatSubmission(Id winningLeadId, Id sourceLeadId,
                                           Map<String, String> extracted, Datetime submittedOn,
                                           String forwardedByEmail, String emailSubject) {
        insert buildSubmission(
            (winningLeadId == null) ? sourceLeadId : winningLeadId,
            sourceLeadId, extracted, submittedOn, forwardedByEmail, emailSubject, false
        );
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
     * @param winningLeadId   Winning_Lead__c — the lead that holds the property claim.
     *                        Required by the Winning_Lead_Required validation rule on insert.
     * @param sourceLeadId    Source_Lead__c — the lead this specific email produced, or null
     *                        when it produced none (a competing broker gets no Lead).
     * @param extracted       LLM-extracted field map (may be null).
     * @param submittedOn     Submitted_DateTime__c — the email's original send time.
     * @param forwardedByEmail Forwarded_By_Email__c — internal forwarder.
     * @param emailSubject    Email_Subject__c — the inbound email subject.
     * @param isWinner        Is_Winning_Submission__c — true for the winning submission.
     * @return The unsaved Competing_Broker_Submission__c.
     */
    private static Competing_Broker_Submission__c buildSubmission(
            Id winningLeadId, Id sourceLeadId, Map<String, String> extracted,
            Datetime submittedOn, String forwardedByEmail, String emailSubject, Boolean isWinner) {
        Map<String, String> fields = (extracted == null) ? new Map<String, String>() : extracted;
        return new Competing_Broker_Submission__c(
            Winning_Lead__c = winningLeadId,
            Source_Lead__c = sourceLeadId,
            Broker_Name__c = InboundEmailFieldUtil.clip(fields.get('broker_name'), LEN_TEXT),
            Broker_Email__c = InboundEmailFieldUtil.sanitizeEmail(fields.get('broker_email')),
            Forwarded_By_Email__c = InboundEmailFieldUtil.sanitizeEmail(forwardedByEmail),
            Property_Address_Raw__c = InboundEmailFieldUtil.clip(fields.get('property_address'), LEN_TEXT),
            Submitted_DateTime__c = submittedOn,
            Email_Subject__c = InboundEmailFieldUtil.clip(emailSubject, LEN_TEXT),
            Is_Winning_Submission__c = isWinner
        );
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
