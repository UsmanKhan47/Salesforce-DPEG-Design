/**
 * RecordStageAdvanceService — ONE generic stage-advance service for the EIGHT acquisitions /
 * disposition / transaction objects whose stage is driven by a button rather than by the
 * Path:
 *
 * ⚠ THE WORD "CHILD" LEFT THIS SENTENCE ON 2026-08-19 AND ITS DEPARTURE IS THE HEADLINE. Every
 * object here was a child of a deal or a sale until `Disposition__c` joined; that one is a
 * TOP-LEVEL record with its own Path, its own approval processes and its own record page. What
 * follows from that is not cosmetic — see the `Disposition__c` block below: it is the first object
 * in this config whose stage is ALSO written by machinery outside this class, so for the first time
 * the maps here are a STRICT SUBSET of the object's real transitions rather than the whole path.
 *
 *   NDA__c                              (Status__c)  PER RECORD TYPE — see below
 *   LOI__c                              (Stage__c)   PER RECORD TYPE — see below
 *   Contract_Review__c        (Negotiation_Status__c) PER RECORD TYPE — see below. ⚠ This line
 *                                                    used to read "the two types share ONE SEQUENCE
 *                                                    and differ ONLY in the GATE". FALSE since
 *                                                    2026-08-14 (observation 7): they now differ in
 *                                                    BOTH, and the shared map object is gone
 *   Underwriting__c                     (Stage__c)   Requested -> In Progress -> [approval] -> Approved -> Completed
 *   Construction_Feasibility_Review__c  (Stage__c)   Requested -> Site Visit -> Condition Assessment
 *                                                    -> Cost Estimate -> Share Opinion -> Completed
 *   Development_Feasibility_Review__c   (Stage__c)   Requested -> Feasibility analysis
 *                                                    -> Vendor proposals -> Share Opinion -> Completed
 *   Transaction__c                      (Stage__c)   Open Contract -> Due Diligence -> Closing Prep
 *                                                    -> Post-Closing -> Closed
 *                                                    ADDED 2026-08-12. The FIRST object here from
 *                                                    the TRANSACTIONS module rather than
 *                                                    acquisitions/disposition. ⚠ This line used to
 *                                                    add "and the first whose gate is
 *                                                    MEMBERSHIP-ONLY"; that was true for part of one
 *                                                    day. All three gates are now a single custom
 *                                                    permission — see StageActionGate.
 *   Disposition__c            (Disposition_Stage__c) PER RECORD TYPE — MANUAL HOPS ONLY. See below.
 *                                                    ADDED 2026-08-19 with the disposition flow
 *                                                    redesign (design D-2). 🔴 THE FIRST OBJECT
 *                                                    HERE WHOSE MAPS ARE INCOMPLETE ON PURPOSE.
 *
 * It exists so the Path's "Mark Status as Complete" button can be removed from these record pages
 * and every stage change routed through Apex, where the transition is derived (never supplied),
 * the permission is asserted server-side, and any future validation rule's message is surfaced to
 * the user instead of being swallowed.
 *
 * ── 🔴 THE MAPS ARE PER RECORD TYPE, NOT PER OBJECT (Tranche 3A, 2026-08-09) ──
 * FOUR of the eight objects carry record types, and ALL FOUR have DIFFERENT
 * stage sequences per type (D7 / D14.1 / D6, plus observation 7 and the 2026-08-19 redesign):
 *
 *   NDA__c
 *   Acquisition_NDA   Pending  -> Received -> Signed              explicit targets: none
 *                     gate: DEAL_DRIVER
 *                     ⚠ REORDERED 2026-08-16 (user decision). 'Sent' moved from the SECOND
 *                     position to the TERMINAL one and changed meaning with it: it is now "the
 *                     signed copy has been returned to the broker", not "we issued it". D14.1's
 *                     placement of 'Sent' is REVERSED — see NDA_ACQUISITION_NEXT_STAGE for the
 *                     retracted argument, the unmigrated-row residual, and why this needed NO
 *                     change to NDA_Signed_Status_Sync (the deal gate's checkbox LATCHES true).
 *                     🔴 NARROWED 2026-08-27 (user decision), AND THE PARAGRAPH ABOVE IS NOW
 *                     HISTORY. This line read "Pending -> Received -> Signed -> Sent" until that
 *                     day, when the user removed 'Sent' from the Acquisition_NDA record type in
 *                     Setup. 'Signed' is the acquisition TERMINAL again and 'Sent' is unreachable
 *                     on this record type — see NDA_ACQUISITION_NEXT_STAGE for the measurement,
 *                     the DML-refusal defect it fixed, and why no legacy hop was retained. Do not
 *                     restore either the 2026-08-16 order or D14.1's from the paragraphs above.
 *   Disposition_NDA   Prepare -> Approved -> Sent -> Signed
 *                                                                   explicit targets: {Declined}
 *                     gate: DISPOSITION_DRIVER
 *                     ⚠ EXTENDED 2026-08-25. Read "Not Sent -> Sent -> Signed" until that day,
 *                     when the user removed 'Not Sent' from the record type in Setup and the NDA
 *                     seed moved to 'Prepare'. The 'Not Sent' => 'Sent' hop is KEPT for pre-existing
 *                     rows but is unreachable for new ones — see NDA_DISPOSITION_NEXT_STAGE.
 *                     ⚠ NARROWED 2026-08-25, LATER THE SAME DAY. This line read
 *                     "Prepare -> Review -> Approved -> Sent -> Signed" for a few hours. The user
 *                     then removed 'Review' from the record type in Setup as well, so 'Prepare'
 *                     now hops STRAIGHT to 'Approved' and nothing targets 'Review' anywhere. Two
 *                     values left this sequence on one day; do not restore either from the
 *                     paragraphs above.
 *
 *   LOI__c            (Tranche 3B, 2026-08-09 — this was the config addition the note at
 *                      CONFIG_BY_TYPE predicted, and it changed nothing below the config)
 *   Acquisition_LOI   Draft -> Under Review -> Submitted -> Negotiation -> Signed
 *                     explicit targets: {Negotiation, Signed}      gate: DEAL_DRIVER
 *                     ⚠ RENAMED THROUGHOUT 2026-08-14 (observation 5) from
 *                       Draft -> Prepare/Review -> Sent -> Counter -> Completed. Same SHAPE, new
 *                       labels; 'Draft' is the only surviving literal.
 *   Disposition_LOI   Received -> Under Review -> Negotiation -> Signed
 *                     explicit targets: NONE                      gate: DISPOSITION_DRIVER
 *                     ⚠ RETRACTED 2026-08-21 (user request, design agent-output/
 *                       disposition-loi-stages.md). This block used to read:
 *                         "Disposition_LOI   Received -> Under Review -> Countered by DPEG
 *                            -> Counter Received from Buyer -> Executed
 *                          explicit targets: {Countered by DPEG,
 *                            Counter Received from Buyer} — the negotiation LOOP, added at the
 *                            Tranche 3B close-out (2026-08-09)"
 *                       The user replaced the sell-side sequence with four stages. The
 *                       negotiation LOOP IS RETIRED: counter rounds are now recorded by editing
 *                       Counter History on the LOI (Counter_Offer__c / c/loiCounterOffer), which
 *                       is unchanged by this wave. The two named quick actions and their two LWC
 *                       bundles are deleted, so the two explicit targets have no sender left.
 *                     🔴 THE SELL-SIDE SEQUENCE NOW SHARES **TWO** VALUES WITH THE ACQUISITION
 *                       ONE — 'Negotiation' and 'Signed', on top of 'Under Review'. Only the
 *                       first three of the acquisition sequence are now acquisition-only. See the
 *                       explicit-target hazard note further down this header.
 *
 *   Contract_Review__c (Tranche 3C, 2026-08-09 for the GATE; observation 7, 2026-08-14 for the
 *                      SEQUENCE)
 *   Acquisition_PSA   Draft -> Negotiation -> Signed -> Executed
 *                     explicit targets: none                       gate: DEAL_DRIVER
 *   Disposition_PSA   Initial Draft -> Revised -> Ready for Execution -> Executed
 *                     explicit targets: none                       gate: DISPOSITION_DRIVER
 *
 *   Disposition__c    (2026-08-19 flow redesign, design D-2)
 *   On_Market         Broker Selection -> NDA, NDA -> Release Materials,
 *                       Release Materials -> Active Listing, LOI -> PSA
 *                     explicit targets: none                       gate: DISPOSITION_DRIVER
 *   Off_Market        NDA -> Release Materials, LOI -> PSA
 *                     explicit targets: none                       gate: DISPOSITION_DRIVER
 *
 * ── 🔴 Disposition__c IS THE FIRST OBJECT HERE WHOSE MAPS ARE A *SUBSET* OF ITS PATH ──
 * Every other sequence above is the object's WHOLE path minus its terminal stage. The two
 * disposition maps are deliberately NOT: the full on-market path is eleven stages and the map holds
 * FOUR hops. THE MISSING HOPS ARE NOT MISSING — THEY BELONG TO SOMEONE ELSE, and listing them here
 * would let the Advance Stage button skip an approval:
 *
 *   Disposition Readiness -> BOV Outreach / Broker Selection   `Sale_Decision_Approval`, via the
 *                                                             D-1 semaphore + Queueable
 *   BOV Outreach -> Broker Selection (on-market)               `Broker_Finalize_Approval` on the
 *                                                             BOV_Submission__c child
 *   Broker Selection -> NDA (OFF-market only)                  `Broker_Selection_Approval`
 *   Active Listing / Release Materials -> Offer Selection      `DispositionApprovalService
 *                                                             .selectOffer` (explicit service DML)
 *   Offer Selection -> LOI                                     `Offer_Selection_Approval` on the
 *                                                             Disposition_Offer__c child
 *   PSA -> Closing                                             `ContractExecutionService`, on PSA
 *                                                             execution
 *   Closing -> Sale Closes                                     `Closing_Approval`, via the
 *                                                             semaphore + Queueable
 *
 * ⇒ SO A REFUSAL FROM THIS SERVICE IS THE NORMAL CASE ON THIS OBJECT, NOT AN EDGE CASE, and the
 * `NO_NEXT_STEP_HINTS` entries naming each real owner are load-bearing here in a way they are on no
 * other object: without them the button would refuse at SEVEN of the eleven stages with wording
 * ("there is no next step available") that reads exactly like a bug.
 *
 * 🔴 `Broker Selection` IS THE SHARPEST ENTRY IN THE TWO MAPS AND MUST NOT BE HARMONISED. It is a
 * MANUAL hop on `On_Market` and an APPROVAL-OWNED one on `Off_Market` — the same key producing a
 * hop on one record type and a refusal on the other, which is precisely the property the class
 * argues an object-keyed map cannot express (see the NDA 'Sent'/'Signed' divergence above). Adding
 * `Broker Selection -> NDA` to the off-market map would hand a user a one-click bypass of
 * `Broker_Selection_Approval`.
 *
 * ── 🔴 Contract_Review__c IS SPLIT ON BOTH AXES — AND IT WAS SPLIT ON ONE AXIS FIRST ──
 * ⚠ THIS BLOCK USED TO BE TITLED "WHY Contract_Review__c IS SPLIT AT ALL WHEN ITS VALUES ARE
 * IDENTICAL" AND ARGUED THAT THE TWO TYPES SHARE ONE MAP OBJECT BY REFERENCE, BECAUSE "COPYING IT
 * WOULD INVITE THE TWO TO DRIFT APART WHILE THE REQUIREMENT IS THAT THEY CANNOT". That argument was
 * correct on 2026-08-09 and is OBSOLETE, not overturned — its premise (identical value sets) was
 * ended by observation 7. It is recorded here because the git history reads oddly without it and
 * because a future reader must not "restore" the shared reference as a tidy-up.
 *
 * The two axes, and why each is split, in the order they were split:
 *   - THE GATE (3C, 2026-08-09). A disposition persona holds `Disposition_Deal_Actions` and NOT
 *     `Acquisition_Deal_Actions`, and the two tokens are disjoint (measured across every permission
 *     set in the repo: exactly one set carries each module's token). Left at a single
 *     DEAL_DRIVER config, `hasStageActionAccess` and `assertStageActionAccess` would REFUSE every
 *     disposition PSA for the only persona meant to work it — the sell-side PSA would be
 *     unadvanceable from its own record page.
 *     ⚠ AMENDED 2026-08-12: this used to say the disjointness was in FLS on
 *     `User.Disposition_Driver__c` vs `User.Deal_Driver__c`. Those flags are retired — the token is
 *     now the `Disposition_Deal_Actions` vs `Acquisition_Deal_Actions` CUSTOM PERMISSION. The
 *     disjointness, and therefore this whole argument, is unchanged; only what the sets carry is.
 *     ⚠ AMENDED AGAIN 2026-08-19, AND AGAIN THE ARGUMENT IS UNCHANGED: the user retired the
 *     dedicated `Disposition_Deal_Driver` set and moved its token onto the `DPEG_Disposition_Edit`
 *     persona set. Still exactly ONE set per module token, still disjoint, so the split stands. The
 *     amendment is recorded because this paragraph named the SETS twice and had to stop naming a
 *     deleted one — and because the disposition token's AUDIENCE widened sharply in the move (see
 *     DispositionActionPermissionService's header). Widening one side of a boundary is not merging
 *     the two sides; do NOT read this as licence to collapse the two configs.
 *   - THE SEQUENCE (observation 7, 2026-08-14). The acquisition PSA moves to
 *     `Draft -> Negotiation -> Signed -> Executed`; the disposition PSA keeps its four values
 *     verbatim, and O3 of the requirements doc makes that a HARD STOP — those three values stay
 *     ACTIVE on the field precisely because Disposition_PSA still runs on them. A shared map would
 *     have to hold BOTH sides' values, so `advance()` itself would then aim an acquisition-only
 *     status at a sale. Two maps is the only shape in which that is unexpressible.
 *     ⚠ RETRACTED 2026-08-21 — MECHANISM ONLY. This bullet used to say "and Apex DML does not
 *     enforce record-type picklist restriction, so `advance()` itself would then WRITE an
 *     acquisition-only status onto a sale." False for a `restricted` value set — see the measured
 *     block at the END OF THIS HEADER, and CONFIG_BY_TYPE's Contract_Review__c entry for the
 *     re-derived (and stronger) reason the two maps still may not be collapsed.
 * ⇒ THE 3C LESSON STILL STANDS AND IS NOW JOINED BY ITS CONVERSE. Sharing a sequence is not
 *   sharing a gate (3C: someone who checks only the picklists ships a dead feature). And sharing
 *   an OBJECT is not sharing a sequence (observation 7: someone who edits one map and assumes the
 *   other followed ships a cross-module write). The two axes are independent in BOTH directions.
 *
 * ⚠ AND THE SPLIT COSTS ONE QUERY, WHICH IS NOT FREE AND IS WORTH KNOWING. `gateFor()`
 * short-circuits only for an object with ONE configured sequence, so Contract_Review__c now LOADS
 * the row inside `hasStageActionAccess` — a `cacheable=true` path invoked once per record view.
 * That is the same price NDA__c has paid since 3A and LOI__c since 3B, and it is accepted for the
 * same reason: the gate is a property of the record type and the record type is a property of the
 * row. Pinned by gateResolutionLoadsTheRecordOnlyForAMultiRecordTypeObject.
 *
 * ── 🔴 THE GATE IS PER RECORD TYPE TOO, SINCE 2026-08-09 ─────────────────────
 * It used to live on StageConfig (per object) because all six objects then configured answered to
 * one persona.
 * That stopped being true the moment `NDA__c` served both modules: an acquisitions deal driver
 * must not be able to drive a SALE's NDA, nor a sale driver an acquisition's, merely because the
 * two share a table. The gate therefore moved onto StageTypeConfig alongside `nextStage` and
 * `explicitTargets` — all three are the per-record-type configuration, and keeping them in one
 * object is what stops a future change extending one and forgetting the others.
 *
 * The visible consequence is in hasStageActionAccess(), which now LOADS the row for a
 * multi-record-type object (see its own header for the two small behavioural changes that
 * follow). Objects with a single sequence short-circuit and still pay nothing.
 *
 * ⚠ ON NDA__c, 'Sent' and 'Signed' are SHARED by both value sets, so the CURRENT STAGE ALONE DOES
 * NOT IDENTIFY THE PATH. 🔴 SINCE 2026-08-16 THAT IS TRUE MORE STRONGLY THAN BEFORE, NOT LESS.
 * The example this block used to give is now WRONG and is corrected here rather than deleted, so
 * nobody re-derives the old map from it. RETRACTED, verbatim: "From 'Sent' an acquisition NDA
 * advances to 'Received' and a disposition NDA advances to 'Signed'."
 *
 * What is true now, on BOTH shared values, in OPPOSITE directions:
 *   'Sent'    acquisition: advances NOWHERE — it is the TERMINAL of that sequence.
 *             disposition: advances to 'Signed'.
 *   'Signed'  acquisition: advances to 'Sent'.
 *             disposition: advances NOWHERE — it is the TERMINAL of that sequence.
 *
 * So one of the two record types reaches "no next step available" from each shared value while the
 * other keeps walking — the same key must produce a hop on one type and a refusal on the other.
 * That single fact is why an object-keyed map cannot express this feature and why the record type
 * has to be read off the record. The conclusion is unchanged; only the illustration moved.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SUPERSEDED 2026-08-27 — THE TWO-LINE TABLE AND THE PARAGRAPH ABOVE ARE BOTH OBSOLETE ON
 * NDA__c. THEY ARE RETAINED VERBATIM BECAUSE THIS IS THE THIRD TIME THIS EXACT BLOCK HAS BEEN
 * REWRITTEN AND THE HISTORY IS THE POINT — BUT DO NOT RE-DERIVE ANY MAP FROM THEM.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The user removed 'Sent' from the Acquisition_NDA record type in Setup (measured live that day
 * via the UI API picklist-values endpoint — Acquisition_NDA is exactly Pending | Received |
 * Signed; Disposition_NDA is unchanged at Prepare | Approved | Sent | Signed | Declined). So:
 *
 *   'Sent'    NOT ON the acquisition value set at all. DML refuses it there on insert AND on
 *             update, so no acquisition NDA can reach the value to be refused BY THIS SERVICE.
 *             disposition: still advances to 'Signed'. UNCHANGED.
 *   'Signed'  acquisition: advances NOWHERE — it is the TERMINAL again, as it was before
 *             2026-08-16.
 *             disposition: advances NOWHERE — TERMINAL, as it always was.
 *
 * 🔴 ⇒ THE TWO NDA VALUE SETS NOW SHARE EXACTLY ONE VALUE ('Signed'), AND NEITHER MAP HAS AN ENTRY
 * FOR IT. THE "SAME KEY, HOP ON ONE TYPE, REFUSAL ON THE OTHER" PROPERTY — WHICH THIS BLOCK HAS
 * PRESENTED SINCE 3A AS *THE* ARGUMENT THAT AN OBJECT-KEYED MAP CANNOT EXPRESS NDA__c — IS GONE.
 * Stated plainly, because someone will work it out and propose the merge as a tidy-up: a single
 * merged NDA map {Pending=>Received, Received=>Signed, Prepare=>Approved, Approved=>Sent,
 * Not Sent=>Sent, Sent=>Signed} would today produce the CORRECT hop or the CORRECT refusal for
 * every stage on both NDA record types. That is a real fact and pretending otherwise would be
 * worse than recording it.
 *
 * 🔴 THE SPLIT MUST NOT BE MERGED ANYWAY, AND THE TWO REASONS THAT SURVIVE ARE THE TWO THAT WERE
 * ALWAYS THE SECURITY-RELEVANT ONES:
 *   1. THE GATE. Acquisition_NDA answers to DEAL_DRIVER and Disposition_NDA to
 *      DISPOSITION_DRIVER, and the two custom permissions are disjoint across every permission set
 *      in the repo. A merged StageTypeConfig has ONE gate, so merging hands an acquisitions deal
 *      driver the buttons on a SALE's NDA or locks the disposition persona out of its own object.
 *      Pinned by theGateIsResolvedPerRecordTypeNotPerObject.
 *   2. THE EXPLICIT-TARGET ALLOW-LIST. 'Declined' belongs to Disposition_NDA alone; an
 *      object-level list makes advanceTo(acquisitionNdaId, 'Declined') reachable. Pinned by
 *      acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget. See
 *      NDA_DISPOSITION_EXPLICIT_TARGETS.
 * ⚠ AND THE SEQUENCE REASON IS ONLY DORMANT, NOT DEAD. It has been revived by a one-line Setup
 * change three times in eleven days (2026-08-16, 2026-08-25, 2026-08-27), each time without any
 * Apex deploy. Collapsing the split now would mean re-deriving it on the next one, under time
 * pressure, on a live defect. The SPLIT IS THE CHEAP HALF; the argument is what costs.
 *
 * ⚠ LOI__c AND Contract_Review__c ARE NOT AFFECTED BY THIS PARAGRAPH AND THEIR SEQUENCE SPLITS
 * REMAIN LOAD-BEARING ON THE ORIGINAL GROUNDS — LOI__c shares 'Under Review', 'Negotiation' and
 * 'Signed' across its two types with genuinely different onward hops. Do not generalise the NDA
 * observation above to either of them.
 *
 * 🔴 ON LOI__c THE TWO STAGE SETS ARE NO LONGER DISJOINT — 'Under Review' IS SHARED BY BOTH SINCE
 * 2026-08-14 (observation 5). It is the acquisition sequence's second stage and the disposition
 * sequence's second stage. ⚠ THIS BLOCK USED TO OPEN "THE TWO STAGE SETS ARE FULLY DISJOINT, AND
 * THAT DOES NOT MAKE THE RECORD TYPE REDUNDANT HERE" and then gave three reasons the service needs
 * the record type ANYWAY. Every one of those three reasons still holds and is retained verbatim
 * below — but they have been promoted from "belt and braces" to "the only thing holding this
 * together", because the premise they were arguing against is now simply false.
 *
 * ⇒ NOTHING IN THIS CLASS REGRESSED, and that is a property of the 3A/3B design rather than luck:
 *   this service has always resolved the sequence from the RECORD TYPE and never from the stage
 *   value, so a shared stage cannot mis-route it. What DID break is everything OUTSIDE this class
 *   that keyed on the stage value alone — the LOI record-type files' own comments, the
 *   LOI_Record_Page visibility rules, and LOI__c.Is_Advance_Allowed__c, a formula whose header
 *   records that it omits a record-type test PRECISELY because the sets were disjoint (design
 *   collision C1). Those are the declarative half of this pack and are not fixed from here.
 *
 * The three reasons, unchanged, any one of which is sufficient:
 *   1. the PERMISSION GATE is not a function of the current stage at all — hasStageActionAccess is
 *      asked before any stage is known to the client, and answering it needs the record type;
 *   2. the EXPLICIT-TARGET allow-list is checked against a caller-supplied string, so deriving the
 *      allow-list from the record's current stage would let a row parked on a shared/unknown stage
 *      inherit the wrong list;
 *   3. a row CAN carry an off-set stage — at which point "the sets are disjoint" is an assumption
 *      about data, not a fact.
 *      ⚠ RETRACTED 2026-08-21 — MECHANISM REPLACED, CONCLUSION STRENGTHENED. This reason used to
 *      open "Apex DML does not enforce record-type picklist restriction, so ...", which is false
 *      for a `restricted` value set (measured block at the end of this header). The true mechanism
 *      is that DML validates the record-type subset AT WRITE TIME ONLY — nothing revalidates rows
 *      that already exist. Removing a value from a record type, or changing a row's record type,
 *      leaves live rows parked on a stage their type no longer carries. The user did exactly that
 *      twice on 2026-08-21 (Disposition_PSA dropped Revised / Ready for Execution / Executed;
 *      Disposition_LOI dropped the counter loop), so this is a fact about THIS org's data, not a
 *      hypothetical. Deriving the sequence from the stage value would mis-route every such row.
 * ✅ AND THE SENTENCE THAT USED TO CLOSE THIS BLOCK WAS A PREDICTION THAT CAME TRUE: "Deriving the
 * sequence from the stage value would also silently break the day any LOI stage is shared, with no
 * compile error and no failing walk test." That day was 2026-08-14. Because the sequence is derived
 * from the record type, nothing broke.
 *
 * 🔴 THE EXPLICIT-TARGET ALLOW-LIST IS PER RECORD TYPE TOO, AND THAT IS THE SECURITY HALF OF THIS
 * CHANGE — NOT A TIDY-UP. An object-level allow-list containing 'Declined' (for the disposition
 * NDA's Mark Declined action) would let a hand-crafted advanceTo(acquisitionNdaId, 'Declined')
 * attempt a disposition-only value on an acquisition NDA — the exact hole the allow-list exists to
 * close, re-opened one layer up. Making only nextStage record-type-aware LOOKS finished and is not.
 * Pinned by RecordStageAdvanceServiceTest.acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 RETRACTED 2026-08-21 — MEASURED, NOT REASONED. THIS BLOCK USED TO ASSERT, AND ~20 OTHER
 * PLACES IN THIS REPO STILL ASSERT: "Record-type picklist restrictions are enforced by the UI
 * ONLY; Apex DML does not enforce them."  THAT IS FALSE FOR A RESTRICTED VALUE SET.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * MEASUREMENT (usman-dpeg, 2026-08-21, from a check-only validation running this class's own test
 * suite — reproducible, not anecdotal):
 *   - `Contract_Review__c.Negotiation_Status__c` has `restrictedPicklist: true`, and the value
 *     'Revised' is ACTIVE on its master value set (confirmed by REST describe). The org's
 *     `Disposition_PSA` record type had 'Revised' removed from it by a concurrent change.
 *   - A plain Apex `insert` of a Disposition_PSA row carrying `Negotiation_Status__c = 'Revised'`
 *     was REFUSED: `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST, bad value for restricted picklist
 *     field: Revised`.
 *   - Independently, an insert of a `Disposition_LOI` row carrying `Stage__c = 'Signed'` — active
 *     on the master `Stage__c` value set, which is also `restricted` — was refused identically
 *     while that value was absent from the record type, and ACCEPTED in the same test the moment
 *     the record type was deployed carrying it.
 * ⇒ FOR A `restricted` VALUE SET, THE RECORD TYPE'S SUBSET *IS* ENFORCED BY APEX DML. Both stage
 *   fields this class writes (`LOI__c.Stage__c`, `Contract_Review__c.Negotiation_Status__c`) are
 *   restricted. This repo has separately measured that a restricted value set rejects values off
 *   the MASTER list; the new fact is that the RECORD-TYPE subset is enforced too.
 *
 * ── WHAT THIS CHANGES, AND WHAT IT POINTEDLY DOES NOT ────────────────────────
 * ✅ THE PER-RECORD-TYPE ALLOW-LIST IS STILL LOAD-BEARING AND MUST NOT BE COLLAPSED. Do not read
 *    "DML enforces it after all" as licence to move the allow-list back to object level. DML only
 *    refuses a value the target record type does not CARRY. The allow-list refuses a value the
 *    record type carries but the ACTION has no business writing — and after 2026-08-21 that is the
 *    live case on LOI__c: 'Negotiation' and 'Signed' are on BOTH record types, so DML would accept
 *    advanceTo(dispositionLoiId, 'Signed') and the allow-list is the ONLY refusal left. See the
 *    hazard note below and LOI_ACQUISITION_EXPLICIT_TARGETS.
 * ⚠  WHAT IT DOWNGRADES is the *wording* of the older NDA/PSA arguments: where they say a leak
 *    "would SUCCEED and park a value on the wrong record type", the truer statement is that it
 *    would be refused by DML with an opaque restricted-picklist error instead of by this service
 *    with a user-safe message. A worse failure than a refusal, still not a silent bad write.
 * 🔴 IT MAKES DEPLOY ORDER A HARD REQUIREMENT, NOT A PREFERENCE: a record type must carry a value
 *    BEFORE any map or allow-list here can name it, or the first click writes a DML error. This was
 *    an unmeasured "nicety" in the 2026-08-21 design (§5.2, gate U1) and is now proven mandatory.
 *
 * ⚠ THE SAME HOLE EXISTS ON LOI__c, WHICH IS WHY THE 3B CONFIG SPLITS LOI_EXPLICIT_TARGETS RATHER
 * THAN SHARING IT. Held at object level, {Negotiation, Signed} would be writable onto a DISPOSITION
 * LOI by a hand-crafted advanceTo. Pinned by dispositionLoiRefusesTheAcquisitionExplicitTargets.
 *
 * ⚠ RETRACTED 2026-08-21. The two paragraphs that used to sit here read:
 *   "⚠ THE SAME HOLE EXISTS IN BOTH DIRECTIONS ON LOI__c ... Held at object level, {Negotiation,
 *    Signed} would be writable onto a DISPOSITION LOI — a value set that record type does not carry
 *    at all — and the disposition type's own {Countered by DPEG, Counter Received from Buyer} would
 *    be writable onto an ACQUISITION LOI, which carries neither. ⚠ The acquisition pair was
 *    {Counter, Completed} until observation 5 renamed it; the two ALLOW-LISTS remain fully disjoint
 *    even though the two SEQUENCES no longer are (they share 'Under Review', which is on neither
 *    list, deliberately). Pinned in both directions by
 *    acquisitionLoiRefusesADispositionStageAsAnExplicitTarget /
 *    dispositionLoiRefusesTheAcquisitionExplicitTargets."
 *   "🔴 THAT SECOND DIRECTION STOPPED BEING HYPOTHETICAL AT THE 3B CLOSE-OUT. Until the loop
 *    actions landed, Disposition_LOI supplied NO explicit targets, so the acquisition-side test
 *    could only prove 'the acquisition list has not silently widened to the union'. It now has two
 *    real disposition-only values to leak, and both are refused — which is the shape the test was
 *    written in advance for."
 * BOTH premises died on 2026-08-21. Disposition_LOI supplies NO explicit targets again, so there is
 * no second direction to leak: the SECOND direction has reverted to exactly the "has the acquisition
 * list widened to the union?" control it was before the 3B close-out, and that test's own comments
 * now say so rather than claiming to refuse literals a deployed bundle can send. There are no such
 * bundles any more. ⚠ IT WAS ALSO RENAMED ON 2026-08-21, to
 * acquisitionExplicitTargetListHasNotWidenedToTheUnion — the verbatim quote above still carries the
 * old name acquisitionLoiRefusesADispositionStageAsAnExplicitTarget because a quote is not edited,
 * and that name will not resolve against the current suite.
 * The first clause of the old paragraph — "{Negotiation, Signed} would be writable onto a
 * DISPOSITION LOI" — SURVIVES, but its parenthetical ("a value set that record type does not carry
 * at all") does NOT; see the next paragraph, which is the reason this retraction is not cosmetic.
 *
 * 🔴 A NEW HAZARD, CREATED 2026-08-21, THAT DID NOT EXIST BEFORE — READ BEFORE TOUCHING
 * LOI_ACQUISITION_EXPLICIT_TARGETS. 'Negotiation' and 'Signed' are now on BOTH record types' value
 * sets. THE PER-RECORD-TYPE ALLOW-LIST SPLIT IS THEREFORE THE ONLY THING PREVENTING
 * LOI__c.Mark_Completed — an ACQUISITION quick action that sends the hardcoded literal 'Signed' —
 * from writing a *legal* disposition value onto a sale via a hand-crafted
 * advanceTo(dispositionLoiId, 'Signed'). Before this change such a write produced an off-set value
 * that at least LOOKED wrong to anyone reading the row, the Path or a flexipage rule keyed on it;
 * now it would look entirely normal and no downstream reader could tell it apart from a legitimate
 * sell-side Signed. The allow-list refusal is the only detection there is.
 * ⇒ DO NOT MOVE THE ALLOW-LIST BACK TO OBJECT LEVEL, and do not add 'Signed' or 'Negotiation' to
 * LOI_DISPOSITION_* on the grounds that "the record type carries them now". They are reached on the
 * sell side by advance() deriving them, never by an explicit target.
 *
 * ── ⚠ THE CALL ORDER CHANGED, AND advanceTo's CHANGE IS THE LOAD-BEARING ONE ──
 * configFor() resolves from Id.getSObjectType() alone, so it still runs FIRST — it is what proves
 * the object is stage-controlled before load() is asked to dispatch, and it supplies the stage FIELD
 * NAME. What moved is the choice of MAP: the record type is not knowable until the row is in hand,
 * so map selection now happens AFTER load().
 *
 *   advance()    load() already ran before the map was consulted. Order effectively unchanged.
 *   advanceTo()  🔴 THE ALLOW-LIST CHECK NOW HAPPENS AFTER THE LOAD, where it used to happen
 *                before it. It has to: the allow-list is a property of the record type, and the
 *                record type is a property of the row. One visible consequence — advanceTo against
 *                a NON-EXISTENT Id and a disallowed target now raises System.QueryException where
 *                it previously raised RecordStageAdvanceException. Both surface a fixed generic
 *                message at the controller, so no user-visible wording changes.
 *
 * ── THE null / Master FALLBACK IS LOAD-BEARING, NOT DEFENSIVE ────────────────
 * Between the record-type deploy (T1) and the row migration (GATE T-B) every existing NDA, LOI and
 * Contract Review sits on the Master record type, and today — before T1 — none of the three has a
 * RecordTypeId field at all. Each StageConfig therefore names a defaultTypeKey pointing at the
 * ACQUISITION map, which is what keeps live rows advancing through that window. An object with no
 * record types (FOUR of the eight — Underwriting__c, the two Feasibility Reviews and
 * Transaction__c) keeps a single map and
 * never pays a describe: record-type awareness degrades to exactly today's behaviour.
 *
 * ✅ ON Contract_Review__c THE FALLBACK USED TO BE THE QUIETEST OF THE THREE, AND OBSERVATION 7
 * MADE IT THE LOUDEST. ⚠ This block used to read: "Because both PSA types share one sequence, a
 * Master-type row advances CORRECTLY through the fallback — the walk works, the toasts are right,
 * nothing looks wrong ... There is no loud symptom to lead anyone to gate T-B here." That is FALSE
 * as of 2026-08-14 and is rewritten rather than left standing.
 *
 * The two sequences now differ, and the P3 row migration is scoped BY RECORD TYPE, so a Master-type
 * row is NOT migrated and keeps whatever value it had:
 *   - a legacy / Master ACQUISITION row still on 'Initial Draft' finds no entry in the acquisition
 *     fallback map and is REFUSED on its first click, naming its own stale status. That refusal is
 *     the loud symptom this block used to complain was missing — it points straight at gate T-B.
 *   - a Master-type DISPOSITION row is worse off than before, not better: it takes the ACQUISITION
 *     sequence, which no longer describes it at all, so it is refused as well as being on the wrong
 *     gate. Before observation 7 it at least walked. Gate T-A1/T-B closes both cases; nothing in
 *     Apex can.
 * See CONFIG_BY_TYPE for why the default nevertheless STAYS Acquisition_PSA (a refusal beats the
 * wrong write the disposition default would produce).
 *
 * ⚠ The fallback is safe on LOI__c for the same reason it is safe on NDA__c and for no other:
 * every LOI in the org today is buy-side by construction, because the Disposition__c lookup and the
 * sell-side stages arrive in this same tranche. It is a MIGRATION-WINDOW guarantee, not a general
 * one — the day a Master-type row can legitimately be sell-side, this fallback starts applying
 * buy-side stages and the ACQUISITIONS gate to a sale.
 *
 * ⚠ A REAL, NAMED record type with no map is a different case and is REFUSED, not defaulted. A
 * silent fallback there would apply the acquisition sequence to a record the acquisition sequence
 * does not describe.
 * ⚠ RETRACTED 2026-08-21 — the MECHANISM this sentence used to cite is false; the CONCLUSION is
 * not. It used to read: "— and, because DML does not enforce record-type picklist restrictions,
 * would happily write an off-set value." See the measured retraction block above
 * (`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`): both stage fields this class writes are
 * `restricted`, so DML DOES enforce the target record type's subset and an off-set value is
 * refused, not written. The correct reason to fail loudly here is that BOTH outcomes of a silent
 * fallback are worse than a refusal, and which one you get depends on data nobody controls:
 *   - the acquisition value the fallback picks is SHARED with the unmapped type's value set
 *     ('Under Review' on LOI__c, 'Signed'/'Sent' on NDA__c) ⇒ DML accepts it, and the row is
 *     parked on the wrong module's sequence SILENTLY — the bad write, still fully live;
 *   - it is NOT shared ⇒ DML refuses it with an opaque restricted-picklist error surfaced from a
 *     write the user did not ask for, instead of this service's user-safe "no next step" message.
 * Failing loudly is also what makes a typo in a map key falsifiable
 * (Apex Map<String,...> keys are case-SENSITIVE while getDeveloperName() returns the metadata
 * casing, so a mis-cased key would otherwise degrade in silence).
 *
 * ── ⚠ THERE ARE TWO STAGE SERVICES. KNOW WHICH ONE YOU ARE EDITING ────────────
 *   StageAdvanceService        — OPPORTUNITY only. Its advance() BRANCHES into an approval
 *                                submission, and its advanceTo() exists because Opportunity has
 *                                parallel record-type branches (Land / Retail) and an off-ramp;
 *                                that is why it carries ALLOWED_EXPLICIT_TARGETS.
 *   RecordStageAdvanceService  — THIS CLASS. The eight objects above, carrying TWELVE
 *                                StageTypeConfigs since Disposition__c joined 2026-08-19 (NDA 2,
 *                                LOI 2, Contract Review 2, Disposition 2, plus one each for the
 *                                FOUR record-type-free objects). TWO
 *                                of the twelve are not straight lines, and each is a
 *                                DIFFERENT shape: the ACQUISITION LOI BRANCHES at 'Submitted' and
 *                                the DISPOSITION NDA has the 'Declined' OFF-RAMP.
 *                                ⚠ RETRACTED 2026-08-21 — THE COUNT WAS THREE AND THIS SENTENCE
 *                                USED TO READ: "THREE of the twelve are not straight lines, and
 *                                each is a DIFFERENT shape: the ACQUISITION LOI BRANCHES at
 *                                'Submitted', the DISPOSITION NDA has the 'Declined' OFF-RAMP, and
 *                                the DISPOSITION LOI is a LOOP (Countered by DPEG <-> Counter
 *                                Received from Buyer)." The disposition LOI's negotiation loop was
 *                                retired by the user on 2026-08-21; that sequence is now the
 *                                LINEAR Received -> Under Review -> Negotiation -> Signed, its
 *                                allow-list is empty, and counter rounds moved to Counter History
 *                                (Counter_Offer__c). Do not restore the loop as a tidy-up.
 *                                Both remaining exceptions reach their extra stages through a
 *                                per-record-type
 *                                allow-list rather than a free-form write. ⚠ Every exception is
 *                                RECORD-TYPE-scoped, never object-scoped — the ACQUISITION NDA,
 *                                BOTH PSA types, BOTH Disposition__c types and (since 2026-08-21)
 *                                the DISPOSITION LOI are genuinely linear
 *                                within what they own and offer no explicit target at all.
 *                                🔴 THE DISPOSITION TYPES ARE LINEAR FOR A DIFFERENT REASON THAN
 *                                THE OTHERS, AND THE DIFFERENCE MATTERS: the PSA types are linear
 *                                because their PATH is; the disposition types are linear because
 *                                every branch, loop and off-ramp in their path belongs to an
 *                                approval or to another service. An empty allow-list therefore
 *                                makes `advanceTo()` STRUCTURALLY UNREACHABLE on Disposition__c,
 *                                which is the strongest available guarantee that no hand-crafted
 *                                call can park a sale on `Sale Closes`. Adding a disposition
 *                                explicit target is a REAL widening — do it only when a named quick
 *                                action needs a stage no approval owns.
 * They are deliberately NOT merged: folding a live, gated, deployed feature into a new one buys
 * tidiness and costs a re-test of the Opportunity approval hand-off. They DO share the permission
 * service (OpportunityActionPermissionService) and the confirm/guard shape on the client. Same
 * "know which one you are editing" convention as the three LeadConvert* classes.
 *
 * ── 🔴 THERE IS NO *GENERIC* advanceTo, AND THERE MUST NEVER BE ONE ──────────
 * A generic explicit-target write across eight objects would re-open exactly the hole
 * StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close: any holder of class access
 * could write any stage on any of eight objects, skipping every hop. advance() derives the target
 * from the map, so it CANNOT skip a hop. advanceTo() exists only for the two
 * branch / off-ramp cases (⚠ this read "the three branch / off-ramp / loop cases" until 2026-08-21,
 * when the disposition LOI's loop was retired) and writes NOTHING that is not on the allow-list FOR
 * THAT RECORD TYPE. Adding a branch action means adding its stage to that record type's set — never
 * widening the check.
 *
 * ── WHY THE MAPS ARE APEX AND NOT CUSTOM METADATA ────────────────────────────
 * A Stage_Map__mdt would let an admin change a stage map with no deploy and no review, which is the
 * SAME class of hole as the Path button this program removes. It also costs a getAll() per
 * transaction, is not compile-checked against its callers, and — recorded org defect — CMDT *record*
 * deploys fail in this org with UNKNOWN_EXCEPTION and need an Apex loader. A stage change already
 * requires touching the picklist, the pathAssistant and the quick action, all metadata deploys, so
 * the map is not the bottleneck. The Opportunity precedent (StageAdvanceService.NEXT_STAGE) is an
 * Apex map; matching it keeps one pattern.
 *
 * ── LAYERING ─────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). It holds ZERO SOQL: every read
 * goes to the object's own selector via selectStageRequiredById. There is deliberately NO dynamic
 * SOQL — a generic Database.query() over eight objects would violate the selector rule, skip
 * WITH USER_MODE and add an injection surface. The cost is an eight-branch dispatch in load(), which
 * is two lines per object and compile-checked.
 *
 * ⚠ Record-type resolution adds ZERO queries. RecordTypeId rides along on the selector read that
 * already happens, and the Id -> developer name step is a DESCRIBE
 * (getRecordTypeInfosById().get(id).getDeveloperName()), not a lookup on RecordType.
 *
 * ── WRITE MODE (design decision D1): plain `update`, i.e. SYSTEM MODE ─────────
 * Matches StageAdvanceService.setStage exactly. The control here is the permission gate plus the
 * (future) validation rule, not FLS; and a silent divergence between two sibling services is itself
 * a defect source. RESIDUAL, accepted and documented: a user with the deal-driver gate but WITHOUT
 * FLS edit on the stage field can still drive the button. Switching to
 * Database.update(record, AccessLevel.USER_MODE) is a one-line change, but FLS truth is not in
 * source control (profiles are .forceignore'd), so it cannot be regression-tested from this repo.
 *
 * ── BULKIFICATION ────────────────────────────────────────────────────────────
 * The 251-record mandate in .claude/rules/bulk-test-rule.md does not apply. advance() is a
 * per-transaction-singleton @AuraEnabled operation invoked once per quick-action click: one record,
 * one selector read, one update, no loop over records and no collection DML. Same shape and same
 * exemption as StageAdvanceService and OpportunityActionPermissionService.
 *
 * @see force-app/main/default/classes/StageAdvanceService.cls (the Opportunity sibling)
 * @see force-app/main/default/classes/RecordStageAdvanceController.cls (the LWC boundary)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the gate)
 */
