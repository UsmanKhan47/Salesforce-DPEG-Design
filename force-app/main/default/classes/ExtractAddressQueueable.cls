/**
 * Broker-Protection inbound-email intake — async router (staging model). One instance is
 * enqueued per inbound broker email by EmailToLeadHandler, carrying the Id of the
 * Inbound_Email_Staging__c row that email was landed on. In an async, callout-capable
 * context it asks the LLM who the broker is and WHICH PROPERTIES they are pitching, then
 * runs the ROUTING TREE that decides what that email actually is — and only then, if at
 * all, creates a Lead.
 *
 * ═══ THE ROUTING TREE (rewritten 2026-07-31 for D1 multi-property + D2 relevance gate) ═══
 * Three phases now: an email-level PROLOGUE that runs once, a PER-PROPERTY LOOP, and an
 * email-level EPILOGUE that runs once. Inside the loop the first branch that matches wins,
 * and the order is not arbitrary — each branch is a reason NOT to do what the branch below
 * it would do.
 *
 *   EMAIL-LEVEL PROLOGUE (once)
 *    0. staging Status == 'Processed'        -> skip; the row is already terminal.
 *    1. Message-ID already on a Task         -> skip; the platform is redelivering.
 *    2. (a) REPLY — In-Reply-To / References cite a thread this pipeline already logged.
 *           Filed on that conversation's record, following a converted Lead through to its
 *           live Opportunity. NO LEAD, and ** NO CALLOUT ** (C-6).
 *    3. DETERMINISTIC PRE-FILTER (noreply / mailer-daemon / auto-submitted headers)
 *           -> gated. NO LEAD, NO CLAIM, ** NO CALLOUT **. Task still logged.
 *    4. LLM CALLOUT — exactly one per job, still. Its text input is the SUBJECT LINE + the
 *           body (2026-08-03, FIX 1 — see buildLlmText): brokers routinely put the offer
 *           deadline, the unit count, the asset name and the market in the subject and nowhere
 *           else. Composed HERE, not in the callout service, and BEFORE the callout so the
 *           40,000-char clip (which preserves the head) can never drop it. A blank subject
 *           returns the body byte-identically.
 *    5. Extracted_JSON__c written VERBATIM, before any routing decision (D3).
 *    6. Regex + envelope broker fallbacks, then SENDER-FIRST BROKER IDENTITY (email-level).
 *           2026-08-03, intake-rules-v2 / U1: the envelope From_Address__c IS THE BROKER and
 *           OUTRANKS any body-extracted identity; whoever the BODY names is demoted to the
 *           listing contact. Every email in this pipeline is a forward from DPEG's
 *           coordinator, so From_Address__c already carries the ORIGINAL SENDER and
 *           Forwarded_By__c carries the coordinator. Guarded by the paste-forward test
 *           (From == Forwarded_By, or a blank/malformed From) which falls back to the
 *           body-extracted identity. See applySenderFirstBrokerIdentity.
 *    7. RELEVANCE GATE (D2, tiered):
 *           HARD (is_acquisition_related = false AND confidence >= 0.85)
 *                -> NO LEAD, NO CLAIM, Task logged, outcome recorded.
 *           SOFT (false but less certain) -> continue, Parse_Confidence__c = LOW,
 *                and STILL CLAIM.
 *    7b. CALL-FOR-OFFERS GATE (2026-08-03, intake-rules-v2 / U2). email_category is
 *           'call_for_offers' -> NO LEAD, NO CLAIM, Task logged. Unconditional: DPEG does not
 *           work marketed call-for-offers campaigns. Nothing is lost — the staging row keeps
 *           the raw body and the full Extracted_JSON__c, and the Gated_Call_For_Offers list
 *           view is how the population is found. Deliberately POST-CALLOUT: see the
 *           SENDER_CONTAINS block for why a pre-callout blast filter is still prohibited.
 *    8. Build the property work-list: drop blank addresses, de-duplicate on the NORMALIZED
 *           address, SORT by cluster key, truncate to MAX_PROPERTIES.
 *           Empty work-list -> (c) NO-PROPERTY: ONE Lead, no claim, done.
 *           (c) STAMPS THE FIRST PROPERTY'S DEAL BLOCK when the email named one it could not
 *           address (2026-08-03, FIX 2). Same LeadRequest.property / applyPropertyBlock path
 *           the winner branch uses; Property_Address__c stays null, enforced by
 *           claimableAddress(). Outcome is OUTCOME_NO_ADDRESS rather than OUTCOME_NO_PROPERTY.
 *           ⚠ STILL NO CLAIM — see routeNoProperty's residual note: these Leads have no
 *           first-broker-wins protection, and a later broker submitting the same property WITH
 *           an address wins it outright.
 *
 *   PER-PROPERTY LOOP (each property, in sorted order, isolated by try/catch)
 *    (b) REPEAT    — the same broker has already submitted THIS property inside the lookback
 *                    window. It is a follow-up, so it is filed on the record their earlier
 *                    email already produced, with an audit row. NO new Lead. This precedes
 *                    the competing branch because a broker chasing their own submission is
 *                    not a competing broker and must never be treated as one. The WINNER's
 *                    repeat lands on their own Lead; a COMPETING broker's repeat lands on the
 *                    WINNING Lead, because they have no Lead of their own (see branch (d)).
 *    (d) COMPETING — the property is already claimed by a DIFFERENT broker. NO LEAD IS
 *       SUBMISSION   CREATED. The claim is recorded as a Competing_Broker_Submission__c
 *                    against the winner (Source_Lead__c = null), and the email is logged on
 *                    the WINNING Lead so the property's whole story lives in one place. Note
 *                    the ordering inside this branch: the registry read happens BEFORE
 *                    createLead, so no orphan Lead is ever minted and then abandoned.
 *    (e) WINNER    — nobody has claimed this property. A Lead is created and takes the claim
 *                    under the cluster lock. If the claim comes back DUPLICATE_RACE — a
 *                    concurrent submission won between this job's read and its lock — that
 *                    Lead is DELETED and the email is re-routed exactly like branch (d).
 *
 *   EMAIL-LEVEL EPILOGUE (once)
 *    9.  ONE Task per DISTINCT routed record, ONE bulk DML, ASCENDING PRIORITY (C-2 / C-3) —
 *        which is what makes branch (a) possible for the NEXT email.
 *    10. Stamp staging: Outcome__c (summary), Result_Record_Id__c (primary),
 *        Routed_Record_Ids__c (all N), Property_Count__c, Processed_DateTime__c.
 *
 * ═══ 🔴 WHY THE LOOP IS ORDERED BY CLUSTER KEY — THE DEADLOCK FIX ═══
 * PropertyClaimService.claim() takes a pessimistic FOR UPDATE lock on the address cluster,
 * and APEX CANNOT RELEASE A ROW LOCK BEFORE COMMIT. A job claiming N properties therefore
 * holds N locks at once. Two concurrent multi-property emails sharing two properties are a
 * textbook AB-BA cycle:
 *
 *     Job A (Royal Inn, Bass Inn)        Job B (Bass Inn, Royal Inn)
 *       lock "1400 royal"   OK             lock "220 bass"    OK
 *       lock "220 bass"     blocked        lock "1400 royal"  blocked
 *
 * Salesforce does not detect or report this as a deadlock. Both sides hit the ~10s lock-wait,
 * acquireClusterLock retries once, both give up, and claim() FAILS SAFE to
 * ClaimOutcome.UNCLAIMED — leaving a Lead that holds no claim, with only a System.debug to
 * show for it. Broker protection would fail SILENTLY on exactly the blast emails D1 exists
 * to support.
 *
 * The fix costs nothing and adds no API: visit properties in ascending deriveClusterKey
 * order (ties broken by normalized address). Because every transaction visits shared clusters
 * in the same relative order, no wait-for cycle can form — the loser simply blocks on the
 * first shared key and proceeds once the winner commits. Three rules the fix depends on, all
 * easy to get wrong:
 *   • the sort key comes ONLY from the address, NEVER from the LLM's array order, which is
 *     not stable across transactions (PropertyExtraction.compareTo owns this);
 *   • de-duplication is on the NORMALIZED ADDRESS, never on the cluster key — the key is
 *     deliberately coarse, so two different buildings can share one, and re-locking the same
 *     row inside a transaction is a harmless no-op;
 *   • locks are NOT hoisted up front. That would extend the last cluster's hold time across
 *     the whole loop for no correctness gain; sorted lazy acquisition already removes the
 *     cycle.
 * A lock timeout is now genuine CONTENTION rather than a deadlock, and it stops being
 * invisible: the staging Outcome__c gains a ' [unclaimed: lock timeout]' suffix.
 *
 * True concurrency is not reproducible in Apex, so the honest coverage is (i) direct unit
 * tests of the ordering (a pure function) and (ii) an end-to-end assertion that
 * Routed_Record_Ids__c comes back in cluster-key order for a scrambled input array.
 *
 * ═══ PER-PROPERTY ISOLATION — AND WHY THERE IS STILL NO SAVEPOINT ═══
 * Each iteration is wrapped so a failure on one property records an Error outcome and the
 * loop CONTINUES: without that, one bad property would roll back a legitimate claim on
 * another. The staging row then records Status 'Error' PLUS the outcomes that did succeed —
 * exactly the partial-success contract the routed-outcome members were introduced for.
 *
 * ⚠ Do NOT reach for a Savepoint to isolate iterations. There is deliberately none in this
 * module, and PropertyClaimService.isLostRaceAgainst's Javadoc depends on that fact for its
 * self-match reasoning — which is what guards the destructive Lead delete. try/catch +
 * continue is the correct isolation primitive here.
 *
 * ═══ WHY A COMPETING BROKER GETS NO LEAD (changed 2026-07-31) ═══
 * Branches (d) and (e)'s lost-race path used to create a Lead flagged
 * Is_Duplicate_Property__c with Duplicate_Of_Lead__c pointing at the winner. Two independent
 * problems killed that design, and both are worth keeping in view because either alone
 * justifies the change:
 *   1. LEAD-TABLE POLLUTION — one junk Lead per competing broker per property, none of which
 *      anyone works, and which nothing in the app ever displayed.
 *   2. DUPLICATES_DETECTED / SAVEPOINT ROLLBACK — orgs commonly run Lead duplicate rules on
 *      Email. Inserting a second Lead with a broker's address throws DUPLICATES_DETECTED, the
 *      surrounding Savepoint rolls back the WHOLE transaction, and the inbound email's Task is
 *      silently lost. Not inserting the Lead removes that entire failure class structurally
 *      instead of defending against it case by case.
 * The two Lead fields survive as LEGACY for historical rows; no code path writes them.
 *
 * ═══ IDEMPOTENCY ═══
 * Two guards, before any work: a staging row already marked 'Processed' is never re-run, and
 * an RFC Message-ID already present on a Task means the platform is redelivering a message
 * that was already routed. A BLANK Message-ID skips only the second guard and proceeds
 * normally — some forwarding paths strip the header, and refusing those emails would be far
 * worse than reprocessing a rare duplicate.
 *
 * ═══ DEGRADED EXTRACTION (LLM OUTAGE OR MALFORMED REPLY) ═══
 * A failure at the LLM boundary — a 429, a 5xx, a timeout, a truncated reply — is NOT a
 * failure of this pipeline, it is the absence of one optional input. It is therefore caught
 * at the callout itself and DEGRADES rather than aborts: extraction becomes an empty result,
 * the regex fallback still recovers the broker's name and email from the raw "From:" line,
 * and routing proceeds normally. Because the regex fallback never yields a property address,
 * the degraded path can only ever reach branch (a) or branch (c) — so a real Lead is always
 * created (or an existing thread correctly reused) and the broker is never silently dropped
 * because OpenAI was rate-limiting. The staging row records OUTCOME_NO_PROPERTY_LLM_DOWN so
 * outage-degraded Leads are distinguishable from genuinely addressless emails and can be
 * re-extracted by hand.
 *
 * The alternative — treating the outage as an error and stamping Status 'Error' — left the
 * email on a staging row with no Lead, no Task, no notification and no claim: an
 * indistinguishable-from-lost broker submission caused by a transient third-party 429.
 *
 * ⚠ DELIBERATE REVERSAL, 2026-07-31 (design C-14) — DO NOT "RESTORE" THE OLD COMMENT.
 * This catch used to be narrowed to CalloutException ONLY, with the stated reasoning that
 * "a parsing/JSON failure inside extract() is a defect in our own contract and still escapes
 * to the error handler below". That reasoning was correct for a 512-token, four-key response
 * and is WRONG for this one. The enriched contract is ~8x larger, so a malformed or truncated
 * reply is no longer a defect in our contract — it is the same category of event as an
 * outage: an absent optional input. The consequences are wildly asymmetric. Degrading loses
 * the ADDRESS; erroring loses the EMAIL — no Lead, no Task, no claim, on a staging row nobody
 * reads. The catch is therefore widened to JSONException, with a defensive Exception arm
 * behind it. MAX_TOKENS 4096 and OpenAI JSON mode make truncation unlikely; this makes it
 * survivable.
 *
 * ═══ LAYER ═══
 * Queueable orchestrator. It contains NO SOQL and NO DML of its own — every read goes through
 * a service (InboundEmailStagingService, PropertyMatchingService, InboundEmailActivityService)
 * and every write through the service that owns that object (EmailToLeadService for the Lead —
 * both its insert and, on the lost-race path, its delete; PropertyClaimService for the
 * registry/submissions, InboundEmailActivityService for the Task, InboundEmailStagingService
 * for the staging row). The only external call is via
 * LLMExtractionCalloutService, the dedicated callout wrapper — this class implements
 * Database.AllowsCallouts so that boundary can run here and be mocked via HttpCalloutMock.
 *
 * There is NO configuration read of any kind — intake-rules-v2's rules are both unconditional, so
 * the Custom Metadata accessor an earlier draft introduced was deleted rather than shipped dark.
 *
 * `with sharing` is declared for standards conformance (ARCHITECTURE.md §2). It is functionally
 * a no-op here because the class performs no SOQL/DML directly — the classes it delegates to
 * enforce their own sharing.
 *
 * ═══ ERROR MODEL ═══
 * execute() swallows every REMAINING exception rather than letting the job fail (the callout
 * boundary is handled separately — see DEGRADED EXTRACTION). The email is already
 * durable on the staging row, so nothing is lost; the failure is written back to that row
 * (Status 'Error' plus the full stack trace) ALONGSIDE whatever outcome had already been
 * reached, so a Task-insert failure after a successful claim is recorded as both, not as a
 * blanket failure. Re-throwing would instead hand the platform an async failure with no
 * record of the work that did commit.
 *
 * ⚠ THAT PROMISE WAS ONLY HALF-KEPT UNTIL 2026-08-03, AND THE GAP COST AN INCIDENT. The
 * PER-PROPERTY isolation catch recorded the exception TYPE in the Outcome__c label and threw the
 * message, line and stack away, because it could not reach finish()'s stamp — so staging row
 * a0aiw000000OCckAAG read `Outcome__c = 'Error (System.DmlException)'` with `Error__c` NULL and
 * `Status__c = 'Processed'`. Both catches now funnel through describeFailure() into the
 * `routingErrors` member, which finish() persists; see routingErrorText() for why a partial
 * failure now correctly stamps Status 'Error', and why the Message-ID guard — not the Status
 * guard — is what keeps a redelivery from re-running the pipeline.
 *
 * @see EmailToLeadHandler.cls (creates the staging row and enqueues this job)
 * @see LLMExtractionCalloutService.cls (the mocked callout boundary)
 * @see PropertyMatchingService.cls / PropertyClaimService.cls (the first-broker-wins engine)
 */
