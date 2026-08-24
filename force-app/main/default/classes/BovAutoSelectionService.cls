/**
 * AUTOMATIC BROKER APPOINTMENT: the highest-scoring, non-preferred, unlocked BOV submission on a
 * Disposition becomes its `Submission_Status__c = 'Selected'` one, recomputed on every save that
 * can change the ranking, and LOCKED the moment a human or an approval takes over.
 * Added 2026-08-24 (`agent-output/bov-autoselect-preferred-brokers.md`).
 *
 * It replaces the manual **Select Broker** button on `c/bovComparisonMatrix`. **Replace Broker**
 * survives untouched and remains the deliberate human override — see THE LOCK below for how the
 * two are kept from fighting.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT MUST RUN IN AN **AFTER** CONTEXT AND IT MUST WRITE **ONE** DML. BOTH OR NEITHER.
 *    THIS IS THE SINGLE MOST IMPORTANT PARAGRAPH IN THIS FILE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BovSubmissionSelectionGuardService` is wired at `before insert` AND `before update` and REFUSES
 * — with `addError`, on the user's own row — any save that would leave a Disposition with two
 * `Selected` submissions. It subtracts rows present in `Trigger.new` from its committed count,
 * because their in-memory value supersedes their database value. That mechanism dictates this
 * service's shape exactly, and the two obvious implementations are both REFUSED:
 *
 *   ❌ BEFORE-INSERT, setting the incoming row's own status in memory and demoting the incumbent in
 *      a separate statement. The committed incumbent is NOT in `Trigger.new` on an insert, so the
 *      guard counts it: `others = 1 + 1 - 1 = 1 > 0`. THE USER'S OWN INSERT IS ROLLED BACK, with a
 *      message telling them to use Replace Broker — on a save that had nothing to do with
 *      selection. 100% reproducible and attributed to the wrong feature.
 *   ❌ AFTER context, TWO DML: promote the challenger, then demote the incumbent. Refused on
 *      statement 1 by the same arithmetic. (Demote-then-promote happens to pass, which is worse:
 *      correctness would then depend on statement ORDER, which is exactly the fragility the guard's
 *      header warns about.)
 *
 *   ✅ AFTER context, ONE `Database.update([demote..., promote])`. `beforeUpdate` fires with BOTH
 *      rows in `Trigger.new`; the incumbent's in-memory `Backup` supersedes its committed
 *      `Selected`; PASS 2 skips it because it is in `incomingIds`; `others = 0 + 1 - 1 = 0`. PASSES.
 *
 * This is the SECOND class of caller that has to obey that contract —
 * `BovSubmissionService.replaceSelectedBroker` is the first, and the guard's header already names
 * the trap for it. `BovSubmissionSelectionGuardTest.autoSelectionSwap_isNotRefusedByTheGuard` is
 * this service's falsifier and must never be deleted.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE LOCK — WHEN AUTO-SELECTION STOPS, AND WHY IT IS THREE LEGS AND NOT ONE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *     LOCKED(disposition) <=> ANY of its submissions has
 *           Approval_Pending__c       = true      // an approval is in flight
 *        OR Approval_Status__c       != null      // a decision was MADE (Approved OR Rejected)
 *        OR Is_Manually_Appointed__c  = true      // a human used Replace Broker
 *
 * Each leg answers a question no other leg can:
 *
 *   `Approval_Pending__c` covers the pending window — and it is ALSO what prevents
 *   `ENTITY_IS_LOCKED`. `Broker_Finalize_Approval` is `recordEditability = AdminOnly`, and
 *   `AccessLevel.SYSTEM_MODE` DOES NOT LIFT AN APPROVAL LOCK. An unlocked auto-selection that tried
 *   to demote a submission with a pending approval would throw inside an `allOrNone = true` bulk
 *   update and roll back THE UNRELATED BOV THE USER WAS SAVING. The business rule and the technical
 *   guard are the same line of code; never decouple them.
 *
 *   `Approval_Status__c != null` covers approved AND rejected, permanently. It goes non-null only
 *   via the approval's final actions, so a RECALL (which fires no status update) leaves it null.
 *
 *   `Is_Manually_Appointed__c` covers the deliberate human override and survives everything.
 *   🔴 IT IS NOT OPTIONAL. `BovSubmissionService.replaceSelectedBroker` deliberately CLEARS
 *   `Approval_Status__c` on BOTH rows so the replacement broker needs a fresh approval. Without
 *   this third leg, a manual Replace Broker after a rejection would leave every leg false and
 *   auto-selection would UNDO the human's pick on the very next BOV save.
 *
 * ⚠ RECALL UNLOCKS AND RECOMPUTATION RESUMES. That is correct and falls out of the predicate with
 * no special case: a recall means "I did not mean to send that yet", nothing was decided, and the
 * state is identical to pre-submission.
 *
 * 🔴 REJECTION KEEPS IT LOCKED (user decision, 2026-08-24). A rejection is a decision the
 * principals made about THIS BROKER. If auto-selection resumed it would answer a question a human
 * just answered — and since the rejected broker is still the highest scorer it would either
 * re-select the same broker (a no-op that reads as the system ignoring the rejection) or, on the
 * next BOV arrival, silently swap in a different broker with no actor. The remedy after a rejection
 * is **Replace Broker**, which is precisely the deliberate human override this feature preserves.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A NULL SCORE IS NOT A RANK. IF EVERY CANDIDATE SCORES NULL, NOTHING IS SELECTED.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BOV_Score__c` is a FORMULA that returns null when the parent Disposition has no
 * `Asking_Price__c` (or it is `<= 0`), or when the row has no `BOV_Amount__c`. That null means
 * "NOT SCOREABLE", not "worst" — the formula says so with an explicit `ISBLANK` guard and
 * `formulaTreatBlanksAs = BlankAsBlank`. Treating it as rankable would mean the tie-break decides
 * everything, i.e. "auto-select whichever BOV arrived first", appointing a broker for a sale nobody
 * has priced. So a null-scored row is never the winner, and a disposition whose candidates all
 * score null keeps NO Selected broker and costs ZERO DML.
 *
 * ⚠ SCOPED TO THE SCORED PATH ONLY, SINCE 2026-08-24. A PREFERRED row is selected WITHOUT a score
 * and this rule must never be applied to it — see A PREFERRED BROKER WINS OUTRIGHT below. The two
 * live in one method (`planFor`) and the boundary between them is the `Is_Preferred_Broker__c`
 * branch; widening this rule back across both would silently disable the preferred feature for
 * every broker who has not quoted, which is most of them.
 *
 * ⚠ THE PRICE OF THAT RULE, STATED PLAINLY, BECAUSE IT MAKES A GREEN SUITE MEANINGLESS: every
 * `TestDataFactory` BOV fixture scores null, because the Dispositions that factory builds set no
 * `Asking_Price__c` (its own header says so). A test of this service that does not give its
 * disposition an asking price PASSES WITHOUT EXERCISING ANY OF IT. Use
 * `TestDataFactory.createPricedDisposition(...)`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A PREFERRED BROKER WINS OUTRIGHT — IT DOES NOT COMPETE, IT PRE-EMPTS
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ RETRACTED IN PLACE 2026-08-24 (user decision, option 2). This block used to be headed
 * *"PREFERRED BROKERS NEVER PARTICIPATE"* and read: *"`Is_Preferred_Broker__c = true` rows are
 * excluded from the ranking entirely and can never be auto-Selected, whatever they score."* THAT
 * IS NOW EXACTLY BACKWARDS and is quoted rather than deleted, because the design document, the two
 * field XML comments and this class's first version all say it and a reader will meet it again.
 *
 * THE RULE NOW: **if a disposition has ANY preferred row, the preferred row IS the Selected one,
 * whatever it scores and whatever the scored responses score.** Adding a preferred broker demotes
 * the scored winner to `Backup` and takes the slot. Remove the last preferred row — unflag it or
 * delete it — and scoring RESUMES and re-ranks from the top.
 *
 * ⚠ SCORE IS IRRELEVANT ON THIS PATH, AND THAT IS DELIBERATE, NOT AN OVERSIGHT. A preferred row is
 * exempt from `BOV_Amount_Required_On_Submission`, so it legitimately carries NO `BOV_Amount__c`
 * and therefore a NULL `BOV_Score__c`. The "a null score is not a rank" rule is scoped to the
 * SCORED path ONLY — applying it to preferred rows would make the feature silently never fire for
 * the exact rows it exists to serve.
 *
 * ⚠ MULTIPLE PREFERRED ROWS: THE NEWEST WINS (`CreatedDate DESC, Id DESC`), which INVERTS every
 * other tie-break in this module. The argument is at `isNewer`'s own declaration; the short form is
 * that under oldest-wins a second **Add Preferred Broker** click would be a silent no-op with no
 * remedy, because Replace Broker refuses preferred rows.
 *
 * 🔴 THIS IS A RANKING RULE, NOT A LOCK LEG, AND THE DISTINCTION IS LOAD-BEARING. A lock means
 * "stop computing and freeze whatever is there" — which would be wrong twice over: adding a
 * preferred broker to a disposition that already has a scored winner MUST change state (the
 * scored winner has to be demoted), and removing the preferred row MUST resume scoring. Both fall
 * out of ranking for free and neither is expressible as a lock. The three real lock legs
 * (approval pending / decided / manually appointed) are unchanged and still win over this: a
 * preferred broker added to a disposition with a pending or decided approval changes NOTHING.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE MODAL MUST NOT INSERT A PREFERRED ROW AS `Selected`. THE FLAG IS THE INPUT; `Selected`
 *    IS THE OUTPUT. THIS IS A HARD CONTRACT WITH `c/bovAddResponseModal`.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It is tempting to have the modal simply write `Submission_Status__c = 'Selected'` alongside
 * `Is_Preferred_Broker__c = true` and skip this service entirely. **THAT INSERT IS REFUSED**, and
 * the arithmetic is `BovSubmissionSelectionGuardService`'s, traced:
 *   the disposition already has a committed `Selected` scored winner; on an INSERT that incumbent
 *   is NOT in `Trigger.new`, so PASS 2 counts it; `others = 1 + 1 - 1 = 1 > 0`; the guard
 *   `addError`s and THE USER'S OWN "ADD PREFERRED BROKER" SAVE IS ROLLED BACK with a message
 *   telling them to use Replace Broker.
 * So the modal inserts the row at `Backup` (exactly as it does today — NO LWC CHANGE IS REQUIRED)
 * carrying only the flag, and THIS SERVICE promotes it and demotes the incumbent in ONE
 * `Database.update`, which is the only shape the guard permits. Pinned by
 * `BovSubmissionSelectionGuardTest.preferredInsertedAsSelected_isRefused_soTheModalMustNotSetIt`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * WHERE IT RUNS — ⚠ THIS SAID "BOTH HOOKS" UNTIL 2026-08-24; THERE ARE NOW FOUR CONTEXTS
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   `BOV_Submission__c` after insert / after update  -> `reselect(newList, oldMap)`
 *   `BOV_Submission__c` after delete                 -> `reselectForDeleted(oldList)`
 *   `Disposition__c`    after update                 -> `reselectForRepricedDispositions(...)`
 *
 * 🔴 THE PARENT HOOK IS NOT A NICETY, IT IS THE PRIMARY PATH. The score's 50-point Value term is
 * `BOV_Amount__c / Disposition__r.Asking_Price__c`, so the real sequence on a live sale is:
 * an analyst logs three BOV responses (all score null, nothing is selectable), then LATER types the
 * asking price ON THE DISPOSITION — at which point all three scores materialise in one parent save
 * WITH ZERO CHILD DML. Without the parent hook no broker is ever auto-selected on such a sale,
 * there may be no further reason to edit a BOV again, and the feature looks broken with no error
 * anywhere.
 *
 * ── BUDGET / BULK ───────────────────────────────────────────────────────────────────────────
 * **AT MOST 1 SOQL AND AT MOST 1 DML PER CHUNK — CONSTANT IN THE NUMBER OF SUBMISSIONS.**
 * 🔴 ZERO-QUERY FAST PATH: a chunk in which no ranking input, status, preferred flag, parent or
 * `Approval_Pending__c` changed returns BEFORE the query, which is what keeps this service
 * invisible to every unrelated feature's 251-record bulk test — the same "an ordinary save costs
 * nothing" contract `BovSubmissionBrokerStampService` and `BovSubmissionSelectionGuardService`
 * already carry on these very contexts.
 * `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE APPLIES IN FULL. There is no exemption to
 * claim: this is a trigger path and it loops over a collection. ⚠ 251 submissions on ONE
 * disposition span TWO chunks (200 + 51), so this service runs TWICE and may flip the appointment
 * twice before settling. Tests must assert THE END STATE plus a CONSTANT per-chunk cost, never
 * "it flipped once".
 *
 * ── ⚠ NO `BOV_Broker_Change__c` HISTORY ROW IS WRITTEN, DELIBERATELY ────────────────────────
 * Not because logging is expensive — because THE CASE THAT OBJECT EXISTS FOR CANNOT ARISE HERE.
 * Under the lock, this service only ever operates on a disposition where NO submission has been
 * submitted, approved, rejected or manually appointed. So every row it demotes has
 * `Approval_Status__c = null` already (the state the guard's header says a self-heal must not
 * recreate), and every row it demotes was put there by this same algorithm. There is no human
 * decision to overwrite and no approval to revoke. Writing a row whose `Logged_By__c` would be
 * whoever happened to save a BOV, with a synthetic `Reason__c`, would DILUTE the exact log
 * Workstream B built to record human decisions — and on a 251-row load split across two chunks it
 * would write TWO rows for one net outcome.
 * 🔴 THAT LEAVES NO AUDIT TRAIL AT ALL, AND IT IS NAMED RATHER THAN HIDDEN:
 * `BOV_Submission__c.object-meta.xml` is `<enableHistory>false</enableHistory>`. A broker
 * who is Selected on Monday and Backup on Tuesday has no record of when or why. FIELD HISTORY
 * TRACKING on the object and on `Submission_Status__c` is the cheap, correct place for "the system
 * flipped this, at this time" and is admin work outside this class.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────────────────────
 * Service (`layer=service`, ARCHITECTURE.md §2, `.claude/rules/apex-layering-rule.md`). It CANNOT
 * be a Domain method: the decision needs a SIBLING READ and domains get zero SOQL. It CANNOT live
 * in the trigger handler for the same reason. ZERO inline SOQL here — the one read goes to
 * `BovSubmissionSelector.selectSelectionContextByDispositionIds`.
 *
 * 🔴 IT DOES NOT CALL `BovSubmissionService.replaceSelectedBroker`, AND THAT IS A DECISION, NOT AN
 * OVERSIGHT. Four independent blockers, ANY ONE SUFFICIENT: (1) that method calls
 * `DispositionActionPermissionService.assertDispositionActionAccess()` — a HUMAN action permission
 * a trigger has no business asserting, which would refuse auto-selection for any principal who can
 * save a BOV but is not a "disposition driver"; (2) it REQUIRES a `reason`, and there is no honest
 * human reason for a rescore; (3) it UNCONDITIONALLY inserts a `BOV_Broker_Change__c` row (see
 * above); (4) it takes a savepoint and issues 3 DML across 3 objects per invocation — the wrong
 * budget for a trigger. The SHAPE and the INVARIANT are shared; the method is not.
 *
 * @see force-app/main/default/classes/BovSubmissionSelectionGuardService.cls (the guard this must satisfy)
 * @see force-app/main/default/classes/BovSubmissionService.cls (the human override, and why it is not reused)
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the child hook)
 * @see force-app/main/default/classes/DispositionTriggerHandler.cls (the parent hook)
 */