public with sharing class RecordStageAdvanceService {

    /**
     * Raised when a record cannot advance and the reason is user-safe and surfaced verbatim:
     * no record supplied, an unsupported object, no stage set, no next step from the current
     * stage, or a platform save block whose validation message is surfaced. Distinct from an
     * unexpected QueryException (missing/inaccessible record), which the controller maps to a
     * fixed generic message instead.
     */
    public class RecordStageAdvanceException extends Exception {}

    /**
     * Raised when the running user may not drive this record's stage action. Owned by THIS class
     * rather than re-thrown from the gate's own type so that adding a second gate (e.g. a Property
     * Management persona on a future object) changes nothing at the controller boundary.
     */
    public class AccessDeniedException extends Exception {}

    /**
     * Which permission gate a RECORD TYPE's stage action answers to. An enum, not a String, so a
     * new object cannot be wired to a gate that does not exist (.claude/rules — "use enums over
     * string constants").
     *
     * ── 🔴 REWRITTEN 2026-08-12: ALL THREE MEMBERS ARE NOW ONE CUSTOM PERMISSION ──
     * This block previously described three DIFFERENT mechanisms and warned "THE THREE MEMBERS ARE
     * NOT ALL THE SAME SHAPE ... do not generalise from the first two". That warning is now
     * OBSOLETE and is rewritten rather than left standing: the `*_Driver__c` flag model was retired
     * entirely and every gate below is a single `FeatureManagement.checkPermission` call plus the
     * shared "Modify All Data" bypass.
     *
     *   DEAL_DRIVER         `Acquisition_Deal_Actions`, granted by `Acquisition_Deal_Driver`.
     *                       The acquisitions deal children. The LOI and Underwriting record pages
     *                       carry the matching Dynamic Actions visibility rule
     *                       `{!$Permission.CustomPermission.Acquisition_Deal_Actions} EQUAL true`,
     *                       so this costs no new machinery.
     *
     *                       🔴 THAT TOKEN HAS THREE SEGMENTS AND THE PLATFORM REJECTS THE OTHER TWO
     *                       SPELLINGS — MEASURED AT DEPLOY 2026-08-12, NOT INFERRED. A FlexiPage
     *                       `<leftValue>` must read `{!$Permission.CustomPermission.<Name>}`. Both
     *                       `{!$Permission.<Name>}` (the two-segment form this comment itself
     *                       carried until it was corrected) and `{!$CustomPermission.<Name>}` were
     *                       REFUSED by the Metadata API, so a rule copied from a shortened comment
     *                       fails the deploy rather than silently mis-evaluating. Keep every written
     *                       occurrence in this repo in the three-segment form for that reason.
     *   DISPOSITION_DRIVER  `Disposition_Deal_Actions`, granted by `DPEG_Disposition_Edit` since
     *                       2026-08-19 (it was `Disposition_Deal_Driver`, now retired — the token
     *                       and this config are untouched, only the grantor moved).
     *                       WIRED 2026-08-09 (Tranche 3A, decision D15/Q1). Until then the value
     *                       was deliberately NOT declared: an unwired enum member is
     *                       indistinguishable from a wired one at a glance, and passesGate's
     *                       `when else` would have denied it silently for every disposition user.
     *   TRANSACTION_STAGE_ACTIONS
     *                       `Transaction_Stage_Actions`, granted by
     *                       `Transaction_Stage_Actions_Access`. WIRED 2026-08-12 with the
     *                       Transaction Advance Stage action — for the reason recorded on
     *                       DISPOSITION_DRIVER above.
     *
     * ⚠ THE ENUM VALUE NAMES WERE DELIBERATELY NOT RENAMED. `DEAL_DRIVER` and `DISPOSITION_DRIVER`
     * still read as if a `*_Driver__c` checkbox existed, and it no longer does. They name the GATE
     * (which persona drives this record type), not the MECHANISM, and renaming them is churn across
     * a config map with three call sites and zero behavioural benefit. Read them as "the
     * acquisitions deal-driving persona" / "the disposition deal-driving persona".
     *
     * 🔴 THE ONE ASYMMETRY THAT SURVIVES IS WHICH LAYER CARRIES THE PERMISSION, AND IT MATTERS.
     * `Acquisition_Deal_Actions` and `Disposition_Deal_Actions` sit on LAYER-5 authorization sets
     * assigned DIRECTLY to a narrow population. `Transaction_Stage_Actions` sits on the LAYER-4
     * capability set `Transaction_Stage_Actions_Access`, which is a member of the
     * `DPEG_Transaction_Team` group — so the Transaction gate is TEAM-WIDE and has no per-user
     * revocation, exactly as it was under the membership check it replaced. That is a preserved
     * policy, not an artefact of the migration. Moving either of the first two onto a layer-4 set
     * would be a real WIDENING (`Opportunity_Stage_Actions_Access` is a member of
     * `DPEG_Junior_Analyst_PSG`); moving the third off one would be a real NARROWING. Read
     * TransactionActionPermissionService's header before harmonising any of them.
     *
     * 🔴 THE GATE IS A PROPERTY OF THE RECORD TYPE, NOT OF THE OBJECT — that is the point of
     * wiring it here rather than reusing DEAL_DRIVER for `NDA__c` wholesale. One object serves
     * both modules, and an acquisitions deal driver must not be able to drive a sale's NDA (or
     * the reverse) merely because the two share a table. That stays true for an object with a
     * single sequence: `Transaction__c` names its gate exactly once because it has exactly one
     * sequence, not because the gate is an object-level property.
     *
     * ⚠ A NOTE FOR ANYONE READING THE GIT HISTORY. This block used to argue at length that the two
     * `*_DRIVER` members must NOT become permission-set MEMBERSHIP checks, because a user holding
     * the set with the flag `false` was denied and would have been GRANTED — a silent widening of a
     * live boundary. That argument is now MOOT, not overturned: there is no flag left to disagree
     * with the set, and the custom permission is carried BY those same sets, so the population is
     * preserved by construction. Do not resurrect it as an objection to a future change; the
     * argument that still bites is the layer-4/layer-5 one above.
     */
    public enum StageActionGate {
        DEAL_DRIVER,
        DISPOSITION_DRIVER,
        TRANSACTION_STAGE_ACTIONS
    }

    private static final String NO_RECORD_MESSAGE = 'No record was provided.';
    private static final String UNSUPPORTED_OBJECT_MESSAGE =
        'This action is not available on this record.';
    private static final String NO_STAGE_MESSAGE =
        'This record has no stage set, so it cannot be advanced.';
    /**
     * Distinct from UNSUPPORTED_OBJECT_MESSAGE on purpose: the object IS stage-controlled, but the
     * record sits on a record type this service has no sequence for. Separate wording so the
     * condition is falsifiable in a test and so the reader of a toast can tell "wrong object" from
     * "unconfigured record type" — two different fixes.
     */
    private static final String UNSUPPORTED_RECORD_TYPE_MESSAGE =
        'This action is not configured for this record type.';

    /** The standard field carrying the row's record type. Compared case-insensitively — see recordTypeIdOf. */
    private static final String RECORD_TYPE_ID_FIELD = 'RecordTypeId';

    /**
     * The map key used by an object with NO record types at all — Underwriting__c,
     * Construction_Feasibility_Review__c, Development_Feasibility_Review__c and, since
     * 2026-08-12, Transaction__c.
     *
     * A sentinel rather than a real developer name so it can never collide with one, and so a
     * reader can see at a glance which configs are record-type-aware.
     *
     * ⚠ ITS DOC COMMENT USED TO OFFER A SECOND USE — "or because its types deliberately share one
     * sequence (Contract_Review__c…)" — AND THAT WAS WRONG, corrected in Tranche 3C. Sharing a
     * SEQUENCE is not sharing a GATE, and this key carries BOTH. Contract_Review__c's two types do
     * share their sequence (by reference, one map object) and answer to two DIFFERENT personas, so
     * it is keyed by developer name like NDA__c and LOI__c. There is now no object in the config
     * that has record types AND uses this key, and there should not be one: an object that has
     * record types has, by construction, a question this key cannot answer.
     */
    private static final String SINGLE_TYPE_KEY = '__DEFAULT__';

    /** NDA__c record type developer names (D7 / D14.1). Case must match the metadata exactly. */
    private static final String RT_ACQUISITION_NDA = 'Acquisition_NDA';
    private static final String RT_DISPOSITION_NDA = 'Disposition_NDA';

    /**
     * LOI__c record type developer names (D6, Tranche 3B). Case must match
     * objects/LOI__c/recordTypes/ exactly — these strings are Map keys and Apex Map<String, …>
     * keys are case-SENSITIVE, so a mis-cased constant would route every disposition LOI to the
     * acquisition fallback with no error anywhere.
     */
    private static final String RT_ACQUISITION_LOI = 'Acquisition_LOI';
    private static final String RT_DISPOSITION_LOI = 'Disposition_LOI';

    /**
     * Contract_Review__c record type developer names (D16.3, Tranche 3C). Case must match
     * objects/Contract_Review__c/recordTypes/ exactly — these strings are Map keys and Apex
     * Map<String, …> keys are case-SENSITIVE, so a mis-cased constant would route every
     * disposition PSA to the acquisition fallback with no error anywhere. That degradation is
     * QUIETER here than on NDA__c / LOI__c, because the fallback map is the SAME map and the walk
     * would still work perfectly — only the GATE would be wrong.
     */
    private static final String RT_ACQUISITION_PSA = 'Acquisition_PSA';
    private static final String RT_DISPOSITION_PSA = 'Disposition_PSA';

    /**
     * Disposition__c record type developer names (design D-2, 2026-08-19). Case must match
     * objects/Disposition__c/recordTypes/ exactly — Map keys are case-SENSITIVE, so a mis-cased
     * constant would route every off-market sale to the ON-MARKET fallback and silently offer it
     * `Broker Selection -> NDA`, a hop that belongs to `Broker_Selection_Approval`. That is a
     * one-click approval bypass produced by a typo, which is why the constants are named and not
     * inlined.
     *
     * ⚠ THIS NOTE USED TO SAY "nothing enforces it but this note" — SOMETHING DOES NOW. Retracted,
     * verbatim: "THESE TWO STRINGS ALSO APPEAR IN `DispositionApprovalAdvanceService` and
     * `DispositionApprovalService`, each holding its own copy for its own layer. They must agree;
     * nothing enforces it but this note and the fact that all three read the same metadata folder."
     * That arrangement produced code-review finding C-2 on 2026-08-19 — not through a mis-cased
     * constant, but through the two `recordTypeNameOf` helpers those copies fed, which disagreed
     * about the Master/unset default while a comment asserted they agreed. Both the helper and the
     * canonical strings now live in `DispositionDomain`, and the four holders (this class,
     * `DispositionApprovalService`, `DispositionApprovalAdvanceService`, `DispositionService`) keep
     * a local ALIAS purely for readability at the point of use. Do not re-inline a literal.
     */
    private static final String RT_ON_MARKET = DispositionDomain.RT_ON_MARKET;
    private static final String RT_OFF_MARKET = DispositionDomain.RT_OFF_MARKET;

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE MAPS — current stage -> the single next stage.
    // Each map is one PATH, minus its terminal stage (which has no entry and therefore yields the
    // "no next step available" message). Values are the DECODED runtime picklist strings.
    //
    // ⚠ NO VALUE IN ANY OF THESE TEN MAPS CONTAINS A '/' ANY MORE. This note used to say
    // "'Prepare/Review' carries a literal slash, which is why the future validation rules must use
    // TEXT(...) compares rather than ISPICKVAL" — observation 5 renamed that value to
    // 'Under Review' and it was the last one. The TEXT(...) discipline is still correct for
    // validation rules on these fields (it is what makes a value rename a one-line edit rather
    // than a re-encoded one), but there is no longer a %2F hazard to point at. Opportunity's
    // 'Dead/Pass' still carries it; that is StageAdvanceService's field, not this one.
    //
    // ⚠ An object with record types has ONE MAP PER RECORD TYPE. Do not merge two record types'
    // maps into one even when they share values — see the 'Sent' divergence in the class header.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * NDA__c.Status__c / Acquisition_NDA — Pending -> Received -> Signed -> Sent. 🔴 'Sent' is
     * TERMINAL.
     *
     * ── 🔴 REORDERED 2026-08-16 (USER DECISION). D14.1's PLACEMENT OF 'Sent' IS REVERSED. ──
     * The four values are unchanged; their ORDER is not, and 'Sent' now MEANS something different.
     * The business sequence is: the broker's NDA arrives (Pending), we receive it (Received), we
     * sign it (Signed), and we send the signed copy BACK to the broker (Sent) — which ends the
     * acquisition NDA's life. So 'Sent' is no longer "we issued it"; it is "the executed copy is
     * with the broker".
     *
     * ⚠ SUPERSEDED. D14.1's argument is retained rather than deleted because the git history reads
     * oddly without it and because it still explains why the VALUE exists at all. RETRACTED,
     * verbatim: "'Received' was INSERTED between 'Sent' and 'Signed' by decision D14.1
     * (2026-08-09). The source document describes the acquisition NDA as Pending -> Received ->
     * Signed; D14.1 reads that as the broker-facing milestones and keeps 'Sent' as the internal
     * step it pairs with Date_Sent__c. Retaining 'Sent' is what makes the change ADDITIVE — every
     * existing acquisition NDA keeps a valid value and no row migration is needed for the value set
     * itself." What survives: the value set is still exactly these four, so this reorder is again
     * additive-by-value and again needs no value-set migration. What does NOT survive: 'Sent' is
     * not an internal pre-issue step and no longer pairs with Date_Sent__c as the SECOND hop —
     * Date_Sent__c is now stamped at the END of the sequence, not near its start. Do not "restore"
     * the old order on the strength of the D14.1 sentence above.
     *
     * ⚠ THE ROWS THEMSELVES ARE NOT MIGRATED BY THIS CHANGE, AND THAT IS A REAL RESIDUAL. Every
     * acquisition NDA parked on 'Sent' under the OLD meaning ("we issued it, awaiting the broker")
     * now reads as TERMINAL and can no longer be advanced at all — it will be refused with "There
     * is no next step available from the Sent stage." Those rows need a data pass (most belong on
     * 'Pending' or 'Received'); nothing in Apex can tell the two meanings apart, because the value
     * is identical.
     *
     * 🔴 THERE IS A LIVE DEAL GATE ON THE FAR SIDE OF THIS SEQUENCE, AND THE REORDER IS SAFE ONLY
     * BECAUSE THE CHECKBOX FEEDING IT *LATCHES*. This is the one thing to understand before moving
     * any value in this map again.
     *
     * `NDA_Signed__c` is derived by `NDA_Signed_Status_Sync`, a BEFORE-SAVE flow on NDA__c. It sets
     * the checkbox TRUE when `Status__c = 'Signed'` and it NEVER SETS IT FALSE: the `Is_Signed`
     * decision carries a `<defaultConnectorLabel>Not Signed</defaultConnectorLabel>` but NO
     * `<defaultConnector>`, so the false branch simply TERMINATES, and the `Set_Signed_False`
     * assignment the flow defines is UNREACHABLE — nothing connects to it. Once true, the checkbox
     * stays true through every later status change.
     *
     * ⚠ THE FLOW'S OWN `<description>` CONTRADICTS ITS OWN ELEMENT GRAPH AND IS THE TRAP HERE. It
     * claims the flow derives the checkbox "in both directions: Status = 'Signed' sets the checkbox
     * true, any other Status sets it false." The second half is not implemented. Read the
     * connectors, not the description — an earlier draft of THIS comment asserted the two-direction
     * behaviour as fact on the strength of that sentence and was wrong.
     *
     * The gate itself: `NDA_Signed_Before_Deal_Progression` (Opportunity) blocks Underwriting / LOI
     * / Under Contract (PSA) / About to Close / Closed Won unless `Primary_NDA__r.NDA_Signed__c` is
     * true.
     *
     * ⇒ SO MOVING AN ACQUISITION NDA OFF 'Signed' AND ONTO THE NEW TERMINAL 'Sent' LEAVES THE
     * CHECKBOX TRUE AND THE DEAL GATE UNAFFECTED. This reorder required NO flow change, and none
     * was made.
     *
     * 🔴 BUT THE LATCH IS NOW LOAD-BEARING FOR THIS MAP, WHICH IT WAS NOT BEFORE. Under the OLD
     * order 'Signed' was terminal, so an acquisition NDA never left it and the latch was never
     * exercised; the flow's unreachable false branch was harmless dead metadata. Under THIS order
     * the final hop deliberately moves the record PAST 'Signed'. ⇒ IF ANYONE EVER CONNECTS THAT
     * DEFAULT BRANCH — "fixing" the flow to match its own description, which reads like an
     * unfinished job — the final Advance Stage click would set `NDA_Signed__c` back to FALSE and
     * LOCK THE DEAL out of Underwriting, LOI, PSA, About to Close and Closed Won. The button would
     * appear to complete the NDA and would in fact un-sign it. That is the hazard to guard: a
     * FUTURE flow change, not this map. Anyone making the flow set false must ALSO exempt the
     * acquisition terminal 'Sent'.
     *
     * =====================================================================
     * 🔴 NARROWED 2026-08-27 (USER DECISION) — 'Sent' IS OFF THE Acquisition_NDA RECORD TYPE
     * ENTIRELY, SO THE 'Signed' => 'Sent' HOP IS GONE AND 'Signed' IS NOW THE TERMINAL.
     * EVERYTHING ABOVE THIS BLOCK DESCRIBES A FOUR-VALUE SEQUENCE IN ONE ORDER OR THE OTHER AND IS
     * RETAINED VERBATIM AS THE RECORD OF WHAT CHANGED, NOT AS CURRENT BEHAVIOUR.
     * =====================================================================
     *
     * THE MAP IS NOW Pending -> Received -> Signed, WITH 'Signed' TERMINAL. Measured live on
     * usman-dpeg 2026-08-27 via the UI API picklist-values endpoint for record type
     * 012iw0000009yeZAAQ: Status__c on Acquisition_NDA is exactly Pending | Received | Signed,
     * default Pending. Disposition_NDA (012iw0000009yeaAAA) is UNCHANGED and still carries
     * Prepare | Approved | Sent | Signed | Declined — so NDA_DISPOSITION_NEXT_STAGE was not
     * touched, and its two uses of 'Sent' ('Approved' => 'Sent' and the legacy
     * 'Not Sent' => 'Sent') stand exactly as they were.
     *
     * 🔴 THIS WAS A LIVE DEFECT, NOT A TIDY-UP — SAME SHAPE AS THE 'Review' INCIDENT ON THE
     * DISPOSITION MAP TWO DAYS EARLIER, AND FOR THE SAME REASON. `NDA__c.Status__c` is a
     * RESTRICTED value set whose record-type subset DML DOES enforce (measured; see the block at
     * the end of this class header and the 2026-08-20 correction in
     * objects/NDA__c/recordTypes/Acquisition_NDA.recordType-meta.xml). With the hop still in
     * place, the Advance Stage click on an acquisition NDA sitting at 'Signed' resolved a target
     * of 'Sent' and threw `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` — surfaced verbatim to the
     * user by setStage's DmlException clause, because that clause cannot tell a validation rule
     * from a picklist refusal. The org's ONE live acquisition NDA was sitting at 'Signed' when
     * this was found, so the broken button was on screen. It now falls through to
     * noNextStepMessage and reads 'There is no next step available from the Signed stage.'
     *
     * ⚠ NO RESIDUAL ROWS. A live aggregate the same day
     * (SELECT RecordType.DeveloperName, Status__c, COUNT(Id) FROM NDA__c GROUP BY both) returned
     * exactly ONE row org-wide — an Acquisition_NDA at 'Signed' — and ZERO acquisition rows at
     * 'Sent'. So unlike the 2026-08-16 reorder, this change strands nobody and needs no data pass.
     * Do not cite that as a standing fact; re-measure before relying on it.
     *
     * ✅ THE DEAL GATE IS AGAIN UNAFFECTED, AND NOW FOR A STRONGER REASON THAN THE LATCH. The
     * 2026-08-16 block above rests the gate's safety on `NDA_Signed_Status_Sync`'s checkbox
     * LATCHING true past 'Signed'. That argument is no longer load-bearing: the acquisition NDA
     * now STOPS at 'Signed', so nothing moves it past the value that sets the checkbox in the
     * first place. The latch is back to being harmless dead metadata on this path, exactly as it
     * was before 2026-08-16. 🔴 The hazard warning above is NOT retracted — it applies again the
     * moment anyone re-adds a hop out of 'Signed', which is precisely the "tidy-up" this note
     * exists to make visible.
     *
     * ⚠ 'Sent' GETS NO LEGACY HOP HERE, AND THAT ASYMMETRY WITH 'Not Sent' ON THE DISPOSITION MAP
     * IS DELIBERATE AND EVIDENCE-BASED, NOT PRINCIPLED. 'Not Sent' keeps its hop because a future
     * data load could land a disposition row on it. 'Sent' gets none because it is UNREACHABLE on
     * this record type in both directions — nothing in this map targets it and DML refuses it on
     * insert or update — so an entry would be dead code that reads as evidence 'Sent' is still
     * part of the buy-side sequence. Do NOT add 'Sent' => anything "for symmetry".
     */
    private static final Map<String, String> NDA_ACQUISITION_NEXT_STAGE = new Map<String, String>{
        'Pending' => 'Received',
        'Received' => 'Signed'
    };

    /**
     * NDA__c.Status__c / Disposition_NDA — Prepare -> Approved -> Sent -> Signed. 'Signed' is
     * terminal.
     *
     * 🔴 'Sent' MAPS SOMEWHERE ELSE HERE THAN IT DOES ON THE ACQUISITION MAP ABOVE. That is not an
     * inconsistency to reconcile; it is the requirement. A disposition NDA goes straight from Sent
     * to Signed (there is no "received back from the broker" step on a sale, because DPEG issues
     * the NDA), while an acquisition NDA passes through 'Received'.
     *
     * ⚠ AMENDED 2026-08-16 — THE TWO MAPS NOW DISAGREE MORE, NOT LESS, AND THIS MAP DID NOT MOVE.
     * The sentence above understates it as of the acquisition reorder: on THIS map 'Sent' is a
     * mid-sequence hop to 'Signed', while on the acquisition map it maps NOWHERE AT ALL — it is
     * the terminal. And the divergence now runs in the OPPOSITE direction on the other shared
     * value: 'Signed' is terminal here and a hop (to 'Sent') there. Both sequences are correct for
     * their own side of the business; do NOT harmonise either one toward the other. This map is
     * verbatim what it has always been — Not Sent -> Sent -> Signed — and the acquisition change
     * deliberately left it untouched.
     *
     * ⚠ EXTENDED 2026-08-25 — THE LAST SENTENCE ABOVE IS NO LONGER TRUE, AND THE RULE IT SERVES IS
     * UNCHANGED. The map is now Prepare -> Approved -> Sent -> Signed (it read
     * "Prepare -> Review -> Approved -> Sent -> Signed" for a few hours the same day — see the
     * NARROWED block at the foot of this comment). Nothing was REMOVED from the sequence as it
     * stood that morning and no hop was repointed: 'Sent' => 'Signed' is untouched, and the
     * acquisition map is still not harmonised toward this one.
     *
     * 🔴 WHY IT HAD TO GROW, AND WHY THIS IS NOT SCOPE CREEP. The user removed 'Not Sent' from the
     * Disposition_NDA record type in Setup and cleared that type's default, and
     * DispositionStageEntryService's seed moved to 'Prepare' in the same change. Every NDA created
     * from that day forward therefore ENTERS at 'Prepare' — a value this map did not carry. Without
     * these hops the Advance Stage button would refuse the FIRST click on every new
     * disposition NDA with "There is no next step available from the Prepare stage", i.e. the
     * feature would be dead on arrival rather than subtly wrong.
     *
     * ⚠ 'Not Sent' => 'Sent' IS DELIBERATELY RETAINED AND IS NOW A LEGACY-ONLY HOP. The value stays
     * ACTIVE on the master value set (see the field file), so rows created before 2026-08-25 still
     * sit at 'Not Sent' in usman-dpeg and must remain advanceable. It can never be REACHED again —
     * nothing maps TO it and no record type exposes it — so it is unreachable, not dead. Do not
     * prune it; doing so strands those rows with no forward hop at all.
     * 🔴 CORRECTED 2026-08-25 — "rows created before 2026-08-25 still sit at 'Not Sent' in
     * usman-dpeg" IS NOT TRUE AS MEASURED. A live aggregate that day
     * (SELECT RecordType.DeveloperName, Status__c, COUNT(Id) FROM NDA__c GROUP BY both) returned
     * exactly ONE Disposition_NDA row, at 'Prepare', and ZERO at 'Not Sent'. The hop is KEPT
     * anyway — it costs one map entry and it protects any row a future data load lands on the
     * legacy value. What is retracted is the EVIDENCE, not the decision: do not cite "there are
     * such rows" as fact again without re-measuring.
     *
     * =====================================================================
     * ⚠ NARROWED 2026-08-25, LATER THE SAME DAY — 'Review' IS OUT OF THIS MAP ENTIRELY.
     * =====================================================================
     *
     * The user removed 'Review' from the Disposition_NDA record type in Setup. Measured live via
     * the UI API picklist-values endpoint for record type 012iw0000009yeaAAA: Status__c on that
     * type is exactly Prepare | Approved | Sent | Signed | Declined, with no default.
     *
     * 🔴 THIS WAS A LIVE DEFECT, NOT A TIDY-UP. NDA__c.Status__c is a RESTRICTED value set whose
     * record-type subset DML DOES enforce (measured — see recordTypes/Acquisition_NDA
     * .recordType-meta.xml's 2026-08-20 correction). The two hops this map carried for a few
     * hours — 'Prepare' => 'Review' and 'Review' => 'Approved' — meant the FIRST Advance click on
     * every new disposition NDA failed with
     * "bad value for restricted picklist field: Review". Every new NDA enters at 'Prepare', so
     * the button was dead on 100% of them.
     *
     * 🔴 'Review' IS TREATED DIFFERENTLY FROM 'Not Sent' AND THE ASYMMETRY IS DELIBERATE. Both
     * values are still ACTIVE on the master set and on NO record type; 'Not Sent' keeps a legacy
     * hop and 'Review' gets none. The reason is evidence, not principle: 'Review' existed on the
     * record type only between 2026-08-24 and 2026-08-25, and the same live aggregate found ZERO
     * rows carrying it on EITHER record type — there is nothing to strand. Do NOT add
     * 'Review' => 'Approved' "for symmetry". Nothing can write the value, so the entry would be
     * unreachable AND unjustified, and its presence would read as evidence that 'Review' is still
     * part of the sequence.
     */
    private static final Map<String, String> NDA_DISPOSITION_NEXT_STAGE = new Map<String, String>{
        'Prepare' => 'Approved',
        'Approved' => 'Sent',
        'Not Sent' => 'Sent',
        'Sent' => 'Signed'
    };

    /**
     * The disposition NDA's off-ramp, reached by the Mark Declined quick action rather than by
     * advance() — 'Declined' is a terminal alternative to 'Signed', not a forward hop, so no single
     * derived target from 'Sent' can express both.
     *
     * 🔴 THIS SET IS THE REASON THE ALLOW-LIST HAD TO BECOME RECORD-TYPE-AWARE. The Mark Declined
     * action keys on Status__c = 'Sent', a value SHARED by both NDA record types (§3.2 of the
     * design). Held at object level, this set would make advanceTo(acquisitionNdaId, 'Declined')
     * reachable. The acquisition NDA supplies NO explicit targets at all, so advanceTo cannot move
     * it.
     * ⚠ RETRACTED 2026-08-21 — MECHANISM FALSE, CONCLUSION INTACT. This used to read "would make
     * advanceTo(acquisitionNdaId, 'Declined') SUCCEED, because Apex DML does not enforce
     * record-type picklist restrictions." `NDA__c.Status__c` is `restricted` (see the measured
     * block in the class header), so an object-level list would not produce a silent bad write —
     * it would produce an opaque `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` for as long as
     * Acquisition_NDA omits 'Declined'. That is a WORSE failure than this set's user-safe refusal,
     * not a substitute for it, and it is a backstop on loan: it disappears the day someone adds
     * 'Declined' to the acquisition type for an unrelated reason, at which point the split is the
     * only control and the original sentence becomes literally true.
     *
     * ⚠ AMENDED 2026-08-27 — THE PREMISE "a value SHARED by both NDA record types" IS NOW FALSE,
     * AND THIS SET IS UNCHANGED BECAUSE OF IT, NOT IN SPITE OF IT. The user removed 'Sent' from
     * Acquisition_NDA, so the Mark Declined action's `Status__c = 'Sent'` visibility rule can no
     * longer render on an acquisition NDA at all — the shared-value framing of the paragraph above
     * described the state of the org between 2026-08-09 and 2026-08-27 and is retained as the
     * record of why the split was made.
     * 🔴 THE SPLIT IS STILL LOAD-BEARING AND MUST NOT BE COLLAPSED ON THE STRENGTH OF THAT. What
     * changed is only how a hand-crafted advanceTo(acquisitionNdaId, 'Declined') would REACH the
     * button — it never could reach it through the UI in the first place, which is the entire
     * reason the allow-list exists as a SERVER-side control. Both the refusal and its user-safe
     * wording are unchanged, and the acquisition NDA still supplies no explicit target at all, so
     * advanceTo remains structurally unreachable on it. Pinned by
     * acquisitionNdaRefusesTheDispositionOnlyDeclinedTarget, whose fixture moved from 'Sent' to
     * 'Signed' on this date for the DML reason, not for a change of subject.
     *
     * The action itself is `quickActions/NDA__c.Mark_Declined` -> `c/ndaMarkDeclined`, which
     * passes this exact literal as a module constant. It is no longer "a future action".
     *
     * ⚠ 'Declined' is deliberately NOT in NDA_DISPOSITION_NEXT_STAGE. It is a TERMINAL ALTERNATIVE
     * to 'Signed', not a forward hop — putting it there would make the ordinary Advance Stage
     * button decline the NDA.
     */
    private static final Set<String> NDA_DISPOSITION_EXPLICIT_TARGETS = new Set<String>{
        'Declined'
    };

    /**
     * LOI__c.Stage__c / Acquisition_LOI — Draft -> Under Review -> Submitted -> Negotiation ->
     * Signed. 'Signed' is terminal.
     *
     * 🔴 EVERY VALUE BUT 'Draft' CHANGED (Acquisition Observations, observation 5, 2026-08-14).
     * The old map read Draft -> Prepare/Review -> Sent -> Counter -> Completed. The rename is
     * one-for-one and preserves the SHAPE exactly — same five stages, same branch point, same
     * terminal — so nothing below this map moved:
     *
     *   Prepare/Review -> Under Review     ('Under Review' ALREADY EXISTED on this picklist)
     *   Sent           -> Submitted
     *   Counter        -> Negotiation
     *   Completed      -> Signed
     *
     * ⚠ 'Draft' IS THE ONLY SURVIVING LITERAL, and that is what keeps OpportunityReviewService's
     * LOI seed stage (`Stage__c = 'Draft'`) and TestDataFactory's LOI fixture correct with no edit.
     * Do not read that as "the LOI half was small".
     *
     * 🔴 THE SLASH IS GONE, AND WITH IT THE %2F HAZARD ON THIS MAP. 'Prepare/Review' carried a
     * literal slash, which is why every validation rule keyed on this field was required to use
     * TEXT(...) rather than ISPICKVAL and why the value appears as `Prepare%2FReview` in some
     * metadata contexts. NOT ONE value in the new sequence contains a '/', so no encoding applies
     * to any of them. Do not "helpfully" encode 'Under Review' — it is two words and a space.
     * (`Dead/Pass` on Opportunity.StageName is a different field and still carries the trap.)
     *
     * 🔴 'Under Review' IS NOW SHARED WITH Disposition_LOI, WHICH BREAKS THE DISJOINTNESS THE
     * WHOLE LOI FEATURE USED TO ASSUME. See the class header's rewritten LOI block: the two stage
     * sets are no longer disjoint, so a rule, formula or hint keyed on the STAGE VALUE ALONE can no
     * longer identify which side of the business a row belongs to. Nothing in THIS class regressed
     * — it has always resolved the sequence from the RECORD TYPE and never from the stage — but the
     * three arguments in the header for why that was the right choice have gone from "belt and
     * braces" to "the only thing holding this together".
     */
    private static final Map<String, String> LOI_ACQUISITION_NEXT_STAGE = new Map<String, String>{
        'Draft' => 'Under Review',
        'Under Review' => 'Submitted',
        'Submitted' => 'Negotiation',
        'Negotiation' => 'Signed'
    };

    /**
     * LOI__c.Stage__c / Disposition_LOI — Received -> Under Review -> Negotiation -> Signed.
     * 'Signed' is terminal.
     *
     * 🔴 THE DIRECTION IS REVERSED, WHICH IS WHY THIS IS A SECOND MAP RATHER THAN A LONGER ONE.
     * On a purchase DPEG DRAFTS the LOI and SENDS it, so the path starts at 'Draft'. On a sale the
     * LOI ARRIVES from the buyer through the appointed broker, so it starts at 'Received' — there
     * is no Draft and no Submitted. That is unchanged and is still the whole reason for two maps.
     *
     * ⚠ RETRACTED 2026-08-21 (user request; design agent-output/disposition-loi-stages.md). This
     * map read:
     *     'Received' => 'Under Review',
     *     'Under Review' => 'Countered by DPEG',
     *     'Countered by DPEG' => 'Counter Received from Buyer',
     *     'Counter Received from Buyer' => 'Executed'
     * and this doc-comment carried two paragraphs that are now false and are recorded rather than
     * deleted:
     *   (a) "🔴 THE SENTENCE THAT USED TO END THAT PARAGRAPH — 'Not one value is shared with the
     *       acquisition map' — IS FALSE SINCE 2026-08-14 ... 'Under Review' is now on BOTH maps ...
     *       This map itself is UNCHANGED — the sell side was not touched by observation 5".
     *       Still true about 'Under Review', but "this map itself is UNCHANGED" expired today, and
     *       the sharing is now WIDER: 'Negotiation' and 'Signed' are shared too. THREE of this
     *       map's four keys/values are also acquisition values. Anything inferring "which side is
     *       this?" from an LOI stage value alone was already wrong and is now wrong three ways over.
     *   (b) "✅ THE 'OPEN' NOTE THAT USED TO SIT HERE IS CLOSED — see LOI_DISPOSITION_EXPLICIT_-
     *       TARGETS immediately below. This map stays exactly as it was: it is the LINE through the
     *       loop, and the two loop edges are reached by advanceTo() instead. The line is what
     *       advance() walks, so 'Counter Received from Buyer' still derives 'Executed' and never
     *       derives a cycle."
     *       THERE IS NO LOOP ANY MORE and LOI_DISPOSITION_EXPLICIT_TARGETS NO LONGER EXISTS. The
     *       sell-side negotiation is recorded by editing Counter History on the LOI
     *       (Counter_Offer__c / c/loiCounterOffer, unchanged by this wave), not by cycling the
     *       stage field. This map is now the WHOLE sequence, not a line through a cycle.
     *
     * ⇒ This sequence is now LINEAR and every hop is derivable, so Disposition_LOI supplies NO
     * explicit targets at all and advanceTo() is STRUCTURALLY UNREACHABLE on it — see the
     * two-arg StageTypeConfig in CONFIG_BY_TYPE. That is a strengthening, not a loss.
     *
     * 🔴 'Signed' IS NOT A KEY HERE AND MUST NOT BECOME ONE. It is the terminal on BOTH record
     * types now; adding a hop out of it would move a sale past its own end state.
     */
    private static final Map<String, String> LOI_DISPOSITION_NEXT_STAGE = new Map<String, String>{
        'Received' => 'Under Review',
        'Under Review' => 'Negotiation',
        'Negotiation' => 'Signed'
    };

    /**
     * Contract_Review__c.Negotiation_Status__c / Acquisition_PSA — Draft -> Negotiation -> Signed
     * -> Executed. 'Executed' is terminal.
     *
     * ── 🔴 THE SHARED MAP IS GONE. THIS IS THE SPLIT ITS OWN COMMENT PREDICTED. ──
     * Until 2026-08-14 there was ONE map object, `CONTRACT_REVIEW_NEXT_STAGE`, that BOTH record
     * types pointed at BY REFERENCE, and the class header argued at length that copying it "would
     * invite the two to drift apart while the requirement is that they cannot". That argument was
     * correct for as long as its premise held — Disposition_PSA's record type file recorded that
     * `Initial Draft -> Revised -> Ready for Execution -> Executed` were ALREADY exactly the
     * sell-side states, so the two sides had nothing to disagree about.
     *
     * Observation 7 (Acquisition Observations, 2026-08-14) ends that premise. The ACQUISITION PSA
     * moves to `Draft -> Negotiation -> Signed -> Executed`; the DISPOSITION PSA keeps its four
     * values verbatim. The two sequences now genuinely differ, so the old block's own escape clause
     * applies literally: *"IF THE TWO SIDES EVER DO DIVERGE, SPLIT INTO TWO NAMED MAPS — do not add
     * a value here and restrict it in the record type file."* That is exactly what happened, and it
     * is why the split is CORRECT here and would have been a defect a week ago.
     *
     * 🔴 THE ALTERNATIVE THE OLD COMMENT FORBIDS IS THE ONE THAT LOOKS CHEAPEST, SO NAME IT: adding
     * `Draft`/`Negotiation`/`Signed` to a single shared map and relying on the record type files to
     * keep them off the sell side. Record-type picklist restriction is UI-ONLY and is not enforced
     * by Apex DML, so `advance()` ITSELF would then write an acquisition-only status onto a
     * disposition PSA — not a hand-crafted call, the ordinary Advance Stage button. Two maps is the
     * only shape in which that is unexpressible.
     *
     * ⚠ 'Executed' IS THE ONE VALUE STILL SHARED BY BOTH SEQUENCES, and it is deliberately the
     * TERMINAL of both — so it has no entry in either map and can never derive a hop on the wrong
     * side. That is what keeps the `Executed` handoff (see below) identical for both modules.
     *
     * 🔴 THIS OBJECT'S STAGE FIELD IS Negotiation_Status__c, NOT Stage__c — THE ONLY EXCEPTION
     * BESIDES THE NDA, AND FOR A COMPLETELY DIFFERENT REASON.
     * The NDA simply names its field Status__c. Here, Stage__c is a DERIVED PROJECTION that CANNOT
     * be written at all: the active before-save flow Contract_Review_Stage_Sync recomputes it from
     * Negotiation_Status__c on every create and update. A first attempt at this object mapped
     * Stage__c directly and produced a button that reported SUCCESS and changed nothing — the DML
     * committed, LastModifiedDate moved, and the flow had already replaced the value (measured
     * 2026-08-05 on CTR-0000). Driving the status is what makes the Path move, as a consequence —
     * and this projection is now PER RECORD TYPE too, because the flow maps status values and the
     * status values differ:
     *
     *   ACQUISITION (this map)          DISPOSITION (CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE)
     *   Draft       -> 'PSA Drafting'   Initial Draft -> 'PSA Drafting'
     *   Negotiation -> 'Review'         Negotiation   -> 'Review'
     *   Signed      -> 'Review'         Signed        -> 'Review'   🔴 SEE BELOW
     *   Executed    -> 'Contract        (no 'Executed' on this record type since 2026-08-21)
     *                   Execution'
     *
     * ⚠ THE DISPOSITION COLUMN READ `Revised -> 'Review'` / `Ready for Execution -> 'Review'` /
     * `Executed -> 'Contract Execution'` until 2026-08-21, when the user harmonised the record type.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ✅ A DECLARATIVE GAP OPENED AND WAS CLOSED IN THIS SAME WAVE — RECORDED BECAUSE THE APEX
     * SIDE CANNOT SEE IT AND NO APEX TEST WOULD HAVE CAUGHT IT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Contract_Review_Stage_Sync`'s decision routed BOTH its 'Contract Execution' branches on the
     * literal 'Executed'. A DISPOSITION PSA can no longer HOLD 'Executed', so for as long as that
     * flow was unchanged, a sell-side PSA sitting at its own terminal 'Signed' fell to the DEFAULT
     * connector and projected `Stage__c = 'Review'` — reading as still-in-review forever on every
     * surface driven by `Stage__c`.
     *
     * ⚠ IT NEVER BROKE THE HANDOFF, WHICH IS PRECISELY WHY IT WAS INVISIBLE.
     * `ContractExecutionService` keys on `Negotiation_Status__c`, never on `Stage__c`, so
     * `Disposition_Stage__c -> 'Closing'` fired correctly at 'Signed' throughout. The damage was
     * display-only, and `Stage__c` is a derived projection — writing it from Apex commits and is
     * silently discarded (measured 2026-08-05 on CTR-0000) — so nothing in this class or its tests
     * could have detected or repaired it.
     *
     * ✅ FIXED 2026-08-21 in the declarative half of this wave: a new `Is_Disposition_Signed` rule
     * testing `Negotiation_Status__c = 'Signed' AND Disposition__c != null`, routing to the EXISTING
     * `Set_Stage_Executed_Only` assignment. 🔴 NOTE THE DISCRIMINATOR IS THE PARENT LOOKUP, matching
     * `ContractExecutionService`'s two arms and its terminal split — the same choice, made
     * independently on both sides of the wave, and the reason the two halves agree about which rows
     * are sell-side. A blanket 'Signed' -> 'Contract Execution' edit would have been wrong for
     * ACQUISITION (where 'Signed' still precedes 'Executed' and is genuinely still in review) and
     * is explicitly NOT what was built.
     * ⚠ The 'Draft' row below (design collision C4) is a DIFFERENT, still-OPEN gap of the same
     * class. Do not read this ✅ as covering it.
     *
     * 🔴 THE 'Draft' ROW IS A DEPENDENCY ON A FLOW THIS CLASS DOES NOT OWN, AND IT FAILS QUIETLY.
     * `Contract_Review_Stage_Sync` is a before-save flow with an explicit rule for 'Initial Draft'
     * and a DEFAULT connector sending everything else to `Stage__c = 'Review'`. Until that flow
     * learns 'Draft' (design collision C4, owned by the declarative half of this pack), a brand-new
     * acquisition PSA shows the coarse 'Review' instead of 'PSA Drafting' — it deploys green,
     * nothing errors, and no Apex test can see it, because `Stage__c` is derived and writing it
     * from here commits and is silently discarded. The flow must learn 'Draft' while KEEPING
     * 'Initial Draft', which the disposition side still runs on.
     *
     * ⚠ TWO CONSEQUENCES WORTH KNOWING BEFORE EDITING EITHER MAP.
     * 1. The MIDDLE hop leaves the PATH UNCHANGED on both sides (Negotiation -> Signed on the
     *    acquisition map, Revised -> Ready for Execution on the disposition one; all four project
     *    to 'Review'), so the user sees a success toast and a stationary Path. That is correct, not
     *    a repeat of the defect above — the status genuinely advanced.
     * 2. The final hop is NOT just a status write, on EITHER map. It fires
     *    ContractReviewTrigger -> ContractExecutionService, and since Tranche 3C that service has
     *    TWO ARMS keyed on which parent lookup is populated:
     *      Opportunity__c set -> stamps the Opportunity (Contract Signed, Day 0) + 4 notifications
     *      Disposition__c set -> moves Disposition__c.Disposition_Stage__c to 'Closing'
     *    Adding or reordering entries around either terminal changes when the matching handoff
     *    fires.
     *    🔴 REWRITTEN 2026-08-21 — THE HOP IS NO LONGER "INTO 'Executed'" ON BOTH SIDES. This item
     *    read: "The final hop into 'Executed' is NOT just a status write, on EITHER map ... ⚠ Note
     *    the PREDECESSOR of that hop now differs by side ('Signed' vs 'Ready for Execution'), which
     *    is the one place the split changes the shape of the handoff rather than just its labels."
     *    The user harmonised Disposition_PSA to Initial Draft -> Negotiation -> Signed, so it is
     *    the TERMINAL ITSELF that differs by side now, not merely its predecessor:
     *      ACQUISITION  ... -> Signed -> Executed      handoff fires on 'Executed'
     *      DISPOSITION  ... -> Negotiation -> Signed   handoff fires on 'Signed'
     *    ⚠ AND 'Signed' IS ON BOTH SEQUENCES, mid-sequence on one and terminal on the other — so
     *    `ContractExecutionService` had to split its single `EXECUTED` constant into
     *    ACQUISITION_TERMINAL / DISPOSITION_TERMINAL. A shared constant repointed to 'Signed' would
     *    fire the acquisition handoff one hop early and re-date the whole Day-0 checklist. Read
     *    that class's two constants before touching either map's tail.
     *    ⚠ The sentence here used to say this hop "CREATES THE Transaction__c". That has been
     *    FALSE since 2026-08-05 — creation moved to ContractExecutionService
     *    .openTransactionsOnAboutToClose, keyed on Opportunity.StageName = 'About to Close'. The
     *    hop still stamps the Day-0 DATE that the later creation reads back, so the two remain
     *    coupled; they simply no longer run together.
     *
     * Seller Counter and Buyer Counter are deliberately absent: they are branch states, and the
     * user chose (2026-08-05) to record them by editing the field rather than with named buttons.
     * Adding them later means an explicit-target allow-list, exactly as the LOI has. Neither PSA
     * record type supplies an explicit target today, so advanceTo() is structurally unreachable on
     * this object — the split did not change that.
     */
    private static final Map<String, String> CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE =
        new Map<String, String>{
            'Draft' => 'Negotiation',
            'Negotiation' => 'Signed',
            'Signed' => 'Executed'
        };

    /**
     * Contract_Review__c.Negotiation_Status__c / Disposition_PSA — Initial Draft -> Negotiation ->
     * Signed. 'Signed' is terminal.
     *
     * ⚠ RETRACTED 2026-08-21 (user harmonisation, done directly in Setup). This map read:
     *     'Initial Draft' => 'Revised',
     *     'Revised' => 'Ready for Execution',
     *     'Ready for Execution' => 'Executed'
     * and its doc-comment asserted, verbatim: "🔴 THIS MAP IS THE OLD SHARED ONE, VERBATIM AND
     * UNCHANGED. Observation 7 is an ACQUISITION-ONLY change: `Disposition_PSA`'s own record type
     * file records that these four values are already exactly the states the client document names
     * for the sell-side PSA, and O3 of the requirements doc states as a HARD STOP that
     * `Initial Draft` / `Revised` / `Ready for Execution` remain ACTIVE on the field precisely
     * because this record type still runs on them."
     *
     * 🔴 THE "HARD STOP" WAS OVERTAKEN BY THE USER, NOT BY THIS CODE. Measured live on 2026-08-21
     * via the UI API (the ONLY channel that reports record-type-scoped picklist values on this
     * object — Metadata API retrieve, Tooling `RecordType.Metadata` and `PicklistValueInfo` all
     * return empty here, so their silence is not evidence):
     *
     *   Acquisition_PSA   Draft (default) | Negotiation | Signed | Executed     ← UNCHANGED
     *   Disposition_PSA   Initial Draft (default) | Negotiation | Signed
     *
     * `Revised`, `Ready for Execution` and `Executed` are all still ACTIVE on the master value set;
     * they are simply off this record type. Because `Negotiation_Status__c` is `restricted`, Apex
     * DML enforces that subset (see the class header's measurement block), so every entry in the
     * old map was writing a value the platform now refuses — the sell-side Advance Stage button was
     * dead at the first hop.
     *
     * ⚠ ZERO ROWS MIGRATED, VERIFIED AT THE TIME OF THE CHANGE rather than cited: a GROUP BY over
     * `Contract_Review__c` returned only Acquisition_PSA rows (4 Executed, 4 Draft, 1 Negotiation)
     * and NO Disposition_PSA rows at all. Re-run it before deploying; the LOI equivalent went stale
     * within an hour on the same day.
     *
     * 🔴 THE TWO SEQUENCES NOW OVERLAP ON 'Negotiation' AND 'Signed', where before observation 7
     * they shared only 'Executed'. So the "one value shared, and it is terminal on both" property
     * that several comments on this object lean on is GONE, and 'Signed' in particular is TERMINAL
     * on disposition and MID-SEQUENCE on acquisition. Nothing in this class regressed — it has
     * always resolved the sequence from the record type — but `ContractExecutionService` had to
     * split its terminal constant in the same wave, and that is where the real cost landed.
     *
     * ⚠ `DispositionStageEntryService`'s `DISPOSITION_PSA_INITIAL_STATUS = 'Initial Draft'` is this
     * map's entry point and is UNAFFECTED — 'Initial Draft' survives as the record type's default.
     * `DispositionStageEntryServiceTest` pins it. That is the thing to check first if this map is
     * ever re-pointed at its head rather than its tail.
     */
    private static final Map<String, String> CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE =
        new Map<String, String>{
            'Initial Draft' => 'Negotiation',
            'Negotiation' => 'Signed'
        };

    /**
     * 🔴 THE ACQUISITION LOI PATH IS NOT LINEAR (2026-08-05) — it branches at 'Submitted'.
     *
     * At 'Submitted' a broker either counters or accepts, so the deal driver gets two named buttons
     * instead of one generic Advance Stage: Negotiation and Signed. 'Signed' cannot be reached by
     * advance() from 'Submitted' — LOI_ACQUISITION_NEXT_STAGE derives 'Negotiation' — so it needs
     * an explicit target.
     *
     * ⚠ BOTH VALUES WERE RENAMED IN PLACE (observation 5, 2026-08-14): 'Counter' -> 'Negotiation'
     * and 'Completed' -> 'Signed'. The MEMBERSHIP is unchanged — same two stages, same branch, same
     * reasoning — so this is a rename and not a widening. The two bundles that send these literals,
     * c/loiMarkCountered and c/loiMarkCompleted, were repointed in the same change and still pass
     * them as hardcoded module constants, which is the property that makes this list meaningful.
     *
     * Membership is limited to the two stages that legitimately have no single derivable
     * predecessor from 'Submitted'. 'Under Review' and 'Submitted' are deliberately EXCLUDED — they
     * are derivable forward hops belonging to advance(), and listing them would let a direct Apex
     * call skip the approval gate the LOI page enforces at the review stage.
     *
     * 🔴 EXCLUDING 'Under Review' IS NOW LOAD-BEARING FOR A SECOND, NEWER REASON. That value is
     * SHARED with Disposition_LOI since observation 5 (it is the sell-side's second stage). Listing
     * it here would therefore not merely skip a hop — it would put a value BOTH record types carry
     * onto an acquisition-scoped allow-list, which is precisely the shape of leak the per-record-
     * type split exists to prevent. The two allow-lists remain fully disjoint even though the two
     * SEQUENCES no longer are, and that disjointness is what
     * acquisitionExplicitTargetListHasNotWidenedToTheUnion (renamed 2026-08-21 from
     * acquisitionLoiRefusesADispositionStageAsAnExplicitTarget) /
     * dispositionLoiRefusesTheAcquisitionExplicitTargets still measure. ⚠ Only the SECOND of those
     * two still measures a live leak; the first is a widening control. See both test comments.
     *
     * 🔴 THIS SET WAS OBJECT-LEVEL UNTIL TRANCHE 3B AND IS NOW PER RECORD TYPE, AND SINCE
     * 2026-08-21 THE SPLIT IS THE *ONLY* THING STOPPING A LEAK ONTO A SALE. An object-level list
     * would let advanceTo(dispositionLoiId, 'Signed') write this set's values onto a sale.
     * ⚠ RETRACTED 2026-08-21, TWO SEPARATE ERRORS IN ONE SENTENCE. It read: "Neither value exists
     * on Disposition_LOI's value set, and Apex DML does not enforce record-type picklist
     * restriction — so an object-level list would let advanceTo(dispositionLoiId, 'Signed') write
     * an acquisition-only stage onto a sale."
     *   1. BOTH VALUES NOW EXIST ON THAT VALUE SET. The user's new sell-side sequence is
     *      Received -> Under Review -> Negotiation -> Signed, so 'Negotiation' and 'Signed' are
     *      legal disposition stages that advance() derives.
     *   2. "Apex DML does not enforce record-type picklist restriction" IS FALSE for a restricted
     *      value set — MEASURED 2026-08-21, see the class header. `Stage__c` IS restricted.
     * 🔴 THOSE TWO ERRORS USED TO CANCEL OUT AND NOW DO NOT, WHICH IS WHY THIS MATTERS. Before the
     * change the belief "DML won't stop it" was wrong but harmless, because the record type did not
     * carry the values and DML WOULD have stopped it. After the change the record type DOES carry
     * them, so DML will NOT stop it — and the sentence that was accidentally safe is now the exact
     * description of a real, reachable write. The SPLIT IS NOT WEAKENED BY THIS; it is the only
     * control left. See the next paragraph.
     *
     * 🔴 THE LEAK GOT WORSE, NOT BETTER, ON 2026-08-21 — THIS IS THE HAZARD NOTE THE CLASS HEADER
     * CROSS-REFERENCES. 'Signed' was already "a particularly bad value to leak onto a sale" because
     * the word is plausible on either side of a deal (the pre-observation-5 'Completed' at least
     * read as vocabulary from the other module). It is now WORSE THAN PLAUSIBLE — IT IS CORRECT
     * SELL-SIDE VOCABULARY. A hand-crafted advanceTo(dispositionLoiId, 'Signed'), carrying the
     * literal that the ACQUISITION quick action LOI__c.Mark_Completed hardcodes, would previously
     * have been REFUSED BY THE PLATFORM — 'Signed' was not on Disposition_LOI's value set and
     * `Stage__c` is a restricted picklist, so DML raised INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST
     * (measured 2026-08-21; see the class header). Today it would LAND: a value the record type
     * carries, the Path renders and every reader accepts — while skipping 'Negotiation' entirely.
     * ⇒ A PLATFORM-LEVEL BACKSTOP WAS REMOVED BY THIS CHANGE AND NOBODY ASKED FOR IT TO BE. That is
     * not an argument against the change (the user's sequence is right); it is the reason this
     * allow-list stopped being belt-and-braces.
     * ⇒ THE PER-RECORD-TYPE ALLOW-LIST IS THE ONLY REMAINING DETECTION. Do not move this set back
     * to object level; do not "harmonise" it with the disposition config on the grounds that both
     * record types now carry these two values. Pinned by
     * dispositionLoiRefusesTheAcquisitionExplicitTargets, which is now the ONLY cross-type
     * allow-list guard in this class with real content on LOI__c.
     *
     * ⚠ THE SENTENCE THAT USED TO END THIS BLOCK — "the disposition type supplies NO explicit
     * targets at all, which makes advanceTo() structurally unreachable for it" — WAS TRUE UNTIL THE
     * 3B CLOSE-OUT, WAS FALSE FROM THEN UNTIL 2026-08-21, AND IS TRUE AGAIN NOW. It is restored,
     * not resurrected in ignorance: the negotiation loop that made it false was retired with the
     * user's decision to move counter rounds onto Counter History. The intervening retraction ("
     * Disposition_LOI has its own two-value set (LOI_DISPOSITION_EXPLICIT_TARGETS, the negotiation
     * loop). The leak is therefore live in BOTH directions and both are tested.") is recorded here
     * so the git history reads correctly and so nobody re-adds the set believing it was lost.
     */
    private static final Set<String> LOI_ACQUISITION_EXPLICIT_TARGETS = new Set<String>{
        'Negotiation',
        'Signed'
    };

    /**
     * Underwriting__c.Stage__c.
     *
     * 🔴 THE 'In Progress' -> 'Approved' HOP IS DELIBERATELY ABSENT. IT IS NOT AN OVERSIGHT.
     *
     * 'Approved' is owned by the PRINCIPAL APPROVAL PROCESS. A naive "same as the other objects"
     * copy would put Approved one button-click away and bypass the approval entirely — the deal
     * would show a principal-approved underwriting that no principal ever saw. The already-deployed
     * `Underwriting__c.Submit_for_Approval` quick action (OpportunityApprovalController ->
     * OpportunityApprovalService) is the route from 'In Progress'.
     *
     * 🔴 THIS MAP AND ITS NO_NEXT_STEP_HINTS ENTRY ARE CORRECT AS-IS AND WERE DELIBERATELY NOT
     * TOUCHED on 2026-08-28 when the principal approval moved onto Underwriting__c. Both key on
     * Underwriting__c.Stage__c (via `config.label + '|' + currentStage`), NOT on
     * Opportunity.StageName, so the Opportunity-side change cannot reach them. The 'In Progress'
     * gap and the hint's "Use Submit for Approval" wording became MORE accurate, not less: that
     * action now submits THIS record rather than its parent deal.
     *
     * From 'In Progress' this service therefore refuses, with wording that NAMES the real route
     * (see NO_NEXT_STEP_HINTS) so the omission reads as a rule rather than a bug.
     *
     * ⚠ RETRACTED 2026-08-28 — TWO CLAIMS ABOVE WENT STALE, kept verbatim so they are not
     * re-derived from the code:
     *
     *   1. "…and ApprovalAuditService stamps Stage__c = 'Approved' on principal sign-off."
     *      NO LONGER TRUE. That block was DELETED from ApprovalAuditService; the writer is now the
     *      Underwriting_Approval process's own finalApprovalActions on this very record.
     *      ApprovalAuditService still runs, but only to stamp the APPROVER and TIMESTAMP onto the
     *      parent deal. 'Approved' is still not reachable from this map — only the writer changed.
     *
     *   2. "Exactly the same shape as StageAdvanceService.NEXT_STAGE deliberately omitting
     *      'Underwriting' for exactly the same reason."
     *      NO LONGER TRUE. StageAdvanceService.NEXT_STAGE now CONTAINS 'Underwriting' => 'LOI':
     *      Initiate LOI became a plain stage write, gated by a validation rule instead of by an
     *      approval submission. The two maps no longer mirror each other and must not be
     *      "reconciled" — the omission HERE is still deliberate and is unrelated to that change.
     *
     * ⚠ The stamp warning below still applies, to the approval's field update rather than to Apex:
     * any future validation rule on Underwriting__c.Stage__c MUST explicitly permit the transition
     * into 'Approved', or the Path simply never reaches Approved (design doc §7.3). It now fails
     * inside an approval-process field update rather than inside a DmlException-swallowing
     * try/catch — still silent from the user's point of view.
     */
    private static final Map<String, String> UNDERWRITING_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'In Progress',
        // 'In Progress' => (no entry) — reaching 'Approved' is the approval process's job.
        'Approved' => 'Completed'
    };

    /**
     * Construction_Feasibility_Review__c.Stage__c —
     * Requested -> Site Visit -> Condition Assessment -> Cost Estimate -> Share Opinion -> Completed.
     */
    private static final Map<String, String> CONSTRUCTION_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Site Visit',
        'Site Visit' => 'Condition Assessment',
        'Condition Assessment' => 'Cost Estimate',
        'Cost Estimate' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Development_Feasibility_Review__c.Stage__c —
     * Requested -> Feasibility analysis -> Vendor proposals -> Share Opinion -> Completed.
     * ⚠ 'Feasibility analysis' and 'Vendor proposals' are lower-cased on their second word in the
     * picklist metadata. The literals here match the org exactly; "correcting" the casing yields a
     * map that silently never matches.
     */
    private static final Map<String, String> DEVELOPMENT_REVIEW_NEXT_STAGE = new Map<String, String>{
        'Requested' => 'Feasibility analysis',
        'Feasibility analysis' => 'Vendor proposals',
        'Vendor proposals' => 'Share Opinion',
        'Share Opinion' => 'Completed'
    };

    /**
     * Transaction__c.Stage__c —
     * Open Contract -> Due Diligence -> Closing Prep -> Post-Closing -> Closed.
     * 'Closed' is terminal and therefore has NO entry.
     *
     * ⚠ RENAMED 2026-08-28 (USER, IN SETUP): the terminal value was 'Closed Won' and is now
     * 'Closed' — BOTH the label AND the API name changed, and Salesforce migrated the existing
     * rows. `Stage__c` is a RESTRICTED picklist and restriction on this project is a MEASURED
     * DML-enforced fact, so the stale literal was not cosmetic: the Transaction record page still
     * renders the Advance Stage button at 'Post-Closing' (its visibility keys on that unchanged
     * value) and the write it produced was rejected with
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. Every REMAINING 'Closed Won' in this class (see the
     * NDA gate narration around lines 802 and 815) belongs to `Opportunity.StageName` — a
     * DIFFERENT field on a DIFFERENT object — and must stay exactly as it is.
     *
     * 🔴 THE ORDER IS A USER DECISION, NOT A DERIVATION, AND IT IS THE ONE THING HERE THAT CANNOT
     * BE WRONG QUIETLY. The picklist's element order and the Transaction Path's step order both
     * read `… Closing Prep -> Post-Closing -> Closed`, but the Path's own step TEXT argues the
     * other way — 'Closed' says "Transaction closed and funded" while 'Post-Closing' says
     * "Complete the post-closing checklist and file recorded documents", and funding precedes
     * post-closing work in a real deal. Whichever order is configured becomes the ONLY order the
     * button offers, with nothing to signal a mistake. The sequence above was CONFIRMED BY THE
     * USER at Gate 1 on 2026-08-12 against the org's live picklist. Do not "correct" it from the
     * step text; re-ask.
     *
     * ⚠ THERE IS NO EXPLICIT-TARGET ALLOW-LIST FOR THIS OBJECT, DELIBERATELY. The path is a
     * straight line — no branch, no off-ramp, no loop — so every hop is derivable and advance()
     * reaches all of them. An empty allow-list makes advanceTo() STRUCTURALLY UNREACHABLE here,
     * which is the strongest available guarantee that a hand-crafted call cannot skip Due
     * Diligence and land a deal on 'Closed'. Adding a target is a real widening: do it only
     * when a named quick action needs a stage advance() cannot derive.
     *
     * ⚠ `Transaction__c` HAS NO RECORD TYPES, so this is a SINGLE-SEQUENCE config (see
     * CONFIG_BY_TYPE) and there is no second map to keep in step. If it is ever given record
     * types, TransactionSelector.selectStageRequiredById must start selecting RecordTypeId in the
     * same change — omitting it degrades SILENTLY to this sequence rather than failing.
     *
     * ⚠ `Closed Lost` DOES NOT EXIST on this picklist (five restricted values, verified in the org
     * 2026-08-12). `lwc/activeTransactionsList` carries a dead pill-map entry for it; that is a
     * cosmetic leftover, not a stage this map is missing.
     */
    private static final Map<String, String> TRANSACTION_NEXT_STAGE = new Map<String, String>{
        'Open Contract' => 'Due Diligence',
        'Due Diligence' => 'Closing Prep',
        'Closing Prep' => 'Post-Closing',
        'Post-Closing' => 'Closed'
    };

    /**
     * Disposition__c.Disposition_Stage__c / On_Market — FOUR MANUAL HOPS OUT OF AN ELEVEN-STAGE
     * PATH (design D-2, 2026-08-19).
     *
     * The full on-market path is:
     *   Disposition Readiness -> BOV Outreach -> Broker Selection -> NDA -> Release Materials ->
     *   Active Listing -> Offer Selection -> LOI -> PSA -> Closing -> Sale Closes
     *
     * 🔴 THIS MAP HOLDS ONLY THE HOPS A HUMAN OWNS. The class header lists which owner has each of
     * the other seven; do not "complete" this map from the path. Every value omitted below is
     * omitted because adding it would put an approval-owned or service-owned transition one
     * Advance-Stage click away — the same reason `UNDERWRITING_NEXT_STAGE` deliberately has no
     * `In Progress` entry, and the same shape `StageAdvanceService.NEXT_STAGE` uses to omit
     * `Underwriting`.
     *
     * The four that ARE here, and why each is genuinely manual:
     *   `Broker Selection -> NDA`              ON-MARKET ONLY. The broker has been approved on the
     *                                          BOV submission; issuing the buyer NDA is a decision
     *                                          a human makes. 🔴 On OFF-market this same key is
     *                                          approval-owned (`Broker_Selection_Approval`) and is
     *                                          therefore ABSENT from the other map.
     *   `NDA -> Release Materials`             gated by `All_NDAs_Signed_Before_Progression`, whose
     *                                          message surfaces through `setStage`. The gate is the
     *                                          control; the click is the decision.
     *   `Release Materials -> Active Listing`  ON-MARKET ONLY. Off-market has no listing stage at
     *                                          all — it collects offers AT `Release Materials`.
     *   `LOI -> PSA`                           the negotiation concluded; drafting the PSA is a
     *                                          human step on both record types.
     *
     * ⚠ `Sale Closes` IS TERMINAL AND HAS NO ENTRY, which is ordinary. `PSA` ALSO has no entry and
     * that is NOT ordinary: `PSA -> Closing` is written by `ContractExecutionService` when the
     * sell-side Contract Review is Executed. A hint names it, because otherwise the refusal at PSA
     * reads exactly like the terminal one at Sale Closes.
     */
    private static final Map<String, String> DISPOSITION_ON_MARKET_NEXT_STAGE =
        new Map<String, String>{
            'Broker Selection' => 'NDA',
            'NDA' => 'Release Materials',
            'Release Materials' => 'Active Listing',
            'LOI' => 'PSA'
        };

    /**
     * Disposition__c.Disposition_Stage__c / Off_Market — TWO MANUAL HOPS OUT OF A NINE-STAGE PATH.
     *
     * The full off-market path is the on-market one minus `BOV Outreach` and `Active Listing`:
     *   Disposition Readiness -> Broker Selection -> NDA -> Release Materials -> Offer Selection ->
     *   LOI -> PSA -> Closing -> Sale Closes
     *
     * 🔴 IT IS THE ON-MARKET MAP MINUS TWO ENTRIES, AND BOTH OMISSIONS ARE THE POINT:
     *   `Broker Selection -> NDA`             OMITTED because on a direct sale that transition is
     *                                         owned by `Broker_Selection_Approval` (whose entry
     *                                         criteria are `Broker Selection` AND record type Off
     *                                         Market), which sets the D-1 semaphore and lets
     *                                         `DispositionApprovalAdvanceService` write the stage.
     *                                         Listing it here would be a one-click approval bypass.
     *   `Release Materials -> Active Listing` OMITTED because `Active Listing` IS NOT ON THIS
     *                                         RECORD TYPE'S VALUE SET, so a shared map would have
     *                                         `advance()` ITSELF try to move a direct sale onto a
     *                                         broker-listing stage it does not carry — exactly the
     *                                         failure the per-record-type split exists to make
     *                                         unexpressible (see CONTRACT_REVIEW_ACQUISITION_NEXT_-
     *                                         STAGE's header for the same argument on that object).
     * ⚠ RETRACTED 2026-08-21 — the omission bullet above used to justify itself with "Apex DML does
     * NOT enforce record-type picklist restriction, so a shared map would ... PARK a direct sale on
     * a broker-listing stage". That mechanism is false for a `restricted` value set (class header,
     * measured). 🔴 `Disposition__c.Disposition_Stage__c` IS `restricted` but has NOT itself been
     * measured, so treat the platform refusal as UNVERIFIED here: on the measured fields the write
     * is refused with an opaque `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` rather than parked. The
     * omission stands either way — a stage `advance()` should never offer must not be in the map,
     * whether the consequence is a bad write or a platform error the user cannot act on.
     *
     * ⚠ `Release Materials` IS THE OFFER-COLLECTION STAGE ON THIS TYPE, so it has NO hop at all
     * here: it leaves via `DispositionApprovalService.selectOffer`. The hint says so — a stage that
     * is mid-path and refuses is the case a user is most likely to read as broken.
     */
    private static final Map<String, String> DISPOSITION_OFF_MARKET_NEXT_STAGE =
        new Map<String, String>{
            'NDA' => 'Release Materials',
            'LOI' => 'PSA'
        };

    /**
     * Stage-specific wording for a refused advance, keyed `<StageConfig.label>|<currentStage>`.
     *
     * Keyed on the config's own label rather than on the SObjectType so no key depends on
     * SObjectType.toString(), which is undocumented.
     *
     * Only populated where the absence of a hop is a RULE rather than the end of the path. Without
     * this, the Underwriting refusal reads exactly like a terminal stage and looks like a defect;
     * with it, the message names the action that actually performs the transition.
     *
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 IT IS STILL NOT RECORD-TYPE-AWARE, AND ON 2026-08-19 THAT STOPPED BEING FREE.
     * ══════════════════════════════════════════════════════════════════════════
     * ⚠ THIS BLOCK USED TO READ: "DELIBERATELY NOT record-type-aware. THIS MAP HAS EXACTLY ONE ENTRY
     * AND IT IS ON Underwriting__c, an object with NO record types at all — so today the question
     * cannot arise." Both halves are now FALSE. The map has EIGHT entries and seven of them are on
     * `Disposition__c`, an object with TWO record types whose two sequences SHARE most of their
     * stage values. The instruction the old block gave — CHECK, DO NOT ASSUME — was written for
     * exactly this moment, so it was followed rather than quoted, and the check is recorded here.
     *
     * 🔴 THE PROPERTY THAT MAKES A SHARED KEY SAFE IS NARROW AND MUST BE RE-CHECKED PER ENTRY:
     * A HINT IS ONLY EVER CONSULTED WHERE THERE IS NO HOP. So a key on a stage that BOTH record
     * types carry is safe if EITHER (a) neither type has a hop from it and one wording is correct
     * for both, OR (b) exactly one type has a hop, in which case the hint fires for the other type
     * alone. It is UNSAFE only where both types lack a hop AND need DIFFERENT wording — and there
     * is no such stage on this object today. Entry by entry:
     *
     *   `Disposition Readiness`  neither type has a hop; ONE owner (`Sale_Decision_Approval`) on
     *                            both. Case (a). One wording, correct for both.
     *   `BOV Outreach`           ON-MARKET VALUE ONLY. Cannot collide.
     *   `Broker Selection`       🔴 CASE (b), AND THE ONE TO UNDERSTAND. On-market HAS a hop
     *                            (`-> NDA`), so the hint is never consulted there; off-market has
     *                            none, so it fires for off-market alone — and its wording names
     *                            `Broker_Selection_Approval`, which is the off-market owner. If
     *                            anyone ever adds `Broker Selection -> NDA` to the off-market map
     *                            (they must not — see that map) this hint goes dead silently.
     *   `Release Materials`      CASE (b) again, mirrored: on-market has a hop
     *                            (`-> Active Listing`), off-market has none, so this fires for
     *                            off-market alone and names Select Offer.
     *   `Active Listing`         ON-MARKET VALUE ONLY. Cannot collide.
     *   `Offer Selection`        neither type has a hop; ONE owner (`Offer_Selection_Approval`).
     *                            Case (a).
     *   `PSA`                    neither type has a hop; ONE owner (`ContractExecutionService`, on
     *                            PSA execution). Case (a).
     *   `Sale Closes`            NO ENTRY, deliberately — it is genuinely terminal on both types,
     *                            so the default "there is no next step available from the Sale
     *                            Closes stage" is correct wording and a hint would be noise.
     *
     * ⇒ BEFORE ADDING ANY NINTH ENTRY, run that same three-case check. The moment one is UNSAFE,
     * widen the key to `<label>|<recordTypeKey>|<currentStage>` rather than adding a second map.
     *
     * 🔴 THE SAFETY ARGUMENT FOR LOI__c CHANGED ON 2026-08-14 AND IS NOW WEAKER. This block used to
     * read: "NDA__c: the only shared stage values ('Sent', 'Signed') have a hop or are terminal on
     * BOTH record types, so neither reaches this map. LOI__c: the two value sets are fully
     * DISJOINT, so a key can only ever match one record type's stage in the first place." ⚠ THE NDA
     * HALF HELD UNTIL 2026-08-16 AND NO LONGER DOES: the acquisition reorder made 'Sent' TERMINAL on
     * Acquisition_NDA while it remains a HOP on Disposition_NDA, and made 'Signed' a HOP on
     * Acquisition_NDA while it remains TERMINAL on Disposition_NDA — so neither shared value has the
     * same hop-or-terminal status on both types any more, which is exactly the premise that sentence
     * rested on. What it buys, as it happens, is safety rather than risk: a hint fires ONLY where
     * there is no hop, so `NDA|Sent` could now fire on the acquisition type alone and `NDA|Signed` on
     * the disposition type alone — one wording, one record type, no collision. Before the reorder
     * `NDA|Signed` would have fired on BOTH.
     *
     * 🔴 REVERSED 2026-08-27 — THE SENTENCE IMMEDIATELY ABOVE HAS COME BACK TRUE, AND THE NDA HALF
     * IS NOW THE *UNSAFE* CASE RATHER THAN THE SAFE ONE. The user removed 'Sent' from the
     * Acquisition_NDA record type, so 'Signed' is terminal on BOTH NDA record types again and
     * neither map has an entry for it. A hint keyed `NDA|Signed` would therefore fire on a PURCHASE
     * and on a SALE with one wording — exactly the collision the LOI paragraph below forbids.
     * `NDA|Sent` is the mirror and is now simply dead: 'Sent' is off the acquisition value set and
     * has a HOP on the disposition side, so no NDA can ever reach a hint keyed on it.
     * ⇒ THERE IS NO SUCH KEY TODAY, WHICH IS THE ONLY REASON THIS IS A NOTE AND NOT A DEFECT — the
     * same standing this map's LOI paragraph has had since 2026-08-14. BEFORE ADDING ANY NDA ENTRY
     * HERE, widen the key to `<label>|<recordTypeKey>|<currentStage>` rather than adding a second
     * map. The instruction is still the LOI one below: check, do
     * not assume. The LOI half is FALSE — observation 5 made 'Under Review' a stage on BOTH
     * LOI record types, so a hint keyed `LOI|Under Review` would now fire on a purchase AND a sale
     * with one wording. There is no such key today, which is the only reason this is a note rather
     * than a defect.
     *
     * ⇒ BEFORE ADDING ANY LOI ENTRY HERE, widen the key to
     * `<label>|<recordTypeKey>|<currentStage>` rather than adding a second map. Contract_Review__c
     * needs no such care: observation 7 left its two sequences sharing only 'Executed', which is
     * terminal on both and therefore takes the default wording correctly on either side.
     */
    private static final Map<String, String> NO_NEXT_STEP_HINTS = new Map<String, String>{
        'Underwriting|In Progress' =>
            'Underwriting moves to Approved through the principal approval, not this action. '
            + 'Use Submit for Approval.',
        // ── Disposition__c, 2026-08-19. SEVEN entries, because seven of the eleven stages are
        // owned by an approval or by another service — see DISPOSITION_ON_MARKET_NEXT_STAGE. Each
        // NAMES THE REAL OWNER, so the refusal reads as a rule and points at the control that
        // actually performs the transition. Acceptance criterion AC-4 tests exactly this.
        'Disposition|Disposition Readiness' =>
            'This disposition advances when the Sale Decision approval is approved. '
            + 'Use Submit for Approval.',
        'Disposition|BOV Outreach' =>
            'This disposition advances when the selected broker is approved. '
            + 'Choose a broker in the BOV matrix, then use Submit Selected Broker.',
        'Disposition|Broker Selection' =>
            'An off-market disposition advances when the Broker Selection approval is approved. '
            + 'Use Submit for Approval.',
        'Disposition|Release Materials' =>
            'This disposition advances when an offer is selected. Use Select Offer.',
        'Disposition|Active Listing' =>
            'This disposition advances when an offer is selected. Use Select Offer.',
        'Disposition|Offer Selection' =>
            'This disposition advances when the selected offer is approved.',
        // ⚠ REPOINTED 2026-08-21. This read '...Advance the Contract Review to Executed.' —
        // instructions for a value the Disposition_PSA record type no longer carries, so the hint
        // was telling the user to do something the platform would refuse. The sell-side PSA
        // terminal is now 'Signed' (ContractExecutionService.DISPOSITION_TERMINAL).
        // 🔴 THIS KEY IS SAFE TO REPOINT BECAUSE IT IS ALREADY SCOPED: the key is the DISPOSITION
        // object at its PSA stage, so no acquisition surface reads it. Contrast the LOI entries
        // this map's own header forbids, which would need the record type folded into the key.
        'Disposition|PSA' =>
            'This disposition advances to Closing when the sell-side PSA is executed. '
            + 'Advance the Contract Review to Signed.'
    };

    /**
     * ONE record type's stage sequence: the permission gate, the derived-hop map, and the explicit
     * targets advanceTo() may write for that record type and no other.
     *
     * These three travel together on purpose. They are the only pieces of configuration that
     * differ per record type, and separating them into parallel maps keyed by developer name would
     * let one be extended without the others — which is exactly the half-finished shape this
     * change exists to avoid (a record-type-aware nextStage with an object-wide allow-list, or an
     * object-wide gate).
     *
     * ⚠ THE GATE MOVED HERE FROM StageConfig ON 2026-08-09, and that is a real behavioural change,
     * not a refactor: `NDA__c`'s two record types now answer to two DIFFERENT personas — and since
     * Tranche 3C so do `Contract_Review__c`'s, which is the case that PROVES `gate` and `nextStage`
     * are INDEPENDENT axes: those two types share one `nextStage` map object and differ ONLY in
     * this field. The three record-type-free objects each name their gate exactly once, so nothing
     * about them changed.
     */
    private class StageTypeConfig {
        /** The permission gate this RECORD TYPE's stage actions answer to. */
        private final StageActionGate gate;
        private final Map<String, String> nextStage;
        /**
         * The ONLY stages advanceTo() will write for this record type. Empty for a linear sequence,
         * which makes advanceTo() structurally unreachable there.
         */
        private final Set<String> explicitTargets;

        /** Linear sequence: no branch, so no explicit target is permitted at all. */
        private StageTypeConfig(StageActionGate gate, Map<String, String> nextStage) {
            this(gate, nextStage, new Set<String>());
        }

        private StageTypeConfig(
            StageActionGate gate,
            Map<String, String> nextStage,
            Set<String> explicitTargets
        ) {
            this.gate = gate;
            this.nextStage = nextStage;
            this.explicitTargets = explicitTargets;
        }
    }

    /**
     * Per-OBJECT configuration: display label, stage field API name, and the per-RECORD-TYPE
     * sequences (each of which carries its own permission gate).
     *
     * ⚠ THE GATE IS NO LONGER HERE. It moved onto StageTypeConfig on 2026-08-09 when
     * DISPOSITION_DRIVER was wired, because `NDA__c`'s two record types answer to two different
     * personas. Nothing on this class is record-type-invariant except the label and the stage
     * FIELD — and the field genuinely is: a record type cannot change which column a stage lives
     * in.
     */
    private class StageConfig {
        private final String label;
        private final String stageField;
        /**
         * The key used when the row's record type is null or Master.
         *
         * 🔴 INVARIANT: it MUST be a key of byRecordType. Both constructors below satisfy it by
         * construction, and the config is a single static literal a reviewer reads in one screen —
         * so this is deliberately not re-checked at runtime, which would add an unreachable branch
         * to a class whose coverage is otherwise all live code. A violation surfaces immediately as
         * a NullPointerException inside sequenceFor(), on the first click, for every record.
         */
        private final String defaultTypeKey;
        /** Sequences keyed by record type DEVELOPER NAME, or by SINGLE_TYPE_KEY when invariant. */
        private final Map<String, StageTypeConfig> byRecordType;

        /** An object whose sequence does not vary by record type. */
        private StageConfig(
            String label,
            String stageField,
            StageTypeConfig onlySequence
        ) {
            this(label, stageField, SINGLE_TYPE_KEY,
                new Map<String, StageTypeConfig>{ SINGLE_TYPE_KEY => onlySequence });
        }

        private StageConfig(
            String label,
            String stageField,
            String defaultTypeKey,
            Map<String, StageTypeConfig> byRecordType
        ) {
            this.label = label;
            this.stageField = stageField;
            this.defaultTypeKey = defaultTypeKey;
            this.byRecordType = byRecordType;
        }
    }

    /**
     * The whole feature's configuration, keyed by SObjectType TOKEN (not by name String) so every
     * key is compile-checked and a renamed object breaks the build instead of silently disabling
     * the action.
     *
     * ⚠ NDA__c's stage field is `Status__c` and Contract_Review__c's is `Negotiation_Status__c`;
     * the other four use `Stage__c`. That difference is the reason this config carries the field
     * name per object rather than hardcoding `Stage__c`.
     *
     * ✅ ADDING LOI__c's TWO RECORD TYPES (Tranche 3B) AND THEN Contract_Review__c's (Tranche 3C)
     * WERE CONFIG ADDITIONS, NOT REFACTORS — EXACTLY AS THIS NOTE PREDICTED, BOTH TIMES. 3B cost
     * four edits (the five-argument constructor, two sequences, defaultTypeKey, RecordTypeId on
     * LoiSelector). 3C cost THREE: the five-argument constructor, the two record-type constants,
     * and RecordTypeId on ContractReviewSelector.selectStageRequiredById. It needed NO new sequence
     * at all — both its types pointed at ONE map by reference — which is the case this seam was
     * never explicitly designed for and absorbed anyway.
     *
     * ✅ AND A THIRD TIME, THE HARDEST ONE, IN THE OPPOSITE DIRECTION. Observation 7 (2026-08-14)
     * UNDID 3C's shared map: Acquisition_PSA and Disposition_PSA now hold two DIFFERENT sequences.
     * That cost exactly TWO edits below — renaming one map and adding a second — plus the
     * defaultTypeKey re-argument in the Contract_Review__c entry. So the seam absorbed a
     * convergence AND a divergence at the same cost.
     *
     * ✅ AND A FOURTH TIME, 2026-08-19, ADDING AN OBJECT RATHER THAN RE-SHAPING ONE.
     * `Disposition__c` cost THREE edits below the maps — this entry, the two record-type constants,
     * and a `load()` branch — plus one NEW selector method. It is the first entry whose sequences
     * are a deliberate SUBSET of the object's path (see the class header), and the seam did not
     * notice: a map with four entries out of eleven behaves exactly like a map with all of them,
     * because `advance()` has always refused a key it does not hold.
     *
     * ⚠ THE CLAIM THAT USED TO CLOSE THIS BLOCK IS NOW FALSE BY EXACTLY ONE METHOD AND IS CORRECTED
     * RATHER THAN DELETED, because it was the seam's headline property. RETRACTED, verbatim: "NOT
     * ONE LINE BELOW THIS MAP HAS CHANGED SINCE 3A — advance(), advanceTo(), sequenceFor(),
     * gateFor(), load() and setStage() are byte-identical, through three record-type changes and
     * one full value-set rename."
     *
     * WHAT IS TRUE NOW: `advance()`, `advanceTo()`, `sequenceFor()`, `gateFor()` and `setStage()`
     * are STILL byte-identical to their 3A originals, through four record-type changes and one full
     * value-set rename. `load()` has gained one two-line branch per object added — four times now —
     * which is the ONE cost this design consciously accepted in exchange for having zero dynamic
     * SOQL (see the LAYERING block). That was never claimed to be free; the sentence above simply
     * overstated it by omitting the branch.
     */
    private static final Map<Schema.SObjectType, StageConfig> CONFIG_BY_TYPE =
        new Map<Schema.SObjectType, StageConfig>{
            // ⚠ FOUR record-type-aware objects since 2026-08-19 (NDA__c here, LOI__c,
            // Contract_Review__c and Disposition__c below). THREE of the four split their two types
            // across DIFFERENT PERSONAS; Disposition__c does NOT — it is disposition-only and its
            // split is about the path. Do not read the first three as a rule. defaultTypeKey is the
            // ACQUISITION sequence on both so Master / pre-migration rows keep advancing — and,
            // note, keep answering to DEAL_DRIVER, which is the conservative fallback: it grants
            // the disposition buttons to nobody new during the deploy window rather than to
            // everybody.
            NDA__c.SObjectType => new StageConfig(
                'NDA', 'Status__c',
                RT_ACQUISITION_NDA,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_NDA => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER, NDA_ACQUISITION_NEXT_STAGE),
                    RT_DISPOSITION_NDA => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER,
                        NDA_DISPOSITION_NEXT_STAGE, NDA_DISPOSITION_EXPLICIT_TARGETS)
                }),
            // Tranche 3B (D6). ⚠ The comment that used to open this block — "The two stage sets are
            // DISJOINT, unlike NDA__c's" — was already false from observation 5 ('Under Review')
            // and is emphatically false from 2026-08-21: the two sets now share 'Under Review',
            // 'Negotiation' and 'Signed'. The record type is what resolves the sequence, and that
            // has never depended on disjointness; see the class header. defaultTypeKey is
            // Acquisition_LOI: every LOI in the org today is buy-side by construction, because the
            // Disposition__c lookup arrives in this tranche.
            LOI__c.SObjectType => new StageConfig(
                'LOI', 'Stage__c',
                RT_ACQUISITION_LOI,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_LOI => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER,
                        LOI_ACQUISITION_NEXT_STAGE, LOI_ACQUISITION_EXPLICIT_TARGETS),
                    // 🔴 TWO-ARG CONSTRUCTOR, 2026-08-21 — DELIBERATE STRENGTHENING, NOT AN
                    // OMISSION. It supplies an EMPTY explicit-target set, which makes advanceTo()
                    // STRUCTURALLY UNREACHABLE on Disposition_LOI: there is no target it will
                    // write, so no hand-crafted call can skip a hop or park a sale on 'Signed'.
                    // ⚠ THIS LINE USED TO PASS LOI_DISPOSITION_EXPLICIT_TARGETS (a three-arg call)
                    // and carried the comment "The sell-side path is a LOOP, not a line: its two
                    // explicit targets are the two edges of the Countered by DPEG <-> Counter
                    // Received from Buyer cycle, which a Map<String,String> cannot hold." The loop
                    // is retired — counter rounds moved to Counter History (Counter_Offer__c /
                    // c/loiCounterOffer) — the constant is deleted, and the sequence is a line.
                    // The refusal of 'Negotiation'/'Signed' here is now produced by the EMPTY set
                    // rather than by a non-empty set that happened to exclude them. Same outcome,
                    // stronger reason.
                    RT_DISPOSITION_LOI => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER,
                        LOI_DISPOSITION_NEXT_STAGE)
                }),
            // ⚠ 'Negotiation_Status__c', NOT 'Stage__c' — Stage__c is derived and unwritable here.
            // See CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE above before changing this (renamed from
            // CONTRACT_REVIEW_NEXT_STAGE when the shared map was split on 2026-08-14).
            //
            // ✅ TRANCHE 3C, 2026-08-09 — SPLIT EXACTLY AS THE NOTE THAT USED TO SIT HERE
            // PREDICTED, on the GATE axis only. 🔴 SPLIT AGAIN 2026-08-14 (observation 7) on the
            // SEQUENCE axis, which is the axis 3C explicitly did NOT need: the two types now point
            // at TWO DIFFERENT MAPS, not one shared object. The comment that used to end this block
            // — "Same map OBJECT, not a copy — divergence is unexpressible by construction" — is
            // GONE, not merely reworded. Divergence is now the requirement.
            //
            // 🔴 THE TWO StageTypeConfigs NOW DIFFER IN BOTH ARGUMENTS. Neither may be collapsed:
            //   - the GATE, because a disposition persona does not hold Acquisition_Deal_Actions
            //     (the two module permissions are carried by disjoint sets, measured), so
            //     DEAL_DRIVER refuses every sell-side PSA and the feature is dead for the only
            //     persona that owns it. ⚠ The mechanism named here was FLS on User.Deal_Driver__c
            //     until 2026-08-12; the flag is retired, the argument is not.
            //   - the SEQUENCE, because sharing one map after observation 7 would require the
            //     acquisition-only values to sit on a map the disposition type also walks.
            //     ⚠ RETRACTED 2026-08-21 — THE MECHANISM, NOT THE CONCLUSION. This bullet used to
            //     end: "and Apex DML does not enforce record-type picklist restriction —
            //     advance() itself would then park a sale on an acquisition-only status." That is
            //     false as stated: `Negotiation_Status__c` is `restricted`, so DML DOES enforce
            //     the record type's subset (see the measured retraction in the class header).
            //     The two maps may still not be collapsed, for a reason that survives the
            //     correction and is in fact harder to argue away:
            //       (a) The union map is `{Draft, Initial Draft} => Negotiation, Negotiation =>
            //           Signed, Signed => Executed`. A DISPOSITION PSA sitting on 'Signed' — its
            //           TERMINAL — stops being terminal and tries to write 'Executed'.
            //           Disposition_PSA has not carried 'Executed' since 2026-08-21, so today the
            //           user gets an opaque `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` from a
            //           button the service should never have offered, instead of this service's
            //           user-safe "There is no next step available from the Signed stage."
            //           A broken feature reported as a platform error is not an acceptable
            //           substitute for a refusal.
            //       (b) 🔴 AND THAT PLATFORM BACKSTOP IS ON LOAN FROM A DECLARATIVE DECISION MADE
            //           OUTSIDE THIS FILE. It exists only while Disposition_PSA omits 'Executed'.
            //           The user harmonised that record type by hand once already (2026-08-21,
            //           dropping Revised / Ready for Execution / Executed); a future harmonisation
            //           that ADDS 'Executed' back — the natural thing to do the day sell-side
            //           execution is wanted — silently removes the refusal, and the collapsed map
            //           WOULD then park a sale on an acquisition-only status exactly as the old
            //           wording claimed. Two maps is the only shape in which that outcome is
            //           unexpressible without depending on a picklist nobody here owns.
            //
            // ── 🔴 defaultTypeKey WAS RE-CHOSEN DELIBERATELY, NOT LEFT ALONE (design C9) ──
            // It STAYS Acquisition_PSA — but the ARGUMENT for it is completely different and the
            // old one is dead. Until observation 7, both types shared one sequence, so a Master /
            // pre-T-B row advanced CORRECTLY through the fallback and the only thing the fallback
            // got wrong was the gate. That is why OpportunityReviewService's header could say a
            // Master-type Contract Review "is NOT functionally dead". It is dead now, and that
            // header has been rewritten to say so.
            //
            // The two candidate defaults, and why this one wins — the criterion is WHICH FAILURE,
            // because after the split the fallback is wrong for SOME population either way:
            //
            //   Acquisition_PSA (chosen)  A legacy / Master row still carrying 'Initial Draft' —
            //                             the P3 row migration is scoped BY RECORD TYPE, so a
            //                             Master row is NOT migrated — finds no entry in the
            //                             acquisition map and is REFUSED, loudly, with "There is
            //                             no next step available from the Initial Draft stage."
            //                             Nothing is written. A Master-type row created AFTER this
            //                             pack carries 'Draft' (OpportunityReviewService stamps it
            //                             explicitly) and advances correctly. The gate stays
            //                             DEAL_DRIVER, which grants the disposition buttons to
            //                             nobody new during the deploy window.
            //   Disposition_PSA (rejected) The same legacy Master row WOULD advance — to 'Revised',
            //                             a value no longer on Acquisition_PSA. A WRONG WRITE, not
            //                             a refusal. And the gate would flip to
            //                             DISPOSITION_DRIVER, denying the acquisitions deal driver
            //                             on rows they own while granting disposition drivers
            //                             access to acquisition rows — a real boundary move
            //                             disguised as a default.
            //
            // ⇒ A refusal beats a wrong write, and a conservative gate beats a widened one. Both
            // criteria point at Acquisition_PSA.
            //
            // ✅ AND THE SPLIT FIXES A COMPLAINT THIS FILE HAS CARRIED SINCE 3C. The class header
            // used to record that the Contract Review fallback was QUIETER than NDA__c's or
            // LOI__c's — "the walk works, the toasts are right, nothing looks wrong ... There is no
            // loud symptom to lead anyone to gate T-B here." There is one now: an unmigrated
            // Master-type row refuses on its very first click, naming its own stale status. That is
            // a diagnostic, not a regression.
            Contract_Review__c.SObjectType => new StageConfig(
                'Contract Review', 'Negotiation_Status__c',
                RT_ACQUISITION_PSA,
                new Map<String, StageTypeConfig>{
                    RT_ACQUISITION_PSA => new StageTypeConfig(
                        StageActionGate.DEAL_DRIVER, CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE),
                    RT_DISPOSITION_PSA => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER, CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE)
                }),
            Underwriting__c.SObjectType => new StageConfig(
                'Underwriting', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, UNDERWRITING_NEXT_STAGE)),
            Construction_Feasibility_Review__c.SObjectType => new StageConfig(
                'Construction Feasibility Review', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, CONSTRUCTION_REVIEW_NEXT_STAGE)),
            Development_Feasibility_Review__c.SObjectType => new StageConfig(
                'Development Feasibility Review', 'Stage__c',
                new StageTypeConfig(StageActionGate.DEAL_DRIVER, DEVELOPMENT_REVIEW_NEXT_STAGE)),
            // ── Transaction__c, added 2026-08-12 ────────────────────────────────────────────
            // ⚠ THE SINGLE-SEQUENCE CONSTRUCTOR IS LOAD-BEARING, NOT SHORTHAND. Transaction__c
            // has NO record types (no objects/Transaction__c/recordTypes/ folder — verified in
            // the org), so byRecordType.size() == 1 and BOTH gateFor() and sequenceKeyFor()
            // short-circuit: hasStageActionAccess costs ZERO extra queries on this object, and no
            // describe is paid. That is the same shape Underwriting__c and the two Feasibility
            // Reviews have always had. Using the five-argument constructor with one entry would
            // compile and behave identically today while implying to the next reader that a
            // record type exists to key on.
            //
            // ⚠ THIS COMMENT USED TO READ "ITS GATE IS THE ONLY MEMBERSHIP-ONLY ONE IN THIS MAP".
            // That stopped being true later the same day: all three gates in this map are now a
            // single FeatureManagement.checkPermission call (see StageActionGate), and this one
            // resolves `Transaction_Stage_Actions`.
            //
            // 🔴 WHAT IS STILL TRUE, AND IS THE REAL DIFFERENCE, IS WHICH LAYER CARRIES THE TOKEN.
            // The two deal permissions sit on directly-assigned LAYER-5 sets; this one sits on the
            // LAYER-4 capability set Transaction_Stage_Actions_Access, which is a member of the
            // DPEG_Transaction_Team group — so this gate is TEAM-WIDE, with no per-user revocation.
            // That is a deliberate, user-made policy decision preserved across the migration, NOT an
            // unfinished gate. TransactionActionPermissionService's header carries the full argument.
            //
            // ⚠ The label 'Transaction' is what the success toast reads ("Transaction moved to
            // Due Diligence.") and is also the NO_NEXT_STEP_HINTS key prefix. This object supplies
            // no hint: every stage without a hop is genuinely terminal, so the default "There is
            // no next step available from the Closed stage." is correct wording, unlike
            // Underwriting's approval-owned gap.
            Transaction__c.SObjectType => new StageConfig(
                'Transaction', 'Stage__c',
                new StageTypeConfig(
                    StageActionGate.TRANSACTION_STAGE_ACTIONS, TRANSACTION_NEXT_STAGE)),
            // ── Disposition__c, added 2026-08-19 (disposition flow redesign, design D-2) ──────
            // ✅ A FOURTH CONFIG ADDITION AT THE PREDICTED COST. Three edits below the maps: the
            // five-argument constructor here, the two record-type constants, and a `load()` branch
            // — plus `DispositionSelector.selectStageRequiredById`, which is new. `advance()`,
            // `advanceTo()`, `sequenceFor()`, `gateFor()` and `setStage()` are untouched, through a
            // fourth record-type-aware object.
            //
            // 🔴 BOTH TYPES ANSWER TO **ONE** GATE, WHICH IS NEW IN THIS MAP AND IS NOT AN
            // OVERSIGHT. NDA__c, LOI__c and Contract_Review__c each split their gate because ONE
            // TABLE SERVES TWO MODULES — an acquisitions deal driver must not drive a sale's NDA.
            // `Disposition__c` is a DISPOSITION-ONLY object: both its record types are sales, both
            // are worked by the same persona, and the split here is about the PATH, not the
            // PERSONA. Splitting the gate too would invent a second disposition persona that does
            // not exist and has no permission set. This is the case that proves `gate` and
            // `nextStage` are independent axes from the OTHER direction: same gate, different
            // sequences.
            //
            // ── 🔴 defaultTypeKey = On_Market, AND THE CRITERION IS "WHICH FAILURE" ──────────
            // A Master / null-record-type disposition takes the ON-MARKET map. The two candidates,
            // judged by what a mis-typed row DOES rather than by which is tidier:
            //
            //   On_Market (chosen)   A Master row gets FOUR hops, one of which — `Broker Selection
            //                        -> NDA` — is approval-owned on the OFF-market path. But a
            //                        Master row has no record type, so no record-type-scoped
            //                        approval (`Broker_Selection_Approval` requires Off Market) can
            //                        be pending on it either: there is no approval to bypass. It
            //                        also matches `DispositionApprovalAdvanceService`'s own
            //                        default, so the manual map and the approval map agree about
            //                        what "no record type" means.
            //   Off_Market (rejected) A Master row would get TWO hops and would be REFUSED at
            //                        `Broker Selection` with a hint naming an approval that cannot
            //                        fire on it — a dead end whose message points at a control that
            //                        does not apply. A wrong instruction is worse than a wider one
            //                        here, because the wider one is not actually wider: see above.
            //
            // ⚠ AND THE POPULATION IS EMPTY TODAY, WHICH IS WHY THIS IS CHEAP. The Phase 0 org
            // sweep (2026-08-19) found EIGHT dispositions, all On_Market, none on a removed stage
            // and none Master. Both `DispositionService` entry points stamp a record type
            // explicitly. The default exists for a data load, not for live rows.
            //
            // ⚠ THE STAGE FIELD IS `Disposition_Stage__c`, NOT `Stage__c` — the third distinct
            // stage-field name in this config (after `Status__c` and `Negotiation_Status__c`), and
            // the reason the config carries the field name per object at all.
            Disposition__c.SObjectType => new StageConfig(
                'Disposition', 'Disposition_Stage__c',
                RT_ON_MARKET,
                new Map<String, StageTypeConfig>{
                    RT_ON_MARKET => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER, DISPOSITION_ON_MARKET_NEXT_STAGE),
                    RT_OFF_MARKET => new StageTypeConfig(
                        StageActionGate.DISPOSITION_DRIVER, DISPOSITION_OFF_MARKET_NEXT_STAGE)
                })
        };

    /**
     * Moves the record to the single next stage for its current stage.
     *
     * The target is DERIVED from the record's own record-type sequence and can never be supplied by
     * the caller, so this method cannot skip a hop and cannot cross into another record type's
     * value set.
     *
     * @param recordId the NDA / LOI / Contract Review / Underwriting / Construction or Development
     *                 Feasibility Review record to advance (required)
     * @return a user-facing confirmation message, e.g. 'LOI moved to Submitted.'
     * @throws RecordStageAdvanceException when recordId is null, the object is not stage-controlled,
     *         the record has no stage set, the record sits on a record type with no configured
     *         sequence, there is no next step from the current stage, or the write is blocked (the
     *         block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advance(loiId);
     */
    public static String advance(Id recordId) {
        StageConfig config = configFor(recordId);
        SObject record = load(recordId);

        String currentStage = (String) record.get(config.stageField);
        if (String.isBlank(currentStage)) {
            throw new RecordStageAdvanceException(NO_STAGE_MESSAGE);
        }

        // ⚠ The sequence is chosen from the LOADED record, not from the Id — see the call-order
        // note in the class header. On an object with one sequence this costs nothing at all.
        StageTypeConfig sequence = sequenceFor(config, record);

        String target = sequence.nextStage.get(currentStage);
        if (target == null) {
            throw new RecordStageAdvanceException(noNextStepMessage(config, currentStage));
        }
        return setStage(record, config, target);
    }

    /**
     * Moves the record to an EXPLICIT stage, which must be on that object's allow-list.
     *
     * Added 2026-08-05 for the LOI 'Sent' branch — a broker either counters or accepts, so the deal
     * driver needs two named buttons where advance() can only derive one. Extended 2026-08-09 for
     * the disposition NDA's 'Declined' off-ramp. It mirrors StageAdvanceService.advanceTo,
     * including the reason that method exists at all.
     *
     * ⚠ RETRACTED 2026-08-21. This paragraph continued: "...and again at the Tranche 3B close-out
     * for the DISPOSITION LOI'S NEGOTIATION LOOP — the sharpest case of the three, because its
     * back-edge ('Counter Received from Buyer' -> 'Countered by DPEG') is not merely inconvenient
     * to derive, it is PROVABLY inexpressible in a Map<String, String> that already maps that key
     * forward." That third case is GONE: the user retired the sell-side loop and counter rounds now
     * live on Counter History (Counter_Offer__c), so Disposition_LOI's allow-list is empty and this
     * method is unreachable on it. Two callers remain, both acquisition-or-NDA.
     *
     * 🔴 THE ALLOW-LIST IS THE WHOLE POINT AND IS PER RECORD TYPE. Without it, any holder of
     * controller access could write ANY stage on ANY of eight objects, skipping every hop and every
     * gate — the exact hole StageAdvanceService.ALLOWED_EXPLICIT_TARGETS was created to close. Held
     * at OBJECT level it would be only half closed: 'Declined' belongs to the disposition NDA, and
     * an object-level list would offer it on an acquisition NDA just as readily.
     * ⚠ RETRACTED 2026-08-21 — MECHANISM ONLY. The clause "but Apex DML does not enforce
     * record-type picklist restrictions, so an object-level list would write it onto an acquisition
     * NDA just as happily" is false for a `restricted` value set; see the class header and
     * NDA_DISPOSITION_EXPLICIT_TARGETS for what the platform does instead (an opaque refusal, on
     * loan from a record type this file does not own). Adding a branch action means adding its
     * stage to that RECORD TYPE's set; do NOT add derivable forward hops, which belong to advance()
     * and therefore cannot skip a step.
     *
     * ⚠ THE ALLOW-LIST CHECK IS AFTER load(), NOT BEFORE IT. It has to be — the list is a property
     * of the record type, and the record type is a property of the row. See the class header for
     * the one visible consequence (a non-existent Id now raises QueryException here).
     *
     * The rejection message deliberately does NOT echo the supplied value back: a legitimate caller
     * can never reach that branch (each bundle passes a hardcoded constant), so the only way in is a
     * hand-crafted call, and reflecting attacker-supplied text into a toast has no upside. Same
     * wording choice as StageAdvanceService.
     *
     * @param recordId the stage-controlled record to move (required)
     * @param target   the destination stage; must be on this RECORD TYPE's allow-list
     * @return a user-facing confirmation message, e.g. 'LOI moved to Signed.'
     * @throws RecordStageAdvanceException when recordId is null, target is blank, target is not an
     *         allowed explicit target for this record's record type, the object is not
     *         stage-controlled, the record sits on a record type with no configured sequence, or
     *         the write is blocked (the block's message is surfaced verbatim)
     * @throws System.QueryException when recordId matches no record
     * @example
     * String msg = RecordStageAdvanceService.advanceTo(loiId, 'Signed');
     */
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw new RecordStageAdvanceException('No target stage was provided.');
        }
        StageConfig config = configFor(recordId);
        SObject record = load(recordId);
        StageTypeConfig sequence = sequenceFor(config, record);
        if (!sequence.explicitTargets.contains(target)) {
            throw new RecordStageAdvanceException('That stage is not available from this action.');
        }
        return setStage(record, config, target);
    }

    /**
     * Whether the running user may drive the stage action on this record. The UX gate behind
     * RecordStageAdvanceController.hasStageActionAccess.
     *
     * DISPATCHES to the RECORD TYPE's configured gate; it does NOT merge gates. THREE of the eight
     * objects answer wholly to DEAL_DRIVER (`Underwriting__c` and the two Feasibility Reviews);
     * three — `NDA__c`, `LOI__c` and, since Tranche 3C, `Contract_Review__c` — answer to
     * DEAL_DRIVER on their `Acquisition_*` type and DISPOSITION_DRIVER on their `Disposition_*`
     * type; `Transaction__c` (2026-08-12) answers wholly to TRANSACTION_STAGE_ACTIONS; and
     * `Disposition__c` (2026-08-19) answers wholly to DISPOSITION_DRIVER on BOTH its record types.
     *
     * 🔴 THAT LAST ONE IS THE FIRST MULTI-RECORD-TYPE OBJECT WHOSE TYPES SHARE A GATE, and it
     * breaks a pattern a reader could otherwise mistake for a rule. The other three split their
     * gate because ONE TABLE SERVES TWO MODULES; `Disposition__c` is disposition-only, so its split
     * is about the PATH, not the PERSONA. It still costs the row load below — `byRecordType.size()`
     * is 2, so `gateFor` cannot short-circuit — for an answer that cannot vary. That is accepted
     * rather than special-cased: a `size() == 1`-style optimisation keyed on "all sequences share a
     * gate" would be a second, subtler short-circuit whose failure mode (a future gate split
     * silently not taking effect) is far worse than one query on a `cacheable=true` path.
     *
     * ⚠ That last clause used to end "…, the one MEMBERSHIP-ONLY gate in the enum" and no longer
     * does: since the 2026-08-12 custom-permission migration all three gates are the same shape, and
     * the surviving asymmetry is which permission-set LAYER carries each token (see StageActionGate).
     * Dispatch is unaffected either way — this method never knew a gate's mechanism, only its name.
     *
     * ⚠ IT NOW LOADS THE RECORD — but only when it has to. Since 2026-08-09 the gate is a property
     * of the record type, and the record type is a property of the row, so an object with more
     * than one configured sequence costs ONE extra SOQL here (a `cacheable=true` path invoked once
     * per record view — the design accepts that). An object with a single sequence short-circuits
     * and still costs ZERO queries, the same optimisation sequenceKeyFor already makes.
     *
     * ⚠ THE GATE ITSELF GOT CHEAPER ON 2026-08-12 AND THE ROW LOAD DID NOT. Retiring the
     * `*_Driver__c` flags took each gate from 2 queries to 0 (holder) or 1 (non-holder), so this
     * method now costs, per record view: 1 for a single-sequence object's non-holder and 0 for its
     * holder; 2 and 1 respectively for a multi-record-type object, where the row load survives
     * untouched because it answers a different question — WHICH gate applies, not whether the user
     * passes it. Anyone hoping the migration removed the load should read `gateFor`.
     *
     * ⚠ TWO CONSEQUENCES, BOTH SMALL AND BOTH REAL:
     *   - `advance()` on an NDA now costs 2 SOQL for the pair (this check, then the service's own
     *     load) rather than 1, because the controller asserts BEFORE calling advance and each call
     *     is independent. Acceptable on a per-click singleton; sharing the row between them would
     *     mean changing the controller's shape for one query.
     *   - A NON-EXISTENT NDA Id now raises System.QueryException here where it previously returned
     *     the object-level answer. The controller maps that to its fixed generic message, so the
     *     gate still fails CLOSED and no user-visible wording changes.
     *
     * @param recordId the record whose object AND record type decide which gate applies (required)
     * @return true when the running user passes that record type's gate
     * @throws RecordStageAdvanceException when recordId is null, the object is not
     *         stage-controlled, or the record sits on a record type with no configured sequence
     * @throws System.QueryException when recordId matches no record, or when the permission
     *         machinery itself fails unexpectedly. Deliberately NOT swallowed — a fault must not
     *         read as a denial. The controller masks and logs it; the LWC treats a thrown check
     *         exactly like false, so the gate still fails CLOSED end to end.
     * @example
     * if (!RecordStageAdvanceService.hasStageActionAccess(loiId)) { return; }
     */
    public static Boolean hasStageActionAccess(Id recordId) {
        return passesGate(gateFor(configFor(recordId), recordId));
    }

    /**
     * The gate governing THIS record.
     *
     * The `size() == 1` short-circuit is a correctness statement as much as an optimisation: an
     * object with one configured sequence has one gate BY CONSTRUCTION, so loading the row could
     * not change the answer — and paying a query per record view on the FOUR objects that will
     * never need it (the three record-type-free acquisitions children plus Transaction__c) would
     * be a real cost for no information.
     */
    private static StageActionGate gateFor(StageConfig config, Id recordId) {
        if (config.byRecordType.size() == 1) {
            return config.byRecordType.get(config.defaultTypeKey).gate;
        }
        return sequenceFor(config, load(recordId)).gate;
    }

    /**
     * Server-side guard. Called as the first statement of every @AuraEnabled entry point so the
     * declarative Dynamic Actions visibility rule — a UX affordance only — cannot be bypassed by
     * invoking the @AuraEnabled method directly.
     *
     * @param recordId the record whose object decides which gate applies (required)
     * @throws AccessDeniedException carrying the shared denial wording when the user lacks access
     * @throws RecordStageAdvanceException when recordId is null or the object is not stage-controlled
     * @throws System.QueryException when the permission lookup itself fails unexpectedly
     * @example
     * RecordStageAdvanceService.assertStageActionAccess(recordId);
     */
    public static void assertStageActionAccess(Id recordId) {
        if (hasStageActionAccess(recordId)) {
            return;
        }
        // One wording for the client gate, the server assert, and both stage features — the user
        // must never see two phrasings for one condition.
        throw new AccessDeniedException(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE);
    }

    /**
     * Whether an object is stage-controlled by this service. Lets a caller ask without provoking an
     * exception.
     *
     * @param recordId any record Id; null-safe
     * @return true when the record's object has a stage map here
     */
    public static Boolean isSupported(Id recordId) {
        return recordId != null && CONFIG_BY_TYPE.containsKey(recordId.getSObjectType());
    }

    private static StageConfig configFor(Id recordId) {
        if (recordId == null) {
            throw new RecordStageAdvanceException(NO_RECORD_MESSAGE);
        }
        StageConfig config = CONFIG_BY_TYPE.get(recordId.getSObjectType());
        if (config == null) {
            throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
        }
        return config;
    }

    /**
     * The stage sequence that governs THIS record — chosen by record type, which is why it takes a
     * loaded record and not an Id.
     *
     * FALLBACK RULES, in order, each for a different reason:
     *   1. The object has exactly ONE sequence  -> that sequence, with no describe at all. FOUR of
     *      the eight objects since Disposition__c joined 2026-08-19, and the whole reason
     *      record-type awareness is free for them. ⚠ "One sequence" means one StageTypeConfig, NOT
     *      one map: Contract_Review__c has two configs sharing one map and correctly does NOT take
     *      this branch, because its two configs carry different GATES.
     *   2. RecordTypeId is null or unqueried    -> defaultTypeKey (the ACQUISITION sequence). This
     *      is the deploy window: before T1 the field does not exist, and between T1 and the row
     *      migration every live row is on Master.
     *   3. The record type is Master            -> defaultTypeKey, same window, same reason.
     *   4. A real, NAMED record type with no configured sequence -> REFUSED. Never defaulted; see
     *      the class header for why a silent fallback here is unsafe rather than merely untidy.
     */
    private static StageTypeConfig sequenceFor(StageConfig config, SObject record) {
        return config.byRecordType.get(sequenceKeyFor(config, record));
    }

    private static String sequenceKeyFor(StageConfig config, SObject record) {
        if (config.byRecordType.size() == 1) {
            return config.defaultTypeKey;
        }
        Id recordTypeId = recordTypeIdOf(record);
        if (recordTypeId == null) {
            return config.defaultTypeKey;
        }
        Schema.RecordTypeInfo info = record.getSObjectType()
            .getDescribe()
            .getRecordTypeInfosById()
            .get(recordTypeId);
        if (info == null || info.isMaster()) {
            return config.defaultTypeKey;
        }
        String developerName = info.getDeveloperName();
        if (!config.byRecordType.containsKey(developerName)) {
            throw new RecordStageAdvanceException(UNSUPPORTED_RECORD_TYPE_MESSAGE);
        }
        return developerName;
    }

    /**
     * The loaded record's RecordTypeId, or null when the object carries no record types, when the
     * selector did not select the field, or when the row genuinely has none.
     *
     * ⚠ getPopulatedFieldsAsMap() rather than record.get('RecordTypeId') because it NEVER THROWS.
     * MEASURED on usman-dpeg 2026-08-09, both halves:
     *   - get('RecordTypeId') on a record whose SELECT omitted it -> System.SObjectException;
     *   - get('RecordTypeId') on a record whose SELECT included it, value null -> null.
     * FOUR of the eight selectors here deliberately do not select RecordTypeId, so the direct read
     * would turn "this object has no record types" into a runtime failure for them.
     *
     * ⚠ ALSO MEASURED, and it is the reason this returns null so often: a field that WAS queried
     * but is NULL is DROPPED from getPopulatedFieldsAsMap() entirely —
     * `SELECT Id, Status__c, RecordTypeId` on a Master-type row yields the key set {Id, Status__c}.
     * So this method cannot distinguish "not selected" from "selected and empty", and it does not
     * need to: both mean "no record type to key on", and both must take the default sequence. A
     * caller wanting to assert the field was actually SELECTED must use get() and expect the
     * SObjectException — see NdaSelectorTest.
     *
     * ⚠ The key comparison is case-INSENSITIVE deliberately. Apex Map<String, Object> keys are
     * case-SENSITIVE, while the casing of that map's keys is chosen by the platform. A mismatch
     * would return null and route every record to the fallback sequence — a silent degradation
     * whose only symptom is "the disposition NDA behaves like an acquisition one". The map holds a
     * handful of entries, so the scan costs nothing.
     */
    private static Id recordTypeIdOf(SObject record) {
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        for (String fieldName : populated.keySet()) {
            if (RECORD_TYPE_ID_FIELD.equalsIgnoreCase(fieldName)) {
                return (Id) populated.get(fieldName);
            }
        }
        return null;
    }

    /**
     * Loads the record through its own selector.
     *
     * Deliberately a chain of SObjectType TOKEN comparisons rather than an Apex `switch on`: Apex's
     * switch accepts a String or an enum but not a Schema.SObjectType, so a switch here would have
     * to key on the object's API NAME as a string literal — trading compile-checking for eight
     * stringly-typed keys, for no benefit. Every branch is a static, fully-literal, WITH USER_MODE
     * selector call: zero dynamic SOQL and zero string-built queries.
     *
     * ⚠ The local is named `objectType`, not `recordType`. Since 2026-08-09 this class also deals
     * in RECORD types, and a Schema.SObjectType called `recordType` is now actively misleading.
     *
     * ⚠ A selector whose object is record-type-aware MUST select RecordTypeId — today NdaSelector
     * (3A), LoiSelector (3B) and ContractReviewSelector (3C). Omitting it does not fail; it
     * degrades to the default sequence, silently. All three selector methods carry a DO-NOT-NARROW
     * note saying so. ⚠ ContractReviewSelector's is the easiest to talk yourself out of, because
     * that object's two record types share a stage sequence — but they do NOT share a gate, and the
     * gate is resolved from the same field.
     *
     * FETCH-FOR-USE: each selector method throws System.QueryException on a miss (repo contract).
     */
    private static SObject load(Id recordId) {
        Schema.SObjectType objectType = recordId.getSObjectType();
        if (objectType == NDA__c.SObjectType) {
            return NdaSelector.selectStageRequiredById(recordId);
        }
        if (objectType == LOI__c.SObjectType) {
            return LoiSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Underwriting__c.SObjectType) {
            return UnderwritingSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Construction_Feasibility_Review__c.SObjectType) {
            return ConstructionFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Development_Feasibility_Review__c.SObjectType) {
            return DevelopmentFeasibilityReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Contract_Review__c.SObjectType) {
            return ContractReviewSelector.selectStageRequiredById(recordId);
        }
        if (objectType == Transaction__c.SObjectType) {
            return TransactionSelector.selectStageRequiredById(recordId);
        }
        // ⚠ Disposition__c is record-type-aware, so its selector MUST select RecordTypeId. It does,
        // and carries the same DO-NOT-NARROW note the other three do — omitting it degrades
        // SILENTLY to the On_Market sequence, which would offer every off-market sale two hops it
        // does not own.
        // ⚠ AND ITS SELECTOR IS `WITH SYSTEM_MODE` WHERE THE OTHER SEVEN ARE `WITH USER_MODE`. That
        // is argued in full at DispositionSelector.selectStageRequiredById and is specific to how
        // the DISPOSITION gate is provisioned (the custom permission and the FLS ride on different
        // permission sets). It is NOT a pattern to copy onto the other branches.
        if (objectType == Disposition__c.SObjectType) {
            return DispositionSelector.selectStageRequiredById(recordId);
        }
        // Unreachable in practice — configFor() already rejected every unsupported type before this
        // is called. Kept so a new CONFIG_BY_TYPE entry without a matching selector branch fails
        // loudly and immediately instead of returning null.
        throw new RecordStageAdvanceException(UNSUPPORTED_OBJECT_MESSAGE);
    }

    /**
     * Asks the record type's configured gate. A gate with no branch here DENIES — an unwired gate
     * must never read as a grant, which is exactly why DISPOSITION_DRIVER was not declared until
     * the day its permission set and this branch landed together.
     *
     * ⚠ SINCE 2026-08-12 ALL THREE BRANCHES ARE THE SAME SHAPE — one custom-permission check plus a
     * "Modify All Data" bypass, each memoized in its own service. That does NOT make the switch
     * collapsible into a single call with a permission-name parameter: the three services are three
     * separate authorization boundaries with three separate caches, and flattening them would let a
     * future change to one silently apply to all three. The dispatch IS the boundary.
     *
     * ⚠ COST: every branch is now 0 SOQL for a holder and 1 for everyone else (it was 2 for the
     * first two branches before the migration). That is ON TOP of the row load `gateFor` performs
     * for a multi-record-type object, which is unchanged.
     */
    private static Boolean passesGate(StageActionGate gate) {
        Boolean allowed = false;
        switch on gate {
            when DEAL_DRIVER {
                allowed = OpportunityActionPermissionService.hasDealActionAccess();
            }
            when DISPOSITION_DRIVER {
                allowed = DispositionActionPermissionService.hasDispositionActionAccess();
            }
            when TRANSACTION_STAGE_ACTIONS {
                // ⚠ Same MECHANISM as the two branches above since 2026-08-12, but a different
                // POLICY: its permission rides on a layer-4 capability set inside
                // DPEG_Transaction_Team, so this gate is team-wide and has no per-user revocation.
                // That is preserved from the membership check it replaced, not a side effect of it.
                // See StageActionGate and TransactionActionPermissionService's class header.
                allowed = TransactionActionPermissionService.hasTransactionActionAccess();
            }
            when else {
                allowed = false;
            }
        }
        return allowed;
    }

    private static String noNextStepMessage(StageConfig config, String currentStage) {
        // ⚠ Do NOT name this local `hint` — that identifier is RESERVED in Apex and fails to
        // compile with "Identifier name is reserved: hint" (same trap as `bulk`).
        String specificMessage = NO_NEXT_STEP_HINTS.get(config.label + '|' + currentStage);
        if (String.isNotBlank(specificMessage)) {
            return specificMessage;
        }
        return 'There is no next step available from the ' + currentStage + ' stage.';
    }

    private static String setStage(SObject record, StageConfig config, String target) {
        try {
            record.put(config.stageField, target);
            update record;
            return config.label + ' moved to ' + target + '.';
        } catch (DmlException e) {
            // A validation rule, a required-field rule, or a picklist restriction. Surfacing the
            // platform message verbatim is the POINT of routing these writes through Apex — on the
            // LDS route the rule text lands in body.output.errors[] where the shared guard never
            // reads it, and the rule would ship invisible (design doc §5).
            //
            // ⚠ The getNumDml() guard is load-bearing, not defensive noise. A DmlException with NO
            // row detail is a real shape (MIXED_DML_OPERATION, LIMIT_EXCEEDED); on those,
            // getDmlMessage(0) itself throws, which would escape this catch, land in the
            // controller's GENERIC clause and mask a genuine save block as "refresh the page".
            // StageAdvanceService.setStage calls getDmlMessage(0) unguarded — that is a latent
            // difference, not an oversight here.
            throw new RecordStageAdvanceException(
                e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }
    }
}
