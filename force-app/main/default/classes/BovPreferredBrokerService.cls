/**
 * PREFERRED-BROKER RETIREMENT: when a new preferred broker is added to a Disposition, the OUTGOING
 * preferred submission is REMOVED FROM THE LIST — and a `BOV_Broker_Change__c` history row is
 * written FIRST, in the same transaction, so the swap survives the row that recorded it.
 * Added 2026-08-24 with the two-slot selection model (user decision).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE HISTORY ROW IS WRITTEN **BEFORE** THE DELETE, AND THE WHOLE THING IS ONE ATOMIC UNIT.
 *    THIS IS THE ENTIRE REASON THE CLASS EXISTS RATHER THAN A `delete` STATEMENT SOMEWHERE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * A delete that succeeds while the history insert fails destroys THE ONLY RECORD THAT THE BROKER
 * WAS EVER APPOINTED. `BOV_Submission__c` is `<enableHistory>false</enableHistory>` and the row
 * itself is gone, so there is no field history, no audit trail and nothing in the Recycle Bin a
 * report can read — the appointment simply never happened as far as the org is concerned. That is
 * strictly worse than either "no swap" or "swap plus history", and it is the ONE outcome this class
 * must make unreachable.
 *
 * Three mechanisms, and all three are needed:
 *   1. ORDER — history INSERT, then DELETE. If the insert is refused nothing has been destroyed yet.
 *   2. `allOrNone = true` ON BOTH — a partial insert (some brokers logged, some not) followed by a
 *      full delete is the same defect at a smaller scale. ⚠ `allOrNone = false` would SWALLOW it.
 *   3. A SAVEPOINT + ROLLBACK + RETHROW around the pair. Belt and braces today, because an uncaught
 *      exception in an after-insert trigger already rolls the whole transaction back — but it makes
 *      the atomicity a property of THIS CODE rather than of its current call site, so a future
 *      caller (a batch repair, a Queueable) cannot inherit half the guarantee.
 *
 * 🔴 IT THROWS RATHER THAN DEGRADING, AND THE ALTERNATIVE WAS CONSIDERED. Swallowing the failure
 * would leave the user's "Add Preferred Broker" click committed with TWO preferred rows on the sale
 * and no record of the swap — a state that LOOKS like success in the UI and is exactly the
 * half-applied outcome the savepoint exists to prevent. Refusing the click is honest and leaves the
 * previous preferred broker intact and re-attemptable. Same trade, same direction, as
 * `BovAutoSelectionService.reselectFor`'s `allOrNone = true`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THE DELETE CANNOT FIGHT AUTO-SELECTION — AND WHY THE CALL ORDER IN THE HANDLER IS PART
 *    OF THE MECHANISM, NOT A STYLE CHOICE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BovSubmissionTrigger` has an `after delete` context that routes to
 * `BovAutoSelectionService.reselectForDeleted`, which RE-RANKS the parent. So this class's delete
 * fires a full re-selection pass, synchronously, in the middle of its own work. That is not a hazard
 * to be worked around — it is the mechanism that fills the vacated slot — PROVIDED the replacement
 * row already exists when the delete happens:
 *
 *   ✅ THE ACTUAL SEQUENCE. The modal INSERTS the new preferred row (at `Backup`, carrying only the
 *      flag). That insert COMMITS. Its `after insert` fires. THIS SERVICE runs, logs, and deletes
 *      the outgoing row. The `after delete` re-rank therefore sees the NEW preferred row already
 *      present and promotes it. There is no window in which the sale has no preferred broker and no
 *      window in which an interim winner can be appointed, because both rows exist for the whole of
 *      it. `replacingThePreferredBroker_neverPromotesAnInterimWinner` is the falsifier.
 *
 *   ❌ THE SEQUENCE THAT WOULD FIGHT. Delete the outgoing row FIRST and insert the replacement
 *      afterwards — the obvious shape if this were driven from the client, or from a `before insert`
 *      context. The `after delete` re-rank would then run with the preferred slot genuinely empty,
 *      appoint whichever SCORED response ranks highest as an interim occupant, and the subsequent
 *      insert would have to undo it. Two appointments, two sets of writes, and a moment in which a
 *      broker nobody chose held the slot.
 *
 * ⚠ IT ALSO RUNS **BEFORE** `BovAutoSelectionService.reselect` IN `afterInsert`, and that ordering
 * is asserted rather than assumed. Running it after would mean the re-rank first DEMOTES the
 * outgoing preferred row (a write) and this class then deletes the row it just wrote to — wasted
 * DML on a doomed row, and one more chance for a refusal on a record that is about to cease to
 * exist.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THE `Reason__c` VALUE IS `Company Decision`, AND IT IS A COMPROMISE THAT SHOULD BE REVISITED
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BOV_Broker_Change__c.Reason__c` is a RESTRICTED picklist with six values — Initial Appointment,
 * Performance Issue, Better BOV Received, Broker Withdrew, Company Decision, Other — and its field
 * XML says in terms that the set is FINAL and must not be re-flagged as open. Adding a value is
 * `objects/` work and out of this class's scope, so of the six:
 *   `Company Decision` is the closest true statement — a human deliberately named a different
 *   preferred broker, which is a company decision and not a performance judgement about the
 *   outgoing one. `Other` would be the un-attributed row that whole workstream exists to prevent,
 *   and the remaining four each assert something specific that this event does not establish.
 *
 * 🔴 THE "IT WAS A PREFERRED BROKER" FACT IS CARRIED IN `Notes__c`, BECAUSE THERE IS NOWHERE ELSE.
 * The object has no boolean or type column, and the outgoing submission — which DOES carry
 * `Is_Preferred_Broker__c` — is about to be deleted, so `Outgoing_BOV_Submission__c` will be blank
 * on the very row that needs to answer the question. The authored `Notes__c` sentence is therefore
 * LOAD-BEARING DATA, not a comment: it is the only place the Broker Replace History card can learn
 * that this row records a preferred-broker swap. ⚠ RECOMMENDED FOLLOW-UP FOR THE ADMIN AGENT: add a
 * `Preferred Broker Replaced` value to `Reason__c` and repoint `REASON_PREFERRED_REPLACED` at it;
 * that is a one-constant change here and makes the fact reportable instead of merely readable.
 *
 * ── BUDGET / BULK ───────────────────────────────────────────────────────────────────────────
 * **AT MOST 1 SOQL AND AT MOST 2 DML PER CHUNK — CONSTANT IN THE NUMBER OF SUBMISSIONS.** No SOQL
 * and no DML inside any loop; the one query is keyed on the `Set<Id>` of parents drawn from the rows
 * that BECAME preferred.
 * 🔴 ZERO-QUERY FAST PATH: a chunk in which no row became preferred returns BEFORE the query, which
 * is what keeps this service invisible to every unrelated feature's 251-record bulk test — the same
 * "an ordinary save costs nothing" contract `BovAutoSelectionService` and
 * `BovSubmissionSelectionGuardService` already carry on these very contexts.
 * ⚠ THE `after delete` RE-RANK THIS SERVICE TRIGGERS HAS ITS OWN BUDGET (1 SOQL + at most 1 DML)
 * and is charged to the same transaction. A bulk test asserting THIS class's budget must therefore
 * assert the combined figure, or it will report a number that is right and mean nothing.
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES IN FULL — trigger path, loops over
 * a collection, no exemption to claim.
 *
 * ── RE-ENTRANCY ─────────────────────────────────────────────────────────────────────────────
 * ⚠ NO SUPPRESSION FLAG, AND IT IS NOT AN OVERSIGHT. This service is keyed on
 * `Is_Preferred_Broker__c` BECOMING true. Nothing it writes touches that field — it writes a
 * `BOV_Broker_Change__c` row and it deletes a submission — and the `after delete` re-rank it fires
 * writes only `Submission_Status__c` / `Is_System_Selected__c` / `Approval_Status__c`. So the
 * re-entry key can never be satisfied by this service's own output, and the fast path stops the
 * cascade at zero cost. Contrast `BovAutoSelectionService.suppressReentry`, which DOES write one of
 * its own change keys and needs the flag for cost rather than for correctness.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────────────────────
 * Service (`layer=service`, ARCHITECTURE.md §2, `.claude/rules/apex-layering-rule.md`). It cannot be
 * a Domain method (domains get zero SOQL and zero DML; this needs both) and it cannot live in the
 * trigger handler (same SOQL prohibition — the identical line
 * `BovSubmissionSelectionGuardService` and `BovSubmissionBrokerStampService` already sit on). ZERO
 * inline SOQL: the one read goes to `BovSubmissionSelector.selectPreferredByDispositionIds`. The
 * history row is built by `BovSubmissionService.buildChangeRow` — ONE writer of that row shape for
 * the whole module, deliberately; see that method's header for why the INSERT is not shared too.
 *
 * @see force-app/main/default/classes/BovSubmissionService.cls (the shared history row builder)
 * @see force-app/main/default/classes/BovAutoSelectionService.cls (the re-rank this delete fires)
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/BovSubmissionSelector.cls (the ONE query)
 */
