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
 *    6b. LISTING-BROKER ADDRESS GROUNDING GUARD (email-level), 2026-08-31.
 *           `listing_broker_email` is DROPPED when the address appears nowhere in the text the
 *           model was given (Subject__c + Raw_Body__c). Measured defect: the model invented
 *           `info@nordhavencommercial.com` from a firm name for an email whose body contains no
 *           '@' at all, and it landed on a field a human reads as "who do I call". Scoped to the
 *           listing pair — `broker_email` is a claim value and keeps its envelope backstop
 *           instead. See dropUngroundedListingBrokerEmail.
 *           🔴 CORRECTED 2026-08-31 (SEQUENCING DEFECT A): IT RUNS TWICE — once BEFORE step 6's
 *           demotion so a cleared slot can still be filled with the real demoted contact, and
 *           once AFTER it so the guard is the LAST WRITER of the field it protects. With the
 *           single "before" call, a fabrication the model put in `broker_email` was copied into
 *           the slot by the demotion's fill-if-blank AFTER the guard had already skipped it as
 *           blank, and reached two live Leads. Both calls are load-bearing; the method's header
 *           enumerates what each earns and why one moved call is NOT the equivalent fix.
 *    6c. THE DEMOTION'S CONTACT BLOCK IS CONDITIONAL, 2026-08-31 (DEFECT B).
 *           `demoteBodyBroker` used to clear broker_phone / broker_mobile / broker_title
 *           unconditionally. It still does for a genuinely different body-named broker — that is
 *           the case it exists for. It stands down when the demoted identity is the SENDER
 *           THEMSELVES under an address the model invented (same compacted local part, not a role
 *           mailbox, and the address appears nowhere in the email). Measured: a real phone and a
 *           real title were destroyed because the model mistyped one word of the sender's own
 *           domain. See demoteBodyBroker and isMistypedSenderAddress.
 *    7. RELEVANCE GATE (D2, tiered):
 *           HARD (is_acquisition_related = false AND confidence >= 0.85)
 *                -> NO LEAD, NO CLAIM, Task logged, outcome recorded.
 *           SOFT (false but less certain) -> continue, Parse_Confidence__c = LOW,
 *                and STILL CLAIM.
 *    7b. CALL-FOR-OFFERS BRANCH (2026-08-03 as a bare gate / 2026-08-10 as a branch —
 *           intake-rules-v2 U2, then Tranche 4B D3+D8+D26). email_category is
 *           'call_for_offers' -> STILL NO LEAD AND STILL NO CLAIM, Task logged. Unconditional:
 *           DPEG does not work marketed call-for-offers campaigns. Since 4B it ALSO matches
 *           each named property through the CLAIM PIPELINE ONLY (registry -> resolveLiveRecord)
 *           and, when that resolves a CONVERTED winner's Opportunity, stamps the deal's
 *           Offer_Due_Date__c / Listing_Broker_Name__c / Listing_Broker_Email__c and files the
 *           email on it. Where nothing matches, nothing is created — byte-identical to the
 *           pre-4B behaviour. 🔴 ATTACHMENTS STAY SUPPRESSED on this branch even though it now
 *           produces routed record Ids (D26 Q2) — see suppressFilePersist. Nothing is lost —
 *           the staging row keeps the raw body and the full Extracted_JSON__c, and the
 *           Gated_Call_For_Offers list view is how the population is found. Deliberately
 *           POST-CALLOUT: see the SENDER_CONTAINS block for why a pre-callout blast filter is
 *           still prohibited. See routeCallForOffers.
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
 *    8b. PORTFOLIO DEAL (2026-08-17, Decision C1) — when the work-list holds TWO OR MORE
 *           properties, ONE Portfolio_Deal__c is created HERE, before the loop and outside its
 *           per-property try/catch, and every Lead the loop creates is stamped with it AT INSERT.
 *           Single-property emails create NOTHING (Decision E, and the single-property DML budgets
 *           in the test class are its permanent falsifier). It exists because the grouping was
 *           already derived correctly and recorded only as TEXT on this backend staging row, which
 *           the Acquisitions team cannot see — so this is a visibility surface over an existing
 *           derivation, not a new derivation. FAIL-SOFT: a portfolio deal failure degrades to "no
 *           grouping" and is recorded on Error__c; it must never cost the email its claim. See
 *           createPackageIfMultiProperty.
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
 *        which is what makes branch (a) possible for the NEXT email. Each Task now names the
 *        SENDER (2026-08-04) — see "THE SENDER SHOWN ON THE LOGGED TASK" below.
 *    9b. NO FILE DML HERE — CORRECTED 2026-08-10. This step used to read "ONE bulk DML linking
 *        this email's already-persisted Salesforce Files to THE SAME ORDERED TARGET LIST", and
 *        that has been untrue since 2026-08-06, when routed linking LEFT finish() with the
 *        carrier redesign. finish() now hands the carrier BYTES to a THIRD transaction: it
 *        ENQUEUES AttachmentPersistQueueable with IDS ONLY, or RELEASES the carrier when there
 *        is nothing to link to. See "ATTACHMENT HANDOFF" below and enqueueAttachmentPersist's
 *        four decisions. 🔴 The enqueue lives in finish() and NOWHERE ELSE — that location is
 *        the redelivery guard. ⚠ Since Tranche 4B the U2 call-for-offers branch reaches this
 *        step with a NON-EMPTY target list and must still RELEASE; `suppressFilePersist` is
 *        what makes it, and finish() is now the load-bearing method of that whole branch.
 *    10. Stamp staging: Outcome__c (summary), Result_Record_Id__c (primary),
 *        Routed_Record_Ids__c (all N), Property_Count__c, Processed_DateTime__c.
 *    10b. Copy that same routed audit onto the portfolio deal's Routed_Outcomes__c (Decision B2), so the
 *        portfolio deal itself records the properties that went to ANOTHER broker. A no-op — zero DML —
 *        whenever there is no portfolio deal. 🔴 THIS IS THE SECOND DML ON Portfolio_Deal__c AND IT IS
 *        UNAVOIDABLE, NOT AN OVERSIGHT: the audit exists only after the loop while the portfolio deal Id
 *        is needed before it, so no one statement can do both. The alternatives (mixed-type DML,
 *        post-loop insert plus N Lead updates, dropping B2) are enumerated at the call site in
 *        finish().
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
 * ═══ THE SENDER SHOWN ON THE LOGGED TASK (2026-08-04) ═══
 * `senderName` / `senderEmail` carry the ONE broker identity this job resolved, and finish()
 * hands them to InboundEmailActivityService so the Task actually says who the email came from.
 * ONE EMAIL, ONE BROKER IDENTITY: the Task shows the same identity that drove arbitration, never
 * a second independently-derived notion of "who sent this" that would be free to disagree with it.
 *
 * They are DEFAULTED FROM THE ENVELOPE (`From_Name__c` / `From_Address__c`) the instant the
 * staging row loads, BEFORE ANY BRANCH — and that placement is load-bearing, not tidiness.
 * finish() is reachable from FOUR places, and the reply / deterministic-pre-filter prologue
 * RETURNS BEFORE THE CALLOUT, so no extraction exists on that path at all. Deriving the sender
 * only where an extraction is in scope would ship a fix that is silently absent from the
 * highest-volume branch. They are then REFINED fill-if-present (never blanked) immediately after
 * applySenderFirstBrokerIdentity — a no-op on the ordinary auto-forward, and the whole point on
 * the PASTE-FORWARD shape, where U1 stands down and the envelope is DPEG's OWN COORDINATOR.
 *
 * DISPLAY ONLY. Nothing here is written to `Property_Key__c`, `Broker_Email__c`, `Lead.Email` or
 * any other arbitration input, and the pair adds NO SOQL and NO DML — the
 * `lastRunQueryCount` / `lastRunDmlCount` budgets are unchanged.
 *
 * ═══ ATTACHMENT HANDOFF (2026-08-05; REDESIGNED 2026-08-06) ═══
 * 🔴 THIS JOB OWNS THE LEAD AND THE REGISTRY CLAIM, SO IT MUST NEVER TOUCH `ContentVersion`.
 * A `ContentPublication Limit exceeded` here would take the claim with it — recoverable only by
 * manual registry surgery. It therefore does not create files and no longer links them either;
 * it hands the work to `AttachmentPersistQueueable`, a transaction that owns nothing else.
 *
 * The 4th constructor argument (`List<Id> contentDocumentIds`) and `linkAttachments()` are GONE.
 * Document Ids do not exist until after routing, so that parameter was always null — a vestigial
 * trap. Their REASONING relocates rather than disappearing:
 *
 *   • **linkTo() MUST NEVER BE CALLED PER PROPERTY OR PER FILE** — one bulk statement, once.
 *     That invariant moved WITH the call, to `AttachmentPersistQueueable`, whose budget is
 *     pinned constant in BOTH file count and target count.
 *   • **🔴 REDELIVERY SAFETY IS STRUCTURAL AND STILL DEPENDS ON A LOCATION IN THIS FILE.** The
 *     duplicate-delivery guard in execute() returns WITHOUT calling finish(), and the file job
 *     is enqueued only from inside finish(). Moving `enqueueAttachmentPersist` out of finish(),
 *     or making the skip path call finish(), silently re-opens duplicate files on live Leads.
 *     The skip path now also RELEASES the duplicate's carrier, so it leaves no bytes behind.
 *   • **THE DML BUDGETS DROPPED BY 1**, because routed linking left finish() on 2026-08-06.
 *     ⚠ CORRECTED 2026-08-08 — the earlier wording said "`singlePropertyDmlBudget` 8 -> 7" as if
 *     there were one such literal. **THE TEST CLASS CARRIES THREE, AND ONLY THE THIRD MOVED:**
 *
 *       ExtractAddressQueueableTest:2673  singlePropertyDmlBudget = 20  ceiling (<=)  UNCHANGED
 *       ExtractAddressQueueableTest:3475  singlePropertyDmlBudget = 20  ceiling (<=)  UNCHANGED
 *       ExtractAddressQueueableTest:3690  singlePropertyDmlBudget =  7  EQUALITY      8 -> 7
 *
 *     plus `DML_BUDGET` 44 -> 43 at :1214 (N=10, also an EQUALITY assertion) and the two QUERY
 *     budgets, 30 at N=1 (:2672, :3474) and 120 at N=10 (:1206), which are UNCHANGED. Naming only
 *     one of the three sent the next reader to "verify" against a number their test does not use.
 *     A failing query budget still means someone reintroduced a re-read.
 *
 * ═══ 🔴 BUDGET AMENDED 2026-08-17 — MULTI-PROPERTY ONLY: N=10 DML 43 -> 45, N=1 UNCHANGED ═══
 * The portfolio deal (step 8b / 10b above) adds TWO DML statements to a MULTI-property email and
 * ZERO to every other shape:
 *
 *       N = 10   DML_BUDGET (EQUALITY)          43 -> 45   +1 portfolio deal insert, +1 audit stamp
 *       N = 10   QUERY_BUDGET (ceiling, 120)    UNCHANGED  the insert is BLIND — zero SOQL
 *       N = 1    singlePropertyDmlBudget (<=20) UNCHANGED  ┐ 🔴 THE PERMANENT FALSIFIER FOR
 *       N = 1    singlePropertyDmlBudget (==7)  UNCHANGED  ┘ DECISION E — DO NOT TOUCH THESE
 *       N = 1    singlePropertyQueryBudget (30) UNCHANGED
 *       call-for-offers CFO_DML_BUDGET (8)      UNCHANGED  the U2 branch creates no Lead, so it
 *                                                          never reaches routeProperties' portfolio deal
 *
 * ⚠ THE +2 IS A DELIBERATE DEVIATION FROM THE DESIGN'S OWN ARITHMETIC, WHICH PREDICTED 44. That
 * estimate counted the portfolio deal insert and treated Decision B2's audit copy as free; it is not, for
 * the reason spelled out at the `stampRoutedOutcomes` call in finish() — the audit does not exist
 * until after the loop and the portfolio deal Id is needed before it, and Apex cannot write two SObject
 * types in one statement. It is recorded here rather than quietly absorbed, and the ONE-LINE way
 * to get back to 44 (drop the audit stamp, i.e. drop B2) is named at that call site.
 *
 * ⚠ AND THE TWO NEW STATEMENTS ARE CONSTANT IN PROPERTY COUNT — that is the property worth
 * protecting. 2 at N=2 and 2 at N=10. A future change that creates or stamps the portfolio deal inside
 * the loop would make it 2N and would show up HERE, as an equality failure at N=10, which is the
 * whole reason that assertion is an equality rather than a ceiling.
 *
 * ═══ 🔴 BUDGET AMENDED 2026-08-30 (WS8) — +1 QUERY PER EMAIL, +0 PER PROPERTY, +0 DML ═══
 * The intake broker match (resolveBrokerLink) resolves the SENDER to an existing broker Contact so
 * every Lead this email mints is born carrying `Broker__c` / `Broker_Firm__c`. The sender is an
 * EMAIL-level fact, so it is read ONCE per job and latched:
 *
 *       N = 1    QUERY (ceiling 30)             +1        still passes; ceiling NOT moved
 *       N = 10   QUERY_BUDGET (ceiling, 120)    +1        🔴 +1, NOT +10 — the latch is the reason
 *       N = 1    singlePropertyDmlBudget (<=20) UNCHANGED  ┐ no DML is added on ANY path;
 *       N = 1    singlePropertyDmlBudget (==7)  UNCHANGED  ┘ the two lookups ride the EXISTING
 *       N = 10   DML_BUDGET (EQUALITY, 45)      UNCHANGED    `insert lead` in EmailToLeadService
 *       call-for-offers CFO_QUERY_BUDGET (60)   UNCHANGED  U2 creates no Lead, so resolveBrokerLink
 *       call-for-offers CFO_DML_BUDGET (8)      UNCHANGED  is never reached — same for reply,
 *                                                          pre-filter, duplicate delivery, hard gate
 *
 * ⚠ NO BUDGET LITERAL IN THE TEST CLASS WAS MOVED BY WS8, and that is a claim worth checking
 * rather than trusting: the two QUERY figures are CEILINGS with tens of queries of slack, so +1
 * is invisible to them. That slack is exactly why the ceilings CANNOT falsify the property that
 * matters — "once per EMAIL, never once per property" — and why
 * `lastRunBrokerLookupCount` exists and is asserted as an EQUALITY of 1 at N = 10. A change that
 * moves this read inside the per-property loop would add nine queries, pass every budget above,
 * and fail that one assertion.
 *
 * ⚠ **THE SINGLE CHAINED-JOB SLOT IS NOW CONSUMED.** SP-2 confirmed this class held zero
 * `System.enqueueJob` calls; `enqueueAttachmentPersist` takes that one slot. A future
 * 11+-property chaining feature (deferred in MAX_PROPERTIES' own comment) must SHARE this job
 * rather than add a second enqueue.
 *
 * ⚠ **THE CHAIN CANNOT BE PROVEN BY AN APEX TEST.** SP-2 measured a queueable-to-queueable chain
 * throwing `System.AsyncException: Maximum stack depth has been reached` inside `@isTest`
 * (catchably), while working cleanly in real execution. So the call is guarded by
 * `Test.isRunningTest()` and the DECISION is asserted through the `lastRunEnqueuedTargets` seam;
 * the firing itself is proven only by UAT U1. Same precedent as EmailThreadAdopterService's
 * `AdoptionWriter`.
 *
 * ═══ LAYER ═══
 * Queueable orchestrator. It contains NO SOQL and NO DML of its own — every read goes through
 * a service (InboundEmailStagingService, PropertyMatchingService, InboundEmailActivityService)
 * and every write through the service that owns that object (EmailToLeadService for the Lead —
 * both its insert and, on the lost-race path, its delete; PropertyClaimService for the
 * registry/submissions, InboundEmailActivityService for the Task, InboundEmailStagingService
 * for the staging row, InboundEmailAttachmentService for the carrier release,
 * CallForOffersStampService for the Opportunity stamp on the U2 branch — the module's ONLY
 * Opportunity writer; and since 2026-08-17 PortfolioDealService for the multi-property portfolio deal,
 * the ONLY writer of Portfolio_Deal__c). The only external call is via
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
 * ⚠ AMENDED 2026-08-30 (WS8) — "performs no SOQL/DML directly" IS STILL TRUE, but this class now
 * calls a SELECTOR directly for the first time (`ContactSelector.selectBrokerByEmailForIntake`,
 * from resolveBrokerLink) rather than reaching every read through a service. Stated plainly so the
 * next reader does not have to rediscover it:
 *   • `.claude/rules/apex-layering-rule.md`'s real requirement — ALL SOQL lives in a Selector — is
 *     satisfied; there is still no inline SOQL anywhere in this file.
 *   • The sharing sentence above is also still true: `ContactSelector` is `with sharing` and
 *     enforces its own, and that method is deliberately NOT in a `without sharing` inner class.
 *   • A one-method service wrapper was considered and rejected: it would add a class whose entire
 *     body is a selector call, and the mode/sharing argument that actually matters already lives
 *     where the query does, in the selector's ApexDoc. If a SECOND direct selector call ever
 *     appears here, revisit that — one is a shortcut, two is a missing layer.
 *
 * ═══ ROUTING RESILIENCE (2026-08-08) — ONE STATEMENT, AND IT IS THE FIRST ONE ═══
 * 🔴 `System.attachFinalizer(new RoutingFailureFinalizer(stagingId))` is the FIRST statement of
 * execute(), ABOVE the getStaging call. Both facts are load-bearing:
 *
 *   • **This job's catch cannot see the failures that matter most.** SP-R1 (2026-08-08,
 *     `usman-dpeg`) measured a heap `LimitException` and a CPU `LimitException` both ESCAPING a
 *     `catch (Exception e)` positioned directly around the failing code — the catch block never
 *     ran, in either case. The ERROR MODEL below is therefore true only of ORDINARY exceptions;
 *     for the uncatchable family, a Finalizer is the only mechanism that can record anything at
 *     all, and SP-3 measured its DML committing durably AFTER the parent's rollback.
 *   • **Above getStaging, because getStaging is outside the try.**
 *     `InboundEmailStagingSelector.selectById` is `WITH USER_MODE`, which THROWS rather than
 *     degrades, so one missing FLS grant kills this job before any recording code would run. One
 *     line lower and that whole failure class stays silent.
 *
 * What follows from that stamp: `Status__c = 'Failed'` (a FOURTH value, never conflated with
 * 'Error' — see `InboundEmailStagingService.STATUS_FAILED`), an incremented
 * `Routing_Attempt_Count__c`, a durable note on `Error__c`, and automatic replay by
 * `RoutingRetrySweepBatch`. Replay is safe ONLY because `UNHANDLED_EXCEPTION` proves the
 * transaction rolled back (SP-5), which is why a caught 'Error' row is never retried.
 *
 * ⚠ COSTS NOTHING HERE. `attachFinalizer` is not a governed statement and the Finalizer runs in
 * its own transaction, so all five pinned budgets are UNCHANGED (see the ATTACHMENT HANDOFF
 * section above for the exact figures and their line numbers).
 *
 * ⚠ AND IT CONSUMES THIS CLASS'S ONE FINALIZER SLOT. The platform permits one finalizer per
 * queueable; a future second concern must extend `RoutingFailureFinalizer` rather than attach
 * another — the same shape as the single chained-job slot noted above.
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
    /**
     * Branch (c) reached because the LLM was unreachable, not because the email had no address.
     * Kept distinct from OUTCOME_NO_PROPERTY on purpose: these are the only Leads worth
     * re-extracting once the outage clears, and an admin needs to be able to list exactly them.
     *
     * 🔴 THE SUBSTRING `'LLM unavailable'` IS LOAD-BEARING — THIS IS THE THIRD `Outcome__c` STRING
     * COUPLING IN THIS CLASS, AND IT GAINED A DEPLOYED CONSUMER ON 2026-08-08. The
     * `LLM_Unavailable` list view filters `Outcome__c contains 'LLM unavailable'`, so changing
     * that fragment — even by re-casing it — silently empties the only surface that lists the
     * Leads a human must hand-claim during an outage. **It breaks with no compile error and no
     * failing test outside this module**, which is exactly how the `Gated_Not_Acquisition` and
     * `Gated_Call_For_Offers` couplings (see OUTCOME_NOT_ACQUISITION and OUTCOME_CALL_FOR_OFFERS
     * below) came to carry the same warning.
     *
     * ⚠ Note the view matches `contains`, NOT the whole label, and deliberately so: this constant
     * carries an EM DASH (—, U+2014), and requiring an admin to reproduce that character exactly
     * in a list-view filter is needless fragility. The prose either side of the em dash may be
     * reworded freely; the fragment `LLM unavailable` may not.
     * Pinned by `ExtractAddressQueueableTest.llmDownOutcome_keepsTheSubstringItsListViewFiltersOn`
     * — an assertion is the only thing that actually fails when someone edits this string.
     */
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

    /**
     * U2's SECOND label, added 2026-08-10 (Tranche 4B, decisions D3 / D8 / D26). The email is
     * still gated — no Lead, no claim, ever — but the property it named matched a live deal
     * through the CLAIM PIPELINE, so that deal was stamped with the offer due date and the
     * listing broker, and the email itself was filed on it.
     *
     * 🔴 THE PREFIX IS LOAD-BEARING FOR THE SAME TWO REASONS OUTCOME_CALL_FOR_OFFERS' IS, AND
     * BOTH DEPLOYED FILTERS ARE SATISFIED DELIBERATELY, NOT BY LUCK:
     *   1. It MUST start with 'Not Routed' — `Gated_Call_For_Offers` filter 1 is
     *      `startsWith 'Not Routed'`. Nothing was ROUTED here in this module's sense: no Lead
     *      was created and no claim was taken, so the prefix is honest as well as required.
     *   2. It MUST contain 'call for offers' — `Gated_Call_For_Offers` filter 2 (added by
     *      Tranche 4A) is `contains 'call for offers'`, and that filter is what keeps a
     *      MULTI-PROPERTY call-for-offers email in the view: `buildMultiSummary` prefixes
     *      `'Multi-Property (N): '`, which does NOT start with 'Not Routed'. Before 4B the U2
     *      gate always produced exactly one outcome so the case could not arise; this branch
     *      produces one outcome PER PROPERTY, so it arises on the first email naming two.
     *   3. It must NOT start with 'Not Acquisition' — that prefix belongs to the separate
     *      deployed `Gated_Not_Acquisition` view, and a call-for-offers blast IS
     *      acquisition-related (DPEG simply does not work them).
     *
     * ⚠ NO DEPLOYED FILTER READS PAST 'call for offers'. The ' — deal updated' suffix exists
     * purely so a human scanning `Gated_Call_For_Offers` can tell the matched population from
     * the unmatched one, so the suffix — em dash included — may be reworded freely. The
     * PREFIX and the PHRASE may not. Pinned by
     * `ExtractAddressQueueableTest.callForOffersMatchedOutcome_keepsBothListViewCouplings`,
     * because a Javadoc warning is not enforcement.
     *
     * ⚠ IT DESCRIBES THE MATCH, NOT THE WRITE. A deal LOCKED by its own approval matches, is
     * filed on, and refuses the stamp — that email carries this label AND `Status__c = 'Error'`
     * with the refusal named in `Error__c`. That is this class's standing partial-success
     * contract (outcomes and errors are both recorded), not a contradiction.
     */
    public static final String OUTCOME_CALL_FOR_OFFERS_MATCHED =
        'Not Routed (call for offers) — deal updated';

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
     * classified there." The new suppression (`isCallForOffersGated`) runs AFTER THE CALLOUT.
     * That much is precisely what this comment asked for.
     *
     * 🔴 CORRECTED 2026-08-12 — DO NOT READ THAT SUPPRESSION AS TWO-FACTOR OR AS OPTIONAL. This
     * paragraph used to describe the gate as running "on the model's own `email_category` +
     * `category_confidence`, behind an admin toggle that ships OFF". NONE OF THAT IS TRUE, and it
     * never was in shipped code. `isCallForOffersGated` is one statement: it tests `email_category`
     * ALONE, UNCONDITIONALLY. There is no confidence threshold, no Custom Metadata and no toggle
     * anywhere in this feature — that machinery was designed and then DELETED before the feature
     * shipped, because the user's rule is categorical. So the suppression is ONE MODEL OPINION,
     * live on every email, with NO DETERMINISTIC BACKSTOP.
     *
     * ⚠ AND `category_confidence` IS NOT THE MISSING SECOND FACTOR — IT IS MEASURED-DEAD FOR THIS
     * FAILURE. On 2026-08-12 an ordinary offering memorandum from ONE named broker was gated here
     * and lost its registry claim to a different broker; the model returned `category_confidence`
     * 1.0 on it, so NO threshold on that field, anywhere in its range, would have prevented it. The
     * value is parsed and stored as tuning data only — see `isCallForOffersGated`'s Javadoc.
     *
     * 🔴 WHY THE CORRECTION MATTERS AT THIS SPOT SPECIFICALLY: this is the paragraph a future
     * engineer reads before reconsidering the DETERMINISTIC transport-layer corroboration factor
     * (recipient count, `Precedence: bulk`, `List-Unsubscribe:`, a platform sender domain) that the
     * design recommended and the user DECLINED at Gate 1 on 2026-08-12. Told the gate was already
     * two-factor and toggleable, they would conclude that residual was closed. It is open. The only
     * levers today are (a) sharpening the classifier wording in `LLMExtractionCalloutService`'s
     * enriched block — where the 2026-08-12 fix added an explicit mass-send PRECEDENCE rule — or
     * (b) raising that deterministic factor as a new change.
     *
     * ⚠ AND (b) WOULD NOT WEAKEN THE PROHIBITION BELOW — the two are not the same thing. Such a
     * factor would be read AFTER the callout, as corroboration REQUIRED BEFORE SUPPRESSING, i.e. it
     * can only ever make suppression harder. Putting the same signal in the PRE-callout filter
     * suppresses on the header alone and makes suppression easier, which is what the paragraphs
     * above forbid. Do not cite one as licence for the other.
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

    /**
     * DEFECT B (2026-08-31) — COMPACTED LOCAL PARTS THAT NAME A MAILBOX RATHER THAN A PERSON.
     *
     * ⚠ THIS IS NOT A SECOND PRE-FILTER AND MUST NOT BECOME ONE. `SENDER_CONTAINS` /
     * `SENDER_EXACT` above decide whether an email is MACHINE-GENERATED and gate it before the
     * callout; the prohibition attached to them (never add a blast signal there) is untouched by
     * this set and does not apply to it. This set is consulted at ONE place only —
     * `isMistypedSenderAddress` — to answer a narrower question: "is this local part an identity
     * token, or a shared mailbox anyone at the firm could be behind?" `info@firm-a.com` and
     * `info@firm-b.com` share a local part and are not the same person.
     *
     * The list mirrors the role mailboxes the extraction prompt's own carve-out names
     * (`listings@`, `deals@`, `info@`, `marketing@`, `notifications@`, `no-reply@`,
     * `do-not-reply@` — see `LLMExtractionCalloutService`), plus the ordinary shared-inbox
     * handles that carve-out does not enumerate. Compaction is applied before lookup, so
     * `no-reply` and `no.reply` both reduce to `noreply`.
     *
     * ✅ GENEROSITY IS THE SAFE DIRECTION HERE, which is why the list is not minimal. A token
     * wrongly included only means the contact block CLEARS — the pre-2026-08-31 behaviour — so
     * the cost of a false entry is the status quo. A token wrongly OMITTED is the direction that
     * can retain the wrong person's phone number. When in doubt, add it.
     */
    private static final Set<String> ROLE_LOCAL_PARTS = new Set<String>{
        'listings', 'listing', 'deals', 'info', 'marketing', 'notifications', 'notification',
        'noreply', 'donotreply', 'sales', 'admin', 'contact', 'office', 'team', 'hello',
        'support', 'leads', 'offers', 'enquiries', 'inquiries', 'mail', 'email', 'broker',
        'brokers', 'brokerage', 'investmentsales', 'capitalmarkets'
    };

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

    /**
     * WS8 (2026-08-30) TEST-ONLY TELEMETRY — how many times this run ISSUED the intake broker
     * lookup. It must read 1 for an email that creates any Lead, and 1 at N = MAX_PROPERTIES, not
     * N.
     *
     * 🔴 IT EXISTS BECAUSE THE OBVIOUS ASSERTION CANNOT FALSIFY THE THING WE CARE ABOUT.
     * `lastRunQueryCount <= QUERY_BUDGET` is a CEILING (120 at N=10) with tens of queries of
     * slack, so moving this lookup inside the per-property loop — the single most likely future
     * regression, and the one the pinned budgets were built to catch — would add nine queries and
     * still pass. Counting the lookup itself turns "once per EMAIL, never once per property" from
     * a comment into an EQUALITY a test can fail.
     *
     * Reset at the top of every execute(), so it measures ONE job. With several jobs in one
     * transaction it holds the LAST job's figure, exactly like its two siblings above.
     */
    @TestVisible private static Integer lastRunBrokerLookupCount = 0;

    /**
     * TEST-ONLY DECISION SEAM for the intake broker lookup's fail-soft (WS8, 2026-08-30). When
     * true, resolveBrokerLink throws instead of querying.
     *
     * WHY A SEAM RATHER THAN A REAL FAILURE, and why the catch is not dead code: under
     * `WITH SYSTEM_MODE` the selector cannot throw for CRUD/FLS, which is most of what would
     * naturally break a read — so there is no naturally reachable failure to lean on, exactly as
     * forceRouteFailure above documents for its own catch. The catch is nonetheless REQUIRED
     * rather than defensive: the broker link is an optional enrichment and this transaction owns
     * the broker's Lead and their registry claim, so the enrichment must never be able to abort
     * it. That is the same contract applyExtractionScore and the routeCallForOffers try/catch
     * already hold, and it is the contract this seam makes testable.
     *
     * NEVER set this outside a test class. Same prohibition as forceClaimRace / forceRouteFailure.
     */
    @TestVisible private static Boolean forceBrokerLookupFailure = false;

    /**
     * TEST-ONLY DECISION SEAM for the file-job chain (design §8.6.2).
     *
     * 🔴 IT EXISTS BECAUSE THE CHAIN IS UNPROVABLE IN APEX, NOT BECAUSE IT IS OPTIONAL. SP-2
     * measured `System.enqueueJob` from inside a running Queueable throwing
     * `System.AsyncException: Maximum stack depth has been reached` in `@isTest` — catchably —
     * while working cleanly in production. So a test asserts THE DECISION ("we resolved these
     * targets and requested the enqueue") and UAT U1 proves the FIRING. A reviewer who "fixes"
     * this into an assertion on a chained job's effects will get a vacuous or failing test.
     *
     * Null when `enqueueAttachmentPersist` decided NOT to enqueue (no carrier, or a gate).
     */
    @TestVisible private static List<Id> lastRunEnqueuedTargets;

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
     * The broker identity shown on the Task this email is logged against — display only, never
     * an arbitration key. See "THE SENDER SHOWN ON THE LOGGED TASK" in the class header for the
     * full reasoning; the two rules that matter when editing this file:
     *
     *   1. THEY ARE SET AT THE STAGING LOAD, BEFORE ANY BRANCH, because finish() is reachable
     *      from FOUR paths and the reply / pre-filter prologue returns BEFORE the callout — so
     *      `extraction` does not exist on every path and cannot be the source of truth here.
     *   2. THE REFINE AFTER U1 IS FILL-IF-PRESENT AND NEVER BLANKS THE ENVELOPE DEFAULT. A
     *      degraded extraction must leave the envelope sender standing, not erase it.
     *
     * Both are HELD AS MEMBERS for the same reason `outcomes` and `routingErrors` are: finish()
     * needs them and cannot be handed a local from a branch it is called out of.
     */
    private String senderName;
    private String senderEmail;

    /**
     * WS1 (2026-08-30) — the value every Lead this email produces gets as `First_Seen_Date__c`:
     * when the email ARRIVED, not when this job happened to run. `Received_DateTime__c` when the
     * RFC `Date:` header was readable, else the staging row's `CreatedDate`.
     *
     * 🔴 THE FALLBACK IS RESOLVED HERE, EXACTLY ONCE, AND THAT IS THE WHOLE REASON THIS IS A
     * MEMBER RATHER THAN A TERNARY AT THE CALL SITE. Two things depend on it:
     *   1. A NULL MUST NEVER REACH THE LEAD. `Lead_Intake_Stamp` stamps `Datetime.now()` whenever
     *      `First_Seen_Date__c` is null — that is the flow's correct behaviour for the portal and
     *      manual channels and is NOT being changed — so a null arriving from here would silently
     *      restore exactly the late, job-clock timestamp this feature exists to remove, with no
     *      error and nothing to notice.
     *   2. EVERY LEAD FROM ONE EMAIL GETS THE SAME VALUE. A multi-property email creates N Leads
     *      in a loop; resolving per-Lead would be identical today but is one refactor away from N
     *      slightly different protection windows for one email.
     *
     * ⚠ IT COSTS NO QUERY. Both fields are already on the row `InboundEmailStagingSelector`
     * loaded — `CreatedDate` was added to that SELECT alongside `Received_DateTime__c` precisely
     * so this fallback needs no second read. The pinned QUERY_BUDGET / DML_BUDGET are unchanged.
     *
     * ⚠ `Received_DateTime__c` is NULL on every staging row written before WS1 deployed — there
     * is no backfill and none is wanted. Those rows resolve to `CreatedDate`, which is what their
     * Leads effectively used already.
     */
    private Datetime firstSeenDateTime;

    /**
     * WS8 (2026-08-30) — THE INTAKE BROKER LINK, RESOLVED ONCE PER EMAIL.
     *
     * `brokerContactId` is the existing broker Contact this email's SENDER already is, and
     * `brokerFirmAccountId` is that Contact's brokerage Account. Both null when the sender matched
     * nothing, which is the ordinary case for a broker writing in for the first time and is a
     * first-class answer, not a gap (MATCH ONLY at intake — no Contact and no Account is ever
     * created here; creation stays at conversion).
     *
     * 🔴 `brokerLinkResolved` IS THE WHOLE GOVERNOR STORY. THE SENDER IS AN EMAIL-LEVEL FACT AND
     * MUST BE READ AS ONE. createLead() runs once per PROPERTY, up to MAX_PROPERTIES (10) times
     * for a single email; resolving inside it without this latch would turn one query into ten
     * against a class whose QUERY_BUDGET is PINNED (30 at N=1, 120 at N=10). The flag — not the
     * null-ness of the two Ids — is what makes the memoisation correct, because "no match" is a
     * legitimate result that must not be re-queried nine more times.
     *
     * ⚠ RESOLVED LAZILY, FROM createLead(), RATHER THAN EAGERLY IN execute(). Deliberate: the
     * reply, pre-filter, duplicate-delivery, hard-gate and call-for-offers branches all create NO
     * Lead, so under lazy resolution they pay NOTHING and their own pinned budgets (notably
     * CFO_QUERY_BUDGET) are untouched. Resolving eagerly would spend a query on every gated email
     * — the highest-volume traffic this pipeline sees — to populate a field nobody will read.
     *
     * ⚠ IT IS SAFE TO RESOLVE LAZILY ONLY BECAUSE THE SENDER IDENTITY IS SETTLED BEFORE ANY
     * createLead() CALL. Both inputs — `extraction.brokerEmail` and `staging.From_Address__c` —
     * are fixed by the time routeProperties runs. If a future branch ever creates a Lead BEFORE
     * the extraction is available, this latch would freeze an envelope-only answer for the whole
     * email; check that before moving any createLead() call earlier.
     */
    private Id brokerContactId;
    private Id brokerFirmAccountId;
    private Boolean brokerLinkResolved = false;

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
    /**
     * The `Portfolio_Deal__c` grouping every record THIS email produces, or null when the email
     * named fewer than two routable properties (Decision E — the overwhelmingly common case).
     *
     * ⚠ HELD AS A MEMBER for the same reason `outcomes` and `senderName` are: it is set by
     * routeProperties, read by createLead inside the loop, and read AGAIN by finish() — which is
     * called out of four different branches and cannot be handed a local. It is set ONCE per
     * execution and never reassigned; a second assignment would mean a second portfolio deal.
     */
    private Id propertyPackageId;

    /** The "Additional properties" block owed to the FIRST Lead created (C-1), or null. */
    private String pendingSpillover;
    /** Which Lead consumed the spillover, so a lost race can hand it back to the next one. */
    private Id spilloverLeadId;

    /**
     * 🔴 U2 / D26 Q2 — THE CALL-FOR-OFFERS BRANCH MUST NEVER ENQUEUE THE FILE JOB, EVEN THOUGH
     * IT NOW PRODUCES ROUTED RECORD IDs. THIS FLAG IS THE ENFORCEMENT, AND IT IS NOT OPTIONAL.
     *
     * `enqueueAttachmentPersist` decides on `targets.isEmpty()`. Before Tranche 4B a gated
     * call-for-offers email produced NO routed record, so its DECISION 3 (the NO-TARGETS
     * release — the numbering is `enqueueAttachmentPersist`'s own, where this flag is now
     * decision 2) fired and the carrier was
     * RELEASED at zero cost — which is exactly what `ARCHITECTURE.md` means by *"a gated email
     * (D2 / U2) releases its carrier instead of enqueueing, so the pipeline's highest-volume
     * junk costs zero publications and leaves zero residual bytes."* The 4B branch stamps a
     * matched Opportunity Id onto its outcome, so `targets` becomes NON-EMPTY, and without
     * this flag the file job would silently switch ON for the module's bulkiest traffic
     * (marketed campaign OM decks) — spending from the org-wide rolling 2,500/24h
     * `ContentPublication` quota that caused the 2026-08-06 total outage.
     *
     * The user's Gate 1 answer was explicit: KEEP ATTACHMENTS SUPPRESSED, and the branch must
     * RELEASE the carrier rather than merely decline to enqueue, so no bytes are stranded
     * Pending forever.
     *
     * ⚠ WHY A FLAG AND NOT "just call releaseCarrier() in the branch". `releaseCarrier` writes
     * the DATABASE; the in-memory `staging.Attachment_Status__c` this instance holds would
     * still read 'Pending', so `enqueueAttachmentPersist`'s own carrier check would pass and it
     * would enqueue anyway. An explicit flag consulted at the decision point is the only shape
     * that cannot be defeated by that stale read.
     *
     * ⚠ IT IS DELIBERATELY NARROW. Do not generalise it into "suppress files for gates" — the
     * D2 hard gate already gets the same outcome for free, through the empty-targets path, and
     * a broader flag would obscure which decision this actually encodes.
     */
    private Boolean suppressFilePersist = false;

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
     * ⚠ THE 4th ARGUMENT (`List<Id> contentDocumentIds`) WAS REMOVED ON 2026-08-06 AND MUST NOT
     * COME BACK. Files are no longer created at the boundary at all — document Ids do not exist
     * until AFTER routing — so the parameter was always null: exactly the vestigial trap this
     * codebase documents against. The bytes now travel as classic `Attachment` carriers on the
     * staging row, and `AttachmentPersistQueueable` converts and links them afterwards.
     *
     * 🔴 AND NOTHING BYTE-SHAPED MAY BE ADDED HERE. SP-1 measured an UNCATCHABLE
     * `System.LimitException: Batchable instance is too big` thrown at `System.enqueueJob`
     * ITSELF at ~4.2-4.5 MB of payload, inside the transaction that owns the email. The
     * <= 1 MB `imageBase64` is the ONE permitted exception and only because SP-1 proved ~4x
     * headroom for that specific bound.
     *
     * @param stagingId     The Inbound_Email_Staging__c row created for this inbound email.
     * @param imageBase64   Base64 of an optional inline image, <= VISION_MAX_BYTES (may be null).
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
        // 🔴 FIRST STATEMENT, ABOVE getStaging — AND THE ORDER IS THE WHOLE POINT (2026-08-08).
        // This job owns the Lead and the registry claim, and until now its death was invisible and
        // permanent: SP-R1 measured heap and CPU LimitExceptions ESCAPING a `catch (Exception e)`
        // wrapped directly around the failing code, so the catch below cannot see them and the row
        // stranded on 'Pending' with Error__c null, with nothing to retry it.
        //
        // Attaching ABOVE the getStaging call is what makes the OTHER uncatchable shape reportable
        // too: getStaging runs outside the try block, and InboundEmailStagingSelector.selectById is
        // WITH USER_MODE, which THROWS rather than degrades — so one missing FLS grant kills this
        // job before any code that could record it would have run. One line lower and that failure
        // stays silent forever.
        //
        // SP-R2 measured attachFinalizer succeeding inside a `Queueable, Database.AllowsCallouts`
        // class shaped exactly like this one, and the Finalizer still firing after a real callout.
        // It costs 0 SOQL and 0 DML — the Finalizer runs in its OWN transaction after this one
        // rolls back — so all five pinned budgets are unchanged. It is also the only finalizer
        // this class attaches; the platform permits one per queueable.
        System.attachFinalizer(new RoutingFailureFinalizer(stagingId));

        // WS8 telemetry — reset per JOB, not per transaction, so the count means "this email".
        lastRunBrokerLookupCount = 0;

        staging = InboundEmailStagingService.getStaging(stagingId);
        if (staging == null) {
            // The row was hard-deleted between the synchronous insert and this async run.
            // There is nothing left to route and nothing left to stamp.
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.execute: staging record ' + stagingId + ' not found.');
            return;
        }

        // SENDER IDENTITY DEFAULT — set here, before ANY branch, on purpose. finish() is reached
        // from four places and routePrologueWithoutCallout() returns BEFORE the callout, so there
        // is no extraction to read on the reply / pre-filter path. Initialising at the single
        // common point and refining after U1 is what makes every branch correct BY CONSTRUCTION
        // rather than by remembering to pass the sender down each one. Costs no query: both
        // fields are already on the row InboundEmailStagingSelector loaded.
        senderName = staging.From_Name__c;
        senderEmail = staging.From_Address__c;

        // WS1 (2026-08-30) — resolve the received-time fallback ONCE, here, for the same reason
        // the sender identity above is set here: every branch that reaches createLead must see the
        // same answer, and a null must never escape into the Lead (see the member's own Javadoc).
        // Costs no query — both fields are on the row selectById already loaded.
        firstSeenDateTime = (staging.Received_DateTime__c != null)
            ? staging.Received_DateTime__c
            : staging.CreatedDate;

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
                // 🔴 THIS RETURN — NOT ANY DEDUPE CHECK — IS WHY A REDELIVERY COSTS ZERO
                // ContentPublications: it never reaches finish(), and the file job is enqueued
                // only from there. The duplicate's own carrier bytes are released so they cannot
                // accumulate on a row that will never be converted. The ORIGINAL email's files
                // are untouched; only this duplicate's copy of the bytes goes.
                releaseCarrier('duplicate delivery');
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
            // FIX 3 (2026-08-31 ACCEPTANCE RUN) — GROUNDING GUARD FOR THE LISTING-BROKER ADDRESS.
            // ⚠ NOT A SEQUEL TO "FIX 1"/"FIX 2 (2026-08-03)" ELSEWHERE IN THIS CLASS — that is an
            // unrelated, earlier extraction-completeness series. This one's siblings live in
            // LLMExtractionCalloutService (FIX 2 = the `deal_type` rule, FIX 3 = the prompt half
            // of this same guard).
            // 🔴 CALL 1 OF 2. CORRECTED 2026-08-31 (SEQUENCING DEFECT A) — THIS CALL ALONE IS
            // NOT SUFFICIENT AND NEVER WAS. It runs BEFORE the demotion so that a fabricated
            // model value is cleared in time for `demoteBodyBroker`'s FILL-IF-BLANK to put the
            // REAL body-named broker's address into the slot instead — that recovery is the only
            // reason this call still exists, and deleting it would silently convert the fix from
            // "recovers information" into "only destroys it".
            //   ⚠ WHAT IT CANNOT DO: it is not the LAST WRITER of the field it protects. The
            //   demotion below writes `listingBrokerEmail` after this returns, so a value it
            //   installs has never been grounded by the time this call has finished. Call 2, sited
            //   immediately after `applySenderFirstBrokerIdentity`, is the one that closes that —
            //   see the method's own header for the measured failure sequence.
            dropUngroundedListingBrokerEmail(extraction);
            // U1 SENDER-FIRST IDENTITY (intake-rules-v2). LAST of the three identity steps and
            // BEFORE both gates, so a gated email is still attributed to the right broker: the
            // identity feeds the Task this email is logged against and, on a claim path, the
            // arbitration key. (It used to say "so the demotion note still reaches the staging
            // audit trail" — that note was removed 2026-08-03; the ordering reason stands on its
            // own and never depended on it.)
            applySenderFirstBrokerIdentity(extraction);
            // 🔴 CALL 2 OF 2 — THE GUARD IS THE LAST WRITER OF THE FIELD IT PROTECTS.
            // ADDED 2026-08-31 for SEQUENCING DEFECT A, measured on two live Leads created AFTER
            // the guard first shipped. `demoteBodyBroker`'s fill-if-blank copies `broker_email`
            // into `listingBrokerEmail`, and `broker_email` carries NO grounding guard of its own
            // (deliberately — it has the envelope backstop instead). So a fabrication the model
            // put in `broker_email` was being written into the very slot call 1 had just skipped
            // as blank. Nothing between the two calls reads `listingBrokerEmail`, so this is a
            // pure re-check: idempotent on a value call 1 already cleared or already passed.
            // 🔴 DO NOT "TIDY" THIS BY MOVING CALL 1 DOWN HERE AND DELETING IT. The two calls do
            // DIFFERENT jobs and the method's header enumerates them; a single call sited here
            // would leave a fabricated model value blocking the fill-if-blank, so the real
            // body-named broker's address would never be demoted in and would be lost outright.
            // ⚠ IT RE-RUNS `buildLlmText`, AND THAT IS ACCEPTED RATHER THAN UNNOTICED. The
            // composition is rebuilt on each call, so this change costs at most ONE extra pass
            // over Subject__c + Raw_Body__c per email (plus a second, conditional one when the
            // demotion also asks `isMistypedSenderAddress`). It is EMAIL-LEVEL, outside the
            // per-property loop, and adds ZERO SOQL and ZERO DML — which is why
            // `budget_singleProperty_...` stays green and, equally, why that test would NOT catch
            // a regression here: it measures queries and DML, not heap or CPU.
            // NOT HOISTED, deliberately. A memo would put a mutable member on a class whose other
            // state is set exactly once in execute(); passing the text down as a parameter would
            // move "what counts as the email" out of `appearsInEmailText` and back to its
            // callers, which is the drift the shared predicate was extracted to prevent. If heap
            // ever becomes the binding constraint on a maximum-length body, hoist it into a local
            // in execute() and pass it down THEN, with the measurement in hand.
            dropUngroundedListingBrokerEmail(extraction);

            // REFINE THE TASK'S SENDER — fill-if-present, NEVER blanking the envelope default.
            // Placed immediately after U1 so the Task shows the SAME identity arbitration used.
            //   • Ordinary auto-forward: U1 has already made these equal to the envelope, so
            //     this is a no-op.
            //   • PASTE-FORWARD (From_Address__c == Forwarded_By__c): U1 STANDS DOWN because the
            //     envelope sender is DPEG's own coordinator, so the body-extracted broker wins
            //     here too. Without this the Task header would name our own forwarder —
            //     reproducing the exact confusion this change exists to remove.
            //   • LLM degraded / no extraction: both values are blank, so the envelope stands.
            // Pure in-memory: no query, no DML, no arbitration input touched.
            if (String.isNotBlank(extraction.brokerName)) {
                senderName = extraction.brokerName;
            }
            if (String.isNotBlank(extraction.brokerEmail)) {
                senderEmail = extraction.brokerEmail;
            }

            if (isHardGated(extraction)) {
                // D2 HARD GATE. No Lead, no claim — but the Task is still logged by finish(),
                // or a redelivery of this same message would re-run the whole pipeline.
                outcomes.add(new RoutingOutcome(OUTCOME_NOT_ACQUISITION, null, null, PRIORITY_NO_PROPERTY));
                finish();
                return;
            }

            if (isCallForOffersGated(extraction)) {
                // U2 CALL-FOR-OFFERS GATE. THE SUPPRESSION IS UNCHANGED (D3): no Lead, no
                // registry claim, no competing submission — ever, on this branch. Since
                // 2026-08-10 it ALSO matches the named properties against the claim pipeline
                // and stamps any live deal it finds (D8 / D26); see routeCallForOffers.
                //
                // 🔴 THE try/catch IS THE MOST IMPORTANT LINE IN THIS BLOCK, AND IT IS NOT
                // DEFENSIVE PROGRAMMING — IT IS THE REDELIVERY CONTRACT. If a stamp failure
                // escaped to execute()'s catch below, finish() would NEVER RUN: the Task would
                // never be logged, the RFC Message-ID would never be recorded, and the platform
                // redelivering this message would re-run the ENTIRE pipeline from the top. The
                // per-property isolation catch in routeProperties is the exact precedent, and
                // routingErrors is the same durable channel (finish() persists it to Error__c
                // and markRouted derives Status__c 'Error' from it).
                //
                // Nothing is caught and discarded: the failure text is recorded, the Task is
                // still logged, and the staging row still gets its outcome summary.
                suppressFilePersist = true;
                try {
                    routeCallForOffers(extraction);
                } catch (Exception e) {
                    String errorText = describeFailure(e);
                    routingErrors.add(errorText);
                    System.debug(LoggingLevel.ERROR,
                        'ExtractAddressQueueable.routeCallForOffers failed for staging '
                        + stagingId + ': ' + errorText);
                }
                if (outcomes.isEmpty()) {
                    // Belt and braces: routeCallForOffers guarantees at least one outcome, but
                    // if it died before adding any, the row must still carry today's label —
                    // never a blank Outcome__c that no list view can find.
                    outcomes.add(new RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null, PRIORITY_NO_PROPERTY));
                }
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

        // 🔴 THE PORTFOLIO DEAL IS CREATED HERE: ONCE, PRE-LOOP, AND OUTSIDE THE PER-PROPERTY
        // try/catch. All three of those are the design (Decision C1), not incidental placement:
        //   • ONCE — so N properties share ONE portfolio deal rather than minting one each.
        //   • PRE-LOOP — so every Lead the loop creates is stamped with the portfolio deal AT INSERT.
        //     Creating it afterwards would mean re-updating N Leads, i.e. one extra DML per
        //     property instead of one for the whole email.
        //   • OUTSIDE THE ISOLATION CATCH — a per-property failure must not be able to create a
        //     SECOND portfolio deal, and it must not orphan the first. The catch below runs per
        //     iteration; anything inside it runs up to N times.
        // It reuses the SAME `submittedOn` the claim path uses (see routeCallForOffers for the
        // identical "one parse, never two independently-derived instants" reasoning) — a second
        // parseSentDatetime call would return a different now() on the fallback path.
        propertyPackageId = createPackageIfMultiProperty(extraction, workList.size(), submittedOn);

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
     * Create the `Portfolio_Deal__c` for a MULTI-property email, or return null.
     *
     * ═══ 🔴 THE GATE IS `workList.size() > 1`, AND THE THREE CANDIDATES ARE NOT INTERCHANGEABLE ═══
     * Decision E. The work-list count is the DE-DUPLICATED, ADDRESSABLE, CAPPED count — i.e. the
     * number of properties this email will actually produce records for. The two counts sitting
     * right beside it in this class are both WRONG for this purpose, and each fails differently:
     *   • `propertyCount` is what the extraction FOUND, pre-de-duplication and pre-truncation. An
     *     email naming one property twice ("1400 Royal Ln" and "1400 Royal Lane") has
     *     propertyCount 2 and produces ONE Lead — so gating on it would create a portfolio deal with a
     *     single member on an ordinary single-property email.
     *   • `candidateCount` is de-duplicated but NOT capped. It is the right value to STORE (it is
     *     what the email named, and it is the truncation denominator), which is why it is passed
     *     to the service — but gating on it is gating on properties that may never be routed.
     * A portfolio deal must group records that EXIST. That is the whole gate.
     *
     * ⚠ SINGLE-PROPERTY EMAILS THEREFORE CREATE ZERO PORTFOLIO DEALS, AND THAT IS PINNED BY A TEST
     * RATHER THAN BY THIS COMMENT. `ExtractAddressQueueableTest`'s single-property DML budgets
     * (the `<= 20` ceilings and, decisively, the `== 7` EQUALITY assertion) go RED the moment this
     * gate is loosened, which is why those numbers were deliberately left untouched by this
     * change. They are the permanent falsifier for Decision E.
     *
     * ═══ FAIL-SOFT, AND THIS IS THE MOST IMPORTANT LINE IN THE METHOD ═══
     * 🔴 THIS TRANSACTION OWNS THE LEAD AND THE REGISTRY CLAIM. `PortfolioDealService
     * .createForEmail` is `allOrNone = true` and THROWS — correctly, because a half-existing
     * portfolio deal is worse than none — so this method catches, degrades to null, and lets routing
     * continue. Without that catch a failure to create a VISIBILITY AID would destroy a broker's
     * first-come-first-served claim, which is recoverable only by manual registry surgery. That is
     * the 2026-08-06 `ContentPublication` lesson stated in the general form: *a write must never
     * sit unguarded inside a transaction whose rollback would lose something irreplaceable.* Here
     * the write cannot be moved to another transaction (the Leads need the Id in THIS one), so the
     * guard is the mechanism instead.
     *
     * ⚠ THE FAILURE IS RECORDED, NOT SWALLOWED. It goes onto `routingErrors`, which finish()
     * persists to `Error__c` and which makes `markRouted` derive `Status__c = 'Error'` — so an
     * email that routed perfectly but could not be grouped lands in the human queue rather than
     * looking clean. That is this class's standing partial-success contract (outcomes AND errors
     * are both recorded), and it is the right side to err on: the remedy is a human linking the
     * records by hand, and they cannot do that if nothing tells them to. ⚠ It deliberately does
     * NOT add a per-property `OUTCOME_ERROR` — the portfolio deal is an email-level concern, and
     * polluting the per-property outcome labels would corrupt the routed audit and the
     * Outcome__c summary that list views filter on.
     *
     * @param extraction   The email-level extraction; supplies the RESOLVED (post-U1) broker
     *                     identity, so the portfolio deal names the same broker the module arbitrated on.
     * @param routableCount The work-list size — the gate AND the proof that records will exist.
     * @param receivedOn   The parsed send time, shared with the claim path.
     * @return The new portfolio deal's Id, or null when the email is single-property or the insert failed.
     */
    private Id createPackageIfMultiProperty(LLMExtractionResult extraction, Integer routableCount,
                                            Datetime receivedOn) {
        if (routableCount == null || routableCount <= 1) {
            return null;   // Decision E. The common case, and it costs nothing.
        }
        try {
            return PortfolioDealService.createForEmail(
                staging.Subject__c,
                candidateCount,          // what the email NAMED (de-duplicated), not what it routed
                extraction.brokerEmail,  // post-U1: the envelope sender, when U1 applied
                extraction.brokerName,
                stagingId,
                receivedOn
            );
        } catch (Exception e) {
            String errorText = describeFailure(e);
            routingErrors.add('portfolio deal: ' + errorText);
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable: could not create the Portfolio_Deal__c for staging '
                + stagingId + '; routing continues WITHOUT grouping. ' + errorText);
            return null;
        }
    }

    /**
     * U2 CALL-FOR-OFFERS ROUTING (Tranche 4B, 2026-08-10 — decisions D3 / D8 / D26).
     *
     * ═══ 🔴 WHAT THIS BRANCH STILL DOES NOT DO, AND MUST NEVER DO ═══
     * NO LEAD. NO `Property_Registry__c` CLAIM. NO `Competing_Broker_Submission__c` ROW. NO
     * `Property_Claim_Lock__c` LOCK. D3 is explicit that the 2026-08-03 suppression is NOT
     * reversed, and the enforcement here is structural rather than conditional: this method
     * calls neither `createLead` nor `PropertyClaimService`, so there is no input that can
     * reach either. `isCallForOffersGated` itself is untouched, and its Javadoc's "no Lead, no
     * claim" contract stays literally true.
     *
     * The registry read is deliberately LOCK-FREE. `findMatchingRegistry` takes no lock, and
     * taking the cluster lock here would enrol a branch that claims nothing into the deadlock
     * ORDERING CONTRACT that exists solely to protect claimants — cost with no benefit. (The
     * work-list is still built in cluster-key order, because it is `buildWorkList`'s output and
     * reusing that function is what makes this branch normalize addresses IDENTICALLY BY
     * CONSTRUCTION to the claim path rather than by convention — the EmailThreadAnchorService
     * lesson. Ordering is a free side effect here, not a requirement.)
     *
     * ═══ WHAT IT ADDS: MATCH, THEN STAMP ═══
     *   1. Build the work-list with the SAME `buildWorkList` the claim path uses. ⚠ It does
     *      NOT set `pendingSpillover` — that field is consumed only by `createLead`, which
     *      never runs here, so setting it would be a vestigial write.
     *   2. Per property, in order: `findMatchingRegistry` -> `resolveLiveRecord`. D8 forbids an
     *      address-based Opportunity query; the claim pipeline is the ONLY match route.
     *   3. Q1 = OPPORTUNITY ONLY. `resolveLiveRecord` returns an Opportunity Id only for a
     *      CONVERTED winner; an UNCONVERTED winner comes back as the Lead Id unchanged and is
     *      treated as a NO-MATCH. ⚠ Registry rows are created the moment a Lead is minted and
     *      conversion happens later, so at any given time most registry winners are unconverted
     *      — this branch is therefore INERT for the majority of matches. That is the user's
     *      decision (D26 Q1), stated with the consequence, not a defect to "fix" here.
     *   4. ONE `CallForOffersStampService.stamp(...)` call for the whole email — 1 SOQL and at
     *      most 1 DML regardless of how many deals matched. ⚠ Since 2026-08-12 the request also
     *      carries `sale_process`, PER PROPERTY like the deadline; the service describe-guards it
     *      against the live restricted picklist. ⚠ And since 2026-08-14 it carries the
     *      call-for-offers RECEIVED DATE — the one value here that is PER EMAIL, resolved once
     *      above the loop from the same `parseSentDatetime` the claim path uses. Neither adds a
     *      query, a statement or a callout: the budget below is unchanged.
     *   5. One `RoutingOutcome` PER PROPERTY: the matched label carrying the deal Id at
     *      `PRIORITY_REPEAT` (which already means "filed onto an existing record, no claim
     *      taken" — exactly this branch, so no fifth PRIORITY_* constant is invented), or
     *      today's label with a null record Id at `PRIORITY_NO_PROPERTY`.
     *
     * ═══ THE NO-MATCH PATH IS BYTE-IDENTICAL TO THE PRE-4B BEHAVIOUR ═══
     * One property that matches nothing yields exactly one outcome, so `buildOutcomeSummary`
     * returns `OUTCOME_CALL_FOR_OFFERS` verbatim, `primaryRecordId()` is null, and
     * `buildRoutedAudit()` still returns null (it needs two outcomes). The five deployed
     * `callForOffers_*` tests pass unmodified, and so does the `Gated_Call_For_Offers` view.
     * ⚠ ONE FIELD IS DELIBERATELY NOT BYTE-IDENTICAL: `Property_Count__c` was always null on
     * this branch and now records what the extraction found, because the truncation signal
     * (` [truncated: X of M]`) is meaningless without it and the watch list view already
     * displays that column. Additive; no test or filter asserted the null.
     *
     * ═══ 🔴 TWO KNOWN, ACCEPTED CONSEQUENCES OF FILING THE EMAIL ON THE DEAL ═══
     * The Task `finish()` logs now attaches to the matched Opportunity via
     * `InboundEmailActivityService.attachTo`, which uses `WhatId` for anything that is not a
     * Lead/Contact — the same path branches (b) and (d) already take onto a converted winner,
     * so this is an exercised shape and not a new one. But that Task carries `Thread_Key__c`
     * and `Inbound_Message_Id__c`, which makes it a THREAD ANCHOR on the deal:
     *   • later replies in that campaign thread will resolve to the Opportunity through
     *     `findRecordByReplyHeaders` (branch (a)),
     *   • the EAC Thread Adopter will begin re-pointing captured replies' `RelatedToId` onto it,
     *     and
     *   • 🔴 THOSE FOLLOW-UPS NO LONGER REACH THE LLM AT ALL — the consequence that is easiest to
     *     miss, because it is a LOSS rather than an addition. Branch (a) returns BEFORE the
     *     callout (`routePrologueWithoutCallout`), so once this branch's Task carries a `WhatId`,
     *     every later message in that thread is filed on the Opportunity with
     *     `Extracted_JSON__c = {"skipped":"reply"}`: no callout, no extraction, NO CLAIM. And a
     *     campaign thread is exactly where a follow-up says *"also available: 123 New St."* — so
     *     a NEW property named in a reply to a call-for-offers blast is never claimed, and a
     *     later broker submitting it wins outright. This is the standing branch-(a) trade-off
     *     already argued above ("THE GATE CAN ONLY EVER SUPPRESS A NEW CONVERSATION, NEVER AN
     *     EXISTING ONE"), applied unchanged — a header identity match must still outrank a
     *     classifier's opinion — so it is ACCEPTED, not a defect. What is new is the TRAFFIC
     *     CLASS it now covers: before 4B a call-for-offers email produced no routed record, so
     *     its Task carried no target and its thread anchored nothing.
     * All three are BEHAVIOUR CHANGES ON LIVE FEATURES and belong in the UAT script.
     * `Task.Subject` remains a non-matching field (nothing in this repo matches pipeline Tasks
     * by Subject), so the attribution prefix is unaffected.
     *
     * ═══ FILES STAY SUPPRESSED (D26 Q2) ═══
     * `suppressFilePersist` is set by the caller BEFORE this runs, so the carrier is RELEASED
     * rather than converted even though `targets` is now non-empty. See that member's Javadoc.
     *
     * @param extraction The parsed extraction; its properties are matched, never claimed.
     */
    private void routeCallForOffers(LLMExtractionResult extraction) {
        propertyCount = (extraction.properties == null) ? 0 : extraction.properties.size();
        List<PropertyExtraction> candidates = buildWorkList(extraction.properties);
        candidateCount = candidates.size();

        if (candidates.isEmpty()) {
            // No addressable property at all — including the LLM-degraded shape. Byte-identical
            // to the pre-4B gate: one outcome, today's label, no record.
            outcomes.add(new RoutingOutcome(OUTCOME_CALL_FOR_OFFERS, null, null, PRIORITY_NO_PROPERTY));
            return;
        }

        // ⚠ THE LISTING BROKER COMES FROM THE EXTRACTION AND FROM NOWHERE ELSE. THERE IS
        // DELIBERATELY NO ENVELOPE-SENDER FALLBACK, AND THE ABSENCE IS THE POINT — an earlier
        // draft of this branch had one (`: senderName` / `: senderEmail`), it read well, and it
        // was wrong. Do not restore it.
        //
        // 🔴 WHY IT WAS WRONG: it is U1's own documented BLAST-PLATFORM RESIDUAL turned into a
        // write. ARCHITECTURE.md (INTAKE RULES V2 rule 1) records that a broker submitting
        // through RCM / Crexi / Buildout arrives with an envelope From of the PLATFORM
        // (`listings@buildout.com`), and a call-for-offers blast is EXACTLY that traffic — so on
        // this branch the envelope is systematically a platform mailbox rather than a person.
        // Combined with `CallForOffersStampService`'s last-email-wins overwrite, the fallback
        // replaced the REAL listing broker on a LIVE DEAL — the one `LeadConvertService` copied
        // off the winning broker's own email at conversion — with a blast platform's mailbox, or
        // with whoever an unrelated marketing blast happened to name.
        //
        // 🔴 THE TWO FIELD GROUPS ARE NOT THE SAME KIND OF FACT, WHICH IS WHY ONE OVERWRITES AND
        // THE OTHER DOES NOT EVEN FALL BACK. An offer deadline is a fact about THE CAMPAIGN, so
        // the newest email is the authority and last-wins is right. The listing broker on a live
        // deal is a fact about THE TRANSACTION, and a third party's blast is not newer
        // information about it. A blank value is how that is expressed: `buildChange` ignores a
        // null/blank incoming value entirely, so the deal keeps the broker it already knows AND
        // the deadline still lands.
        //
        // These two fields remain the RIGHT source when they ARE populated — including under U1,
        // because `demoteBodyBroker` moves a demoted body-named broker INTO
        // listingBrokerName/Email, so they already hold whoever U1 concluded was the listing
        // contact. Display-only either way: neither reaches Property_Key__c, Broker_Email__c or
        // Lead.Email. `senderName` / `senderEmail` are still resolved for the Task this email is
        // logged against; they are simply not a source for a deal field.
        String listingBrokerName = extraction.listingBrokerName;
        String listingBrokerEmail = extraction.listingBrokerEmail;

        // ⚠ RESOLVED ONCE, ABOVE THE LOOP, AND THAT IS THE POINT — an email has exactly ONE
        // arrival time. `offer_due_date` and `sale_process` are per-property because a portfolio
        // blast can quote a different deadline and a different process per asset; there is no
        // such thing as a per-property "when did this arrive".
        //
        // 🔴 IT IS THE SAME DERIVATION `routeProperties` USES FOR ITS `submittedOn`, not a second
        // independently-sourced guess: the same `parseSentDatetime`, on the same
        // `extraction.sentDatetime`. That is what keeps the date a human reads in the "Received"
        // column and the timestamp this module ARBITRATES with (`Competing_Broker_Submission__c
        // .Submitted_DateTime__c`, and the 90-day recency window behind repeat detection)
        // CONSISTENT BY DERIVATION — one function, one input, so neither can be re-sourced without
        // the other moving with it. Deriving this one separately — from the staging row, from
        // `Date.today()` inline, from anything — would break that, which is the
        // EmailThreadAnchorService lesson applied to a timestamp rather than to an identifier.
        //
        // ⚠ AMENDED 2026-08-14. The previous wording said this was "THE IDENTICAL `submittedOn`
        // VALUE" and that the two are "the same instant BY CONSTRUCTION". Both overstate it, and a
        // reader who went looking for the shared value would not find one:
        //   1. This is a SECOND CALL, not a shared variable, and on a blank `sent_datetime`
        //      `parseSentDatetime` returns `Datetime.now()` — so two calls are two instants, and
        //      across midnight two DATES.
        //   2. More decisively, the two never coexist. `routeCallForOffers` and `routeProperties`
        //      are mutually exclusive: `execute` calls this branch and RETURNS, and this branch
        //      writes no submission row at all (D3). There is no pair to compare.
        // The behaviour is unchanged and correct; only the claim was too strong.
        //
        // ⚠ `.date()` RESOLVES IN THE RUNNING USER'S TIME ZONE, deliberately. `parseSentDatetime`
        // parses a GMT wall-clock string, and `.dateGmt()` would report a US evening email as
        // having arrived the following day — an off-by-one on the one number the column is about,
        // on the majority of this org's traffic. The field is a Date, so SOME zone has to be
        // chosen; this is the org's own, and it is the same one every other date in this pipeline
        // is rendered in.
        //
        // ⚠ The now() fallback inside `parseSentDatetime` is inherited on purpose: the prompt is
        // explicit-or-EMPTY on `sent_datetime`, so a blank is expected traffic, and DPEG's own
        // receipt is still a real timestamp OF THIS EMAIL. That is the whole difference from the
        // proxy this field replaces, which was a real timestamp of a DIFFERENT object.
        Date callForOffersReceivedDate = parseSentDatetime(extraction.sentDatetime).date();

        List<PropertyExtraction> workList = new List<PropertyExtraction>();
        Map<String, Id> dealByAddress = new Map<String, Id>();
        List<CallForOffersStampService.StampRequest> requests =
            new List<CallForOffersStampService.StampRequest>();

        for (Integer i = 0; i < candidates.size() && i < MAX_PROPERTIES; i++) {
            PropertyExtraction property = candidates[i];
            workList.add(property);

            Id deal = findLiveDealForProperty(property.normalizedAddress);
            if (deal == null) {
                continue;
            }
            dealByAddress.put(property.normalizedAddress, deal);

            CallForOffersStampService.StampRequest request =
                new CallForOffersStampService.StampRequest();
            request.recordId = deal;
            // PER PROPERTY, not per email: `offer_due_date` is a property-level key, and a
            // portfolio blast can quote different deadlines for different assets.
            request.offerDueDate = property.offerDueDate;
            request.listingBrokerName = listingBrokerName;
            request.listingBrokerEmail = listingBrokerEmail;
            // PER PROPERTY, for the same reason offerDueDate is: a portfolio blast can market
            // different assets through different processes. LAST-WINS like the deadline and
            // UNLIKE the listing broker — see CallForOffersStampService.buildChange for the
            // argument, and note the service DESCRIBE-GUARDS this value against
            // Opportunity.Sale_Process__c before writing it. The value reaching here has already
            // been validated by LLMExtractionParser against Lead.Sale_Process__c, which is a
            // DIFFERENT picklist that merely happens to match today.
            request.saleProcess = property.saleProcess;
            // PER EMAIL — the same value on every request built from this message. See where it
            // is resolved above.
            request.callForOffersReceivedDate = callForOffersReceivedDate;
            requests.add(request);
        }

        // ONE call for the whole email. An empty request list costs zero SOQL and zero DML —
        // the service returns before its own read — so an all-unmatched blast is exactly as
        // cheap as it was before 4B.
        CallForOffersStampService.StampResult stampResult =
            CallForOffersStampService.stamp(requests);
        // 🔴 REFUSALS ARE RECORDED DURABLY, NEVER SWALLOWED. routingErrors is persisted to
        // Error__c by finish(), and markRouted derives Status__c 'Error' from it — so a deal
        // LOCKED by its own approval is visible as an error on the staging row rather than as
        // a stamp that silently did not happen. (The counter-example to avoid is
        // EmailThreadAdopterService.lastRunFailureCodes, which dies with the transaction.)
        routingErrors.addAll(stampResult.refusals);
        // AND SO IS A DEAL THAT COULD NOT BE READ BACK (review finding S4). A refusal needs a
        // SaveResult; a deal the selector never returned produces none, so without this line it
        // would land in no population at all and this email would still report
        // OUTCOME_CALL_FOR_OFFERS_MATCHED — '— deal updated' for a stamp that never happened.
        // Expected to be empty against today's ReadWrite OWD; see StampResult's Javadoc for the
        // two ways it is not.
        routingErrors.addAll(stampResult.missing);

        for (PropertyExtraction property : workList) {
            Id deal = dealByAddress.get(property.normalizedAddress);
            outcomes.add(deal == null
                ? new RoutingOutcome(
                    OUTCOME_CALL_FOR_OFFERS, null, property.normalizedAddress, PRIORITY_NO_PROPERTY)
                : new RoutingOutcome(
                    OUTCOME_CALL_FOR_OFFERS_MATCHED, deal, property.normalizedAddress, PRIORITY_REPEAT));
        }
    }

    /**
     * The LIVE DEAL for one normalized address, via the claim pipeline only (D8), or null.
     *
     * Two reads at most, and both already exist on the competing/repeat branches, so this
     * introduces no new query SHAPE — only new call sites:
     *   1. `findMatchingRegistry` — one exact `Property_Key__c` lookup, plus a fuzzy 90-day
     *      scan ONLY when the exact lookup misses.
     *   2. `resolveLiveRecord` — one read, only when a registry row was found.
     *
     * 🔴 Q1 = OPPORTUNITY ONLY. Anything else — an UNCONVERTED winner Lead, a Contact from a
     * conversion that created no Opportunity, or a null — is a NO-MATCH, and the email is
     * reported exactly as it was before 4B. `Lead.Offer_Due_Date__c` and
     * `Lead.Listing_Broker_*__c` all exist and are deliberately NOT written (D26 Q1).
     *
     * ⚠ ACCEPTED BLIND SPOT (D8, stated rather than hidden): a MANUALLY-created deal has no
     * registry row and therefore cannot be matched at all. Those emails fall through to
     * no-match, where — per D3 and per the client document — nothing is created.
     *
     * ⚠ THE FUZZY SCAN IS THE DOMINANT COST OF THIS BRANCH: a full 90-day registry read, once
     * per UNMATCHED property. Branch (d) already pays it, so it is not a new query, but a
     * 10-property blast pays it ten times. If the pinned budget ever comes under pressure the
     * fix is a TRANSACTION-SCOPED MEMO of `PropertyRegistrySelector.selectRecentWithWinner`,
     * NOT a raised budget — and that memo touches the claim path, so it is a separate design.
     *
     * @param normalized The normalized property address; blank yields null.
     * @return The matched Opportunity Id, or null when there is no live deal to stamp.
     */
    private Id findLiveDealForProperty(String normalized) {
        Property_Registry__c winner = PropertyMatchingService.findMatchingRegistry(normalized);
        if (winner == null || winner.Winning_Lead__c == null) {
            return null;
        }
        Id live = PropertyMatchingService.resolveLiveRecord(winner.Winning_Lead__c);
        return (live != null && live.getSObjectType() == Opportunity.SObjectType) ? live : null;
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
     * ═══ LABEL FIX, 2026-08-12 — AND IT IS THE `OUTCOME_NO_ADDRESS` QUEUE IT PROTECTS ═══
     * The residual above is the whole reason the label matters: OUTCOME_NO_ADDRESS names the
     * population a human must chase an address for BEFORE a later broker claims the property.
     * A live internal email ("Team lunch Friday + Q3 expense reports") landed in it, because the
     * model returned one structurally EMPTY property object and `firstProperty` accepted any
     * non-null element. `firstProperty` now skips an object that states nothing, so this method's
     * unchanged `stampable == null` test resolves such an email to OUTCOME_NO_PROPERTY instead.
     *
     * ⚠ NOTHING ELSE MOVED. The Lead is still created (explicit user decision — branch (c) is
     * also the LLM-outage landing point and suppressing it here would be a second, differently
     * motivated change), the two label constants keep their exact text, and no historical row is
     * back-filled — standing precedent in this class. Neither constant is named by any deployed
     * `Inbound_Email_Staging__c` list-view filter (verified 2026-08-12 across all eight views;
     * `Gated_Not_Acquisition` filters `startsWith 'Not Acquisition'`, `Gated_Call_For_Offers`
     * `startsWith 'Not Routed'` OR `contains 'call for offers'`, and neither matches a
     * `New Lead (...)` label), so the reclassification is invisible to every deployed view.
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
     * The first property in the model's own array order that actually SAYS something, or null
     * when the email carried none. Branch (c) fires only when the work-list is empty, so in
     * branch (c) EVERY property is addressless — there is no mixed case to reason about and no
     * "best" candidate to choose.
     *
     * ═══ 🔴 LABEL FIX, 2026-08-12 — "NON-NULL" WAS THE WRONG TEST ═══
     * MEASURED: an internal email ("Team lunch Friday + Q3 expense reports") came back with ONE
     * property object in which EVERY field was empty. This method returned the first NON-NULL
     * element, an empty object is non-null, so `stampable` was non-null and `routeNoProperty`
     * chose OUTCOME_NO_ADDRESS — "New Lead (property, no address)", which is the population an
     * administrator works in order to CHASE THE MISSING ADDRESS. A team-lunch email in that
     * queue makes the queue itself untrustworthy, which is the actual cost.
     *
     * ⚠ THIS CHANGES THE LABEL, AND ONLY THE LABEL, FOR THAT SHAPE. It does NOT make branch (c)
     * unreachable and does NOT stop the Lead being created — `routeProperties` falls into
     * `routeNoProperty` whenever the WORK-LIST is empty, and `buildWorkList` already drops blank
     * addresses, so an email with zero properties and an email with one empty property have
     * always behaved identically here. Branch (c) creating a Lead is by design (it is also the
     * LLM-outage landing point) and is retained by explicit user decision.
     *
     * ⚠ THE SKIP TEST IS `hasNoExtractedValues()`, NOT "no name and no address" — see that
     * method's Javadoc. A property described only by its FACTS ("128-unit multifamily, 6.2 cap")
     * has neither a name nor an address and is precisely what OUTCOME_NO_ADDRESS exists for; the
     * narrower test keeps its deal block and its label intact.
     *
     * @param properties The parsed properties; null/empty is tolerated.
     * @return The property to stamp, or null when every element is absent or says nothing.
     */
    private static PropertyExtraction firstProperty(List<PropertyExtraction> properties) {
        if (properties == null) {
            return null;
        }
        for (PropertyExtraction property : properties) {
            if (property != null && !property.hasNoExtractedValues()) {
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
        // WS8 (2026-08-30) — ONE lookup for the whole email, latched. See resolveBrokerLink and
        // the `brokerLinkResolved` member's Javadoc: this line runs once per PROPERTY but queries
        // once per EMAIL, which is the only reason the pinned QUERY_BUDGET survives at N=10.
        resolveBrokerLink(extraction);

        EmailToLeadService.LeadRequest request = new EmailToLeadService.LeadRequest();
        request.brokerName = extraction.brokerName;
        request.brokerEmail = extraction.brokerEmail;
        request.propertyAddress = claimableAddress(property);
        request.fromName = staging.From_Name__c;
        request.fromAddress = staging.From_Address__c;
        request.emailSubject = staging.Subject__c;
        request.rawBody = staging.Raw_Body__c;
        request.forwardedByEmail = staging.Forwarded_By__c;
        // WS1 (2026-08-30) — the email's ARRIVAL time, already fallback-resolved at the staging
        // load and therefore guaranteed non-null. It becomes Lead.First_Seen_Date__c, which is
        // what `Lead_Intake_Stamp` leaves alone when it is populated and what `BP_Expiry__c`
        // (+ 90 days) and `Days_in_System__c` are both derived from.
        request.firstSeenDateTime = firstSeenDateTime;

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
        // WS7 (2026-08-30) — the per-field review signal, carried through to the same insert that
        // already writes parseConfidence above.
        //
        // 🔴 ZERO PER-PROPERTY COST, WHICH IS THE ONLY THING THIS CLASS'S BUDGETS CARE ABOUT.
        // Both values were derived ONCE, by LLMExtractionParser, when the email was parsed. These
        // are two reference assignments off a DTO already in memory: no query, no DML, no
        // describe, and no copy — every Lead this email mints shares the one map object rather
        // than allocating its own. QUERY_BUDGET (30 at N=1 / 120 at N=10) and DML_BUDGET
        // (7 and <=20 at N=1 / 45 at N=10) are all UNCHANGED, and ExtractAddressQueueableTest
        // asserts that at N=10 rather than taking this comment's word for it.
        request.fieldConfidence = extraction.fieldConfidence;
        request.lowConfidenceFieldCount = extraction.lowConfidenceFieldCount;
        // Decision C1 — stamped AT INSERT, so no Lead is ever re-updated for the portfolio deal. Null on
        // a single-property email and on every branch that reaches createLead without a work-list
        // (branch (c), including the LLM-down path), where assigning null is a no-op.
        request.propertyPackageId = propertyPackageId;
        // WS8 — two reference assignments off values already in memory. Every Lead this email
        // mints carries the SAME pair, because the sender is one fact about one email.
        request.brokerContactId = brokerContactId;
        request.brokerFirmAccountId = brokerFirmAccountId;

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
     * WS8 (2026-08-30) — resolve THIS EMAIL'S SENDER to an existing broker Contact and their
     * brokerage Account, at most ONCE per job, and never fail the email over it.
     *
     * ═══ WHAT IT DOES, AND — MORE IMPORTANTLY — WHAT IT DOES NOT ═══════════════════════════
     * MATCH ONLY. On a hit, both `brokerContactId` and `brokerFirmAccountId` are set and every
     * Lead this email produces is born carrying them. On a miss, BOTH STAY NULL and the Lead is
     * created exactly as it is today. This method NEVER creates a Contact, NEVER creates an
     * Account, and NEVER derives a firm from the sender's email domain. Those are the user's
     * decision, not an omission: creation stays at conversion, where `LeadConvertMatchService` and
     * the platform's own convert already own it, and a domain-derived firm ("example.invalid" ->
     * "Example") would be a guess printed onto a broker-attribution record.
     *
     * ═══ 🔴 ONE QUERY PER EMAIL. THE NUMERIC IMPACT, STATED ════════════════════════════════
     * Exactly +1 SOQL and +0 DML on any email that creates at least one Lead; +0 and +0 on every
     * branch that creates none (reply, pre-filter, duplicate delivery, hard gate, call for
     * offers), because this is reached only from createLead(). Against the pinned budgets:
     *
     *     N = 1    QUERY (ceiling 30)      +1     — unchanged ceiling, unchanged pass
     *     N = 10   QUERY (ceiling 120)     +1     — NOT +10; the latch is what makes that true
     *     N = 1    DML (equality 7, ceiling 20)   UNCHANGED — this method performs no DML
     *     N = 10   DML (EQUALITY 45)               UNCHANGED — same reason
     *     CFO      QUERY 60 / DML 8                UNCHANGED — U2 creates no Lead, so unreached
     *
     * `lastRunBrokerLookupCount` pins the "+1, not +10" half as an EQUALITY, because the ceilings
     * above have enough slack to absorb nine extra queries silently. See that member's Javadoc.
     *
     * ═══ THE MATCH KEY IS Lead.Email's OWN RULE, NOT `senderEmail` ═════════════════════════
     * `EmailToLeadService.resolveBrokerEmail` is called here rather than reusing this class's
     * `senderEmail` member, and the difference is real rather than stylistic: `senderEmail` takes
     * `extraction.brokerEmail` whenever it is NON-BLANK, while the Lead takes it only when it
     * SANITIZES. On an extraction that returns a display name instead of an address the two
     * diverge — and keying the lookup on a value that is not the one landing in `Lead.Email` would
     * let intake and conversion disagree about who the broker is, since
     * `LeadConvertMatchService` matches `Contact.Email = Lead.Email`. One rule, one place; see
     * that method's own Javadoc for why it was promoted out of an inline expression.
     *
     * ═══ FAIL-SOFT IS MANDATORY HERE, NOT DEFENSIVE ═══════════════════════════════════════
     * The broker link is an OPTIONAL ENRICHMENT. This transaction owns the broker's Lead and,
     * moments later, their registry claim — the irreplaceable things. So a failure to resolve the
     * link costs THE LINK AND NOTHING ELSE: the text is recorded on `routingErrors` (the same
     * durable channel finish() persists to `Error__c`), and routing continues. That is the
     * identical contract `EmailToLeadService.applyExtractionScore` and the `routeCallForOffers`
     * try/catch already hold, for the identical reason.
     *
     * ⚠ THE LATCH IS SET BEFORE THE QUERY, SO A FAILURE IS NOT RETRIED NINE MORE TIMES. A read
     * that threw once for this email will throw for every property of it; re-entering would turn
     * one logged failure into ten and could spend ten queries doing it.
     *
     * ⚠ `catch (Exception e)`, DELIBERATELY WIDE — the same argument applyExtractionScore makes:
     * a narrower catch is a claim about which failures are possible, and this repo has twice been
     * wrong about exactly that (a `TypeException` is not a `DmlException`; a `QueryException` is
     * not either). There is nothing useful to do differently per type. It cannot catch an
     * uncatchable platform LimitException, and nothing here can.
     *
     * @param extraction The email-level extraction; `brokerEmail` is read as the preferred key.
     */
    private void resolveBrokerLink(LLMExtractionResult extraction) {
        if (brokerLinkResolved) {
            return;
        }
        brokerLinkResolved = true;

        String key = EmailToLeadService.resolveBrokerEmail(
            (extraction == null) ? null : extraction.brokerEmail,
            (staging == null) ? null : staging.From_Address__c);
        if (String.isBlank(key)) {
            // No usable sender address at all. Nothing to match on, and nothing to report — an
            // unaddressable sender is already visible on the Lead, whose Email is blank too.
            return;
        }

        try {
            if (forceBrokerLookupFailure) {
                // TEST-ONLY. A QueryException rather than a bespoke type, to match the shape a
                // real denied read would take — the same reasoning forceRouteFailure's
                // DmlException follows.
                throw new QueryException('Simulated intake broker lookup failure.');
            }
            lastRunBrokerLookupCount++;
            List<Contact> matched = ContactSelector.selectBrokerByEmailForIntake(key);
            if (!matched.isEmpty()) {
                brokerContactId = matched[0].Id;
                // Never re-read, never inferred: the firm is this Contact's OWN Account, which the
                // selector guarantees is non-null. That pairing is what LeadConvertMatchService
                // relies on to satisfy the platform's setContactId/setAccountId rule.
                brokerFirmAccountId = matched[0].AccountId;
            }
        } catch (Exception e) {
            String errorText = describeFailure(e);
            routingErrors.add(errorText);
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.resolveBrokerLink failed for staging ' + stagingId
                + '; the Lead is created WITHOUT a broker link and routing continues: ' + errorText);
        }
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
     * Whether a parsed property belongs in the "not routed" footer: it exists, it SAYS
     * something, it is NOT the one already stamped onto the Lead (D13, identity comparison —
     * PropertyExtraction defines no equals(), and two properties in one email can legitimately
     * share every field value), and its address does not normalize to a usable claim key.
     *
     * ⚠ THE `hasNoExtractedValues()` TERM IS PART OF THE SAME 2026-08-12 LABEL FIX AND MUST NOT
     * BE DROPPED AS "REDUNDANT". `firstProperty` now skips an empty property object, so `exclude`
     * is null for exactly the email that carries one — and without this term the footer would
     * print `- (unidentified property) (no usable address)` into `Deal_Notes__c` on the very Lead
     * the fix exists to clean up, turning one junk label into one junk paragraph. An object that
     * states nothing is not a property that failed to route; there is nothing to footnote.
     * (It is also a strict improvement on the addressable path: that line has never carried
     * information for any caller.)
     *
     * @param property The candidate; null is tolerated.
     * @param exclude  The property stamped onto the Lead, or null.
     * @return true when the property should be footnoted.
     */
    private static Boolean isFootnotable(PropertyExtraction property, PropertyExtraction exclude) {
        return property != null
            && !property.hasNoExtractedValues()
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
     *
     * `senderName` / `senderEmail` are passed so the Task says WHO sent the email. They are
     * always populated by the time any of the four callers reaches here — the envelope default
     * is set at the staging load, before every branch — so this method needs no fallback of its
     * own. Blank on both is still handled downstream: buildSubject then emits no prefix at all.
     *
     * ⚠ `orderedTaskTargets()` IS COMPUTED ONCE INTO A LOCAL AND SHARED (2026-08-05). The Tasks
     * and the attachment links must land on THE SAME ORDERED LIST — that was the user's explicit
     * decision, and calling the method twice would invite the two to drift the moment anyone
     * makes it non-deterministic.
     *
     * ⚠ THE FILE-JOB ENQUEUE IS THE LAST STATEMENT, AFTER markRouted, AND IT IS TRY/CAUGHT
     * (2026-08-06). Order matters: the staging row must already be stamped before a chained job
     * can fail, so a chain failure can never cost this email its routing record.
     */
    private void finish() {
        List<Id> targets = orderedTaskTargets();

        InboundEmailActivityService.logInboundEmail(
            targets, staging.Subject__c, staging.Raw_Body__c,
            staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c,
            senderName, senderEmail);

        // routingErrorText() is null on the clean path, which is what keeps Status__c 'Processed'
        // byte-for-byte as before. When the loop DID isolate a per-property failure it is non-null,
        // and markRouted then derives Status__c 'Error' — see routingErrorText for why that
        // status change is correct rather than incidental.
        InboundEmailStagingService.markRouted(stagingId, buildResult(routingErrorText()));

        // 🔴 THE PORTFOLIO DEAL'S ROUTING AUDIT (Decision B2) — AND THE ONE BUDGET COST THIS FEATURE
        // COULD NOT AVOID. FLAGGED, NOT HIDDEN.
        //
        // buildRoutedAudit() is only meaningful AFTER the loop (it is a function of the outcomes),
        // while the portfolio deal Id must exist BEFORE it (Decision C1, so each Lead is stamped at
        // insert). Those two requirements sit on opposite sides of the loop, so no single DML
        // statement can satisfy both, and a multi-property email therefore costs TWO statements
        // on this object — the pre-loop insert and this stamp — not one.
        //
        // ⚠ THREE ALTERNATIVES WERE CONSIDERED AND ARE ALL DEAD, so do not "optimise" this away:
        //   • folding it into markRouted's update — that statement writes
        //     Inbound_Email_Staging__c, and Apex DML cannot operate on two SObject types in one
        //     statement (the reason fflib's Unit of Work issues one statement per type);
        //   • inserting the portfolio deal AFTER the loop with the audit already set — one statement, but
        //     then the Leads do not exist yet to be stamped, so it costs N Lead updates instead;
        //   • dropping the audit — that is Decision B2, the reason the mixed-outcome case is
        //     visible at all: `Routed_Outcomes__c` is the only place on the portfolio deal that records
        //     the properties which went to ANOTHER broker.
        // Deleting this one line is all it takes to trade B2 back for the lower budget; the
        // N=10 DML budget in ExtractAddressQueueableTest names that trade explicitly.
        //
        // ⚠ IT RUNS AFTER markRouted, AND IT IS FAIL-SOFT INSIDE THE SERVICE — same posture, same
        // reasoning, as the enqueue below it: by this point the email's routing record is durable,
        // the portfolio deal exists and every Lead is already linked to it, so the text written here is a
        // CONVENIENCE COPY of data that is already permanent on the staging row's
        // Routed_Record_Ids__c. Nothing this line does may cost the email its routing.
        // Null portfolioDealId (every single-property and gated path) is a no-op: zero DML.
        PortfolioDealService.stampRoutedOutcomes(propertyPackageId, buildRoutedAudit());

        enqueueAttachmentPersist(targets);
    }

    /**
     * Hand this email's carrier BYTES to `AttachmentPersistQueueable` — the transaction that
     * owns nothing else and is therefore the only admissible home for a `ContentVersion` insert.
     * The LAST statement of finish().
     *
     * ═══ 🔴 WHY THIS IS AN ENQUEUE AND NOT THE WORK ITSELF ═══
     * This job owns the Lead and the registry claim. A `ContentPublication Limit exceeded`
     * raised inside it would roll BOTH back — recoverable only by manual registry surgery — and
     * that exception ignores `allOrNone = false` and escapes `catch (Exception e)` (measured,
     * M2/M3). Doing file work here is the same defect that destroyed inbound emails on
     * 2026-08-05, one transaction further down. 🔴 Never inline it.
     *
     * ═══ IDS ONLY. NEVER BYTES. ═══
     * SP-1 measured an UNCATCHABLE `LimitException: Batchable instance is too big` thrown at
     * `System.enqueueJob` itself above ~4.2-4.5 MB of payload. The bytes stay on the staging row.
     *
     * ═══ ⚠ WHY THIS LIVES IN finish() AND NOWHERE ELSE — THE IDEMPOTENCY DEPENDENCY ═══
     * A platform redelivery creates a duplicate staging row, and that is accepted (decision E1).
     * It does NOT create duplicate files on any business record, and the ONLY reason is
     * structural: execute() short-circuits on
     * `InboundEmailActivityService.isAlreadyLogged(...)` and RETURNS WITHOUT CALLING finish().
     * 🔴 ANYONE WHO MOVES THIS ENQUEUE OUT OF finish(), OR MAKES THE SKIP PATH CALL finish(),
     * SILENTLY RE-OPENS DUPLICATE FILES ON LIVE LEADS. There is no dedupe to catch it.
     *
     * ═══ FOUR DECISIONS, EACH COSTING NOTHING WHEN IT DOES NOT APPLY ═══
     *   1. NO CARRIER (`Attachment_Status__c != 'Pending'`) -> return. The overwhelming majority
     *      of emails. Zero DML, zero enqueue, and the predicate is FREE because
     *      `InboundEmailStagingSelector.selectById` already loaded the field.
     *   2. 🔴 CALL-FOR-OFFERS (`suppressFilePersist`) -> RELEASE, unconditionally, EVEN WHEN
     *      TARGETS EXIST. Added 2026-08-10 (Tranche 4B, D26 Q2). Before 4B the U2 gate produced
     *      no routed record, so decision 3 released the carrier and this traffic cost ZERO
     *      `ContentPublication`s — which is the invariant `ARCHITECTURE.md` states as *"a gated
     *      email (D2 / U2) releases its carrier instead of enqueueing, so the pipeline's
     *      highest-volume junk costs zero publications."* 4B makes that branch produce a matched
     *      Opportunity Id, so decision 3 would no longer catch it and the file job would switch
     *      ON for marketed campaign decks — the bulkiest attachments this module sees — against
     *      the org-wide rolling 2,500/24h quota behind the 2026-08-06 total outage. THIS CHECK
     *      MUST STAY ABOVE DECISION 3; below it, it is dead code on exactly the emails that
     *      matter. Pinned by
     *      `ExtractAddressQueueableTest.callForOffers_matchedWithCarrier_releasesTheCarrierAndNeverEnqueues`.
     *   3. NO TARGETS (a D2 gate, or a call-for-offers email that matched nothing) -> RELEASE the
     *      carrier instead. There is nothing to file a file on and there never will be, so this
     *      is the highest-volume junk in the pipeline being made to cost zero publications AND
     *      zero residual bytes.
     *   4. OTHERWISE -> enqueue with Ids only.
     *
     * ═══ ITS OWN try/catch, AND THE `Test.isRunningTest()` GUARD ═══
     * Wrapped because it runs AFTER `markRouted`: a chain failure must never turn a correctly
     * routed email into an async failure. Guarded because SP-2 measured a queueable-to-queueable
     * chain throwing `AsyncException: Maximum stack depth has been reached` inside `@isTest`;
     * the DECISION is recorded on `lastRunEnqueuedTargets` and UAT U1 proves the firing.
     *
     * The class's "NO SOQL and NO DML of its own" invariant is intact: the release is delegated
     * to `InboundEmailAttachmentService`, which owns every `Attachment` write in this module.
     *
     * @param targets The distinct routed records, the SAME ordered collection the Tasks were
     *                logged against. Empty means a gate fired.
     */
    private void enqueueAttachmentPersist(List<Id> targets) {
        lastRunEnqueuedTargets = null;
        try {
            if (staging == null
                    || !InboundEmailStagingService.ATTACHMENT_STATUS_PENDING
                            .equals(staging.Attachment_Status__c)) {
                return;
            }
            if (suppressFilePersist) {
                // 🔴 DECISION 2 — D26 Q2. Deliberately ABOVE the targets check: the whole point
                // is that a call-for-offers email now HAS targets and must still never convert.
                releaseCarrier('gated - call for offers, files not retained');
                return;
            }
            if (targets == null || targets.isEmpty()) {
                releaseCarrier('gated - no routed record');
                return;
            }
            if (Test.isRunningTest()) {
                // SP-2: the real call throws here. Record the decision instead; UAT U1 is the
                // only proof that the chain fires. 🔴 Do not "fix" this into an assertion on a
                // chained job's effects — inside a test there is no chained job to observe.
                lastRunEnqueuedTargets = targets;
                return;
            }
            lastRunEnqueuedTargets = targets;
            System.enqueueJob(new AttachmentPersistQueueable(stagingId, targets));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.enqueueAttachmentPersist: could not chain the file job '
                + 'for staging ' + stagingId + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * Release this email's carrier bytes because no record will ever be filed against them — a
     * gated email or a duplicate delivery. Delegated to `InboundEmailAttachmentService`, which
     * owns every `Attachment` write in this module, so this class keeps its "no DML of its own"
     * invariant.
     *
     * 🔴 TERMINAL AND UNRECOVERABLE. Only call it where routing has provably finished with no
     * record to attach to; after this the file exists only in the original email.
     *
     * @param reason A short human reason recorded alongside the standard §7 note.
     */
    private void releaseCarrier(String reason) {
        try {
            if (staging == null
                    || !InboundEmailStagingService.ATTACHMENT_STATUS_PENDING
                            .equals(staging.Attachment_Status__c)) {
                return;
            }
            InboundEmailAttachmentService.releaseCarrier(stagingId, reason);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ExtractAddressQueueable.releaseCarrier failed for staging ' + stagingId
                + ': ' + e.getTypeName() + ' | ' + e.getMessage());
        }
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
     * FIX 3 (2026-08-31 ACCEPTANCE RUN) — DROP `listing_broker_email` WHEN THE ADDRESS IS NOWHERE
     * IN THE EMAIL.
     *
     * ⚠ THE NUMBER IS NOT A SEQUEL TO THIS CLASS'S OTHER "FIX N" COMMENTS. `FIX 1 (2026-08-03)`
     * and `FIX 2 (2026-08-03)` above belong to an unrelated, earlier extraction-completeness
     * series. This fix's actual siblings are in `LLMExtractionCalloutService` — FIX 2 there is
     * the `deal_type` definition rule and FIX 3 there is the PROMPT HALF of this same guard.
     *
     * ═══ 🔴 THE MEASURED DEFECT: A FABRICATED, CONTACTABLE ADDRESS ═══
     * Lead `00Qiw000000wuY7EAI` carries `Listing_Broker_Email__c = info@nordhavencommercial.com`.
     * The email's actual sender is `listings@crexi-listings.example.com` — a DIFFERENT domain —
     * and the source text contains NO `@` CHARACTER AT ALL. The model invented a plausible
     * address out of the firm name in the signature block. That value is written to an Email
     * field a human reads as "who do I call about this listing", so the failure is the one the
     * `broker_phone` role-mailbox carve-out exists to prevent — somebody contacts the wrong
     * person — displaced one field across, and WORSE, because an address that looks real invites
     * use in a way a bare number does not.
     *
     * ═══ 🔴 CALLED TWICE, ON PURPOSE. SEQUENCING DEFECT A, CORRECTED 2026-08-31 ═══
     * THE ORIGINAL SINGLE CALL SITE WAS WRONG, AND THE LOGIC BELOW WAS NOT. This method was
     * first shipped with ONE call, placed before `applySenderFirstBrokerIdentity`, on the
     * reasoning that it should "only ever judge a value the MODEL returned". That reasoning was
     * sound and INCOMPLETE: it left the guard not being THE LAST WRITER OF THE FIELD IT PROTECTS.
     *
     * THE OBSERVED FAILURE SEQUENCE, read off the raw extraction JSON of Leads created AFTER the
     * guard was live:
     *   1. The model returned `"listing_broker_email": ""` — the prompt half WORKED.
     *   2. Call 1 hit the blank-skip at the top of this method and returned. Correct: there was
     *      nothing to ground.
     *   3. The model instead put its fabrication in `broker_email`, which this guard deliberately
     *      does not touch (see the SCOPED section below).
     *   4. That value differed from the envelope sender, so `applySenderFirstBrokerIdentity` ->
     *      `demoteBodyBroker` fired, and its FILL-IF-BLANK copied the UNGUARDED value straight
     *      into the slot call 1 had just skipped.
     * 🔴 THE BLANK-SKIP IS NOT A BUG AND MUST NOT BE "FIXED". Step 2 is correct behaviour. The
     * defect is entirely one of PLACEMENT: a guard that runs before its field's last writer
     * cannot protect it, however right its predicate is.
     *
     * LIVE EVIDENCE (both Leads created after the fix deployed):
     *   • `00Qiw000000xEVBEA2` — `Listing_Broker_Email__c = info@kestrelmoor.com` on a subject and
     *     body containing NO `@` AT ALL.
     *   • `00Qiw000000x9fCEAQ` — `tomas.berger@beaconridge.com`, where the real firm is
     *     `beaconridgeadvisors.com`. ⚠ A NEAR-MISS IS WORSE THAN AN OBVIOUS FAKE: it looks right,
     *     so somebody sends to it.
     *
     * ═══ 🔴 WHY TWO CALLS AND NOT ONE MOVED CALL — THE DECISION, WITH ITS COST ═══
     * MOVING the single call to sit after the demotion was considered FIRST and REJECTED, because
     * something between the two sites DOES depend on this field's state: `demoteBodyBroker`'s
     * fill-if-blank is gated on `String.isBlank(extraction.listingBrokerEmail)`. Under a single
     * moved call, a fabricated model value would still be sitting in the slot when the demotion
     * ran, the fill-if-blank would decline, and the guard would then null the fabrication — so the
     * REAL body-named broker's address, which the demotion existed to rescue, would never be
     * written anywhere and would be lost outright. One call trades a fabrication for a blank; two
     * calls trade a fabrication for the real address wherever one exists.
     *
     * WHAT EACH CALL EARNS:
     *   • CALL 1 (before the demotion) is the INFORMATION-RECOVERY call. Its only job is to empty
     *     a fabricated slot in time for the fill-if-blank to put a real address there.
     *   • CALL 2 (after the demotion) is the GROUNDING call, and it is the one that makes the
     *     invariant true: whatever finally sits in `listingBrokerEmail` appears in the email.
     * The pair is IDEMPOTENT, which is what makes running it twice free rather than risky: a value
     * call 1 nulled hits the blank-skip in call 2, and a value call 1 passed is unchanged and
     * passes again. No value can be noted twice, because the note is written only on the same
     * statement that nulls the field.
     *
     * ⚠ CALL 2 CAN JUDGE A VALUE APEX COMPUTED — AND THAT IS PROVABLY SAFE HERE, not an accepted
     * risk. The original "never second-guess an Apex-computed value" concern has exactly two
     * candidates, and both are grounded BY CONSTRUCTION: `applyRegexFallback` reads `brokerEmail`
     * out of a `From:` line IN `Raw_Body__c`, so a demotion of that value cannot fail a text
     * search of the same body; and `applyEnvelopeEmailFallback`'s value can never reach the
     * demotion at all, because `applySenderFirstBrokerIdentity` returns early when the sender and
     * `brokerEmail` are equal. So call 2 is a no-op on every Apex-derived value and fires only on
     * something the model produced.
     *
     * ═══ 🔴 THE COMPLETENESS METRIC REWARDED THE FABRICATION. THAT IS HOW THIS HID AT SCALE ═══
     * On `00Qiw000000x9fCEAQ` — the Lead that LOST a real phone and a real title and GAINED an
     * invented address — `Extraction_Score_Pct__c` ROSE from 56 to 78 against the same broker and
     * the same sender. A populated `listing_broker_email` counts as captured in the nine-key
     * denominator, and the denominator cannot ask whether the value is real. So the one number a
     * human would scan to spot a degraded extraction moved in the WRONG DIRECTION, and it is the
     * exact INVERSE of the ~11.1-point drop documented one section down as this guard's expected
     * signal. Read the two together: a drop means the guard fired, a rise on an email like this
     * one means it did not. 🔴 THIS IS NOT AN ARGUMENT FOR CHANGING `SCORED_KEYS` — that nine-key
     * denominator is signed off (2026-08-14) and is deliberately untouched. It is an argument for
     * never treating the score as a fabrication detector.
     *
     * ═══ 🔴 WHY CODE AND NOT ONLY PROMPT — THE PROMPT RULE EXISTS AND IS NOT SUFFICIENT ═══
     * A prompt bullet was added in the same change ("listing_broker_email must be an address
     * WRITTEN IN THE EMAIL … NEVER construct one"). It is kept, and it is not the control. Three
     * reasons this needs a deterministic guard as well:
     *   1. THE MODEL HAS ALREADY BEEN MEASURED DISOBEYING THIS EXACT INSTRUCTION'S SUBJECT
     *      MATTER. Asking the component that just fabricated an address to stop fabricating
     *      addresses may help; it cannot be relied on.
     *   2. A PROMPT RULE IS NOT TESTABLE HERE, AT ALL. `LLMExtractionCalloutService`'s header
     *      says so twice: the model is mocked in every Apex test, so a green suite proves
     *      nothing about any prompt sentence. A text-presence guard is testable with a
     *      fabricated-address fixture, and is tested — see
     *      `ExtractAddressQueueableTest.fabricatedListingBrokerEmail_isDropped...` and its
     *      grounded negative control, which is what stops a guard that drops EVERYTHING from
     *      passing.
     *   3. The live prompt is `Broker_Protection_Config__mdt.Default.Extraction_Prompt__c`,
     *      which an admin can edit in Setup without touching Apex. A prompt-only mitigation can
     *      therefore be removed by someone who has no idea it was load-bearing. This guard
     *      cannot.
     *
     * ═══ LAYER — WHY THIS METHOD IS HERE AND NOT IN THE PARSER OR A SELECTOR ═══
     * `.claude/rules/apex-layering-rule.md` forbids business rules in orchestration, and this is
     * a rule. It nonetheless belongs in this class, for the same reason
     * `applySenderFirstBrokerIdentity`, `applyRegexFallback`, `applyEnvelopeEmailFallback` and
     * `demoteBodyBroker` do: they are the extraction-post-processing stage, they are pure
     * in-memory operations over an already-fetched `LLMExtractionResult` plus the already-fetched
     * `staging` row, and — decisively — THEY ARE ORDER-DEPENDENT ON EACH OTHER. This guard is
     * only correct BEFORE the demotion (see the call site), and only this class knows that
     * ordering. No SOQL, no DML, no callout is added.
     *   ⚠ `LLMExtractionParser` WAS CONSIDERED AND REJECTED ON TWO GROUNDS. It never sees the
     *   source text — it is handed the response JSON alone, so grounding it would mean widening
     *   `parse(...)` to take the email body, which is a signature change rippling through every
     *   caller and test for one field. And it is documented as NEVER THROWING: an unexpected
     *   shape yields an empty-but-valid result. That contract is compatible with this fix (the
     *   guard DROPS the value and raises nothing) but it does not make the parser the right
     *   home — grounding is a question about the EMAIL, and the parser's whole contract is that
     *   it knows nothing about the email.
     *
     * ═══ 🔴 SCOPED TO THE LISTING-BROKER ADDRESS. `broker_email` IS DELIBERATELY NOT GUARDED ═══
     * `broker_email` is HALF THE `Property_Registry__c` CLAIM KEY (with `property_address`), so
     * any rule that can empty it changes WHO WINS a property. It also already has a stronger,
     * deterministic backstop that this one could never be: `applySenderFirstBrokerIdentity`
     * OVERWRITES it with the envelope sender, a value that by construction cannot be
     * hallucinated. `listing_broker_email` has no equivalent — `EmailToLeadService`'s DTO says
     * in terms that it is "NOT a claim-engine value" — which is exactly why it needed one here
     * and exactly why the guard must not spread to its neighbour. Do not "generalise" this to
     * `broker_email` for symmetry.
     *
     * ═══ `listing_broker_name` IS NOT GUARDED, AND THAT IS A MEASURED DECISION ═══
     * On the same defective extraction the NAME behaved correctly: "Yvette Marchetti" was
     * DEMOTED into the listing slot rather than promoted or invented. So there is no observed
     * fabrication on the name path. Guarding it would also be materially riskier than guarding
     * the address: a name is legitimately re-spaced, initialised or de-titled by the model
     * ("Y. Marchetti", "Yvette Marchetti, CCIM"), so a literal-substring test would drop
     * CORRECT values, whereas an email address is an exact token that either appears or does
     * not. Names stay unguarded until something is measured going wrong with one.
     *
     * ═══ WHAT COUNTS AS "IN THE EMAIL" ═══
     * ⚠ THE PREDICATE NOW LIVES IN `appearsInEmailText`, SHARED WITH `demoteBodyBroker`'s
     * same-person test (2026-08-31, DEFECT B). One expression, one answer — the same "one rule,
     * one expression" reason `senderIsOurOwnForwarder` is shared by two callers. If the two ever
     * needed to differ, that would be a decision to argue in both headers, not to fork silently.
     * `buildLlmText(Subject__c, Raw_Body__c)` — the SAME composition the model was given, not
     * the body alone. The subject is prepended before the callout, so an address quoted only in
     * the subject line is genuinely present and must survive. (This is the same correction the
     * exemplar-leak sweep needed for the same reason.) The UNCLIPPED body is used even though
     * `extract(...)` clips to `MAX_INPUT_CHARS`: that errs toward KEEPING a value, which is the
     * safe direction for a guard whose failure mode is data loss.
     *
     * ⚠ FALSE-POSITIVE RESIDUAL, ACCEPTED AND NAMED. An address the model read from an ATTACHED
     * FLYER IMAGE is not in the text and will be dropped. That is deliberate: the alternative —
     * standing the guard down whenever an image is present — would disable it on marketing
     * blasts, which is precisely the traffic that produced the defect. The value is NOT
     * destroyed: it is recorded via `LLMExtractionResult.addNote`, which
     * `EmailToLeadService.buildDealNotes` files on `Deal_Notes__c` under "-- Extraction notes --"
     * with the parser's other rejections, and the raw response survives verbatim on
     * `Inbound_Email_Staging__c.Extracted_JSON__c` regardless. A note here is the parser's
     * documented "every rejection is recorded" contract, NOT a revival of the demotion note that
     * was removed in 2026-08-03 — that one narrated a SUCCESSFUL arbitration as if it were deal
     * information; this one reports a value that was thrown away.
     *   ⚠ A SECOND, NARROWER FALSE POSITIVE: A BODY THAT SPLITS THE ADDRESS. `Raw_Body__c` is the
     *   text as received, so a soft-wrapped line, a quoted-printable `=` continuation, or any other
     *   transfer encoding that breaks `dana.lister@firm.example` across two lines makes the address
     *   absent as a LITERAL SUBSTRING even though a human reads it plainly. It is narrower than the
     *   flyer case: the model was handed the same broken text, so it had to reassemble the address to
     *   emit the joined form — a value that was inferred rather than read. Accepted on the same
     *   grounds (the guard errs toward dropping, the value survives on `Deal_Notes__c` and
     *   `Extracted_JSON__c`), and none has been measured yet. If one ever is, normalize the SOURCE
     *   TEXT — unfold and decode it — and never loosen the comparison to a fuzzy match.
     *
     * ═══ 🔴 WHAT ELSE MOVES WHEN THIS GUARD FIRES — TWO CONSUMERS NOT VISIBLE AT THE CALL SITE ═══
     *   1. THE EXTRACTION-COMPLETENESS SCORE MOVES. INTENDED, AND DELIBERATELY NOT PINNED BY A TEST.
     *      `listing_broker_email` is 1 OF ONLY 9 MEMBERS of `ExtractionScoreUtil.SCORED_KEYS`, and
     *      `EmailToLeadService.applyExtractionScore` scores WHAT THE LEAD WILL CARRY, not what the
     *      model returned. So on every email where this guard fires, `Fields_Captured_Count__c` is
     *      one LOWER, `Fields_Missing_Count__c` one HIGHER, and `Extraction_Score_Pct__c` roughly
     *      11.1 points (1/9) lower than the same email scored before this change. That is the
     *      CORRECT answer — the Lead genuinely captured no listing broker email, and a score that
     *      counted a fabricated address as "captured" was reporting a worse extraction as a better
     *      one — but it is an unstated movement in a NINE-KEY DENOMINATOR SIGNED OFF 2026-08-14, so
     *      it is stated here. 🔴 THE FIX IS NEVER TO REMOVE `listing_broker_email` FROM
     *      `SCORED_KEYS`. That denominator is signed off; a lower score on a fabricating email is
     *      the signal, not the defect.
     *   2. THE CALL-FOR-OFFERS STAMP ON A LIVE DEAL. `buildLeadRequest` copies
     *      `extraction.listingBrokerEmail` onto `request.listingBrokerEmail`, which
     *      `CallForOffersStampService` writes to `Opportunity.Listing_Broker_Email__c` on an ALREADY
     *      MATCHED, ALREADY CONVERTED deal. A dropped value is a no-op there (that stamp is itself
     *      guarded by `String.isNotBlank`), so this guard also NARROWS THE W1-2026-08-10
     *      BLAST-OVERWRITE PATH: a marketing blast can no longer replace a real listing broker's
     *      address on a live transaction with an address the model invented. A genuine second
     *      benefit — and a second consumer, so any future change to this guard's aggressiveness must
     *      be judged against the DEAL record as well as the Lead.
     *
     * ⚠ `Field_Confidence_JSON__c` STILL CARRIES A `listing_broker_email` SCORE FOR A VALUE THE LEAD
     * DOES NOT CARRY. The per-field confidence map is not pruned when a value is dropped. That is the
     * PRE-EXISTING PATTERN here, not an inconsistency this change introduced: `demoteBodyBroker`
     * already clears `brokerPhone` / `brokerMobile` / `brokerTitle` and leaves their map entries
     * standing. The map is an audit record of what the MODEL said, which is precisely what a reader
     * diagnosing a fabrication needs to see, so do not "tidy" it here alone — pruning would have to
     * change the demotion path in the same pass or the two would disagree.
     *
     * @param extraction The extraction to mutate in place. A blank listing address is a no-op.
     */
    private void dropUngroundedListingBrokerEmail(LLMExtractionResult extraction) {
        if (String.isBlank(extraction.listingBrokerEmail)) {
            return;
        }
        if (appearsInEmailText(extraction.listingBrokerEmail)) {
            return;
        }
        extraction.addNote(
            'listing_broker_email "' + extraction.listingBrokerEmail + '" does not appear '
            + 'anywhere in the email text and was discarded as fabricated.');
        extraction.listingBrokerEmail = null;
    }

    /**
     * IS THIS EXACT STRING WRITTEN IN THE EMAIL THE MODEL WAS GIVEN?
     *
     * ⚠ SHARED BY TWO CALLERS ON PURPOSE, and extracted 2026-08-31 when the second one appeared.
     * `dropUngroundedListingBrokerEmail` asks it of the listing address; `isMistypedSenderAddress`
     * asks it of the body-named broker's address. Both are asking the identical question — "did
     * the email ever actually say this, or did the model construct it?" — and one expression is
     * what stops the two drifting into different answers, exactly as `senderIsOurOwnForwarder`
     * does for its own pair of callers.
     *
     * "The email" is `buildLlmText(Subject__c, Raw_Body__c)` — SUBJECT AND BODY, the same
     * composition passed to `extract(...)`, never the body alone. The full rationale, including
     * the two named and accepted false-positive shapes (an address read from an attached flyer
     * image; an address split across lines by transfer encoding), is in
     * `dropUngroundedListingBrokerEmail`'s header and is not repeated here.
     *
     * ZERO SOQL, ZERO DML — `staging` is already loaded and `buildLlmText` is pure string work.
     *
     * @param value The candidate string; blank always returns false (a blank was not "found").
     * @return true when the source text contains the value, case-insensitively.
     */
    private Boolean appearsInEmailText(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        String sourceText = buildLlmText(staging.Subject__c, staging.Raw_Body__c);
        return String.isNotBlank(sourceText) && sourceText.containsIgnoreCase(value);
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
     * ═══ 🔴 DEFECT B (2026-08-31) — THE CONTACT BLOCK IS NO LONGER CLEARED UNCONDITIONALLY ═══
     * THE PARAGRAPH ABOVE IS STILL THE RULE. What changed is that it had ONE unstated premise —
     * that the body-named person is a DIFFERENT person — and the premise is false on a shape this
     * pipeline actually produces.
     *
     * MEASURED ON THE SAME BROKER, THE SAME SENDER, BEFORE AND AFTER, hours apart:
     *   | field                     | 14:10 `00Qiw000000wtx0EAA` | 18:30 `00Qiw000000x9fCEAQ` |
     *   | Email                     | tomas.berger@beaconridgeadvisors.com (both)             |
     *   | Listing_Broker_Email__c   | null ✅                     | tomas.berger@beaconridge.com 🔴 |
     *   | Phone                     | 4695550288                  | null 🔴                    |
     *   | Title                     | Senior Vice President, ...  | null 🔴                    |
     * The email genuinely carried that phone and that title, and they belong to the ENVELOPE
     * SENDER — a registered broker. They were destroyed because the model mistyped ONE WORD of the
     * firm's domain in an unrelated field, which was enough to make `sender != brokerEmail` and
     * fire a demotion of the sender onto themselves.
     *
     * ═══ THE CONDITION, AND WHY IT IS THIS ONE ═══
     * `isMistypedSenderAddress` requires ALL THREE, and the third is the load-bearing one:
     *   1. The COMPACTED local parts are equal, case-insensitively (`t.berger` == `tberger`).
     *   2. That local part is not a ROLE mailbox token (`info`, `listings`, `deals`, ...).
     *   3. 🔴 THE BODY-NAMED ADDRESS APPEARS NOWHERE IN THE EMAIL TEXT — the same
     *      `appearsInEmailText` predicate the listing-address guard uses. This is what separates
     *      the two cases the demotion must tell apart, and it does so on EVIDENCE rather than on
     *      similarity: an email that genuinely names a different broker WRITES THAT BROKER'S
     *      ADDRESS DOWN. An address the email never states was constructed by the model, so it is
     *      not evidence of a second human at all — and when its local part is also the sender's,
     *      the only thing the model was plausibly describing is the sender.
     * Both live records above resolve correctly under it: `00Qiw000000x9fCEAQ` matches on all
     * three (phone and title kept), and `00Qiw000000xEVBEA2` — whose fabricated address is
     * `info@kestrelmoor.com` — is refused at (2), so its contact block still clears.
     *
     * ═══ WHAT WAS REJECTED, AND WHY ═══
     *   • DELETING THE CLEARING. Rejected outright — it is the reason this method exists. A
     *     colleague does not share a direct line or a job title, and attributing one person's
     *     contact details to another is the incident class the demotion prevents.
     *   • NAME COMPARISON (`From_Name__c` vs `brokerName`). Rejected. `From_Name__c` is routinely
     *     blank or decorated ("Tomas Berger via Crexi"), so requiring agreement would disable the
     *     fix on ordinary traffic; and names are legitimately re-spaced, initialised and
     *     suffixed ("T. Berger", "Tomas Berger, CCIM"), so any comparison loose enough to be
     *     useful is loose enough to match two different people with a common name. This is the
     *     same reasoning that keeps `listing_broker_name` unguarded one method up.
     *   • DOMAIN-STEM SIMILARITY (`beaconridge` is a prefix of `beaconridgeadvisors`). Rejected,
     *     though it fits the measured case exactly. It invents a notion of "similar enough" with
     *     no principled boundary, it silently fails on a character-substitution typo
     *     (`beacomridge`) which is just as likely as a dropped word, and condition (3) already
     *     supplies HARDER evidence from the email itself. A weaker signal added on top of a
     *     stronger one only adds a way to be wrong.
     *   • SAME-DOMAIN (`isSameFirmDomain`, already present). Rejected as the wrong test entirely,
     *     and worth stating because it is the nearest existing helper: same-domain is precisely
     *     the COLLEAGUE case (`colleague@jll.com` naming `mark.stern@jll.com`), where the two ARE
     *     different people and clearing the contact block is CORRECT. Reusing it here would have
     *     broken the rule in the exact scenario the rule was written for.
     *
     * ⚠ SCOPE: `brokerCompany` IS DELIBERATELY NOT INCLUDED IN THIS EXCEPTION. It keeps its own,
     * older `sameFirm` condition. The reported data loss was phone and title only, and
     * `brokerCompany` reaches `Lead.Company` -> `LeadConvertMatchService` -> Account matching —
     * a conversion-path behaviour that is not this fix's to move. Under a mistyped-domain demotion
     * the company therefore still clears to the placeholder, which `LeadConvertMatchService` (D1b)
     * excludes from matching: recoverable, and the firm name survives on `Extracted_JSON__c`.
     *
     * ⚠ RESIDUAL, NAMED: two DIFFERENT people sharing a compacted local part, where the model
     * also fabricated the second one's address, keep the wrong phone. Accepted — it requires a
     * fabrication AND a handle collision AND a non-role handle simultaneously — and the failure
     * direction is bounded: the value shown is one the model returned for this email, not one
     * carried in from anywhere else.
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
        // DEFECT B (2026-08-31) — computed HERE for the same reason `sameFirm` is: it reads the
        // BODY-NAMED address, which the next few lines destroy.
        Boolean samePersonMistyped = isMistypedSenderAddress(sender, extraction.brokerEmail);

        // ⚠ CAPTURE BEFORE CLEARING. Everything below destroys the values these two hold, and they
        // are what the listing-contact slot is filled from.
        String oldName = extraction.brokerName;
        String oldEmail = extraction.brokerEmail;

        extraction.brokerEmail = sender;
        extraction.brokerName = String.isNotBlank(staging.From_Name__c) ? staging.From_Name__c : null;
        if (!sameFirm) {
            extraction.brokerCompany = null;
        }
        // DEFECT B (2026-08-31) — THE CLEARING IS NOW CONDITIONAL. It still fires for every
        // genuinely-different body-named broker, which is the case it was written for and the
        // case that must keep working. It stands down ONLY when the demoted identity is the
        // SENDER THEMSELVES under an address the model invented — see isMistypedSenderAddress.
        // ⚠ THIS BRANCH CAN ONLY EVER *KEEP* A VALUE THE MODEL ALREADY RETURNED. It never writes
        // one, so the role-mailbox carve-out in the prompt (which leaves broker_phone /
        // broker_mobile / broker_title EMPTY when broker_email is a platform or role address)
        // survives untouched BY CONSTRUCTION: empty in, empty out.
        if (!samePersonMistyped) {
            extraction.brokerPhone = null;
            extraction.brokerMobile = null;
            extraction.brokerTitle = null;
        }

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
     * The COMPACTED local part of an email address — lower-cased with every separator removed —
     * or null when there is not one.
     *
     * Compaction is deliberate and matches `matchAutomatedSender`'s treatment of the same
     * substring: it makes `t.berger`, `t_berger` and `tberger` one token, which is the point when
     * the question being asked is "is this the same human?". It also normalises `no-reply` and
     * `no.reply` onto the `noreply` entry in `ROLE_LOCAL_PARTS`.
     *
     * Reads the LAST '@', mirroring `emailDomain`, so the two always split the same string at the
     * same index and cannot disagree about which half is which.
     *
     * @param address The address to read; null/blank, no '@', or a leading '@' all return null.
     * @return The lower-cased, separator-stripped local part, or null when it is empty.
     */
    private static String emailLocalPart(String address) {
        if (String.isBlank(address)) {
            return null;
        }
        Integer at = address.lastIndexOf('@');
        if (at <= 0) {
            return null;
        }
        String compacted = address.substring(0, at).trim().toLowerCase().replaceAll('[^a-z0-9]', '');
        return String.isBlank(compacted) ? null : compacted;
    }

    /**
     * DEFECT B (2026-08-31) — IS THE BODY-NAMED BROKER ACTUALLY THE SENDER, UNDER AN ADDRESS THE
     * MODEL INVENTED?
     *
     * Used ONLY to decide whether `demoteBodyBroker` keeps the contact block (phone / mobile /
     * title). It never writes a value and never influences an arbitration key. The full
     * rationale — the two live Leads, the alternatives rejected, the named residual — is in
     * `demoteBodyBroker`'s header; this Javadoc states the contract, not the argument.
     *
     * TRUE requires ALL THREE:
     *   1. Both addresses yield a compacted local part and the two are EQUAL.
     *   2. That local part is not in `ROLE_LOCAL_PARTS` — a shared mailbox is not an identity.
     *   3. `bodyEmail` appears NOWHERE in the email text (`appearsInEmailText`). An email that
     *      genuinely names a second broker writes that broker's address down; an address the
     *      email never states is one the model constructed, so it is not evidence of a second
     *      person. THIS IS THE DISCRIMINATOR — (1) and (2) alone would be a similarity heuristic.
     *
     * ⚠ ASYMMETRY BY DESIGN: every false answer here degrades to the pre-2026-08-31 behaviour
     * (clear the block), so the failure direction of this predicate is recoverable data loss, not
     * mis-attribution. Do not loosen it to "fix" a missed case without re-reading that sentence.
     *
     * ZERO SOQL, ZERO DML.
     *
     * @param sender    The sanitized envelope sender that is becoming the broker identity.
     * @param bodyEmail The address the MODEL returned in `broker_email`, before it is overwritten.
     * @return true only when the demoted identity is the sender under a fabricated address.
     */
    private Boolean isMistypedSenderAddress(String sender, String bodyEmail) {
        String senderLocal = emailLocalPart(sender);
        String bodyLocal = emailLocalPart(bodyEmail);
        if (senderLocal == null || bodyLocal == null || !senderLocal.equals(bodyLocal)) {
            return false;
        }
        if (ROLE_LOCAL_PARTS.contains(senderLocal)) {
            return false;
        }
        return !appearsInEmailText(bodyEmail);
    }

    /**
     * U2 (intake-rules-v2) — A CALL-FOR-OFFERS EMAIL PRODUCES NO LEAD. Unconditionally.
     *
     * One condition, deliberately: `email_category == 'call_for_offers'`. DPEG does not work
     * mass-marketed call-for-offers campaigns, so a Lead for one is never wanted — the rule is a
     * business fact, not a tuning problem, and it is stated here exactly as the user stated it.
     *
     * ⚠ THIS PREDICATE IS UNCHANGED BY TRANCHE 4B (2026-08-10) AND EVERY CLAIM BELOW STILL
     * HOLDS LITERALLY. What changed is only what the CALLER does after this returns true: it
     * now also matches the named properties against the registry and stamps any live deal it
     * finds (`routeCallForOffers`). No Lead, no registry row, no submission row, no lock — see
     * that method's header, and D3 in `agent-output/stage-by-stage-decisions.md`, which is
     * explicit that the 2026-08-03 suppression is NOT reversed. 🔴 Do not weaken, widen or
     * "tidy" this predicate in order to reach the stamp: the stamp is downstream of it, and
     * softening it would re-enable Lead creation for marketed blasts.
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
     * ═══ 🔴 2026-08-12 — THE RISK ABOVE STOPPED BEING HYPOTHETICAL, AND THIS PREDICATE IS
     * STILL ONE MODEL OPINION ═══
     * MEASURED on live traffic: an ORDINARY offering memorandum from ONE named broker — property
     * name, address, square feet, occupancy, guidance price, cap rate, plus the sentence "Offers
     * due 30 September 2026" — was classified `call_for_offers` at `category_confidence` 1.0.
     * This gate suppressed it, and a DIFFERENT broker who sent the SAME property without a
     * deadline line won the registry claim outright. Most brokered OMs state a bid deadline, so
     * the gated population was ORDINARY traffic rather than the tail case this Javadoc assumed.
     *
     * WHAT WAS DONE: the CLASSIFIER was narrowed in `LLMExtractionCalloutService`'s enriched
     * block — `call_for_offers` now requires a mass-distribution shape, a stated offers-due date
     * is explicitly neither sufficient nor evidence, and the measured email appears as the
     * canonical NEGATIVE exemplar. THIS PREDICATE IS UNCHANGED, deliberately: U2's core business
     * rule is untouched, so a genuine marketed blast still produces no Lead and no claim.
     *
     * 🔴 WHAT WAS NOT DONE, BY EXPLICIT USER DECISION AT GATE 1 — AND THE RESIDUAL IT LEAVES.
     * The design recommended making this gate TWO-FACTOR, where the second factor is of a
     * DIFFERENT KIND from the first: a deterministic transport-layer blast signal Apex can check
     * (recipient count, `Precedence: bulk`, `List-Unsubscribe:`, a platform sender domain), so a
     * named broker emailing DPEG directly could never be suppressed however the model read the
     * prose. The user chose the prompt-only fix. CONSEQUENCE: suppression here still rests
     * ENTIRELY on model judgement with NO DETERMINISTIC BACKSTOP, so the same failure class can
     * recur with different wording, and when it does the loss is again a permanently unclaimed
     * property recoverable only by manual registry surgery. That is a known accepted residual,
     * not an oversight — do not record it as fixed.
     *
     * ⚠ AND `category_confidence` IS NOT THE LEVER FOR IT. It was 1.0 on the measured email, so
     * NO threshold on that field anywhere in its range would have prevented this. The paragraph
     * below still holds for the tuning purpose it describes, but the reservation it makes ("if a
     * threshold is ever reintroduced, gate on THIS field") is MEASURED-DEAD for this specific
     * failure. The two live levers are: sharpen the classifier wording again, or revisit the
     * deterministic second factor.
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