public with sharing class BovAutoSelectionService {

    /**
     * The `Submission_Status__c` value marking the appointed broker. The picklist is RESTRICTED to
     * exactly {Backup, Selected}, so these two constants are the WHOLE value set. Each layer holds
     * its own copy (`BovSubmissionService`, `BovSubmissionTriggerHandler`, `BovSubmissionSelector`,
     * `BovSubmissionSelectionGuardService`); these are auto-selection's.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /** The runner-up value. See STATUS_SELECTED. */
    @TestVisible
    private static final String STATUS_BACKUP = 'Backup';

    /**
     * Every write failure from the most recent selection DML, as
     * `<submissionId> -> <STATUS_CODE> | <message>`. Reset at the top of every
     * write attempt, so it describes ONE chunk's swap and not a session; left EMPTY by every run
     * that decided to write nothing.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON, AND ITS RELATIONSHIP TO THE THROW IS THE POINT. The DML is
     * `allOrNone = true`, so a refusal THROWS rather than returning a failed `SaveResult` — this
     * list is populated from the `DmlException` on the way past and the exception is RE-THROWN
     * unchanged. So the failure is never silent, and a test can assert the actual platform
     * `StatusCode` (`INSUFFICIENT_ACCESS_OR_READONLY` when the `without sharing` escape has been
     * removed) instead of an opaque "expected Selected, was Backup". Twin of
     * `BovSubmissionTriggerHandler.lastRunParentWriteFailures`, whose header records why
     * "cannot recover" is not "must not report".
     */
    @TestVisible
    private static List<String> lastRunSelectionFailures = new List<String>();

    /**
     * Re-entrancy stop. This service's own `Database.update` re-fires `beforeUpdate` (the broker
     * stamp and the exclusivity guard) and `afterUpdate` (which routes straight back here, because
     * `Submission_Status__c` just changed and that is one of the keys).
     *
     * ⚠ THE RECURSION TERMINATES WITHOUT THIS FLAG — the second pass finds the winner already
     * Selected and alone, and computes zero writes. The flag is here for the COST, not for
     * correctness: without it every swap costs a SECOND selection query per chunk, and this repo
     * has a MEASURED incident (`trigger-cascade-on-bulk-insert`) where exactly that shape cost 23
     * SOQL and 23 DML at production scale.
     * 🔴 IT IS RESET IN A `finally`. A flag left true by a thrown exception would silently disable
     * auto-selection for the REST OF THE TRANSACTION — the failure mode
     * `DispositionTriggerHandler`'s header cites as the reason it declines to use one at all.
     */
    @TestVisible
    private static Boolean suppressReentry = false;

    /**
     * The `BOV_Submission__c` after-insert / after-update hook.
     *
     * ── 🔴 THE CHANGE KEYS, AND THE TWO DELIBERATE OMISSIONS ───────────────────────────────────
     * On INSERT (`priorById == null`) every row's parent qualifies — a new submission can always
     * change the ranking. On UPDATE a parent qualifies only when one of these changed:
     *
     *   `BOV_Amount__c`, `Commission_Rate__c`, `Days_To_Market__c`  the three scoring inputs
     *   `Submission_Status__c`                                      a hand edit, or a replace
     *   `Is_Preferred_Broker__c`                                    moves a row in/out of ranking
     *   `Approval_Pending__c`                                       🔴 THE RECALL. See below.
     *   `Disposition__c`                                            reparenting — BOTH parents
     *
     * 🔴 `Approval_Pending__c` IS KEYED BECAUSE OF THE RECALL AND ONLY BECAUSE OF IT.
     * `Broker_Finalize_Approval`'s `recallActions` fire `Clear_Broker_Approval_Pending`
     * (true -> false) and NO status update, so a recall is the one event that RELEASES the lock
     * without any other field moving. Miss it and a recalled disposition silently stops recomputing.
     *
     * ⚠ `Approval_Status__c` AND `Is_Manually_Appointed__c` ARE DELIBERATELY **NOT** KEYED. Both can
     * only ever ADD a lock leg, and a disposition that has just become LOCKED needs no write — so
     * keying them would buy one wasted query per chunk on every approval decision in the org, and
     * would break `BovSubmissionTriggerHandlerTest.bulk251ApprovesAtConstantCost`'s stated budget
     * for a behaviour that is provably a no-op.
     * ⚠ THE RESIDUAL THAT LEAVES, NAMED: an ADMIN who hand-clears `Approval_Status__c` from
     * 'Rejected' back to null UNLOCKS the disposition but does not trigger a recompute until the
     * next qualifying save. Accepted — that is a manual repair of a state this feature deliberately
     * parks, and the next BOV save picks it up.
     *
     * @param incoming  Trigger.new. Null/empty-safe.
     * @param priorById Trigger.oldMap on update; NULL ON INSERT — on insert every parent qualifies,
     *                  which is the correct reading.
     * @example
     * BovAutoSelectionService.reselect(newList, oldMap);
     */
    public static void reselect(
        List<BOV_Submission__c> incoming,
        Map<Id, BOV_Submission__c> priorById
    ) {
        if (incoming == null || incoming.isEmpty()) {
            return;
        }
        Set<Id> dispositionIds = new Set<Id>();
        for (BOV_Submission__c submission : incoming) {
            BOV_Submission__c prior = (priorById == null || submission.Id == null)
                ? null
                : priorById.get(submission.Id);
            if (prior == null) {
                // Insert, or an update whose old row is unavailable: always re-rank.
                if (submission.Disposition__c != null) {
                    dispositionIds.add(submission.Disposition__c);
                }
                continue;
            }
            if (prior.Disposition__c != submission.Disposition__c) {
                // Reparented. BOTH sides change: the old parent lost a candidate, the new one
                // gained one. Adding only the new parent would leave the old one with a stale
                // Selected row nothing recomputes.
                if (prior.Disposition__c != null) {
                    dispositionIds.add(prior.Disposition__c);
                }
                if (submission.Disposition__c != null) {
                    dispositionIds.add(submission.Disposition__c);
                }
                continue;
            }
            if (submission.Disposition__c == null) {
                continue; // no parent, no siblings, no invariant
            }
            if (prior.BOV_Amount__c != submission.BOV_Amount__c
                || prior.Commission_Rate__c != submission.Commission_Rate__c
                || prior.Days_To_Market__c != submission.Days_To_Market__c
                || prior.Submission_Status__c != submission.Submission_Status__c
                || prior.Is_Preferred_Broker__c != submission.Is_Preferred_Broker__c
                || prior.Approval_Pending__c != submission.Approval_Pending__c) {
                dispositionIds.add(submission.Disposition__c);
            }
        }
        reselectFor(dispositionIds);
    }

    /**
     * The `Disposition__c` after-update hook — re-ranks a sale's BOV submissions when its
     * `Asking_Price__c` changes.
     *
     * 🔴 MANDATORY, NOT OPTIONAL, AND THE CLASS HEADER ARGUES IT IN FULL: `BOV_Score__c` is
     * PARENT-DERIVED, so pricing a sale AFTER its BOV responses arrived re-ranks every child with
     * ZERO child DML — and on the evidence that is the PRIMARY path, not an edge case. Without this
     * hook such a sale never gets an appointed broker and there is no error anywhere.
     *
     * ⚠ KEYED ON THE CHANGE, SO AN ORDINARY DISPOSITION SAVE COSTS ZERO QUERIES AND ZERO DML —
     * the same contract `DispositionTrigger`'s header already carries for both of its other hooks.
     * ⚠ INSERT IS DELIBERATELY NOT WIRED: a Disposition has no BOV children at the moment it is
     * created, so there is nothing to rank.
     * ⚠ THE DIRECTION IS SAFE. This writes PARENT -> CHILD. `Disposition__c` is the entry object
     * of three `AdminOnly` approvals, which lock THE DISPOSITION, not its children; the only process
     * that locks a child is `Broker_Finalize_Approval`, and a locked child is precisely the locked
     * state this service refuses to write.
     *
     * @param dispositions Trigger.new. Null/empty-safe.
     * @param priorById    Trigger.oldMap. Null-safe (nothing is re-ranked without an old value —
     *                     see the insert note above).
     * @example
     * BovAutoSelectionService.reselectForRepricedDispositions(newList, oldMap);
     */
    public static void reselectForRepricedDispositions(
        List<Disposition__c> dispositions,
        Map<Id, Disposition__c> priorById
    ) {
        if (dispositions == null || dispositions.isEmpty() || priorById == null) {
            return;
        }
        Set<Id> dispositionIds = new Set<Id>();
        for (Disposition__c disposition : dispositions) {
            Disposition__c prior = priorById.get(disposition.Id);
            if (prior == null) {
                continue;
            }
            if (prior.Asking_Price__c != disposition.Asking_Price__c) {
                dispositionIds.add(disposition.Id);
            }
        }
        reselectFor(dispositionIds);
    }

    /**
     * The `BOV_Submission__c` AFTER DELETE hook — re-ranks the parents of rows that have just been
     * deleted. Added 2026-08-24 with the preferred-broker-wins decision.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 WHY DELETE NEEDS ITS OWN CONTEXT WHEN UNFLAGGING DOES NOT
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The user asked for the same outcome from two different actions, and only ONE of them was
     * already covered:
     *   UNFLAG a preferred row -> `Is_Preferred_Broker__c` is one of `reselect`'s change keys, so
     *       the update hook fires and scoring resumes. NOTHING WAS NEEDED. ✅
     *   DELETE a preferred row -> `BovSubmissionTrigger` had NO delete context at all, so the
     *       appointed broker simply vanished and the sale was left with NO Selected submission and
     *       nothing to notice it. The scored responses sit there unranked forever.
     * ⇒ `after delete` was added to the trigger in the same change.
     *
     * ⚠ IT READS `Trigger.old`, WHICH IS THE ONLY PLACE THE PARENT ID STILL EXISTS. The rows are
     * gone from the database by the time the selector runs, which is exactly what makes the
     * re-rank correct: the deleted row cannot be a candidate and cannot be an incumbent.
     *
     * 🔴 `after delete`, NOT `before delete`. Same reason the whole service is after-context: the
     * promotion of the next-best row must be a `Database.update` the exclusivity guard sees in one
     * statement, and in a BEFORE delete context the row being deleted is still committed as
     * `Selected`, so promoting anyone would be counted as a second Selected row and REFUSED.
     *
     * ⚠ AND NO `after undelete`, DELIBERATELY — THIS IS THE ONE CONTEXT THAT WAS CONSIDERED AND
     * REJECTED. Restoring a `Selected` row from the Recycle Bin onto a disposition that has since
     * appointed someone else is the ONE path that can produce two Selected rows, because the
     * platform has no `before undelete` and the guard therefore never runs. Wiring this service
     * there would SELF-HEAL that state — and three things in this repo depend on it remaining
     * reachable: `DispositionApprovalService.MULTIPLE_SELECTED_BOV_MESSAGE`, whose header names
     * undelete as the reason that branch is a live backstop rather than dead code;
     * `BovSubmissionSelectorTest.twoSelectedViaUndelete`, which BUILDS the state that way and
     * whose own comment says "EVERY STEP IS LORE-BEARING"; and
     * `selectSelectedByDispositionId_twoSelected_returnsBOTH`. Silently repairing it would turn
     * all three green-and-vacuous rather than red. If that trade is ever revisited, those three
     * are the things to change in the same commit.
     *
     * @param deleted Trigger.old. Null/empty-safe.
     * @example
     * BovAutoSelectionService.reselectForDeleted(oldList);
     */
    public static void reselectForDeleted(List<BOV_Submission__c> deleted) {
        if (deleted == null || deleted.isEmpty()) {
            return;
        }
        Set<Id> dispositionIds = new Set<Id>();
        for (BOV_Submission__c submission : deleted) {
            if (submission.Disposition__c != null) {
                dispositionIds.add(submission.Disposition__c);
            }
        }
        reselectFor(dispositionIds);
    }

    /**
     * The whole mechanism: ONE read, an in-memory plan per disposition, and AT MOST ONE write.
     *
     * @param dispositionIds the dispositions whose ranking may have changed; null/empty-safe.
     */
    @TestVisible
    private static void reselectFor(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return; // 🔴 the zero-query fast path — see the class header's budget
        }
        if (suppressReentry) {
            return; // our own Database.update re-entered us; see suppressReentry
        }

        // ONE query for the whole chunk, never one per disposition. It arrives ALREADY RANKED —
        // BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC — and nothing below re-sorts it,
        // deliberately: a second sort in Apex could disagree with what the matrix displays.
        List<BOV_Submission__c> ranked =
            BovSubmissionSelector.selectSelectionContextByDispositionIds(dispositionIds);
        if (ranked.isEmpty()) {
            return;
        }

        // Grouping preserves the query's relative order within each parent, which IS the ranking.
        // (`Disposition__c` is never null here — it is the query's own WHERE clause.)
        Map<Id, List<BOV_Submission__c>> siblingsByDisposition =
            new Map<Id, List<BOV_Submission__c>>();
        for (BOV_Submission__c submission : ranked) {
            List<BOV_Submission__c> siblings = siblingsByDisposition.get(submission.Disposition__c);
            if (siblings == null) {
                siblings = new List<BOV_Submission__c>();
                siblingsByDisposition.put(submission.Disposition__c, siblings);
            }
            siblings.add(submission);
        }

        List<BOV_Submission__c> writes = new List<BOV_Submission__c>();
        for (Id dispositionId : siblingsByDisposition.keySet()) {
            writes.addAll(planFor(siblingsByDisposition.get(dispositionId)));
        }
        if (writes.isEmpty()) {
            return; // locked, unscoreable, or already correct — all three cost ZERO DML
        }

        lastRunSelectionFailures = new List<String>();
        suppressReentry = true;
        try {
            // ── FOUR SEPARATE DECISIONS ON ONE STATEMENT. NONE COVERS ANOTHER'S OBSTACLE. ──
            // ONE STATEMENT: demotions and the promotion together, or
            //   BovSubmissionSelectionGuardService refuses it. See the class header.
            // SYSTEM_MODE: `Approval_Status__c` is granted READ-ONLY in both disposition permission
            //   sets (an approval process is its only other writer), so a USER_MODE write is
            //   refused for everyone. It does NOT bypass validation rules, which is correct.
            // without sharing: a SEPARATE refusal that SYSTEM_MODE cannot touch. See SelectionWrites.
            // allOrNone = TRUE, and this DIVERGES from `BovSubmissionTriggerHandler
            //   .ParentAdvanceWrites` deliberately: there, `allOrNone = false` protects an APPROVAL
            //   that is irreplaceable. Here a half-applied swap leaves TWO Selected rows — the exact
            //   defect the guard exists to prevent. A refusal is the correct outcome, and it rolls
            //   the user's save back with a real message rather than committing a broken invariant.
            new SelectionWrites().apply(writes);
        } catch (DmlException e) {
            // 🔴 REPORT, THEN RE-THROW UNCHANGED. `allOrNone = true` means there are no failed
            // SaveResults to inspect — the refusal arrives as this exception — so recording it here
            // is the ONLY way the StatusCode is ever visible. Swallowing it would recreate the
            // silent no-op that let the sibling handler's identical statement fail in production
            // and look exactly like success.
            recordSelectionFailures(e);
            throw e;
        } finally {
            suppressReentry = false;
        }
    }

    /**
     * Decides what, if anything, to write for ONE disposition. Pure in-memory: no SOQL, no DML.
     *
     * @param siblings every submission on one disposition, ALREADY in ranked order.
     * @return the rows to write; EMPTY when the disposition is locked, has neither a preferred row
     *         nor a scoreable response, or is already correct.
     */
    private static List<BOV_Submission__c> planFor(List<BOV_Submission__c> siblings) {
        List<BOV_Submission__c> noWrites = new List<BOV_Submission__c>();

        BOV_Submission__c preferredWinner;
        BOV_Submission__c scoredWinner;
        List<BOV_Submission__c> incumbents = new List<BOV_Submission__c>();
        for (BOV_Submission__c submission : siblings) {
            // THE LOCK, evaluated over ALL siblings — one locked row locks the disposition. Checked
            // FIRST on every row so a lock discovered late still discards a winner found early.
            if (submission.Approval_Pending__c == true
                || submission.Approval_Status__c != null
                || submission.Is_Manually_Appointed__c == true) {
                return noWrites;
            }
            if (STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                incumbents.add(submission);
            }
            if (submission.Is_Preferred_Broker__c == true) {
                if (preferredWinner == null || isNewer(submission, preferredWinner)) {
                    preferredWinner = submission;
                }
                continue; // a preferred row never competes on score — see the block below
            }
            if (scoredWinner == null && submission.BOV_Score__c != null) {
                // FIRST in ranked order = highest score, then oldest, then lowest Id. `siblings`
                // arrives in that order from the selector and nothing here re-sorts it.
                scoredWinner = submission;
            }
        }

        // ══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 A PREFERRED BROKER OUTRANKS EVERY SCORED RESPONSE, UNCONDITIONALLY AND WHATEVER IT
        //    SCORES. (User decision 2026-08-24 — see the class header's PREFERRED BROKERS block.)
        // ══════════════════════════════════════════════════════════════════════════════════════
        BOV_Submission__c winner = (preferredWinner != null) ? preferredWinner : scoredWinner;

        if (winner == null) {
            // No preferred row, and no scoreable response either. A null score is NOT a rank —
            // nothing is selected, and any existing incumbent is LEFT ALONE rather than demoted.
            // Demoting it would strip a sale of its broker the moment somebody blanked an asking
            // price, which is a destructive answer to a question nobody asked.
            return noWrites;
        }

        Boolean winnerAlreadySelected = STATUS_SELECTED.equals(winner.Submission_Status__c);
        if (winnerAlreadySelected && incumbents.size() == 1) {
            // Idempotent: already exactly right.
            // ⚠ STATED HONESTLY — THIS LINE IS A READABILITY SHORT-CIRCUIT, NOT A GUARD, AND NO
            // TEST CAN FALSIFY IT. The code below reaches the same answer: the sole incumbent IS
            // the winner, so the demotion loop skips it, and `winnerAlreadySelected` suppresses the
            // promotion, leaving `writes` empty either way. It is kept because it names the
            // intent — "the common case is that nothing needs to change" — at the point a reader
            // asks the question. Do not add a test claiming to cover it; it would be green against
            // both versions.
            return noWrites;
        }

        List<BOV_Submission__c> writes = new List<BOV_Submission__c>();
        for (BOV_Submission__c incumbent : incumbents) {
            if (incumbent.Id == winner.Id) {
                continue;
            }
            writes.add(new BOV_Submission__c(
                Id = incumbent.Id,
                Submission_Status__c = STATUS_BACKUP,
                // 🔴 BELT AND BRACES, AND PROVABLY ALREADY NULL. The lock above guarantees no row
                // on this disposition has a non-null Approval_Status__c, so this assignment can
                // never actually clear a real decision. It is written anyway because the guard's
                // header is explicit that a demotion WITHOUT this clause "recreates precisely the
                // state replaceSelectedBroker exists to prevent" — an Approved status on a broker
                // who is no longer appointed. Costs nothing; cannot regress.
                Approval_Status__c = null
            ));
        }
        if (!winnerAlreadySelected) {
            writes.add(new BOV_Submission__c(
                Id = winner.Id,
                Submission_Status__c = STATUS_SELECTED
            ));
        }
        return writes;
    }

    /**
     * Total order over PREFERRED rows: NEWEST FIRST (`CreatedDate DESC`, then `Id DESC`).
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 NEWEST, NOT OLDEST — AND IT IS THE EXACT OPPOSITE OF EVERY OTHER TIE-BREAK IN THIS MODULE
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * Every ranked query in `BovSubmissionSelector` breaks ties `CreatedDate ASC, Id ASC`, so this
     * inversion needs an argument rather than a preference:
     *
     *   THE REQUIREMENT IS "ADDING a preferred broker TAKES the Selected slot". Under oldest-wins,
     *   the FIRST preferred broker keeps the appointment forever and a second **Add Preferred
     *   Broker** click is a SILENT NO-OP — the row appears in the preferred list, the appointment
     *   does not move, and no error says why. That is a defect against the stated requirement, and
     *   it has no remedy: `BovSubmissionService.replaceSelectedBroker` REFUSES preferred rows
     *   (deliberately — read its PREFERRED_CANNOT_BE_APPOINTED_MESSAGE), so the user would have to
     *   delete or unflag the first preferred broker to correct a mistake.
     *
     * ⚠ AND THE "SILENT SWAP WITH NO ACTOR" OBJECTION — the one that makes a REJECTION lock this
     * feature out permanently (see the class header) — DOES NOT APPLY HERE, which is the whole
     * reason the two decisions differ. There, the algorithm would be overturning a decision a human
     * had just made. Here THE HUMAN IS THE ACTOR: they clicked Add Preferred Broker one second ago.
     * Honouring the most recent human instruction is the same principle, not an exception to it.
     *
     * ⚠ EDITING an older preferred row does NOT hand it the appointment: `CreatedDate` is immutable,
     * so a re-save changes nothing about this ordering. Only ADDING a new preferred row moves it.
     *
     * ⚠ `Id` IS COMPARED AS A STRING VIA `compareTo`, because Apex `Id` supports no relational
     * operator. It is a TIE-BREAK, not a clock — two preferred rows inserted in the SAME
     * transaction share a `CreatedDate` (every bulk load, every seed script) and something must
     * decide. All it has to be is TOTAL and STABLE, and lexicographic Id order is both.
     *
     * @param candidate the row being considered; never null.
     * @param incumbent the best preferred row found so far; never null.
     * @return true when `candidate` should displace `incumbent`.
     */
    private static Boolean isNewer(BOV_Submission__c candidate, BOV_Submission__c incumbent) {
        if (candidate.CreatedDate != incumbent.CreatedDate) {
            return candidate.CreatedDate > incumbent.CreatedDate;
        }
        return String.valueOf(candidate.Id).compareTo(String.valueOf(incumbent.Id)) > 0;
    }

    /**
     * Records every row the refused DML named, into `lastRunSelectionFailures` and the debug log.
     * The caller re-throws; this only makes the refusal readable.
     *
     * @param e the DmlException from the `allOrNone = true` write.
     */
    private static void recordSelectionFailures(DmlException e) {
        lastRunSelectionFailures = new List<String>();
        // Same getNumDml() guard as RecordStageAdvanceService.setStage and
        // BovSubmissionService.replaceSelectedBroker: a DmlException with NO row detail is a real
        // shape (MIXED_DML_OPERATION, LIMIT_EXCEEDED) on which getDmlMessage(0) itself throws.
        if (e.getNumDml() > 0) {
            for (Integer i = 0; i < e.getNumDml(); i++) {
                lastRunSelectionFailures.add(
                    e.getDmlId(i) + ' -> ' + e.getDmlStatusCode(i) + ' | ' + e.getDmlMessage(i));
            }
        } else {
            lastRunSelectionFailures.add('no row detail returned | ' + e.getMessage());
        }
        // NOT debug output — this is the failure channel. See lastRunSelectionFailures.
        System.debug(LoggingLevel.ERROR,
            'BovAutoSelectionService.reselectFor: AUTOMATIC BROKER APPOINTMENT REFUSED -> '
            + String.join(lastRunSelectionFailures, ' ;; ')
            + ' | running user: ' + UserInfo.getUserId() + '.');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT THAT ESCAPES SHARING, AND WHY IT HAS TO.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: whoever saved a BOV response, or whoever typed the asking price on the
     * Disposition. Routinely NOT the owner of the SIBLING row being demoted — four brokers, four
     * analysts, one sale is the normal shape of a BOV round.
     *
     * WHY THEY PREDICTABLY LACK RECORD-LEVEL EDIT ON THAT SIBLING:
     *   1. `BOV_Submission__c` is OWD **Private** (`BOV_Submission__c.object-meta.xml`,
     *      `<sharingModel>Private</sharingModel>`).
     *   2. `DPEG_Disposition_Edit` and `DPEG_Disposition_View` both carry `viewAllRecords = true`
     *      and NEITHER carries `modifyAllRecords` (read off both files, 2026-08-24).
     *   3. THAT COMBINATION IS THE TRAP, and it is the same one
     *      `BovSubmissionTriggerHandler.ParentAdvanceWrites` documents: the selection read above
     *      RETURNS the sibling (read access exists) and the write is then REFUSED (edit access does
     *      not). A read that succeeds is not evidence a write will.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` IS NOT SUFFICIENT AND COULD NEVER HAVE BEEN. Per
     * ARCHITECTURE.md §2: *"SYSTEM_MODE bypasses CRUD/FLS ONLY — it does NOT bypass sharing."* It
     * removes the OBJECT/FIELD refusal and leaves the RECORD one standing. FOUR SITES IN THIS
     * MODULE WERE FIXED FOR EXACTLY THIS ON 2026-08-21 AFTER A MEASURED PRODUCTION INCIDENT; this
     * is designed in from the start rather than discovered in UAT.
     *
     * WHY THE ESCAPE IS BOUNDED TO THIS ONE WRITE: the outer class stays `with sharing`, the
     * selector stays `with sharing`, and this inner class holds ONE statement over a list the
     * CALLER built. It cannot query, cannot choose rows and cannot widen — every Id in `writes`
     * came back from a `with sharing` selector read, so a submission the running user cannot SEE is
     * still never written. ARCHITECTURE.md §2 prescribes this exact shape; repo precedents are
     * `BovSubmissionTriggerHandler.ParentAdvanceWrites` and `NdaExpiryAlertBatch.stampMarkers`.
     *
     * ⚠ DO NOT PROMOTE THIS TO THE OUTER CLASS. `BovSubmissionSelector`,
     * `BovSubmissionBrokerStampService` and `BovSubmissionSelectionGuardService` are deliberately
     * sharing-scoped and argue for it in their own headers.
     */
    private without sharing class SelectionWrites {
        /**
         * @param writes rows built by `planFor` from a `with sharing` selector read; never null,
         *               never empty.
         * @throws DmlException on ANY refusal — `allOrNone = true`. The caller records and
         *         re-throws.
         */
        private void apply(List<BOV_Submission__c> writes) {
            Database.update(writes, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