public with sharing class BovPreferredBrokerService {

    /**
     * The `BOV_Broker_Change__c.Reason__c` value stamped on a preferred-broker swap. See the class
     * header for why it is `Company Decision` out of the six restricted values, and for the
     * follow-up that would replace it with a value that says what actually happened.
     *
     * ⚠ RESTRICTED PICKLIST: an off-list value throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at
     * DML in this org (measured twice on this project), so this string must match the field
     * metadata EXACTLY. It is `@TestVisible` so a test asserts the stamped value against the
     * constant rather than against a second hand-typed copy.
     */
    @TestVisible
    private static final String REASON_PREFERRED_REPLACED = 'Company Decision';

    /**
     * The two `Submission_Status__c` values. The picklist is RESTRICTED to exactly these, so the
     * pair is the WHOLE value set. Each layer holds its own copy (`BovSubmissionService`,
     * `BovAutoSelectionService`, `BovSubmissionSelectionGuardService`, `BovSubmissionSelector`,
     * `BovSubmissionTriggerHandler`); these are the retirement path's.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /** The runner-up value. See STATUS_SELECTED. */
    @TestVisible
    private static final String STATUS_BACKUP = 'Backup';

    /**
     * The authored `Notes__c` prefix. 🔴 THIS IS DATA, NOT A COMMENT — it is the only place the
     * history row records that the outgoing broker was a PREFERRED broker, because the submission
     * that carried `Is_Preferred_Broker__c` is deleted by the very operation being logged. See the
     * class header.
     */
    @TestVisible
    private static final String NOTES_PREFERRED_REPLACED =
        'Preferred broker replaced. The outgoing broker was a preferred broker and its BOV response '
        + 'was removed from this disposition when the new preferred broker was added.';

    /**
     * Every failure from the most recent retirement attempt, as `<recordId> -> <STATUS_CODE> |
     * <message>`. Reset at the top of every write attempt, so it describes ONE chunk's swap and not
     * a session; left EMPTY by every run that decided to write nothing.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON, and its relationship to the throw is the point. Both DML
     * statements are `allOrNone = true`, so a refusal THROWS rather than returning a failed
     * `SaveResult` — this list is populated from the exception on the way past and the exception is
     * re-thrown. A test can therefore assert the actual platform `StatusCode`
     * (`INSUFFICIENT_ACCESS_OR_READONLY` when the `without sharing` escape has been removed)
     * instead of an opaque "expected one preferred row, found two". Twin of
     * `BovAutoSelectionService.lastRunSelectionFailures`.
     */
    @TestVisible
    private static List<String> lastRunRetirementFailures = new List<String>();

    /**
     * Retires the preferred broker(s) a newly-added preferred broker replaces: logs one
     * `BOV_Broker_Change__c` per outgoing row, then deletes those rows.
     *
     * ── 🔴 THE TRIGGER KEY IS "BECAME PREFERRED", NOT "IS PREFERRED" ────────────────────────────
     * On INSERT (`priorById == null`) any row arriving with the flag qualifies. On UPDATE only a
     * row whose flag went false -> true does. Keying on "is preferred" instead would re-run the
     * retirement on EVERY ordinary save of an existing preferred row — and since the survivor is
     * recomputed from scratch each time that would be idempotent-and-free in the steady state and
     * catastrophic exactly once, on the save immediately following a data load that left two
     * preferred rows: a row a user was merely editing would silently delete its sibling.
     *
     * ⚠ THE UPDATE HALF IS WIRED EVEN THOUGH THE MODAL ONLY EVER INSERTS. `Is_Preferred_Broker__c`
     * is granted EDIT on `DPEG_Disposition_Edit` (its own field XML records why — the modal writes
     * it programmatically), so a user CAN flag an existing response by hand from a list view or the
     * API. Without the update hook that path would leave two preferred rows with nothing to retire
     * one, and the sale would sit outside the invariant with no error anywhere.
     *
     * @param incoming  Trigger.new. Null/empty-safe.
     * @param priorById Trigger.oldMap on update; NULL ON INSERT — on insert every flagged row
     *                  counts as newly preferred, which is the correct reading.
     * @throws Exception — unchanged and unwrapped — when the history insert or the delete is
     *         refused. USUALLY a `DmlException`, but NOT ALWAYS: a lookup-filter refusal on the
     *         history row's broker Contact has been measured arriving as another type, which is why
     *         the catch is untyped. The transaction is rolled back to the state it was in when this
     *         method was entered BEFORE the exception escapes, so a half-applied retirement is
     *         impossible.
     * @example
     * BovPreferredBrokerService.retireReplacedPreferred(newList, oldMap);
     */
    public static void retireReplacedPreferred(
        List<BOV_Submission__c> incoming,
        Map<Id, BOV_Submission__c> priorById
    ) {
        if (incoming == null || incoming.isEmpty()) {
            return;
        }

        Set<Id> dispositionIds = new Set<Id>();
        for (BOV_Submission__c submission : incoming) {
            if (submission.Disposition__c == null || submission.Is_Preferred_Broker__c != true) {
                continue;
            }
            BOV_Submission__c prior = (priorById == null || submission.Id == null)
                ? null
                : priorById.get(submission.Id);
            if (prior == null || prior.Is_Preferred_Broker__c != true) {
                dispositionIds.add(submission.Disposition__c);
            }
        }
        if (dispositionIds.isEmpty()) {
            return; // 🔴 the zero-query fast path — see the class header's budget
        }

        // ONE query for the whole chunk, never one per disposition. It arrives NEWEST FIRST, which
        // IS the survivor rule — see the selector's ORDER BY, which deliberately inverts every
        // other ranked query in that class and matches `BovAutoSelectionService.isNewer`.
        Map<Id, List<BOV_Submission__c>> preferredByDisposition =
            new Map<Id, List<BOV_Submission__c>>();
        for (BOV_Submission__c preferred
                : BovSubmissionSelector.selectPreferredByDispositionIds(dispositionIds)) {
            List<BOV_Submission__c> rows = preferredByDisposition.get(preferred.Disposition__c);
            if (rows == null) {
                rows = new List<BOV_Submission__c>();
                preferredByDisposition.put(preferred.Disposition__c, rows);
            }
            rows.add(preferred);
        }

        List<BOV_Broker_Change__c> history = new List<BOV_Broker_Change__c>();
        List<BOV_Submission__c> retirements = new List<BOV_Submission__c>();
        for (Id dispositionId : preferredByDisposition.keySet()) {
            List<BOV_Submission__c> rows = preferredByDisposition.get(dispositionId);
            if (rows.size() < 2) {
                // Nothing was REPLACED — this is the first preferred broker on the sale. No history
                // row and no delete: `BovSubmissionService.replaceSelectedBroker` owns the
                // "Initial Appointment" log for the scored slot, and inventing a second first-
                // appointment row here would put two rows in the card for one event.
                continue;
            }
            BOV_Submission__c survivor = rows[0]; // NEWEST — the broker the user just added
            for (Integer i = 1; i < rows.size(); i++) {
                BOV_Submission__c outgoing = rows[i];
                history.add(BovSubmissionService.buildChangeRow(
                    dispositionId,
                    outgoing,
                    survivor,
                    REASON_PREFERRED_REPLACED,
                    notesFor(outgoing, survivor)
                ));
                retirements.add(new BOV_Submission__c(Id = outgoing.Id));
            }
        }
        if (retirements.isEmpty()) {
            return; // first preferred broker on every disposition in scope — zero DML
        }

        lastRunRetirementFailures = new List<String>();
        // 🔴 THE SAVEPOINT IS TAKEN BEFORE THE FIRST WRITE AND AFTER ALL THE READS. See the class
        // header: the ordering (log, then destroy) is what makes the failure mode survivable, and
        // this is what makes it atomic even if a future caller is not a trigger.
        Savepoint beforeRetirement = Database.setSavepoint();
        try {
            // ── 🔴 HISTORY FIRST. NOTHING HAS BEEN DESTROYED YET IF THIS IS REFUSED. ──
            // SYSTEM_MODE: `BOV_Broker_Change__c` is a 2026-08-20 object whose fields arrive with NO
            //   permissions for ANY profile. More fundamentally, an audit row a user can suppress by
            //   lacking FLS on one column is not an audit row — the actor must not be able to
            //   decline to be recorded. Identical argument to `replaceSelectedBroker`'s own insert.
            // without sharing: a SEPARATE refusal SYSTEM_MODE cannot touch. See RetirementWrites.
            // allOrNone = true: a partial log followed by a full delete is the defect this class
            //   exists to prevent, at a smaller scale.
            new RetirementWrites().log(history);

            // ── THEN THE DESTRUCTIVE HALF. ──
            // ⚠ THIS DELETE FIRES `BovSubmissionTrigger`'s `after delete` -> the auto-selection
            // re-rank, synchronously, and that is intended: it is what promotes the surviving
            // preferred row into the vacated slot. See the class header for why the replacement row
            // is guaranteed to exist by this point.
            new RetirementWrites().retire(retirements);
        } catch (Exception e) {
            // ══════════════════════════════════════════════════════════════════════════════════
            // 🔴 RECORD, THEN ROLL BACK, THEN RE-THROW UNCHANGED — AND ALL THREE ORDERINGS WERE
            //    GOT WRONG ONCE BEFORE ARRIVING HERE. MEASURED 2026-08-24.
            // ══════════════════════════════════════════════════════════════════════════════════
            // 1. `catch (Exception e)`, NOT `catch (DmlException e)`. The first version caught only
            //    `DmlException` and `lastRunRetirementFailures` came back EMPTY from a run in which
            //    the retirement had demonstrably been refused (the submission survived, no history
            //    row existed, and the caller's own insert threw). Something other than a
            //    `DmlException` was escaping this block untouched — so the refusal was real, the
            //    rollback never ran here, and the ONLY reason the org was not left half-swapped is
            //    that an uncaught exception in an after-trigger rolls the DML statement back
            //    anyway. Relying on that would make this class's atomicity a property of its
            //    current CALL SITE rather than of itself, which is the exact thing the savepoint
            //    exists to avoid. ONE catch rather than two, per this repo's measured note that a
            //    second typed catch on a thin path is unreachable and fails the coverage gate.
            // 2. RECORD FIRST. `recordRetirementFailures` is pure in-memory bookkeeping and cannot
            //    fail; `Database.rollback` can. Recording afterwards means a rollback problem
            //    silently discards the only diagnostic of the ORIGINAL failure.
            // 3. RE-THROW UNCHANGED. `allOrNone = true` leaves no failed SaveResults to inspect,
            //    so this list is the only place the StatusCode is ever visible; and the re-throw is
            //    what refuses the user's click instead of committing a silent half-swap.
            recordRetirementFailures(e);
            Database.rollback(beforeRetirement);
            throw e;
        }
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 A ROW WHOSE PREFERRED FLAG FLIPS **SURRENDERS ITS SELECTED STATUS**, IN MEMORY, IN THE
     *    BEFORE CONTEXT. WITHOUT THIS STEP THE EXCLUSIVITY GUARD REFUSES THE USER'S OWN SAVE.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * MEASURED 2026-08-24, and it is the same trap this module has now hit three times: **THE FLAG
     * IS THE INPUT AND THE STATUS IS THE OUTPUT.** Flipping `Is_Preferred_Broker__c` moves a row
     * from one appointment slot to the other, and if it is Selected while it does so it arrives in
     * a slot the other broker already occupies:
     *
     *   UNFLAGGING a Selected preferred broker on a sale that also has a Selected scored winner
     *   -> two Selected NON-preferred rows -> `addError` -> **"Preferred Broker" is a checkbox the
     *   user cannot untick**, with a message about Replace Broker that does not apply to them.
     *   That is the exact shape of the un-flagging dead end recorded against
     *   `BOV_Amount_Required_On_Submission`, arriving from a completely different rule.
     *
     *   FLAGGING an already-Selected scored winner as preferred on a sale that has a preferred
     *   broker -> two Selected PREFERRED rows -> the mirror image, equally unusable.
     *
     * ⚠ THE FIX IS SYMMETRIC ON PURPOSE. A one-directional version would leave the other half
     * refusing, and the two halves are one user gesture apart.
     *
     * 🔴 IT SURRENDERS THE SLOT; IT DOES NOT AWARD ONE. The row drops to `Backup` and
     * `BovAutoSelectionService` — running in the AFTER context on the same save, because
     * `Is_Preferred_Broker__c` is one of its change keys — decides both slots afresh. So a row that
     * still deserves an appointment gets it back within the same transaction, and one that does not
     * simply stays Backup. Deciding here instead would be a second, weaker copy of the ranking.
     *
     * ⚠ ZERO SOQL, ZERO DML, AND IT MUST STAY THAT WAY: this runs in a BEFORE context, where the
     * only correct way to change the record being saved is to mutate it in memory.
     * ⚠ IT MUST RUN **BEFORE** `BovSubmissionSelectionGuardService.enforceSelectionExclusivity` in
     * `beforeUpdate`. The guard reads `Submission_Status__c` off the same in-memory rows; running
     * it first would refuse the save this method exists to allow.
     * ⚠ NO INSERT COMPANION, DELIBERATELY: a flag cannot "flip" on an insert, and a row inserted as
     * Selected-and-preferred beside an existing Selected preferred broker is a CLIENT DEFECT the
     * guard must keep refusing —
     * `BovSubmissionSelectionGuardTest.preferredInsertedAsSelected_isRefused_soTheModalMustNotSetIt`
     * is the interface agreement that depends on it.
     *
     * @param incoming  Trigger.new in a BEFORE UPDATE context. Null/empty-safe. MUTATED IN PLACE.
     * @param priorById Trigger.oldMap. Null-safe — nothing flips without an old value.
     * @example
     * BovPreferredBrokerService.surrenderSlotOnFlagChange(newList, oldMap);
     */
    public static void surrenderSlotOnFlagChange(
        List<BOV_Submission__c> incoming,
        Map<Id, BOV_Submission__c> priorById
    ) {
        if (incoming == null || incoming.isEmpty() || priorById == null) {
            return;
        }
        for (BOV_Submission__c submission : incoming) {
            if (!STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                continue; // not holding a slot on this save — nothing to surrender
            }
            BOV_Submission__c prior = (submission.Id == null) ? null : priorById.get(submission.Id);
            if (prior == null) {
                continue;
            }
            if ((prior.Is_Preferred_Broker__c == true)
                    != (submission.Is_Preferred_Broker__c == true)) {
                submission.Submission_Status__c = STATUS_BACKUP;
                // 🔴 THE SYSTEM FLAG GOES WITH IT. A row that surrendered its slot is not the
                // model's pick, and leaving a stale true here would make the approval router treat
                // a Backup row as the scored winner.
                submission.Is_System_Selected__c = false;
            }
        }
    }

    /**
     * The authored `Notes__c` body for one retirement — the constant sentence plus the two firm
     * names, so the Broker Replace History card reads as a sentence even when both Contact lookups
     * have been nulled by a broker-Contact cleanup (`deleteConstraint SetNull` on both).
     *
     * @param outgoing the submission being deleted; never null.
     * @param survivor the new preferred broker; never null.
     * @return the note text; never null and never blank.
     */
    private static String notesFor(BOV_Submission__c outgoing, BOV_Submission__c survivor) {
        // ⚠ NOT `from` / `to`: **`from` IS A RESERVED WORD IN APEX** and the compiler reports it
        // as "Unexpected token 'from'" on the DECLARATION line, which reads like a syntax error in
        // the string literal rather than a naming problem. Measured on this file, 2026-08-24.
        String outgoingFirm = String.isBlank(outgoing.Broker_Firm__c)
            ? '(firm not recorded)'
            : outgoing.Broker_Firm__c;
        String survivorFirm = String.isBlank(survivor.Broker_Firm__c)
            ? '(firm not recorded)'
            : survivor.Broker_Firm__c;
        return NOTES_PREFERRED_REPLACED
            + ' Replaced ' + outgoingFirm + ' with ' + survivorFirm + '.';
    }

    /**
     * Records every row the refused DML named, into `lastRunRetirementFailures` and the debug log.
     * The caller rolls back and re-throws; this only makes the refusal readable.
     *
     * @param e the exception from either `allOrNone = true` write. NOT typed to `DmlException`:
     *          a refusal here has been MEASURED to arrive as something else, and a signature that
     *          insisted otherwise is what left this list empty on a genuinely refused retirement.
     */
    private static void recordRetirementFailures(Exception e) {
        lastRunRetirementFailures = new List<String>();
        // Same getNumDml() guard as `BovSubmissionService.replaceSelectedBroker` and
        // `BovAutoSelectionService.recordSelectionFailures`: a DmlException with NO row detail is a
        // real shape (MIXED_DML_OPERATION, LIMIT_EXCEEDED) on which getDmlMessage(0) itself throws.
        // ⚠ THE `instanceof` IS NOT DEFENSIVE PADDING — it is the whole reason the catch above is
        // untyped. A non-DML exception has no row detail to read at all, and calling getNumDml() on
        // one would not compile.
        DmlException dml = (e instanceof DmlException) ? (DmlException) e : null;
        if (dml != null && dml.getNumDml() > 0) {
            for (Integer i = 0; i < dml.getNumDml(); i++) {
                lastRunRetirementFailures.add(
                    dml.getDmlId(i) + ' -> ' + dml.getDmlStatusCode(i) + ' | '
                    + dml.getDmlMessage(i));
            }
        } else {
            lastRunRetirementFailures.add(
                e.getTypeName() + ' | no row detail returned | ' + e.getMessage());
        }
        // NOT debug output — this is the failure channel. See lastRunRetirementFailures.
        System.debug(LoggingLevel.ERROR,
            'BovPreferredBrokerService.retireReplacedPreferred: PREFERRED BROKER SWAP REFUSED AND '
            + 'ROLLED BACK -> ' + String.join(lastRunRetirementFailures, ' ;; ')
            + ' | running user: ' + UserInfo.getUserId() + '.');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE TWO STATEMENTS THAT ESCAPE SHARING, AND WHY THEY HAVE TO.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: whoever clicked **Add Preferred Broker**. Routinely NOT the owner of the
     * OUTGOING preferred submission — the previous preferred broker was very likely added by a
     * different analyst, which is the normal shape of a BOV round on a shared sale.
     *
     * WHY THEY PREDICTABLY LACK RECORD-LEVEL DELETE ON THAT ROW:
     *   1. `BOV_Submission__c` is OWD **Private** (`<sharingModel>Private</sharingModel>`).
     *   2. `DPEG_Disposition_Edit` and `DPEG_Disposition_View` both carry `viewAllRecords = true`
     *      and NEITHER carries `modifyAllRecords`.
     *   3. THAT COMBINATION IS THE TRAP, and it is the same one
     *      `BovAutoSelectionService.SelectionWrites` and
     *      `BovSubmissionTriggerHandler.ParentAdvanceWrites` each document: the selector read above
     *      RETURNS the row (read access exists) and the write is then REFUSED (delete access does
     *      not). A read that succeeds is not evidence a write will.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` IS NOT SUFFICIENT AND COULD NEVER HAVE BEEN. Per
     * ARCHITECTURE.md §2: *"SYSTEM_MODE bypasses CRUD/FLS ONLY — it does NOT bypass sharing."* It
     * removes the OBJECT-level refusal (which matters independently here: NEITHER disposition
     * permission set grants `allowDelete` on `BOV_Submission__c`, so a USER_MODE delete is refused
     * for EVERY persona this feature exists for) and leaves the RECORD-level one standing. FOUR
     * SITES IN THIS MODULE WERE FIXED FOR EXACTLY THIS ON 2026-08-21 AFTER A MEASURED PRODUCTION
     * INCIDENT; this is designed in from the start rather than discovered in UAT.
     *
     * WHY THE ESCAPE IS BOUNDED: the outer class stays `with sharing`, the selector stays
     * `with sharing`, and this inner class holds TWO statements over lists the CALLER built. It
     * cannot query, cannot choose rows and cannot widen — every Id came back from a `with sharing`
     * selector read, so a submission the running user cannot SEE is never deleted. ARCHITECTURE.md
     * §2 prescribes this exact shape.
     *
     * ⚠ DO NOT PROMOTE THIS TO THE OUTER CLASS. `BovSubmissionSelector` and
     * `BovSubmissionSelectionGuardService` are deliberately sharing-scoped and argue for it in their
     * own headers.
     */
    private without sharing class RetirementWrites {
        /**
         * @param history rows built by `BovSubmissionService.buildChangeRow`; never null/empty.
         * @throws DmlException on ANY refusal — `allOrNone = true`.
         */
        private void log(List<BOV_Broker_Change__c> history) {
            Database.insert(history, true, AccessLevel.SYSTEM_MODE);
        }

        /**
         * @param retirements Id-only shells for the outgoing preferred submissions; never
         *                    null/empty. Called ONLY after `log` has succeeded.
         * @throws DmlException on ANY refusal — `allOrNone = true`.
         */
        private void retire(List<BOV_Submission__c> retirements) {
            Database.delete(retirements, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