public with sharing class ExtractAddressQueueable implements Queueable, Database.AllowsCallouts {

    /**
     * Properties routed from a single email. 10 leaves >2x headroom on the BINDING governor —
     * SOQL, at ~8 queries per property on the winner path (~14 worst case) against the async
     * cap of 200 — and sits comfortably above any real broker blast (the motivating email
     * carries two).
     *
     * Above the cap the email TRUNCATES VISIBLY, never silently: the first 10 in SORTED order
     * are processed (deterministic, not "whatever the model listed first"), Extracted_JSON__c
     * still holds all M verbatim, Property_Count__c records M while Routed_Record_Ids__c has
     * 10 lines — the discrepancy IS the signal — the outcome gains a ' [truncated: 10 of M]'
     * suffix, and the remainder is written onto the first Lead's Deal_Notes__c.
     *
     * Queueable CHAINING for 11+ is DEFERRED, not rejected: it is feasible (the callout is
     * already done and the JSON is on staging, so a child job needs no second callout, and the
     * parent commits and releases its locks before the child starts). It is deferred because it
     * doubles the state machine for a case with no observed occurrences. Raising this constant
     * — or wiring chaining later — stays a small, local change.
     */
    public static final Integer MAX_PROPERTIES = 10;

    /**
     * Inbound_Email_Staging__c.Outcome__c labels — one per routing-tree branch. PUBLIC on
     * purpose: these strings are the pipeline's reporting contract (they are what an admin
     * filters an Inbound Email Staging list view on), so tests and any future dashboard bind
     * to the constant rather than re-typing the literal.
     */
    public static final String OUTCOME_DUPLICATE_DELIVERY = 'Duplicate Delivery (skipped)';
    public static final String OUTCOME_REPLY = 'Reply Thread';
    public static final String OUTCOME_REPEAT = 'Repeat';
    public static final String OUTCOME_NO_PROPERTY = 'New Lead (no property)';
    /** Branch (c) reached because the LLM was unreachable, not because the email had no
     *  address. Kept distinct from OUTCOME_NO_PROPERTY on purpose: these are the only Leads
     *  worth re-extracting once the outage clears, and an admin needs to be able to list
     *  exactly them. */
    public static final String OUTCOME_NO_PROPERTY_LLM_DOWN = 'New Lead (no property) — LLM unavailable';
    /** Branch (c) reached with a NAMED property the pipeline could not address. Distinct from
     *  OUTCOME_NO_PROPERTY for the same reason OUTCOME_NO_PROPERTY_LLM_DOWN is — THE FOLLOW-UP
     *  DIFFERS. These Leads carry the full deal-screening block (name, units, price, due date,
     *  asset type …) but hold NO first-broker-wins claim, because an addressless property cannot
     *  produce a Property_Key__c; a later broker who submits the same property WITH an address
     *  wins it outright. An admin must be able to list exactly this population in order to chase
     *  the address, which is the only mitigation that exists. Outcome__c is free Text and
     *  historical rows are deliberately NOT back-filled — same precedent as the retired
     *  'Competing Duplicate' label. Added 2026-08-03 (extraction-completeness FIX 2, D11). */
    public static final String OUTCOME_NO_ADDRESS = 'New Lead (property, no address)';
    /** Branch (d): a different broker already holds the property. Renamed from the retired
     *  'Competing Duplicate' on 2026-07-31, when the branch stopped creating a duplicate Lead —
     *  there is no longer a duplicate of anything, only a competing submission. Rows stamped
     *  before that date keep the old label; Outcome__c is free Text and was deliberately NOT
     *  back-filled, because the staging object is an audit trail of what the pipeline actually
     *  did at the time. */
    public static final String OUTCOME_DUPLICATE = 'Competing Submission';
    /** Branch (e)'s lost-race path: the Lead was already created when the claim discovered a
     *  concurrent winner, so it was deleted and the email re-routed onto the winner. Kept
     *  distinct from OUTCOME_DUPLICATE so an admin can tell a settled competing submission
     *  from one that came out of a genuine race — the latter is the only shape where a Lead
     *  briefly existed and was removed. */
    public static final String OUTCOME_DUPLICATE_RACE = 'Competing Submission (race)';
    public static final String OUTCOME_WINNER = 'New Lead (winner)';
    public static final String OUTCOME_UNCLAIMED = 'New Lead (unclaimed)';

    /**
     * D2 HARD GATE: the classifier was confidently certain this is not an acquisition email.
     * Distinct from OUTCOME_PRE_FILTERED because the follow-up differs — "the model rejected
     * it" is a prompt/threshold question, "a regex rejected it before we ever asked" is not.
     */
    public static final String OUTCOME_NOT_ACQUISITION = 'Not Acquisition (gated)';
    /** Deterministic pre-filter hit: an automated sender or an auto-reply header. */
    public static final String OUTCOME_PRE_FILTERED = 'Not Acquisition (pre-filtered)';

    /**
     * U2 CALL-FOR-OFFERS GATE (intake-rules-v2): the model classified the email as a marketed
     * call-for-offers campaign. NO LEAD, NO CLAIM, Task still logged, staging row written in full.
     *
     * 🔴 THE PREFIX IS LOAD-BEARING TWICE OVER. DO NOT RENAME THIS WITHOUT READING BOTH.
     *   1. It must NOT start with 'Not Acquisition'. A call-for-offers blast IS
     *      acquisition-related — DPEG simply does not work them — so filing it under that prefix
     *      would be semantically wrong AND would silently pollute the deployed
     *      `Gated_Not_Acquisition` list view, whose filter is
     *      `Outcome__c startsWith 'Not Acquisition'`.
     *   2. It MUST start with 'Not Routed'. The `Gated_Call_For_Offers` list view filters
     *      `Outcome__c startsWith 'Not Routed'`, so any future sibling label intended for that
     *      view has to share this prefix, and any change to this string breaks a deployed view
     *      with no compile error and no failing test outside this module.
     *
     * `Outcome__c` is free Text and historical rows are deliberately NOT back-filled — the same
     * precedent as the retired 'Competing Duplicate' label: the staging object is an audit trail
     * of what the pipeline actually did at the time.
     */
    public static final String OUTCOME_CALL_FOR_OFFERS = 'Not Routed (call for offers)';
    /** Stable, filterable prefix for a multi-property summary, e.g.
     *  'Multi-Property (3): 1 New Lead (winner), 1 Competing Submission, 1 Repeat'. */
    public static final String OUTCOME_MULTI_PREFIX = 'Multi-Property';
    /** Per-property failure inside the loop; the other properties still routed. */
    public static final String OUTCOME_ERROR = 'Error';

    /** Appended when any property failed safe on a lock timeout — the single suffix that turns
     *  an unobservable failure into a filterable one. */
    private static final String SUFFIX_UNCLAIMED = ' [unclaimed: lock timeout]';

    /**
     * Extracted_JSON__c markers for the branches that deliberately skip the callout (C-6), so
     * the field is NEVER ambiguously empty: a blank would be indistinguishable from "we tried
     * and stored nothing".
     */
    private static final String JSON_SKIPPED_REPLY = '{"skipped":"reply"}';
    private static final String JSON_SKIPPED_LLM = '{"skipped":"llm-unavailable"}';

    /**
     * The label `buildLlmText` puts in front of the subject. Deliberately the exact RFC token the
     * model already reads inside forwarded header blocks, so the composed text reads as a
     * continuous email header block rather than as prompt scaffolding. `EMAIL SUBJECT:` /
     * `=== SUBJECT ===` framing was considered and rejected for that reason. The enriched prompt
     * paragraph in LLMExtractionCalloutService names this exact string — change one and you must
     * change the other.
     */
    private static final String SUBJECT_LABEL = 'Subject: ';

    /**
     * Task-insert and primary-record PRIORITY (C-3). One email can route to several records;
     * the Task list is inserted in ASCENDING priority so the highest-priority record gets the
     * highest Id, which is what TaskSelector's `CreatedDate DESC, Id DESC` tie-break then
     * resolves a later reply onto. It also picks Result_Record_Id__c: the primary record is the
     * highest-priority one.
     */
    private static final Integer PRIORITY_NO_PROPERTY = 1;
    private static final Integer PRIORITY_REPEAT = 2;
    private static final Integer PRIORITY_COMPETING = 3;
    private static final Integer PRIORITY_WINNER = 4;

    /**
     * DETERMINISTIC PRE-FILTER (C-7) — envelope and headers ONLY, tuned for PRECISION rather
     * than recall. Runs AFTER reply detection and BEFORE the callout, so the highest-volume
     * junk class costs no tokens, no 60-second timeout risk and no callout at all.
     *
     * Matching is on the COMPACTED local part (separators removed, lower-cased), which is what
     * makes the canonical case work: Gmail's forwarding confirmations come from
     * `forwarding-noreply@google.com`, whose local part neither EQUALS nor STARTS WITH
     * 'noreply'. Two sets, because the right test differs per token:
     *   • SENDER_CONTAINS — tokens that cannot plausibly appear inside a human's address.
     *   • SENDER_EXACT    — tokens that CAN ('bouncer@' contains 'bounce'), so they must match
     *                       the whole local part.
     *
     * NO SUBJECT-KEYWORD FILTERING, deliberately. "Out of Office", "Undeliverable" and
     * "Newsletter" are low-precision in a subject line, and a broker's subject can contain
     * anything. A false positive here costs a broker their claim.
     *
     * A hit is a RECORDED GATE, not a discard: the staging row keeps the raw email forever,
     * Extracted_JSON__c records why it was skipped, and the Task is still logged — the
     * Message-ID MUST be recorded or a redelivery re-runs the whole pipeline.
     *
     * 🔴 `Precedence: bulk` IS DELIBERATELY EXCLUDED. DO NOT ADD IT — the omission is the
     * decision, not an oversight, and the pattern below matches `auto_reply` ONLY.
     *
     * The design (§2.2 / C-7) originally listed `bulk` alongside `auto_reply`; code review
     * overruled that and the user endorsed the ruling. The reasoning: `Precedence: bulk` means
     * MASS-SENT, not MACHINE-GENERATED. It is exactly what a legitimate broker BLAST platform
     * (RCM, Crexi, Buildout) sets on a real listing announcement — the highest-value email this
     * pipeline exists to capture. Every other pattern in this filter identifies mail no human
     * composed; `bulk` identifies mail many humans were meant to read.
     *
     * It also violates D2 on its own terms: only a CONFIDENT not-acquisition verdict may
     * suppress a Lead, and this filter runs BEFORE the callout — so hard-gating on `bulk` would
     * deny genuine bulk mail the tiered gate that is supposed to judge it. Bulk mail must reach
     * the LLM and be classified there, where a wrong call lands in the soft tier (Lead created,
     * Parse_Confidence__c = LOW, claim still taken) instead of vanishing.
     *
     * The asymmetry is what settles it: a false positive here is a broker's LOST CLAIM, and the
     * only signal that it happened would be the broker telling us months later. That is not
     * reversible, and it is not observable, so the pattern is not worth its cost.
     *
     * ⚠ AMENDED, NOT CONTRADICTED, 2026-08-03 (intake-rules-v2 / U2). THIS PROHIBITION STILL
     * STANDS FOR THE PRE-CALLOUT FILTER. intake-rules-v2 introduced a business rule that reads
     * like its opposite — mass-marketed call-for-offers blasts should not become Leads — and the
     * two are reconciled by the sentence three paragraphs up: "Bulk mail must reach the LLM and be
     * classified there." The new suppression (`isCallForOffersGated`) runs AFTER THE CALLOUT, on
     * the model's own `email_category` + `category_confidence`, behind an admin toggle that ships
     * OFF. That is precisely what this comment asked for.
     *
     * 🔴 SO: DO NOT ADD `bulk`, `List-Unsubscribe`, OR ANY OTHER BLAST SIGNAL TO SENDER_CONTAINS /
     * SENDER_EXACT / the header pre-filter, and do not read U2 as licence to. A pre-callout blast
     * suppression would deny bulk mail the tiered gate that is supposed to judge it and would
     * re-open the "lost claim, unobservable" failure this prohibition exists for. If pre-callout
     * suppression is ever genuinely wanted, it is a different change with a materially worse risk
     * profile and must be raised as one.
     */
    private static final Set<String> SENDER_CONTAINS = new Set<String>{
        'noreply', 'donotreply', 'mailerdaemon', 'postmaster'
    };
    private static final Set<String> SENDER_EXACT = new Set<String>{ 'bounce', 'bounces' };

    /** RFC 3834 automatic-response headers, plus the two de-facto ones. */
    private static final Pattern AUTO_SUBMITTED_PATTERN =
        Pattern.compile('(?im)^\\s*Auto-Submitted\\s*:\\s*auto-(replied|generated|notified)');
    private static final Pattern X_AUTOREPLY_PATTERN =
        Pattern.compile('(?im)^\\s*X-Autoreply\\s*:');
    private static final Pattern PRECEDENCE_PATTERN =
        Pattern.compile('(?im)^\\s*Precedence\\s*:\\s*auto_reply');

    /** Inbound_Email_Staging__c.Status__c value that means "already fully routed". */
    private static final String STATUS_PROCESSED = 'Processed';

    /** First "From:" line of a forwarded email — the OUTERMOST/EARLIEST (original broker)
     *  line, consistent with the LLM extraction prompt. Multiline + case-insensitive.
     *  Read ONLY by applyRegexFallback. */
    private static final Pattern FROM_LINE_PATTERN = Pattern.compile('(?im)^\\s*From:\\s*(.+)$');

    /** Email-address regex used by the regex fallback (matches the LLM's own contract). */
    private static final String EMAIL_REGEX = '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}';

    /**
     * Length of `Lead.Listing_Broker_Name__c`, applied by `demoteBodyBroker` when it moves an
     * UNCLIPPED `broker_name` into the listing-contact slot.
     *
     * ⚠ IT IS NOT 255. `LLMExtractionParser` clips `listing_broker_name` to 120 on the way in, so
     * `EmailToLeadService.applyBrokerBlock`'s 255-character clip has never had anything over-long
     * to catch. U1 is the first code path that puts a value into that slot WITHOUT passing
     * through the parser's clip, so it has to carry the destination's real length itself or a
     * 121-character broker name becomes a STRING_TOO_LONG that rolls back a committed claim.
     */
    private static final Integer LEN_LISTING_BROKER_NAME = 120;

    /**
     * TEST-ONLY seam. When true, execute() skips the pre-claim registry lookup in branch (d)
     * and forces the claim path so PropertyClaimService's duplicate-value race recovery is
     * reachable from tests. NEVER set this outside a test class — in production it would
     * suppress the cheap "already a winner" short-circuit and always attempt the optimistic
     * insert.
     */
    @TestVisible private static Boolean forceClaimRace = false;

    /**
     * TEST-ONLY seam for the ERROR-CAPTURE contract. When true, routeProperty throws a
     * DmlException before doing anything else, so the per-property isolation catch — and the
     * Error__c persistence it now owns — can be asserted deterministically.
     *
     * WHY A SEAM RATHER THAN A REAL DEFECT. The catch's job is to persist ANY failure, so its
     * test must not be coupled to whichever bug happens to produce one today: the
     * converted-winner defect it was found through is now FIXED, and reusing that scenario would
     * leave the error-capture assertion silently unexercised the moment it was. Every other
     * input to this pipeline is clipped or sanitized by design, so there is no naturally
     * reachable failure left to lean on.
     *
     * ⚠ IT THROWS RATHER THAN PERFORMING A FAILING DML, and that is a layering requirement, not
     * a shortcut: this class contains NO DML of its own (see the LAYER note in the class header),
     * and a seam that inserted a deliberately-invalid row would break that invariant in the one
     * class whose header promises it. Same precedent and same prohibition as forceClaimRace:
     * NEVER set this outside a test class.
     */
    @TestVisible private static Boolean forceRouteFailure = false;

    /**
     * TEST-ONLY TELEMETRY for the governor-headroom assertions (design §7 item 3).
     *
     * WHY THIS EXISTS RATHER THAN A `Limits.getQueries()` ASSERTION IN THE TEST: Test.stopTest()
     * RESTORES the limit counters in effect before Test.startTest(), so anything the test reads
     * AFTER stopTest reflects the pre-test context, not the queueable's actual consumption — the
     * obvious assertion would be silently vacuous. Recording the counters at the END of
     * execute(), while still inside the async context, is what makes "a future change that adds
     * one query per property fails a TEST instead of failing in production at N = 8" actually
     * true. Two static assignments; no branching, no measurable cost.
     *
     * With several jobs in one transaction these hold the LAST job's figures.
     */
    @TestVisible private static Integer lastRunQueryCount;
    @TestVisible private static Integer lastRunDmlCount;

    private final Id stagingId;
    private final String imageBase64;
    private final String imageMimeType;

    /**
     * The staging row, loaded at the top of execute(). Mutable (not final) because it is
     * fetched during execution, not supplied to the constructor: the Queueable payload stays
     * small — three primitives — instead of serialising a whole SObject with a 131k body.
     */
    private Inbound_Email_Staging__c staging;

    /**
     * Everything routing has achieved SO FAR. Held as members, not locals, so the catch block
     * can report a PARTIAL success: if two properties claimed cleanly and the Task insert then
     * failed, the staging row records both the outcomes reached and the error.
     */
    private final List<RoutingOutcome> outcomes = new List<RoutingOutcome>();
    /**
     * Every failure this run hit, formatted by describeFailure — type, message, line and stack.
     *
     * ⚠ HELD AS A MEMBER FOR THE SAME REASON `outcomes` IS, AND THE REASON IS A PAST INCIDENT.
     * The per-property isolation catch in routeProperties cannot reach finish()'s stamp, so it
     * used to record only `e.getTypeName()` inside the Outcome__c label and DISCARD the message,
     * the line and the stack. Staging row a0aiw000000OCckAAG (2026-08-03) is what that costs:
     * `Outcome__c = 'Error (System.DmlException)'` with `Error__c` NULL, which took a full
     * code-read to diagnose instead of one query. Anything added here is persisted by finish().
     */
    private final List<String> routingErrors = new List<String>();
    /** Properties the extraction FOUND, pre-truncation and pre-de-duplication. */
    private Integer propertyCount = 0;
    /** Addressable, de-duplicated candidates — the denominator of the truncation suffix. */
    private Integer candidateCount = 0;
    /** The "Additional properties" block owed to the FIRST Lead created (C-1), or null. */
    private String pendingSpillover;
    /** Which Lead consumed the spillover, so a lost race can hand it back to the next one. */
    private Id spilloverLeadId;

    /**
     * One property's routing result: what happened, where it landed, and how important that
     * landing is relative to the email's other results.
     */
    private class RoutingOutcome {
        /** The OUTCOME_* label. */
        private final String outcome;
        /** The record this property's email content was filed on; null on a gate or error. */
        private final Id recordId;
        /** The normalized address, for the Routed_Record_Ids__c audit line. */
        private final String normalized;
        /** PRIORITY_* — drives Task insert order and the primary-record choice. */
        private final Integer priority;

        private RoutingOutcome(String outcome, Id recordId, String normalized, Integer priority) {
            this.outcome = outcome;
            this.recordId = recordId;
            this.normalized = normalized;
            this.priority = priority;
        }
    }

    /**
     * Capture the immutable job payload for one inbound broker email.
     *
     * The image is passed as a constructor argument rather than read from the staging row
     * because base64 image data exceeds any text field — the staging object deliberately
     * records only Has_Image__c / Image_Mime_Type__c, and the bytes are needed exactly once,
     * by the vision call in this job.
     *
     * @param stagingId     The Inbound_Email_Staging__c row created for this inbound email.
     * @param imageBase64   Base64 of an optional inline image (may be null).
     * @param imageMimeType MIME type for that image (may be null).
     */
    public ExtractAddressQueueable(Id stagingId, String imageBase64, String imageMimeType) {
        this.stagingId = stagingId;
        this.imageBase64 = imageBase64;
        this.imageMimeType = imageMimeType;
    }

    /**
     * Load → guard → (reply / pre-filter) → extract → gate → per-property loop → log → stamp.
     * See the class header for the routing tree and the error model.
     *
     * @param ctx The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext ctx) {
        staging = InboundEmailStagingService.getStaging(stagingId);
        if (staging == null) {
            // The row was hard-deleted between the synchronous insert and this async run.
            // There is nothing left to route and nothing left to stamp.
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute: staging record ' + stagingId + ' not found.');
            return;
        }

        try {
            if (STATUS_PROCESSED.equals(staging.Status__c)) {
                // The platform re-ran a job whose row is already terminal. Re-routing would
                // mint a second Lead for one email.
                System.debug(LoggingLevel.WARN,
                    'ExtractAddressQueueable.execute: staging ' + stagingId
                    + ' is already Processed; skipping re-run.');
                return;
            }

            if (InboundEmailActivityService.isAlreadyLogged(staging.Message_Id__c)) {
                InboundEmailStagingService.markSkipped(stagingId, OUTCOME_DUPLICATE_DELIVERY);
                return;
            }

            if (routePrologueWithoutCallout()) {
                finish();
                return;
            }

            LLMExtractionResult extraction = extractOrDegrade();
            InboundEmailStagingService.storeExtractedJson(stagingId, extraction.rawJson);

            applyRegexFallback(extraction);
            applyEnvelopeEmailFallback(extraction);
            // U1 SENDER-FIRST IDENTITY (intake-rules-v2). LAST of the three identity steps and
            // BEFORE both gates, so a gated email is still attributed to the right broker: the
            // identity feeds the Task this email is logged against and, on a claim path, the
            // arbitration key. (It used to say "so the demotion note still reaches the staging
            // audit trail" — that note was removed 2026-08-03; the ordering reason stands on its
            // own and never depended on it.)
            applySenderFirstBrokerIdentity(extraction);

            if (isHardGated(extraction)) {
                // D2 HARD GATE. No Lead, no claim — but the Task is still logged by finish(),
                // or a redelivery of this same message would re-run the whole pipeline.
                outcomes.add(new RoutingOutcome(OUTCOME_NOT_ACQUISITION, null, null, PRIORITY_NO_PROPERTY));
                finish();
                return;
            }

            if (isCallForOffersGated(extraction)) {
                // U2 CALL-FOR-OFFERS GATE. Same shape as the hard gate immediately above, and
                // deliberately so — no Lead, no claim, Task still logged by finish().
                outcomes.add(new RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null, PRIORITY_NO_PROPERTY));
                finish();
                return;
            }

            routeProperties(extraction);
            finish();
        } catch (Exception e) {
            String errorText = describeFailure(e);
            routingErrors.add(errorText);
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute failed for staging ' + stagingId + ': ' + errorText);
            // `outcomes` carries whatever routing achieved BEFORE the failure, so a successful
            // claim followed by a failed Task insert is recorded as both rather than discarded.
            // `routingErrors` likewise carries any PER-PROPERTY failure the loop already isolated,
            // so an email that lost one property and then died in the epilogue reports both.
            InboundEmailStagingService.markRouted(stagingId, buildResult(routingErrorText()));
        } finally {
            lastRunQueryCount = Limits.getQueries();
            lastRunDmlCount = Limits.getDmlStatements();
        }
    }

    /**
     * The two prologue branches that resolve an email WITHOUT calling the LLM (C-6):
     * (a) REPLY and the deterministic pre-filter.
     *
     * WHY REPLY MOVED ABOVE THE CALLOUT. Branch (a) reads only the staging row's In-Reply-To /
     * References and calls resolveLiveRecord — it provably never touches the extraction. Moving
     * it above the callout is therefore behaviour-preserving, and it removes an OpenAI call
     * from the highest-volume branch. A literal reading of D3 ("extraction survives for
     * branches that create no Lead") would mandate a callout on every reply; the marker written
     * to Extracted_JSON__c keeps the audit unambiguous instead.
     *
     * WHY REPLY ALSO BEATS THE RELEVANCE GATE. A header match is PROOF this message continues a
     * thread this pipeline already routed; a classifier's read of the body is an opinion, and it
     * cannot outrank an identity match on the transport layer. The failure modes are wildly
     * asymmetric too: gating a genuine reply loses a human-written message from the deal record,
     * while filing a non-acquisition reply costs one extra Task on a record it is already
     * threaded to. And replies systematically LOOK non-acquisition — "Thanks." / "Will do." / an
     * out-of-office inside a live thread — so the gate would discard exactly the conversational
     * tail the thread anchors were built to capture. Consequence, stated plainly: THE GATE CAN
     * ONLY EVER SUPPRESS A NEW CONVERSATION, NEVER AN EXISTING ONE.
     *
     * @return true when the email was fully resolved here and no callout should be made.
     */
    private Boolean routePrologueWithoutCallout() {
        Id priorRecord = PropertyMatchingService.findRecordByReplyHeaders(
            staging.In_Reply_To__c, staging.References__c);
        if (priorRecord != null) {
            outcomes.add(new RoutingOutcome(
                OUTCOME_REPLY, PropertyMatchingService.resolveLiveRecord(priorRecord),
                null, PRIORITY_REPEAT));
            InboundEmailStagingService.storeExtractedJson(stagingId, JSON_SKIPPED_REPLY);
            return true;
        }

        String preFilterHit = matchPreFilter();
        if (preFilterHit != null) {
            outcomes.add(new RoutingOutcome(OUTCOME_PRE_FILTERED, null, null, PRIORITY_NO_PROPERTY));
            InboundEmailStagingService.storeExtractedJson(stagingId,
                JSON.serialize(new Map<String, String>{
                    'skipped' => 'pre-filter', 'reason' => preFilterHit
                }));
            return true;
        }
        return false;
    }

    /**
     * Call the LLM, degrading to an empty extraction on any boundary failure. See the class
     * header's DEGRADED EXTRACTION note — including why the JSONException arm is a deliberate
     * reversal of a previously documented decision.
     *
     * @return The extraction, never null. `rawJson` carries either the model's response or a
     *         `{"skipped":"llm-unavailable"}` marker so the audit field is never ambiguous.
     */
    private LLMExtractionResult extractOrDegrade() {
        try {
            // FIX 1 (2026-08-03): the model is handed the SUBJECT LINE + the body, composed here.
            // Composed at THIS call site, not inside the callout service, because that service's
            // header promises the §3 ASB re-homing changes "only this class's endpoint constant …
            // the public extract(...) signature … stays identical" — that promise is the seam, and
            // a 4-arg extract() would break it for nothing.
            // ⚠ THE PREPEND MUST HAPPEN BEFORE THE CALLOUT. buildRequestBody clips the text to
            // MAX_INPUT_CHARS with substring(0, n), which preserves the HEAD — so composing here
            // makes the subject survive the 40,000-character clip UNCONDITIONALLY. Composing
            // inside the service, after the clip, would silently drop it on a long forward.
            LLMExtractionResult extraction = new LLMExtractionCalloutService()
                .extract(buildLlmText(staging.Subject__c, staging.Raw_Body__c), imageBase64, imageMimeType);
            if (extraction != null) {
                return extraction;
            }
        } catch (CalloutException ce) {
            System.debug(LoggingLevel.WARN,
                'ExtractAddressQueueable: LLM extraction unavailable for staging ' + stagingId
                + ' — degrading to the regex fallback. ' + ce.getMessage());
        } catch (JSONException je) {
            // C-14 REVERSAL — see the class header. A malformed/truncated reply is an absent
            // optional input, not a defect in our own contract, and erroring here would lose the
            // email rather than merely its address.
            System.debug(LoggingLevel.WARN,
                'ExtractAddressQueueable: LLM response was unparseable for staging ' + stagingId
                + ' — degrading to the regex fallback. ' + je.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ExtractAddressQueueable: unexpected failure at the LLM boundary for staging '
                + stagingId + ' — degrading to the regex fallback. ' + e.getMessage());
        }

        LLMExtractionResult degraded = LLMExtractionResult.emptyResult();
        degraded.rawJson = JSON_SKIPPED_LLM;
        return degraded;
    }

    /**
     * FIX 1 (2026-08-03) — compose the text handed to the model: the email's SUBJECT as a single
     * labelled line, a blank line, then the raw body verbatim.
     *
     * ═══ WHY THIS EXISTS ═══
     * The subject routinely carries the whole deal. The triggering incident's subject was
     * "Offers Due: August 18th | Eden Prairie Apartments | 432-Unit Value-Add Community |
     * Suburban Chicago" — the due date, the name, the unit count and the market, none of which
     * appeared in the body. The model never saw it, so the email extracted no address at all,
     * routed to branch (c), and took NO first-broker-wins claim.
     *
     * ═══ 🔴 THE SUBJECT IS ATTACKER-CONTROLLED. TWO PATHS, DEFENDED DIFFERENTLY. ═══
     * A subject is set by whoever sent the email, so everything below treats it as hostile input.
     * The two consumers of that text are defended by DIFFERENT mechanisms with DIFFERENT strengths,
     * and conflating them is the mistake to avoid:
     *
     *   ▸ THE DETERMINISTIC PATH IS HARD-CLOSED BY CONSTRUCTION — it never sees this string.
     *     🔴 PROHIBITION: `applyRegexFallback`, `applyEnvelopeEmailFallback` and
     *     `applySenderFirstBrokerIdentity` MUST continue to read `staging.Raw_Body__c` and the
     *     envelope, NEVER the composed text. The subject is
     *     attacker-controlled; routing it through a line-anchored regex (FROM_LINE_PATTERN is
     *     `(?im)^\s*From:\s*(.+)$`) would make `^From:` injection DETERMINISTIC — a broker's claim
     *     re-attributed by anyone who can set a subject line. This is the one control here that is
     *     actually enforceable in Apex. Do not "unify" the two inputs.
     *     ⚠ `applySenderFirstBrokerIdentity` WAS ADDED TO THIS LIST 2026-08-03. It reads no body
     *     text at all — only `From_Address__c` and `Forwarded_By__c` — and that is precisely the
     *     property to preserve: its inputs come from the TRANSPORT layer, which the sender of the
     *     message cannot forge into our envelope. Give it a body- or subject-derived input and the
     *     broker identity becomes attacker-selectable again.
     *
     *   ▸ THE LLM PATH IS SOFT-MITIGATED — two independent measures, neither absolute:
     *       1. STRUCTURAL: the CR/LF collapse below emits the subject as exactly ONE line, so any
     *          `From:` inside it is mid-line and is not a From: LINE to a model told the
     *          outermost/earliest such line is authoritative. Do not "improve" this by preserving
     *          the subject's own line breaks.
     *       2. SEMANTIC: the enriched prompt paragraph forbids the Subject line as a source for
     *          broker_name, broker_email and sent_datetime outright.
     *     ⚠ Measure 1 alone is NOT sufficient, and must not be described as "the" control. It
     *     closes `From:` injection but NOT the symmetric `Sent:` exposure — prepending INVERTS
     *     that one, because the subject now sits at the HEAD of the input, exactly where
     *     "outermost / earliest Sent: line" points. A fabricated `sent_datetime` reaches
     *     `Competing_Broker_Submission__c.Submitted_DateTime__c`, the 90-day filter behind repeat
     *     detection, so a broker's own follow-up re-routes as a competing claim. Measure 2 is what
     *     closes it, and it is a PROMPT rule — soft by nature, verified live (UAT D/D′), never by
     *     an Apex test. Removing either measure re-opens a live arbitration defect.
     *
     * ═══ THE BLANK-SUBJECT CASE IS THE COMPATIBILITY GUARANTEE ═══
     * A blank or null subject returns the body BYTE-IDENTICALLY — no label, no leading newline.
     * That is what makes FIX 1 a strict superset of the previous behaviour rather than a change
     * to every email, and it is pinned by
     * ExtractAddressQueueableTest.buildLlmText_blankSubject_returnsTheBodyByteIdentically.
     *
     * `@TestVisible` and pure for the same reason `buildWorkList` is: a prompt's EFFECT is not
     * unit-testable (the model is mocked and non-deterministic), but its INPUT is, and this
     * composition is the only part of FIX 1 that can be asserted deterministically.
     *
     * @param subject The staged email subject; blank/null yields the body untouched.
     * @param body    The staged raw body; blank/null yields the subject line alone.
     * @return The text content for the LLM. Never null unless both inputs are null-or-blank, in
     *         which case the body is returned as-is.
     * @example
     * String text = ExtractAddressQueueable.buildLlmText('FW: 432 units', 'From: jane@x ...');
     * // -> 'Subject: FW: 432 units\n\nFrom: jane@x ...'
     */
    @TestVisible
    private static String buildLlmText(String subject, String body) {
        if (String.isBlank(subject)) {
            return body;   // BYTE-IDENTICAL to today. Do not add a label, a newline or a trim.
        }
        String oneLineSubject = subject.replaceAll('[\\r\\n]+', ' ');
        return String.isBlank(body)
            ? SUBJECT_LABEL + oneLineSubject
            : SUBJECT_LABEL + oneLineSubject + '\n\n' + body;
    }

    /**
     * D2's HARD gate. Fires ONLY on an explicit `is_acquisition_related = false` at HIGH
     * confidence (>= 0.85, the band Apex derives — see LLMExtractionParser).
     *
     * Everything else continues, INCLUDING the soft tier — a low-confidence "not acquisition"
     * still creates the Lead AND STILL CLAIMS. That asymmetry is deliberate: claiming a junk
     * address costs one registry row a human can delete, while failing to claim a real one costs
     * a broker their commission and DPEG its protection. Generosity is the correct bias for a
     * first-come-first-served ledger. The soft tier is expressed on the Lead as
     * Parse_Confidence__c = LOW, which flows straight into the existing Review_Queue list view;
     * it deliberately gets no staging label of its own.
     *
     * @param extraction The parsed extraction.
     * @return true when the email must produce no Lead and no claim.
     */
    private static Boolean isHardGated(LLMExtractionResult extraction) {
        return extraction.isAcquisitionRelated == false
            && LLMExtractionParser.BAND_HIGH.equals(extraction.confidenceBand);
    }

    /**
     * Build the work-list and run the per-property loop, or fall through to branch (c) when the
     * email carries no usable address at all.
     *
     * @param extraction The parsed, fallback-backfilled extraction.
     */
    private void routeProperties(LLMExtractionResult extraction) {
        propertyCount = (extraction.properties == null) ? 0 : extraction.properties.size();
        List<PropertyExtraction> candidates = buildWorkList(extraction.properties);
        candidateCount = candidates.size();

        List<PropertyExtraction> workList = candidates;
        List<PropertyExtraction> overflow = new List<PropertyExtraction>();
        if (candidates.size() > MAX_PROPERTIES) {
            workList = new List<PropertyExtraction>();
            for (Integer i = 0; i < candidates.size(); i++) {
                if (i < MAX_PROPERTIES) {
                    workList.add(candidates[i]);
                } else {
                    overflow.add(candidates[i]);
                }
            }
        }
        // exclude = null: nothing is stamped on this path, so every unroutable property is
        // footnoted. routeNoProperty recomputes this with the property it stamps excluded.
        pendingSpillover = buildSpilloverNote(extraction.properties, overflow, null);

        if (workList.isEmpty()) {
            routeNoProperty(extraction);
            return;
        }

        Datetime submittedOn = parseSentDatetime(extraction.sentDatetime);
        for (PropertyExtraction property : workList) {
            try {
                outcomes.add(routeProperty(extraction, property, submittedOn));
            } catch (Exception e) {
                // PER-PROPERTY ISOLATION — see the class header. One property must never roll
                // back another's committed claim, so the failure is recorded and the loop goes on.
                // ⚠ THE LABEL IS NOT THE RECORD OF THE FAILURE. Outcome__c gets only the
                // exception TYPE (it is a 255-char reporting field a list view filters on); the
                // message, line and stack go to Error__c via routingErrors — see that member.
                String errorText = describeFailure(e);
                routingErrors.add('property "' + property.normalizedAddress + '": ' + errorText);
                System.debug(LoggingLevel.ERROR,
                    'ExtractAddressQueueable: property "' + property.normalizedAddress
                    + '" failed to route for staging ' + stagingId + ': ' + errorText);
                outcomes.add(new RoutingOutcome(
                    OUTCOME_ERROR + ' (' + e.getTypeName() + ')',
                    null, property.normalizedAddress, PRIORITY_NO_PROPERTY));
            }
        }
    }

    /**
     * (c) NO-PROPERTY — email-level by construction. A Lead is created so nothing is lost, but
     * no claim is attempted: a blank key would collide with every other addressless email on the
     * registry's unique index.
     *
     * This is ALSO the LLM-outage landing point, and necessarily so: the regex fallback backfills
     * only broker name / email, so a degraded extraction always leaves the work-list empty and
     * can never reach branches (d) or (e). Only the label differs — claiming on an address nobody
     * actually read would be a guess written to a permanent, unique-keyed ledger.
     *
     * ⚠ It fires only when the WHOLE work-list is empty (C-1). If it fired per property, a
     * 3-property email with one name-only entry would mint a junk unclaimable Lead — exactly the
     * Lead-table pollution the 2026-07-31 change removed. Unaddressable entries alongside
     * addressable ones become the spillover note instead.
     *
     * ═══ FIX 2 (2026-08-03) — THE LEAD NOW CARRIES THE FIRST PROPERTY'S DEAL BLOCK ═══
     * It used to pass `null` into createLead, so every field the model DID extract — property
     * name, unit count, price, NOI, due date, asset type — died in the staging JSON, and the Lead
     * converted into an unnamed Property with no deal facts. It now stamps the FIRST property, via
     * the SAME `LeadRequest.property` / `applyPropertyBlock` path the winner branch uses, so there
     * is exactly one field-mapping rule set and no second one to drift. `EmailToLeadService` needed
     * no change at all: `applyPropertyBlock` already never writes the address.
     *
     * ⚠ NO ORDERING GUARANTEE IS CLAIMED HERE, AND NONE IS NEEDED. "First" means
     * `extraction.properties[0]` — the MODEL's own array order. The class header's warning that
     * that order "is not stable across transactions" governs LOCK ORDERING, where cross-transaction
     * stability is a correctness requirement; branch (c) takes no lock and derives no claim key, so
     * nothing here is order-sensitive. The model also lists the headline property first, and
     * `buildSpilloverNote` walks the same order, so the stamped property and the footnote list stay
     * consistent by construction. Do NOT later "harden" this by coupling it to `buildWorkList`'s
     * cluster-key sort — that would be a second ordering rule maintained for no benefit.
     *
     * ⚠ RESIDUAL, STATED (D16): an addressless property CANNOT claim — a blank Property_Key__c
     * would collide with every other addressless email on the registry's unique index, and claiming
     * on a synthesized key would write a guess into a permanent ledger. So these Leads carry the
     * deal facts and NO first-broker-wins protection: a later broker who submits the same property
     * WITH an address wins it outright. The only mitigation is human, which is what
     * OUTCOME_NO_ADDRESS exists to make possible.
     *
     * @param extraction The parsed extraction.
     */
    private void routeNoProperty(LLMExtractionResult extraction) {
        PropertyExtraction stampable = firstProperty(extraction.properties);
        // Recomputed EXCLUDING the property we are about to stamp: leaving it in would print
        // "Additional properties in this email (not routed): - Eden Prairie (no usable address)"
        // on the very Lead whose Property Name reads "Eden Prairie". Overflow is empty by
        // construction here — branch (c) is reached only when the work-list is empty, so there are
        // no addressable candidates and nothing can have overflowed MAX_PROPERTIES.
        pendingSpillover = buildSpilloverNote(
            extraction.properties, new List<PropertyExtraction>(), stampable);

        Id leadId = createLead(extraction, stampable);
        Boolean llmUnavailable = JSON_SKIPPED_LLM.equals(extraction.rawJson);
        // LLM-DOWN WINS the label. Per LLMExtractionResult.emptyResult() a degraded extraction
        // carries an EMPTY properties list, so `stampable` is null and the two can never actually
        // collide — but the precedence is coded explicitly so it stays true if that ever changes.
        String label = llmUnavailable
            ? OUTCOME_NO_PROPERTY_LLM_DOWN
            : (stampable == null ? OUTCOME_NO_PROPERTY : OUTCOME_NO_ADDRESS);
        outcomes.add(new RoutingOutcome(label, leadId, null, PRIORITY_NO_PROPERTY));
    }

    /**
     * The first non-null property in the model's own array order, or null when the email carried
     * none. Branch (c) fires only when the work-list is empty, so in branch (c) EVERY property is
     * addressless — there is no mixed case to reason about and no "best" candidate to choose.
     *
     * @param properties The parsed properties; null/empty is tolerated.
     * @return The property to stamp, or null.
     */
    private static PropertyExtraction firstProperty(List<PropertyExtraction> properties) {
        if (properties == null) {
            return null;
        }
        for (PropertyExtraction property : properties) {
            if (property != null) {
                return property;
            }
        }
        return null;
    }

    /**
     * The property's address ONLY when it could actually have produced a claim key — i.e. when
     * `PropertyMatchingService.normalizeAddress` returns something non-blank. Otherwise null.
     *
     * ⚠ DO NOT SIMPLIFY THIS TO `property.propertyAddress`. FIX 2 stamps properties that
     * `buildWorkList` REJECTED, and buildWorkList rejects on the NORMALIZED form — normalizeAddress
     * strips every non-alphanumeric, so a raw value of `'###'` or `'—'` is non-blank while its
     * normalized form is empty. Without this guard that punctuation would land in
     * Lead.Property_Address__c, on the exact field the claim key is derived from.
     *
     * The invariant it encodes is worth stating on its own:
     *   ▸ Lead.Property_Address__c only ever holds an address that COULD have produced a claim key.
     *
     * Branches (b)/(d)/(e) are unaffected — their properties normalize non-blank by construction,
     * which is how they reached those branches at all — so this is a pure guard rather than a
     * behaviour change on any claim path. The RAW address is returned, never the normalized form:
     * `execute_newUnclaimedProperty_...` pins that a winner Lead stamps the address VERBATIM.
     *
     * Never fabricate an address, never synthesize one from property_name, never copy the subject.
     *
     * @param property The property being stamped; null is tolerated.
     * @return The raw address when it normalizes non-blank, otherwise null.
     */
    private static String claimableAddress(PropertyExtraction property) {
        if (property == null) {
            return null;
        }
        return String.isBlank(PropertyMatchingService.normalizeAddress(property.propertyAddress))
            ? null
            : property.propertyAddress;
    }

    /**
     * Turn the extraction's raw property array into the ordered work-list: drop entries with no
     * usable address, de-duplicate on the NORMALIZED address (the model does repeat itself),
     * stamp each survivor's routing keys, and SORT into cluster-key order.
     *
     * 🔴 THE SORT IS THE DEADLOCK FIX. See the class header. `@TestVisible` because it is a pure
     * function and the ordering is the only part of the deadlock guarantee that CAN be asserted
     * directly — true concurrency is not reproducible in Apex.
     *
     * The input objects are mutated in place (normalizedAddress / clusterKey are stamped on
     * them) rather than copied: they are this transaction's own DTOs and nothing else reads them
     * first.
     *
     * @param extracted The parsed properties in the model's original order; null is tolerated.
     * @return Addressable, de-duplicated properties in ascending (clusterKey, normalizedAddress)
     *         order; never null.
     * @example
     * List&lt;PropertyExtraction&gt; workList = ExtractAddressQueueable.buildWorkList(properties);
     */
    @TestVisible
    private static List<PropertyExtraction> buildWorkList(List<PropertyExtraction> extracted) {
        List<PropertyExtraction> candidates = new List<PropertyExtraction>();
        if (extracted == null || extracted.isEmpty()) {
            return candidates;
        }
        Set<String> seen = new Set<String>();
        for (PropertyExtraction property : extracted) {
            if (property == null) {
                continue;
            }
            String normalized = PropertyMatchingService.normalizeAddress(property.propertyAddress);
            if (String.isBlank(normalized) || seen.contains(normalized)) {
                continue;
            }
            seen.add(normalized);
            property.normalizedAddress = normalized;
            // Derived from the ADDRESS ONLY — never from the model's array order, which is not
            // stable across transactions. De-duplication stays on the normalized address, never
            // on this coarse key: two different buildings can legitimately share one.
            property.clusterKey = PropertyMatchingService.deriveClusterKey(normalized);
            candidates.add(property);
        }
        candidates.sort();
        return candidates;
    }

    /**
     * Route ONE property through branches (b) → (d) → (e).
     *
     * @param extraction  The email-level extraction (broker identity + notes).
     * @param property    The property to route; its routing keys are already stamped.
     * @param submittedOn The email's original send time.
     * @return What happened, where it landed, and its priority.
     */
    private RoutingOutcome routeProperty(LLMExtractionResult extraction, PropertyExtraction property,
                                         Datetime submittedOn) {
        if (forceRouteFailure) {
            // TEST-ONLY. See the forceRouteFailure seam — this exists so the per-property
            // isolation catch's Error__c persistence is provable without depending on a live bug.
            throw new DmlException('Simulated per-property routing failure.');
        }
        String normalized = property.normalizedAddress;
        Map<String, String> extracted = extraction.toLegacyMap(property);
        String fromAddress = staging.From_Address__c;
        String forwardedBy = staging.Forwarded_By__c;
        String emailSubject = staging.Subject__c;

        // (b) REPEAT — the same broker, the same property, again. No new Lead.
        // Two lookups because the broker can be identified two ways and either may be the
        // one that was recorded last time: the LLM's answer (right for a manual forward,
        // where the broker is only inside the quoted body) and the envelope From (right for
        // an auto-forward, where the broker IS the sender). The second is skipped when it
        // would repeat the first — the LLM's answer can be blank or plain wrong on
        // auto-forwarded mail, so trying only one of the two misses real repeats.
        String brokerEmail = extraction.brokerEmail;
        Competing_Broker_Submission__c prior =
            PropertyMatchingService.findBrokerSubmission(brokerEmail, normalized);
        if (prior == null && String.isNotBlank(fromAddress) && !fromAddress.equalsIgnoreCase(brokerEmail)) {
            prior = PropertyMatchingService.findBrokerSubmission(fromAddress, normalized);
        }
        if (prior != null) {
            // 🔴 RESOLVE BEFORE WRITING (2026-08-03). The winner's Lead may have been CONVERTED
            // since it took the claim — a repeat is the FIRST write that can encounter that, by
            // definition — and a Lead lookup cannot be SET to a converted Lead. The resolved
            // record is needed by the write AND by the routing outcome, so it is computed ONCE,
            // here, and the query budget is unchanged: this is the same single resolveLiveRecord
            // call the branch already made, only moved above the DML.
            //
            // BOTH ANCHORS ARE READ, and the Opportunity one is preferred because it is ALREADY a
            // live record — resolving it would be a query spent to learn nothing. A prior row is
            // Opportunity-anchored exactly when it was itself written after the winner converted,
            // so this is also the cheaper branch on every subsequent email about that property.
            Id liveWinner = (prior.Winning_Opportunity__c != null)
                ? prior.Winning_Opportunity__c
                : PropertyMatchingService.resolveLiveRecord(prior.Winning_Lead__c);
            // The audit row is appended for BOTH kinds of repeat: Competing_Broker_Submission__c
            // is the append-only trail of every inbound email that matched a property
            // (ARCHITECTURE.md §1), so a competing broker's second email is recorded as
            // faithfully as the winner's. prior.Source_Lead__c carries through, which means a
            // competing broker's repeat appends another source-less row under the same winner.
            PropertyClaimService.logRepeatSubmission(
                prior.Winning_Lead__c, prior.Source_Lead__c, liveWinner, extracted, submittedOn,
                forwardedBy, emailSubject);
            // A WINNER re-emailing goes back to their own Lead. A COMPETING broker has no Lead
            // of their own (branch (d) never made one), so their follow-up lands on the WINNING
            // Lead alongside their submission entry — the same place their first email went.
            Id repeatTarget = (prior.Source_Lead__c != null)
                ? prior.Source_Lead__c
                : prior.Winning_Lead__c;
            // Reuse `liveWinner` whenever the repeat target IS the winning anchor — which covers
            // every persisted shape: Source_Lead__c is null or equal to Winning_Lead__c per that
            // field's contract, and an Opportunity-anchored row has NO Lead at all, so
            // `repeatTarget` is null and `liveWinner` (the Opportunity) is the only target there
            // is. The second resolve exists only for the S4 transient window and is the one place
            // this branch can spend an extra query.
            Id liveTarget = (repeatTarget == null || repeatTarget == prior.Winning_Lead__c)
                ? liveWinner
                : PropertyMatchingService.resolveLiveRecord(repeatTarget);
            return new RoutingOutcome(OUTCOME_REPEAT, liveTarget, normalized, PRIORITY_REPEAT);
        }

        // (d) COMPETING SUBMISSION — a different broker already holds this property, so this
        // broker gets NO LEAD (see "WHY A COMPETING BROKER GETS NO LEAD" in the class header).
        // The claim is recorded as a non-winning Competing_Broker_Submission__c against the
        // winner with Source_Lead__c = null, and the email is logged on the WINNING Lead —
        // resolved through conversion, so it lands on the live Opportunity when that Lead has
        // already been converted.
        //
        // ORDER IS LOAD-BEARING: the registry read runs BEFORE createLead. Creating the Lead
        // first and only then testing for an existing winner would mint an orphan Lead on
        // every competing email — exactly the Lead-table pollution this branch exists to stop —
        // and would still be exposed to the org's Lead duplicate rules on Email. This is also
        // the reason the claim engine is NOT bulkified (C-5): a bulk insert of all N Leads up
        // front would break precisely this ordering.
        //
        // The cheap read avoids taking the cluster lock for a claim that is already settled;
        // claim() re-checks under the lock, so this short-circuit can only ever be an
        // optimisation, never the authority.
        Property_Registry__c existing =
            forceClaimRace ? null : PropertyMatchingService.findMatchingRegistry(normalized);
        if (existing != null) {
            // Resolved BEFORE the write for the same reason branch (b) does it, and at the same
            // cost — one call, used by both the submission's winner anchor and the outcome. A
            // competing email arriving after the winner converted is the second shape that hit
            // the 2026-08-03 CANNOT_UPDATE_CONVERTED_LEAD failure.
            Id liveWinner = PropertyMatchingService.resolveLiveRecord(existing.Winning_Lead__c);
            PropertyClaimService.markDuplicate(
                existing, null, liveWinner, extracted, submittedOn, forwardedBy, emailSubject);
            return new RoutingOutcome(OUTCOME_DUPLICATE, liveWinner, normalized, PRIORITY_COMPETING);
        }

        // (e) WINNER — unclaimed property. claim() reports what it actually did (a concurrent
        // claim can win between the read above and the lock), so the outcome recorded is the
        // truth rather than this branch's optimistic assumption.
        Id leadId = createLead(extraction, property);
        PropertyClaimService.ClaimOutcome claimed = PropertyClaimService.claim(
            leadId, normalized, extracted, submittedOn, forwardedBy, emailSubject);

        if (claimed == PropertyClaimService.ClaimOutcome.DUPLICATE_RACE) {
            return routeLostRace(leadId, normalized, claimed);
        }
        return new RoutingOutcome(toOutcomeLabel(claimed), leadId, normalized, PRIORITY_WINNER);
    }

    /**
     * Branch (e)'s LOST-RACE tail. A concurrent submission registered the property between
     * this job's own pre-read and its claim under the cluster lock, so the broker turns out to
     * be a COMPETING broker after all — and the Lead created moments ago is a Lead that should
     * never have existed. Delete it and finish exactly like branch (d): the claim is already
     * recorded as a competing submission against the winner, and the email is logged on the
     * WINNING Lead.
     *
     * Split out of route() rather than inlined because route() is already at the top of its
     * complexity budget, and because this tail is a single cohesive decision that reads as one
     * line at the call site.
     *
     * THREE SAFETY RULES, ALL DELIBERATE — this is a destructive path, so each is load-bearing:
     *   1. This runs ONLY on the explicit DUPLICATE_RACE outcome, never on UNCLAIMED. An
     *      UNCLAIMED Lead is a legitimate broker submission that merely failed to take the
     *      lock; deleting it would destroy real work.
     *   2. The Lead being deleted is never the winner. DUPLICATE_RACE is gated by
     *      PropertyClaimService.isLostRaceAgainst, which reports a race only when the
     *      registration is held by a DIFFERENT Lead. That guard is what makes rule 3's re-read
     *      meaningful: without it, a claimant could match its OWN registration (see that
     *      method's Javadoc for the two paths) and this code would delete the Lead that had
     *      just won, orphaning the registry row it owned.
     *   3. The winner is re-read BEFORE the delete, so a Lead is never removed without a live
     *      record to route its email to. If that read comes back empty the Lead is KEPT and
     *      reported UNCLAIMED — the data-preserving answer. The email itself is safe either
     *      way: the raw body and every RFC header live on the staging row, which is never
     *      deleted.
     *
     * @param leadId     The Lead created by branch (e), now known to be surplus.
     * @param normalized The normalized property address, used to re-read the real winner.
     * @param claimed    The claim outcome (DUPLICATE_RACE), mapped to the staging label.
     * @return The re-routed outcome.
     */
    private RoutingOutcome routeLostRace(Id leadId, String normalized,
                                         PropertyClaimService.ClaimOutcome claimed) {
        Property_Registry__c winner = PropertyMatchingService.findMatchingRegistry(normalized);
        if (winner == null) {
            return new RoutingOutcome(OUTCOME_UNCLAIMED, leadId, normalized, PRIORITY_WINNER);
        }
        EmailToLeadService.deleteLead(leadId);
        if (spilloverLeadId == leadId) {
            // The spillover note went onto the Lead just deleted. Hand it back so the next Lead
            // this email creates carries it instead of losing it silently.
            spilloverLeadId = null;
        }
        return new RoutingOutcome(toOutcomeLabel(claimed),
            PropertyMatchingService.resolveLiveRecord(winner.Winning_Lead__c),
            normalized, PRIORITY_COMPETING);
    }

    /**
     * Create the Lead for one property of this email from the extracted fields plus the staged
     * envelope. The first Lead an email creates also carries the "additional properties" block
     * for anything the pipeline could not route (C-1).
     *
     * @param extraction The email-level extraction.
     * @param property   The property this Lead is for; null on branch (c).
     * @return The Id of the inserted Lead.
     */
    private Id createLead(LLMExtractionResult extraction, PropertyExtraction property) {
        EmailToLeadService.LeadRequest request = new EmailToLeadService.LeadRequest();
        request.brokerName = extraction.brokerName;
        request.brokerEmail = extraction.brokerEmail;
        request.propertyAddress = claimableAddress(property);
        request.fromName = staging.From_Name__c;
        request.fromAddress = staging.From_Address__c;
        request.emailSubject = staging.Subject__c;
        request.rawBody = staging.Raw_Body__c;
        request.forwardedByEmail = staging.Forwarded_By__c;

        request.brokerCompany = extraction.brokerCompany;
        request.brokerPhone = extraction.brokerPhone;
        request.brokerMobile = extraction.brokerMobile;
        request.brokerTitle = extraction.brokerTitle;
        request.listingBrokerName = extraction.listingBrokerName;
        request.listingBrokerEmail = extraction.listingBrokerEmail;

        request.property = property;
        request.dealSummary = extraction.dealSummary;
        request.extractionNotes = extraction.notes;
        request.parseConfidence = extraction.confidenceBand;

        if (String.isNotBlank(pendingSpillover) && spilloverLeadId == null) {
            request.spilloverNote = pendingSpillover;
        }

        Id leadId = EmailToLeadService.createLeadFromExtracted(request);
        if (String.isNotBlank(request.spilloverNote)) {
            spilloverLeadId = leadId;
        }
        return leadId;
    }

    /**
     * Compose the "additional properties" block for everything this email mentioned but did NOT
     * route: entries with no usable address, and entries beyond MAX_PROPERTIES.
     *
     * Neither kind gets a Lead (C-1): minting an unclaimable Lead per name-only entry re-creates
     * the Lead-table pollution the 2026-07-31 change removed. Both are preserved VERBATIM in
     * Extracted_JSON__c regardless — this note simply puts them where a human working the deal
     * will actually see them.
     *
     * ⚠ `exclude` (added 2026-08-03, FIX 2 / D13) is the ONE property whose block branch (c) has
     * stamped onto the Lead. It must not also appear under "not routed" — that would print
     * "- Eden Prairie (no usable address)" on the very Lead whose Property Name reads
     * "Eden Prairie", a visible self-contradiction on the exact record FIX 2 exists to improve.
     * In the common single-property case the note becomes empty and no footer is emitted at all.
     * Comparison is by OBJECT IDENTITY: PropertyExtraction defines no equals(), so `==` on a
     * user-defined type is a reference comparison — which is what is wanted, because two distinct
     * properties in one email can legitimately carry identical field values.
     *
     * @param extracted All parsed properties, in the model's order.
     * @param overflow  Addressable candidates beyond the cap.
     * @param exclude   The property already stamped onto the Lead; null when nothing was stamped.
     * @return The note, or null when everything was routed.
     */
    private static String buildSpilloverNote(List<PropertyExtraction> extracted,
                                             List<PropertyExtraction> overflow,
                                             PropertyExtraction exclude) {
        List<String> lines = new List<String>();
        if (extracted != null) {
            for (PropertyExtraction property : extracted) {
                if (!isFootnotable(property, exclude)) {
                    continue;
                }
                String label = String.isNotBlank(property.propertyName)
                    ? property.propertyName
                    : property.propertyAddress;
                lines.add('- ' + (String.isBlank(label) ? '(unidentified property)' : label)
                    + ' (no usable address)');
            }
        }
        for (PropertyExtraction property : overflow) {
            lines.add('- ' + property.propertyAddress + ' (beyond the '
                + MAX_PROPERTIES + '-property limit for one email)');
        }
        return lines.isEmpty()
            ? null
            : 'Additional properties in this email (not routed):\n' + String.join(lines, '\n');
    }

    /**
     * Whether a parsed property belongs in the "not routed" footer: it exists, it is NOT the one
     * already stamped onto the Lead (D13, identity comparison — PropertyExtraction defines no
     * equals(), and two properties in one email can legitimately share every field value), and its
     * address does not normalize to a usable claim key.
     *
     * @param property The candidate; null is tolerated.
     * @param exclude  The property stamped onto the Lead, or null.
     * @return true when the property should be footnoted.
     */
    private static Boolean isFootnotable(PropertyExtraction property, PropertyExtraction exclude) {
        return property != null
            && property != exclude
            && String.isBlank(PropertyMatchingService.normalizeAddress(property.propertyAddress));
    }

    /**
     * The epilogue: log ONE Task per DISTINCT routed record in a single bulk DML, then stamp the
     * staging row with the full N-result picture.
     *
     * Targets are ordered by ASCENDING priority so the highest-priority record's Task receives
     * the highest Id — which is what TaskSelector's `CreatedDate DESC, Id DESC` tie-break needs
     * in order to resolve a later reply onto the deal DPEG actually owns. When routing produced
     * no record at all (a gate, or a total failure) the Task is still logged, UNATTACHED: the
     * Message-ID must be recorded or a redelivery re-runs the whole pipeline.
     */
    private void finish() {
        InboundEmailActivityService.logInboundEmail(
            orderedTaskTargets(), staging.Subject__c, staging.Raw_Body__c,
            staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c);

        // routingErrorText() is null on the clean path, which is what keeps Status__c 'Processed'
        // byte-for-byte as before. When the loop DID isolate a per-property failure it is non-null,
        // and markRouted then derives Status__c 'Error' — see routingErrorText for why that
        // status change is correct rather than incidental.
        InboundEmailStagingService.markRouted(stagingId, buildResult(routingErrorText()));
    }

    /**
     * One formatter for every failure this class reports, so the per-property catch and the
     * execute()-level catch can never drift into describing the same exception differently.
     *
     * @param e The caught exception.
     * @return 'Type | message | line N | stack', the shape Error__c has always carried.
     */
    private static String describeFailure(Exception e) {
        return e.getTypeName() + ' | ' + e.getMessage()
            + ' | line ' + e.getLineNumber() + ' | ' + e.getStackTraceString();
    }

    /**
     * Everything that failed this run, or null when nothing did.
     *
     * ═══ WHY A PARTIAL FAILURE NOW STAMPS Status__c 'Error' (2026-08-03) ═══
     * `InboundEmailStagingService.markRouted` derives Status__c from this value: blank means
     * 'Processed', non-blank means 'Error'. So wiring the per-property failures in here changes
     * a partially-failed email from 'Processed' to 'Error'. That is deliberate and it is what
     * this class's ERROR MODEL header has always promised ("the failure is written back to that
     * row (Status 'Error' plus the full stack trace) ALONGSIDE whatever outcome had already been
     * reached") — the code simply did not do it for the per-property catch, which is how staging
     * row a0aiw000000OCckAAG came to read 'Processed' over a DmlException.
     *
     * ⚠ IT ALSO MAKES THE ROW RE-RUNNABLE, AND THAT IS SAFE — but only because of a guard in
     * ANOTHER method. execute()'s first idempotency check short-circuits on Status__c
     * 'Processed', so an 'Error' row no longer skips there. The SECOND guard is what still
     * blocks a genuine redelivery: `InboundEmailActivityService.isAlreadyLogged(Message_Id__c)`
     * — and finish() logs that Task even when routing produced no record at all, precisely so
     * the Message-ID is always recorded. Do not "tidy" the unattached-Task insert away; it is
     * what keeps this status change from re-minting Leads on redelivery.
     *
     * @return The joined failure text, or null when the run had none.
     */
    private String routingErrorText() {
        return routingErrors.isEmpty() ? null : String.join(routingErrors, '\n\n');
    }

    /**
     * The distinct records to log this email on, in ascending priority. A record reached by
     * several properties appears ONCE, ranked by the highest priority any of them gave it —
     * otherwise the same email would be double-logged on one record.
     *
     * @return Distinct record Ids in ascending priority; empty when nothing was routed.
     */
    private List<Id> orderedTaskTargets() {
        Map<Id, Integer> priorityByRecord = new Map<Id, Integer>();
        for (RoutingOutcome outcome : outcomes) {
            if (outcome.recordId == null) {
                continue;
            }
            Integer known = priorityByRecord.get(outcome.recordId);
            if (known == null || outcome.priority > known) {
                priorityByRecord.put(outcome.recordId, outcome.priority);
            }
        }

        // Bucketed by priority, then in PROCESSING order within a bucket, so the result is
        // deterministic — Apex Map key order is not guaranteed and must not be relied on here.
        List<Id> targets = new List<Id>();
        Set<Id> added = new Set<Id>();
        for (Integer priority = PRIORITY_NO_PROPERTY; priority <= PRIORITY_WINNER; priority++) {
            for (RoutingOutcome outcome : outcomes) {
                if (outcome.recordId != null && !added.contains(outcome.recordId)
                        && priorityByRecord.get(outcome.recordId) == priority) {
                    added.add(outcome.recordId);
                    targets.add(outcome.recordId);
                }
            }
        }
        return targets;
    }

    /**
     * Assemble the staging stamp: primary record, outcome summary, the full N-result audit, and
     * the property count.
     *
     * @param errorText Failure text, or null on the success path.
     * @return The routing result to stamp.
     */
    private InboundEmailStagingService.RoutingResult buildResult(String errorText) {
        InboundEmailStagingService.RoutingResult result =
            new InboundEmailStagingService.RoutingResult();
        result.resultRecordId = primaryRecordId();
        result.outcome = buildOutcomeSummary();
        result.routedRecordIds = buildRoutedAudit();
        result.propertyCount = (propertyCount > 0) ? propertyCount : null;
        result.errorText = errorText;
        return result;
    }

    /**
     * The PRIMARY routed record for Result_Record_Id__c — the field is Text(18) and holds
     * exactly one Id, so a multi-property email has to choose. The choice follows the same
     * priority as Task ordering: the first WINNER Lead, else the first COMPETING winner, else
     * the REPLY/REPEAT target, else null. A single-property email therefore stamps exactly what
     * it always did.
     *
     * @return The primary record Id, or null.
     */
    private Id primaryRecordId() {
        for (Integer priority = PRIORITY_WINNER; priority >= PRIORITY_NO_PROPERTY; priority--) {
            for (RoutingOutcome outcome : outcomes) {
                if (outcome.recordId != null && outcome.priority == priority) {
                    return outcome.recordId;
                }
            }
        }
        return null;
    }

    /**
     * The Outcome__c label.
     *
     * ONE result keeps TODAY'S LABEL, byte for byte — that backward compatibility is why no
     * sweep of historical rows is needed and why every existing consumer keeps working. Several
     * results produce a stable, filterable summary:
     * `Multi-Property (3): 1 New Lead (winner), 1 Competing Submission, 1 Repeat`.
     *
     * Two suffixes may follow: ` [truncated: X of M]` when the email carried more properties
     * than the cap, and ` [unclaimed: lock timeout]` when any property failed safe. The second
     * is suppressed when the label ALREADY says unclaimed (the single-property case), so N = 1
     * stays byte-identical.
     *
     * @return The Outcome__c value; clipped to 255 by the staging service.
     */
    private String buildOutcomeSummary() {
        if (outcomes.isEmpty()) {
            return null;
        }

        String summary = (outcomes.size() == 1) ? outcomes[0].outcome : buildMultiSummary();

        if (candidateCount > MAX_PROPERTIES) {
            summary += ' [truncated: ' + MAX_PROPERTIES + ' of ' + candidateCount + ']';
        }
        if (hasUnclaimed() && !OUTCOME_UNCLAIMED.equals(summary)) {
            summary += SUFFIX_UNCLAIMED;
        }
        return summary;
    }

    /**
     * The N > 1 summary: counts per outcome label, ordered by descending priority so the most
     * consequential result reads first.
     *
     * @return e.g. 'Multi-Property (3): 1 New Lead (winner), 1 Competing Submission, 1 Repeat'.
     */
    private String buildMultiSummary() {
        Map<String, Integer> countByOutcome = new Map<String, Integer>();
        List<String> order = new List<String>();
        for (Integer priority = PRIORITY_WINNER; priority >= PRIORITY_NO_PROPERTY; priority--) {
            for (RoutingOutcome outcome : outcomes) {
                if (outcome.priority != priority) {
                    continue;
                }
                Integer known = countByOutcome.get(outcome.outcome);
                if (known == null) {
                    order.add(outcome.outcome);
                    countByOutcome.put(outcome.outcome, 1);
                } else {
                    countByOutcome.put(outcome.outcome, known + 1);
                }
            }
        }
        List<String> parts = new List<String>();
        for (String label : order) {
            parts.add(countByOutcome.get(label) + ' ' + label);
        }
        return OUTCOME_MULTI_PREFIX + ' (' + outcomes.size() + '): ' + String.join(parts, ', ');
    }

    /**
     * True when any property failed safe without taking its claim — the signal that used to be
     * visible only as a System.debug.
     *
     * @return true when at least one outcome is UNCLAIMED.
     */
    private Boolean hasUnclaimed() {
        for (RoutingOutcome outcome : outcomes) {
            if (OUTCOME_UNCLAIMED.equals(outcome.outcome)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Routed_Record_Ids__c — one line per routed property IN PROCESSING ORDER:
     * `&lt;normalized address&gt; | &lt;outcome&gt; | &lt;recordId&gt;`. The complete N-result audit, and the
     * only place the full property-to-record mapping exists. Null for the single-result
     * branches, which Result_Record_Id__c already describes completely.
     *
     * @return The audit block, or null.
     */
    private String buildRoutedAudit() {
        if (outcomes.size() < 2) {
            return null;
        }
        List<String> lines = new List<String>();
        for (RoutingOutcome outcome : outcomes) {
            String address = String.isBlank(outcome.normalized) ? '(no address)' : outcome.normalized;
            String target = (outcome.recordId == null) ? '(none)' : String.valueOf(outcome.recordId);
            lines.add(address + ' | ' + outcome.outcome + ' | ' + target);
        }
        return String.join(lines, '\n');
    }

    /**
     * The deterministic pre-filter (C-7). See SENDER_CONTAINS / SENDER_EXACT for the full
     * rationale, including why matching is on the COMPACTED local part.
     *
     * @return A short reason string when the email is automated, else null.
     */
    private String matchPreFilter() {
        String senderHit = matchAutomatedSender(staging.From_Address__c);
        if (senderHit != null) {
            return senderHit;
        }
        return matchAutomationHeaders(staging.Raw_Headers__c);
    }

    /**
     * Match the envelope From against the automated-sender patterns.
     *
     * @param fromAddress The envelope From address; blank never matches.
     * @return The matched pattern, or null.
     */
    private static String matchAutomatedSender(String fromAddress) {
        if (String.isBlank(fromAddress) || !fromAddress.contains('@')) {
            return null;
        }
        String localPart = fromAddress.substring(0, fromAddress.indexOf('@')).toLowerCase();
        // Compacted so 'forwarding-noreply' and 'no.reply' both reduce to a comparable token —
        // Gmail's forwarding confirmations, the canonical case for this filter, are neither an
        // exact nor a prefix match on 'noreply'.
        String compacted = localPart.replaceAll('[^a-z0-9]', '');
        for (String token : SENDER_CONTAINS) {
            if (compacted.contains(token)) {
                return 'sender:' + token;
            }
        }
        return SENDER_EXACT.contains(compacted) ? 'sender:' + compacted : null;
    }

    /**
     * Match the raw headers against the RFC 3834 / de-facto automatic-response headers.
     * EmailToLeadHandler already persists EVERY header verbatim into Raw_Headers__c, which is
     * exactly the class of question that field exists for.
     *
     * @param rawHeaders The persisted headers, one 'Name: Value' per line.
     * @return The matched header name, or null.
     */
    private static String matchAutomationHeaders(String rawHeaders) {
        if (String.isBlank(rawHeaders)) {
            return null;
        }
        if (AUTO_SUBMITTED_PATTERN.matcher(rawHeaders).find()) {
            return 'header:Auto-Submitted';
        }
        if (X_AUTOREPLY_PATTERN.matcher(rawHeaders).find()) {
            return 'header:X-Autoreply';
        }
        return PRECEDENCE_PATTERN.matcher(rawHeaders).find() ? 'header:Precedence' : null;
    }

    /**
     * Map a claim result onto its staging outcome label.
     *
     * @param claimed What PropertyClaimService.claim actually did.
     * @return The matching Outcome__c label.
     */
    private static String toOutcomeLabel(PropertyClaimService.ClaimOutcome claimed) {
        if (claimed == PropertyClaimService.ClaimOutcome.WINNER) {
            return OUTCOME_WINNER;
        }
        if (claimed == PropertyClaimService.ClaimOutcome.DUPLICATE_RACE) {
            return OUTCOME_DUPLICATE_RACE;
        }
        // ClaimOutcome.DUPLICATE is reserved and unreachable from claim() today (every
        // duplicate reached through claim() is a lost race) — mapped anyway so this stays a
        // total function over the enum.
        return (claimed == PropertyClaimService.ClaimOutcome.DUPLICATE)
            ? OUTCOME_DUPLICATE
            : OUTCOME_UNCLAIMED;
    }

    /**
     * Backfill blank broker_name / broker_email from the raw first "From:" line when the LLM
     * missed them. Only fills blanks — a good LLM answer is never overwritten — and does
     * nothing when there is no body text or when both fields are already present.
     *
     * @param extraction The extraction to backfill in place.
     */
    private void applyRegexFallback(LLMExtractionResult extraction) {
        String textContent = staging.Raw_Body__c;
        if (String.isBlank(textContent)) {
            return;
        }

        Boolean nameBlank = String.isBlank(extraction.brokerName);
        Boolean emailBlank = String.isBlank(extraction.brokerEmail);
        if (!nameBlank && !emailBlank) {
            return;
        }

        Matcher fromMatcher = FROM_LINE_PATTERN.matcher(textContent);
        if (!fromMatcher.find()) {
            return;
        }
        String fromLine = fromMatcher.group(1);

        if (emailBlank) {
            Matcher emailMatcher = Pattern.compile(EMAIL_REGEX).matcher(fromLine);
            if (emailMatcher.find()) {
                extraction.brokerEmail = emailMatcher.group();
            }
        }

        if (nameBlank) {
            String name = stripToName(fromLine);
            if (String.isNotBlank(name)) {
                extraction.brokerName = name;
            }
        }
    }

    /**
     * LAST-RESORT BROKER ADDRESS: fall back to the envelope From when neither the LLM nor the
     * regex fallback produced a broker_email. Runs immediately after applyRegexFallback, so it
     * only ever fills what both of those left blank.
     *
     * WHY THIS EXISTS AT ALL. Since 2026-07-31 a competing broker receives no Lead, so their
     * Competing_Broker_Submission__c is the ONLY record of who they are — it must carry an
     * address when one can be known, even though the LLM returned nothing and the body had no
     * parseable "From:" line to scrape.
     *
     * ⚠ ONLY ON AN AUTO-FORWARD. The envelope From is the broker on an AUTO-forward (a
     * mailbox rule preserves the original sender) but is the INTERNAL DPEG EMPLOYEE on a
     * MANUAL forward — a person hitting Fwd puts themselves in From. See EmailToLeadHandler's
     * header. The two shapes are told apart by the module's own tell: EmailToLeadHandler sets
     * Forwarded_By__c to the monitored inbox when a forwarding header proves an auto-forward,
     * and falls back to the envelope From when it cannot — so `From == Forwarded_By` means
     * "no forwarding evidence", i.e. a manual forward, and the fallback is suppressed.
     *
     * The reason to suppress rather than guess: this row is an ADJUDICATION record — it is the
     * evidence for who submitted a property first, and Broker_Email__c is how a disputed claim
     * gets attributed. A blank field is visibly incomplete and invites a human to go look at
     * the raw email on the staging row. A WRONG field is silently authoritative: it would
     * attribute a competing broker's claim to a DPEG employee, and nothing downstream would
     * ever flag it. Blank beats wrong here, and it is not close.
     *
     * ⚠ TWO RESIDUAL GAPS, BOTH ACCEPTED. The `From == Forwarded_By` test is a proxy for
     * "manual forward", not a proof of it, and it is imprecise in both directions:
     *
     *   1. FALSE NEGATIVE — mis-attribution still possible. A MANUAL forward that happens to
     *      carry an X-Forwarded-For header (e.g. the employee forwards a message that had
     *      already been auto-forwarded once) resolves Forwarded_By__c to the monitored inbox,
     *      so From != Forwarded_By and this fallback still fires with the employee's address.
     *      ⚠ SUPERSEDED BY U1, NOT INHERITED. On that email U1 now runs and sets the identity
     *      from the same envelope address, so the mis-attribution is U1's `From != Forwarded_By`
     *      judgement rather than this method's — the same judgement, made once, in
     *      `senderIsOurOwnForwarder()`. Stated explicitly so review does not read this as an
     *      independent second gap.
     *   2. FALSE POSITIVE — a correct address discarded. EmailToLeadHandler sets
     *      Forwarded_By__c to the envelope From whenever NO forwarding header is found, and
     *      that covers two different situations, not one: a manual forward (From = the
     *      employee — the case this suppression targets) AND a broker emailing the monitored
     *      inbox DIRECTLY (From = the broker, because firstNonServiceAddress found nothing to
     *      resolve). The two are indistinguishable here, so the direct-email case is suppressed
     *      too and Broker_Email__c is left blank even though the envelope held the right
     *      address — but only when the LLM and the regex fallback ALSO found nothing, i.e. an
     *      email with no parseable broker identity anywhere in it. Such an email is inherently
     *      ambiguous, and blank-beats-wrong applies to it for the same reason as above: on an
     *      adjudication record, a gap invites a human to read the raw email while a confident
     *      wrong value never gets questioned.
     *
     * ✅ BOTH RESIDUAL GAPS ARE NOW MOOT — SUPERSEDED BY `applySenderFirstBrokerIdentity` (U1,
     * intake-rules-v2, 2026-08-03). This paragraph used to propose a body-shape sharpening ("a
     * quoted From: block is positive evidence of a forward") and ask for it to be raised as its own
     * change. It WAS raised — and the investigation that followed showed the premise was wrong for
     * this workflow: EVERY inbound email here is a forward from DPEG's coordinator, so a
     * body-shape test is always true and would never have fired. U1 shipped as a flat precedence
     * rule instead: the envelope `From_Address__c` IS the broker and outranks the body, guarded by
     * the same `From == Forwarded_By` test this method already used.
     *
     * ⚠ WHAT THAT MEANS FOR THIS METHOD, STATED PLAINLY: U1 runs immediately after it and sets
     * `brokerEmail` from the same envelope address whenever this method would have, so on the
     * overwhelming majority of emails this fallback is now REDUNDANT — it fills a blank that U1 is
     * about to overwrite with the IDENTICAL VALUE. That redundancy is HARMLESS by construction:
     * the two read the same field, apply the same `senderIsOurOwnForwarder()` suppression, and
     * produce the same answer, so there is no interleaving in which one can contradict the other.
     *
     * 🔴 IT IS RETAINED DELIBERATELY. Three reasons, in ascending order of importance:
     *   • it still fires for a non-blank but MALFORMED `From_Address__c`, which U1's
     *     `sanitizeEmail` guard rejects — so the two are not quite co-extensive;
     *   • both gaps 1 and 2 above are now unreachable in practice, because U1 decides the identity
     *     regardless of what the body looks like, so nothing depends on this method's judgement;
     *   • DELETING CODE FROM A CLAIM-KEY PATH FOR TIDINESS, INSIDE A CHANGE THAT HAS ALREADY MOVED
     *     THAT PATH, IS NOT A TRADE WORTH MAKING. `broker_email` is one of the two values the
     *     first-broker-wins ledger arbitrates on; U1 already changed how it is decided. Stacking a
     *     cosmetic removal on top means that if anything regresses, there are two candidate causes
     *     instead of one. If this method should go, it should go in its own commit, on its own
     *     evidence.
     * Its suppression and U1's paste-forward guard are now ONE expression — `senderIsOurOwnForwarder()`
     * — so the two can never disagree about who our own forwarder is.
     *
     * WHY HERE, AND NOT THREADED DOWNSTREAM. The alternative was passing `fromAddress` through
     * claim() -> markDuplicate() / logRepeatSubmission() -> buildSubmission(): five signature
     * changes to deliver one value. This is the only layer that holds the envelope, and every
     * downstream consumer already reads broker_email from this map. It changes nothing on the
     * Lead-creating paths — EmailToLeadService already falls back to the same From address for
     * Lead.Email, so the observable result there is identical.
     *
     * @param extraction The extraction to backfill in place.
     */
    private void applyEnvelopeEmailFallback(LLMExtractionResult extraction) {
        if (String.isNotBlank(extraction.brokerEmail) || String.isBlank(staging.From_Address__c)) {
            return;
        }
        // The "original sender" is really our own forwarder, so it is not the broker. Leave it
        // blank. SHARED PREDICATE — see senderIsOurOwnForwarder(); U1's paste-forward guard asks
        // the identical question and must never drift from this one.
        if (senderIsOurOwnForwarder()) {
            return;
        }
        extraction.brokerEmail = staging.From_Address__c;
    }

    /**
     * U1 (intake-rules-v2) — THE ENVELOPE SENDER IS THE BROKER. IT OUTRANKS THE BODY.
     *
     * ═══ 🔴 THE WORKFLOW THIS IMPLEMENTS — READ THIS BEFORE CHANGING ANYTHING HERE ═══
     * EVERY inbound email reaches this pipeline the same way, confirmed against live staging data
     * 2026-08-03: a broker emails DPEG's coordinator, and the coordinator forwards that message to
     * the Salesforce email service. `EmailToLeadHandler` resolves the two roles from the RFC
     * headers and records them separately, on every row:
     *   • `From_Address__c`  = the ORIGINAL SENDER — i.e. THE BROKER;
     *   • `Forwarded_By__c`  = the coordinator who forwarded it.
     * So the broker's identity is already sitting on the staging row, extracted from the transport
     * layer, before the model is ever asked. The model's `broker_email` is a guess read out of
     * prose; the envelope is a fact. When they disagree, the fact wins — and whoever the BODY
     * names is an offer-submission contact, which is what `listing_broker_*` is for.
     *
     * This is what the reported defect actually was: an email whose body named a broker at a large
     * firm produced a Lead — and a CLAIM — for that person, rather than for the broker who really
     * sent it. No body-shape heuristic is involved and none is wanted: an earlier draft of U1
     * gated on "does the body look like a forward?", which on this workflow is ALWAYS true (the
     * coordinator's client quotes the original), so that version would never have fired and would
     * have fixed nothing.
     *
     * ═══ THE GUARDS — EACH `return` IS A DOCUMENTED REASON NOT TO OVERRIDE ═══
     *   1. NO USABLE ENVELOPE SENDER. `sanitizeEmail(From_Address__c)` came back null, so there is
     *      nothing to override WITH. Fall back to the body-extracted identity.
     *      ⚠ IN PRACTICE THIS FIRES ONLY FOR A **BLANK** ADDRESS, AND THE REASON IS WORTH KNOWING
     *      (established 2026-08-03 when a test asserting the malformed case could not even be set
     *      up). Two independent facts close the malformed route:
     *        (a) `Inbound_Email_Staging__c.From_Address__c` is an **Email-TYPE** field, so the
     *            platform validates format at DML — a value like `'not-an-address'` cannot be
     *            persisted at all;
     *        (b) more decisively, `InboundEmailStagingService.createStaging` already writes it as
     *            `InboundEmailFieldUtil.sanitizeEmail(request.fromAddress)`. Anything malformed was
     *            turned into NULL at the write boundary, so every value that reaches this line has
     *            ALREADY passed the identical check. The call here is idempotent and can only
     *            newly reject a value that is blank.
     *      🔴 DO NOT "SIMPLIFY" THIS TO `String.isBlank(staging.From_Address__c)`. `sanitizeEmail`
     *      is a SHARED utility whose contract is deliberately broader than this caller's — it also
     *      guards LLM output, which is NOT pre-sanitized — and the null-return here is the correct
     *      expression of "give me a usable address or nothing". Narrowing it would couple this
     *      guard to the current write path, so re-ordering or relaxing that write would silently
     *      let a malformed address become a broker identity. Defensive is right here; it simply is
     *      not testable THROUGH THIS FIELD, which is why the test covers blank only.
     *   2. 🔴 PASTE-FORWARD GUARD — `From_Address__c` EQUALS `Forwarded_By__c`. That equality is
     *      this module's own tell, set by `EmailToLeadHandler`: when no forwarding header proves an
     *      original sender, it falls back to the envelope From for BOTH fields. So "they are equal"
     *      means "the original sender could not be resolved, and this address is really OUR OWN
     *      FORWARDER" — a pasted-in forward, or a message the coordinator composed. Making that
     *      address the broker would attribute the claim to DPEG's own staff: silent, authoritative
     *      and unrecoverable. The body-extracted identity is used instead.
     *      ⚠ THE SAME PREDICATE ALREADY GOVERNS `applyEnvelopeEmailFallback` (W2). It is expressed
     *      ONCE, in `senderIsOurOwnForwarder()`, and both callers use it — one semantic rule, one
     *      expression. Do not re-inline it.
     *   3. 🔴 THE MODEL ALREADY AGREED. LOAD-BEARING — DO NOT "SIMPLIFY THIS AWAY". When the model
     *      names the same address the envelope carries (the common good case), NOTHING changes:
     *      company, phone, title and mobile are all kept, and U3's footer-extracted firm survives
     *      to become `Lead.Company`. Without this guard every ordinary email would be stripped of
     *      its contact block for no reason. The demotion therefore only ever runs when the two
     *      identities GENUINELY DIFFER — the only case where the extracted contact block describes
     *      somebody other than the person this Lead is for.
     *
     * ═══ COST ═══
     * ZERO SOQL and ZERO DML — pure in-memory mutation of an already-loaded DTO, and no
     * configuration read of any kind. The `lastRunQueryCount` / `lastRunDmlCount` budgets are
     * untouched, which is asserted rather than assumed.
     *
     * ⚠ IT IS AN ARBITRATION CHANGE, BUT IT RE-KEYS NOTHING. `broker_email` feeds repeat detection
     * and `Competing_Broker_Submission__c.Broker_Email__c`, so who wins a dispute can change. It
     * does NOT touch `property_address`, so no `Property_Key__c` moves and no existing claim is
     * re-keyed. A submission recorded BEFORE U1 under a body-named broker will not match as a
     * repeat afterwards and routes as a competing submission instead — accepted (the trail is
     * append-only, so nothing is lost). Do NOT "fix" that with a second `findBrokerSubmission`
     * lookup on the demoted address: that is +1 SOQL PER PROPERTY INSIDE THE LOOP, up to +10 per
     * email, against a budget this class asserts, for a shrinking historical population.
     *
     * ═══ 🔴 RESIDUAL 1 — BLAST PLATFORMS. "THE ENVELOPE IS THE BROKER" IS NOT UNQUALIFIED. ═══
     * A broker submitting through RCM, Crexi or Buildout can reach us with an envelope From of
     * the PLATFORM (`listings@buildout.com`) rather than their own address. U1 then keys EVERY
     * broker on that platform to ONE identity, and two specific things break:
     *   • REPEAT DETECTION MISFIRES ACROSS BROKERS. Two DIFFERENT brokers blasting THE SAME
     *     property through the same platform: `findBrokerSubmission(platformAddress, thatProperty)`
     *     matches the FIRST broker's row, so the second broker's genuine COMPETING submission is
     *     filed as the first broker's REPEAT — and they lose their claim record entirely.
     *   • THE AUDIT ROW CANNOT IDENTIFY ANYONE. `Competing_Broker_Submission__c.Broker_Email__c`
     *     holds the platform address for every broker on it, so the one record that exists to
     *     adjudicate a dispute names a mailer, not a person.
     * PARTIAL MITIGATIONS, neither sufficient: `noreply@`-shaped platform senders are caught by
     * SENDER_CONTAINS before the callout, and the lookup is per-PROPERTY, so damage cannot cross
     * properties. But `listings@`-shaped senders reach U1 untouched.
     * ⚠ THIS IS EXPECTED TRAFFIC, NOT AN EDGE CASE. The SENDER_CONTAINS block's own
     * `Precedence: bulk` ruling calls a legitimate blast platform's listing announcement "the
     * highest-value email this pipeline exists to capture". So read "the envelope IS the broker"
     * as true of the coordinator-forward workflow it was designed for, NOT as a universal claim.
     * If this starts costing claims, the fix is a platform-sender list that stands U1 down (the
     * shape guard 2 already provides), not a body-shape heuristic.
     *
     * ═══ RESIDUAL 2 — SENDING ON SOMEONE'S BEHALF (accepted) ═══
     * An assistant or analyst emailing for a broker becomes the Lead, and that firm's submissions
     * fragment across two addresses. Accepted deliberately: for an ARBITRATION KEY, deterministic
     * beats accurate-on-average. A rule that is always the envelope can be reasoned about, argued
     * from, and corrected by hand; a rule that is "usually the sender, unless the prose suggests
     * otherwise" cannot be audited at all — and guessing wrong there is exactly the defect U1 was
     * raised to fix.
     *
     * @param extraction The extraction to mutate in place.
     */
    private void applySenderFirstBrokerIdentity(LLMExtractionResult extraction) {
        String sender = InboundEmailFieldUtil.sanitizeEmail(staging.From_Address__c);
        if (sender == null) {
            return;
        }
        if (senderIsOurOwnForwarder()) {
            return;
        }
        if (sender.equalsIgnoreCase(extraction.brokerEmail)) {
            return;
        }
        demoteBodyBroker(extraction, sender);
    }

    /**
     * TRUE when the envelope's "original sender" is really OUR OWN FORWARDER rather than a broker.
     *
     * `EmailToLeadHandler` sets `Forwarded_By__c` to the monitored inbox when a forwarding header
     * proves an original sender, and falls back to the envelope From when it cannot. So equality
     * between the two fields is not a coincidence — it is the module's own signal that the sender
     * could not be resolved to anyone but ourselves.
     *
     * ⚠ SHARED BY TWO CALLERS ON PURPOSE: `applySenderFirstBrokerIdentity`'s paste-forward guard
     * and `applyEnvelopeEmailFallback`'s suppression ask the identical question, and both exist to
     * stop the same failure — attributing a broker's claim to DPEG's own staff. One rule, one
     * expression, so they can never drift apart.
     *
     * ═══ 🔴 PROHIBITION — THIS GUARD DEPENDS ON CODE IN ANOTHER CLASS ═══
     * It works ONLY because `EmailToLeadHandler` NEVER LEAVES `forwardedBy` NULL:
     *
     *     request.forwardedBy = (monitoredInbox != null) ? monitoredInbox : email.fromAddress;
     *
     * (EmailToLeadHandler, ~line 128 — the `: email.fromAddress` fallback is the load-bearing
     * half.) Remove that fallback and `Forwarded_By__c` becomes null on exactly the emails this
     * guard is for; `From_Address__c.equalsIgnoreCase(null)` then returns FALSE, and the guard
     * SILENTLY STOPS FIRING. The consequences are the ones the guard exists to prevent, arriving
     * with no exception, no error row and no failing test outside this module: on every
     * paste-forward the internal forwarder becomes the broker, takes the claim, and lands on the
     * adjudication record as the submitting party. If you ever change how `Forwarded_By__c` is
     * populated, change this predicate in the same commit.
     *
     * @return true when From_Address__c is present and equals Forwarded_By__c, case-insensitively.
     */
    private Boolean senderIsOurOwnForwarder() {
        return String.isNotBlank(staging.From_Address__c)
            && staging.From_Address__c.equalsIgnoreCase(staging.Forwarded_By__c);
    }

    /**
     * Swap the envelope sender into the broker identity and demote whoever the BODY named to the
     * listing-contact fields.
     *
     * ═══ 🔴 NO NOTE IS WRITTEN TO THE LEAD, AND NOTHING IS LOST BY THAT (2026-08-03) ═══
     * This method used to append a "Sender-first identity: ..." note to `Deal_Notes__c` naming
     * every value the demotion discarded. It has been REMOVED at the user's request: it is
     * pipeline bookkeeping, and it was surfacing on the record a human works as if it were deal
     * information. Do not reinstate it.
     *
     * WHERE EACH DISCARDED VALUE ACTUALLY LIVES — verified before removal:
     *   • `brokerName` / `brokerEmail` -> `Lead.Listing_Broker_Name__c` / `Listing_Broker_Email__c`,
     *     written by this very method (fill-if-blank). They are ON THE LEAD, as fields.
     *   • `brokerCompany`, `brokerPhone`, `brokerMobile`, `brokerTitle` -> preserved VERBATIM in
     *     `Inbound_Email_Staging__c.Extracted_JSON__c`, which `execute()` writes with the model's
     *     raw response BEFORE any routing decision (D3) and which nothing ever mutates.
     *
     * 🔴 THE RULE THIS ESTABLISHES: THE AUDIT TRAIL FOR A DEMOTION LIVES ON THE STAGING ROW, NOT
     * ON THE LEAD. `Extracted_JSON__c` is the complete, immutable record of what the model said;
     * the Lead carries only what a human working the deal needs. A future change that wants to
     * "restore visibility" of a discarded value should surface the staging row, not re-add prose
     * to `Deal_Notes__c`.
     *
     * ⚠ THE OTHER `Deal_Notes__c` CONTRIBUTIONS ARE UNAFFECTED and must stay: the model's
     * `deal_summary`, the parser's plausibility-rejection notes ("offer_due_date '2023-08-11' was
     * ignored: not a plausible offer deadline"), and the spillover list of properties the email
     * carried but the pipeline could not route. Each of those describes the DEAL and exists
     * nowhere else on the record. Only the demotion note described the pipeline itself.
     *
     * ⚠ `EmailToLeadService.buildDealNotes` only emits the '-- Extraction notes --' header when
     * the notes list is non-empty, and returns null when no section contributed at all — so
     * removing this note cannot leave an orphaned header or an empty `Deal_Notes__c`.
     *
     * ═══ 🔴 WHY THE CONTACT BLOCK IS CLEARED RATHER THAN CARRIED OVER ═══
     * `brokerPhone`, `brokerMobile` and `brokerTitle` describe the BODY-NAMED PERSON, not the
     * person this Lead is for, so they are always cleared — a colleague does not share a direct
     * line or a job title. `brokerCompany` is not cosmetic either: it flows to `Lead.Company` ->
     * `LeadConvertMatchService.collectMatchKeys` -> `AccountSelector.selectByNames`, so keeping it
     * across firms would ATTRIBUTE THE DEAL TO THE BODY-NAMED BROKER'S FIRM'S ACCOUNT. Clearing it
     * drops `Lead.Company` to `EmailToLeadService.COMPANY_PLACEHOLDER`, which
     * `LeadConvertMatchService` (D1b) DELIBERATELY EXCLUDES from Account matching — the correct,
     * recoverable outcome. The firm name is not lost — it survives verbatim in the staging row's
     * `Extracted_JSON__c` (see the NO NOTE section above).
     *
     * ═══ THE ONE EXCEPTION: SAME-FIRM (TEAM-BLAST) SENDS KEEP THE COMPANY ═══
     * When the envelope sender and the body-named broker share an email DOMAIN, they are
     * colleagues, so the firm is correct for BOTH and clearing it would throw away a good value
     * for no reason. `colleague@jll.com` forwarding an internal note that names
     * `mark.stern@jll.com` is a real and common shape, and the whole hazard above — attributing
     * the deal to somebody ELSE'S firm — does not exist when there is only one firm. So
     * `brokerCompany` (and only `brokerCompany`) survives a same-domain demotion.
     *
     * ⚠ Domain equality is a proxy for "same firm", not a proof of it, and it is deliberately the
     * CONSERVATIVE proxy: it can only ever RETAIN a company that the domain already implies, and
     * a free-mail sender (`hotmail.com`) never matches a brokerage domain, so the incident shape
     * still clears. It is not used for anything except this retention.
     *
     * `brokerName` becomes the envelope display name, or NULL when there is none. Null is
     * correct and needs no new plumbing: `EmailToLeadService.createLeadFromExtracted` already
     * falls back `brokerName -> fromName -> 'Unknown'`, and `createLead` already passes
     * `fromName = staging.From_Name__c`.
     *
     * ═══ THE LISTING CONTACT IS FILL-IF-BLANK ONLY ═══
     * A populated `listingBrokerEmail` is an EXPLICIT model call (the blast-platform shape:
     * sender is not the listing broker) and overwriting it destroys information. `listingBrokerName`
     * is filled independently, and only when it too is blank, for the same reason — a model that
     * named a listing broker without an address still made a call worth keeping.
     *
     * ⚠ BOTH DEMOTED VALUES ARE RE-SANITIZED ON THE WAY IN, and that is not belt-and-braces.
     * `brokerEmail` travels UNSANITIZED by contract (LLMExtractionParser keeps the claim values
     * verbatim) while `listingBrokerEmail` is sanitized by the parser and lands on an Email
     * field, and `brokerName` is UNCLIPPED while `Listing_Broker_Name__c` is Text(120). Moving a
     * value between those two slots without re-applying the destination's rules is how an
     * over-long name or a malformed address becomes a DmlException that rolls back a committed
     * claim. (Note `EmailToLeadService.applyBrokerBlock` clips `listingBrokerName` to 255, not
     * 120 — today that is harmless only because the PARSER clips to 120 first, an invariant this
     * method must not be the one to break.)
     *
     * @param extraction The extraction to mutate in place.
     * @param sender     The sanitized envelope sender that becomes the broker identity.
     */
    private void demoteBodyBroker(LLMExtractionResult extraction, String sender) {
        // Computed BEFORE brokerEmail is overwritten — it compares the sender's domain against the
        // BODY-NAMED broker's, and the next few lines destroy that value.
        Boolean sameFirm = isSameFirmDomain(sender, extraction.brokerEmail);

        // ⚠ CAPTURE BEFORE CLEARING. Everything below destroys the values these two hold, and they
        // are what the listing-contact slot is filled from.
        String oldName = extraction.brokerName;
        String oldEmail = extraction.brokerEmail;

        extraction.brokerEmail = sender;
        extraction.brokerName = String.isNotBlank(staging.From_Name__c) ? staging.From_Name__c : null;
        if (!sameFirm) {
            extraction.brokerCompany = null;
        }
        extraction.brokerPhone = null;
        extraction.brokerMobile = null;
        extraction.brokerTitle = null;

        if (String.isBlank(extraction.listingBrokerEmail)) {
            extraction.listingBrokerEmail = InboundEmailFieldUtil.sanitizeEmail(oldEmail);
        }
        if (String.isBlank(extraction.listingBrokerName)) {
            extraction.listingBrokerName =
                InboundEmailFieldUtil.clip(oldName, LEN_LISTING_BROKER_NAME);
        }
    }

    /**
     * Whether two addresses sit on the SAME email domain — the proxy for "these two people are
     * colleagues", used ONLY to decide whether `brokerCompany` survives a demotion.
     *
     * ⚠ IT IS A PROXY, AND DELIBERATELY THE CONSERVATIVE ONE. It can only ever RETAIN a firm name
     * the sender's own domain already implies, so the worst case is that a Lead keeps a company it
     * would otherwise have lost. Both the incident shape (a free-mail sender against a brokerage
     * domain) and the blast-platform shape (a platform domain against a brokerage domain) fail to
     * match and still clear, which is what makes the exception safe to grant.
     *
     * @param first  The first address; null/blank yields false.
     * @param second The second address; null/blank yields false.
     * @return true when both carry a domain and the two domains match case-insensitively.
     */
    private static Boolean isSameFirmDomain(String first, String second) {
        String firstDomain = emailDomain(first);
        String secondDomain = emailDomain(second);
        return firstDomain != null && secondDomain != null
            && firstDomain.equalsIgnoreCase(secondDomain);
    }

    /**
     * The domain part of an email address, or null when there is not one.
     *
     * Reads the LAST '@' rather than the first: on a malformed multi-'@' value the trailing
     * component is the one a mail system would route on, and splitting on the first '@' would let
     * `a@jll.com@evil.invalid` claim to be at JLL.
     *
     * @param address The address to read; null/blank returns null.
     * @return The lower-cased domain, or null.
     */
    private static String emailDomain(String address) {
        if (String.isBlank(address)) {
            return null;
        }
        Integer at = address.lastIndexOf('@');
        if (at < 0 || at == address.length() - 1) {
            return null;
        }
        return address.substring(at + 1).trim().toLowerCase();
    }

    /**
     * U2 (intake-rules-v2) — A CALL-FOR-OFFERS EMAIL PRODUCES NO LEAD. Unconditionally.
     *
     * One condition, deliberately: `email_category == 'call_for_offers'`. DPEG does not work
     * mass-marketed call-for-offers campaigns, so a Lead for one is never wanted — the rule is a
     * business fact, not a tuning problem, and it is stated here exactly as the user stated it.
     *
     * ═══ 🔴 THE STAGING ROW PRESERVES THE EMAIL. IT DOES NOT PRESERVE THE CLAIM. ═══
     * An earlier version of this comment said "nothing is lost". That OVERSTATES it, and the
     * difference is the whole risk of an unconditional rule, so state it precisely:
     *   • WHAT SURVIVES: the `Inbound_Email_Staging__c` row is written in full BEFORE any routing
     *     decision (D3 tier 1) and is never deleted — raw body, every RFC header, and the complete
     *     `Extracted_JSON__c` with every property named, verbatim. `finish()` still runs, so the
     *     Task is still logged: MANDATORY, not cosmetic, because an unlogged Message-ID means a
     *     platform redelivery re-runs the entire pipeline.
     *   • 🔴 WHAT DOES NOT: no Lead means NO REGISTRY CLAIM. If a genuinely EXCLUSIVE listing is
     *     confidently misclassified as `call_for_offers`, that property stays unclaimed — and a
     *     second broker who later submits it under any other classification WINS IT OUTRIGHT. The
     *     first broker's protection is gone, and restoring it is MANUAL REGISTRY SURGERY, not a
     *     staging re-read. Recoverability here is "a human can reconstruct what happened", not
     *     "the pipeline can undo it".
     * ⚠ `Gated_Call_For_Offers` is therefore an ACTIVE WATCH, not an archive. Someone has to read
     * it, because a wrong call is only visible there and only reversible while the property is
     * still unclaimed.
     *
     * ═══ ⚠ A POLICY INCONSISTENCY, RECORDED HONESTLY ═══
     * D2's HARD gate — the module's PRIMARY relevance signal — suppresses a Lead only on
     * `is_acquisition_related = false` AND `confidence >= 0.85`. This gate suppresses on the
     * CATEGORY ALONE, with no confidence requirement at all, which is STRICTER than the module
     * permits for a stronger signal. That is not an oversight and not an argument for adding a
     * threshold here on consistency grounds: it is the user's explicit instruction ("if email is
     * related to call for offers then we must not store it as a lead, simple"), taken literally
     * because the business rule is categorical. It is written down so the asymmetry is a decision
     * on the record rather than something a future reader discovers and quietly "fixes".
     *
     * ═══ ⚠ WHY category_confidence IS PARSED BUT DELIBERATELY NOT GATED ON ═══
     * The model returns `category_confidence` and the parser reads it into
     * `LLMExtractionResult.categoryConfidence`, but NO branch here consults it. That is a decision,
     * not an omission:
     *   • the rule the business asked for is categorical, and adding a threshold would create a
     *     population of "probably a call for offers, so we made a Lead anyway" that nobody asked
     *     for and nobody would work;
     *   • the value costs nothing to keep — it rides along in `Extracted_JSON__c` on every row —
     *     and it is the ONLY evidence available if suppression later proves too aggressive. Query
     *     the gated staging rows, read the distribution, and a threshold can be introduced later
     *     from data rather than from a guess.
     * An earlier draft gated on it behind a Custom Metadata toggle. That was removed with the rest
     * of the configuration: a toggle that ships OFF is a feature that has never run, and the
     * user's rule needs no dial. If a threshold is ever reintroduced, gate on THIS field —
     * never on `confidence`, which measures certainty about `is_acquisition_related`, and a
     * call-for-offers blast IS acquisition-related, so `confidence` carries no discrimination here
     * at all.
     *
     * ═══ FAIL OPEN EVERYWHERE ELSE ═══
     * `emailCategory` defaults to `CATEGORY_OTHER` and the parser coerces any unrecognised value to
     * it, so a garbled, absent or legacy-shape classification can NEVER reach this gate. That is
     * also what keeps the prompt's one-line rollback lever safe: the pre-enrichment response
     * carries no `email_category`, so reverting the prompt silently disables this rule rather than
     * stranding it on.
     *
     * ═══ WHY EMAIL-LEVEL AND NOT PER-PROPERTY ═══
     * `email_category` is an email-level value. Evaluating it inside the per-property loop would
     * interleave a classification decision with the cluster-lock ordering the deadlock fix depends
     * on, for no gain.
     *
     * ═══ WHY THERE IS NO CLAIM, AND WHY THAT IS THE RIGHT ANSWER ═══
     * Not a trade-off — `Property_Registry__c.Winning_Lead_Required` is
     * `AND(ISNEW(), ISBLANK(Winning_Lead__c))`, and `Competing_Broker_Submission__c` carries the
     * identical rule, so a claim row CANNOT BE INSERTED without a Lead. It would also be harmful
     * if it were possible: registering a blast would make the FIRST BLAST the winner of that
     * property, and a later broker with a genuine EXCLUSIVE would then route to branch (d),
     * receive no Lead, and have their email logged against the blast — a silent total loss of a
     * real submission, inverting the module's whole purpose. An exclusive beating a blast is the
     * desired arbitration.
     *
     * ⚠ STILL POST-CALLOUT, AND THAT IS NON-NEGOTIABLE. See the `SENDER_CONTAINS` block: bulk mail
     * must reach the LLM and be classified there. A pre-callout blast filter would suppress on a
     * header rather than on the model's reading of the email, and its false positives would be
     * invisible lost claims.
     *
     * @param extraction The parsed extraction.
     * @return true when the email must produce no Lead and no claim.
     */
    private static Boolean isCallForOffersGated(LLMExtractionResult extraction) {
        return LLMExtractionResult.CATEGORY_CALL_FOR_OFFERS.equals(extraction.emailCategory);
    }

    /**
     * Reduce a raw "From:" line to a bare display name: strip any &lt;...&gt; angle-bracket
     * block and any bare email address, drop quote and parenthesis characters, collapse
     * whitespace, and trim.
     *
     * @param fromLine The raw content following "From:".
     * @return The cleaned display name (possibly empty).
     */
    private String stripToName(String fromLine) {
        return fromLine
            .replaceAll('<[^>]*>', ' ')
            .replaceAll(EMAIL_REGEX, ' ')
            .replaceAll('["\'()]', ' ')
            .replaceAll('\\s+', ' ')
            .trim();
    }

    /**
     * Parse the LLM's UTC 'yyyy-MM-dd HH:mm:ss' sent timestamp. Falls back to now() when the
     * value is blank or cannot be parsed, so a missing/garbled timestamp never blocks the
     * claim.
     *
     * @param raw The raw sent_datetime string (may be blank).
     * @return The parsed GMT Datetime, or now() on blank/parse failure.
     */
    private Datetime parseSentDatetime(String raw) {
        if (String.isNotBlank(raw)) {
            try {
                return Datetime.valueOfGmt(raw.trim());
            } catch (Exception e) {
                System.debug(LoggingLevel.DEBUG,
                    'ExtractAddressQueueable.parseSentDatetime: unparseable sent_datetime "'
                    + raw + '" — defaulting to now(). ' + e.getMessage());
            }
        }
        return Datetime.now();
    }
}
