/**
 * PHASE 0 WIRE-FRAUD PREREQUISITE GATE — refuses to let a checklist Task be completed while the
 * item it depends on is still open. Story 28; design `agent-output/design-transaction-fsd-gaps.md`
 * §5.1 and §10 (Phase 0).
 *
 * layer=service (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md). Zero inline SOQL — the
 * single read is `TaskSelector.selectChecklistByDealsAndSequences`. Zero DML — this runs in a BEFORE
 * context and mutates the record the platform is already saving, exactly like
 * `OnboardingTaskDomain.stampCompletion` (the established precedent for a before-context Task rule
 * in this org). No Domain class was added: the rule needs a database read, which the Domain Purity
 * Rule forbids, and splitting a temporary feature across three classes to gain nothing is the
 * over-engineering this phase was explicitly told not to do.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT WAS UNENFORCED BEFORE THIS CLASS
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Item B3 (*Send wire request to accounting with verified instructions*) could be completed while
 * B2 (*Call title company to verbally verify wiring instructions (anti-fraud)*) was still open.
 * Same for I8 vs I7. `TransactionTaskService.completeWireVerification` requires a verifier name and
 * phone ON THE VERIFICATION TASK ITSELF and says nothing about the item that follows, and it is
 * only the LWC path in any case — a data loader, the REST API, a Flow or a list-view inline edit
 * completed B3 with no check whatsoever. Story 28 requires enforcement in automation, not UI
 * convention, which is why the rule lives in a trigger context every write path passes through.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 NO SUBJECT-TEXT PARSING. THIS IS THE POINT OF THE FEATURE, NOT A STYLE PREFERENCE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TaskRollupService.cls:48` derives `Wire_Open_Risks__c` from
 * `Subject.toLowerCase().contains('anti-fraud')`, and `transactionTaskGroups.js:11` re-derives
 * CRITICAL by regex on the same string. That is RISK 1 in the design: two independent parsers of a
 * free-text field, neither of which throws when it stops matching — they silently return zero. This
 * class adds NO third parser. Every prerequisite decision here is made from `Blocked_By__c` DATA:
 * stamped at fan-out by `TaskFanoutService` on new deals, and by
 * `scripts/backfill-task-blocked-by.apex` on deals that already existed.
 * ⚠ IN PHASE 0 THE PAIR TABLE IS HARDCODED, in `TaskFanoutService.PREREQUISITE_SEQUENCES`, so
 * adding a third pair IS a deploy of that class. This header previously claimed it was "a data
 * change, not a deploy" — that is design §5.1's INTENT, and it needs the
 * `Transaction_Task_Def__mdt.Blocked_By_Sequence__c` column, which does not exist (the type has six
 * fields today) and is Phase 1 work. The pairs are still keyed on structured coordinates
 * (`Group_Letter__c` + `Sequence__c`), never on Subject text, which is the property that matters
 * here.
 * ⚠ The prerequisite's `Subject` IS interpolated into the refusal MESSAGE. That is DISPLAY, not
 * control flow — no branch anywhere in this class reads it. Do not "tidy" it into a match.
 * ⚠ A naive `contains('critical')` also wrongly matches A4 ("Receive critical dates from title
 * company") and A5 ("Log critical dates into Salesforce deal record"). Another reason not to start.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SHAPE OF `Blocked_By__c`: `Text(20)` HOLDING `<GroupLetter>|<Sequence>` — e.g. `B|2`, `I|7`.
 *    IT IS NOT A LOOKUP, AND IT CANNOT BE. THIS WAS MEASURED, NOT CHOSEN.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The design (§5.1 mechanism 1) specified a self-lookup. A `CustomField` with `referenceTo` = `Task`
 * FAILS DEPLOY on this platform:
 *     referenceTo value of 'Task' does not resolve to a valid sObject type
 * measured against `usman-dpeg` on 2026-08-31 (see the field's own `<description>` and
 * `objects/Activity/validationRules/Prerequisite_Must_Be_Met_To_Complete`). Task and Event are not
 * valid custom-relationship TARGETS. So the prerequisite is named by a KEY and found as a SIBLING
 * under the same `Transaction_Deal__c`.
 *
 * ALL of that knowledge — the parse, the sibling lookup, the index — lives in ONE private method,
 * `resolvePrerequisites`. Everything else in this class, in `TaskRollupTriggerHandler` and in the
 * test class is keyed on the BLOCKED Task's own Id and never touches `Blocked_By__c`. That is not
 * decoration: the class was first written for the lookup shape and converting it touched exactly
 * that one method plus one selector signature.
 *
 * ⚠ THE TEXT SHAPE IS ALSO OPERATIONALLY BETTER HERE, WHICH IS WORTH RECORDING SO NOBODY "UPGRADES"
 * IT LATER: `TaskFanoutService.fanOutNow` inserts B2 and B3 in the SAME `Database.insert`, so a
 * lookup could not have been populated inline — the target Id does not exist yet — and the fan-out
 * would have needed a second DML pass over rows it had just created. The key needs no such pass, and
 * `fanOutNow` DOES now stamp it inline (`tk.Blocked_By__c = blockedByKeyFor(...)`), pinned by
 * `TaskFanoutServiceTest.fanOutStampsWireFraudPrereqKeys`. That test is load-bearing for everything
 * below: without the stamp this gate is RETRO-ONLY — live for backfilled deals and silently absent
 * on every deal created afterwards — and no test in `TaskPrerequisiteServiceTest` would notice,
 * because every fixture in it sets the key by hand.
 * ⚠ THE COST OF THE TEXT SHAPE, EQUALLY PLAINLY: the key is not referentially enforced. A typo, a
 * renamed group letter, or a deal whose prerequisite row was never fanned out all resolve to
 * NOTHING — which this class treats as UNRESOLVED and refuses (fail closed), never as "met".
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ INERT FOR EVERY TASK THAT IS NOT A BLOCKED CHECKLIST ITEM — THE ORG-WIDE COST CONTROL
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TaskRollupTrigger`'s before contexts fire on EVERY Task in the org: the Property Management
 * Onboarding checklist, the 82-row Transaction Day-0 fan-out, Broker Protection pipeline Tasks, EAC
 * companion Tasks, Disposition closing Tasks, and every hand-created Activity. For all of them the
 * cost of this class is TWO blank checks on update (`Blocked_By__c` on `Trigger.new` and on
 * `Trigger.old` — see the surviving-key note at `enforceOnUpdate`) and ONE on insert, with no query,
 * no DML, and no statement that can fail and roll back an unrelated save — the same bound
 * `OnboardingTaskDomain.stampCompletion` established for its own stamp. Only two Tasks per
 * Transaction ever carry a non-blank `Blocked_By__c` (B3 and I8). Onboarding is untouched.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * GOVERNOR BUDGET (pinned by TaskPrerequisiteServiceTest against named constants)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   SOQL per trigger chunk : 0 when no Task in the chunk carries a `Blocked_By__c` (the org-wide
 *                            case), and 0 again when every key in the chunk is unparseable;
 *                            EXACTLY 1 otherwise. NEVER a function of row count.
 *   SOQL in before INSERT  : 0, always — `clampOnInsert` does no lookup at all, deliberately. This
 *                            is the line that keeps the Day-0 fan-out's 41 before-insert firings
 *                            free; see `enforceOnUpdate` for the arithmetic.
 *   DML  per trigger chunk : 0, always, in BOTH contexts. Before-context, in-memory mutation only.
 *   Rows returned          : ~`groups x sequences` per deal — ~22 for the real B3/I8 pair, so
 *                            ~2,200 for a saturated 200-row chunk of blocked items (100 deals).
 *                            Derived at `TaskSelector.selectChecklistByDealsAndSequences`.
 *   Permission gate        : +0 SOQL on every path this budget cares about, and AT MOST +1 per
 *                            TRANSACTION in the worst case. `hasPrereqOverrideAccess` is asked ONLY
 *                            from branch B of `refusalFor`, after four cheap conditions have already
 *                            established that the save is a disarm attempt — so an ordinary
 *                            completion, an ordinary edit and every unblocked Task never reach it.
 *                            The custom-permission check itself is free; only a NON-holder falls
 *                            through to the `Modify All Data` read, that read is one query, and it
 *                            is cached per transaction by
 *                            `TransactionActionPermissionService`. The `&&` ordering that keeps this
 *                            true is load-bearing — do not reorder the conjuncts in branch B.
 * This matters because a throw here rolls back the user's own save, and because routing a new query
 * into this trigger is measured to cost `ceil(rows/200)` SOQL AND DML at Day-0 fan-out scale — the
 * exact cost design §8 says must not be added. It is not added: this class runs in BEFORE UPDATE
 * only. See `enforceOnUpdate` for why the before-INSERT context is deliberately not used.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ SHARING AND MODE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `with sharing`, and the selector read is `WITH SYSTEM_MODE` (justified at its own declaration in
 * `TaskSelector`). SYSTEM_MODE is mandatory, not convenient: `Blocked_By__c` is a Metadata-API-
 * deployed custom field, which arrives with ZERO FieldPermissions for any profile including System
 * Administrator, and `USER_MODE` THROWS rather than degrades — `System.QueryException: No such
 * column`, which escapes a trigger as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the
 * user's save. That exact failure already rolled back a whole 82-Task Day-0 fan-out in this org
 * (see `TaskSelector`'s header, 2026-08-05).
 * SYSTEM_MODE does NOT lift sharing, deliberately. `TaskFanoutService` sets every checklist Task's
 * `OwnerId` to the Transaction owner, so B2 and B3 always share an owner and the read is satisfied
 * by ownership on every path the model builds. NOT widened to `without sharing`: `TaskSelector`'s
 * header states plainly that staying `with sharing` is what makes its SYSTEM_MODE group safe, and
 * one temporary gate is not the place to reverse that. The residual — an individually REASSIGNED
 * checklist Task whose prerequisite is then invisible — fails CLOSED (see below), so it produces a
 * loud refusal rather than a silent bypass of an anti-fraud control.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ WHERE THE REFUSAL SITS, AND WHY THAT IS THE ONLY PLACE IT WORKS
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Task object EDIT is UN-GRANTABLE by permission set on this platform — `ObjectPermissions
 * .SobjectType` excludes `Task`/`Event`/`Activity`, and a permission set carrying such a block
 * deploys green and is then silently discarded. That is why `TransactionTaskService` authorizes via
 * the `Transaction_Task_Actions` custom permission and then writes with
 * `AccessLevel.SYSTEM_MODE`. A refusal implemented in that service would therefore cover ONE path.
 * A before-update trigger runs for a `SYSTEM_MODE` write exactly as it does for a user-mode one, so
 * this refusal survives the org's own completion service, the standard UI, Flow, the REST API and
 * Data Loader alike. `TaskPrerequisiteServiceTest` proves the SYSTEM_MODE case explicitly rather
 * than assuming it.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ACCEPTED RESIDUALS — deliberate, and cheap only because Phase 0 is discarded at M5
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 1. COMPLETING B2 AND B3 IN THE SAME DML IS REFUSED. The read sees committed state, so B2's
 *    in-flight completion is invisible and B3 is refused. This is DELIBERATE HARDENING, not a bug:
 *    a single write that closes the verification and the wire request together is precisely the
 *    fraud pattern the control exists to stop. Nobody making the phone call does both in one save.
 * 2. REOPENING B2 AFTER B3 COMPLETED IS NOT REFUSED, and leaves `Is_Prerequisite_Met__c` stale-true
 *    on B3 until B3 is next saved. Correcting it would need a query plus DML against a DIFFERENT
 *    record from a before context — the `ceil(rows/200)` cost this class exists to avoid. The
 *    trigger refusal itself is never stale (it re-reads every time); only the denormalised backstop
 *    is, and only for a record already past the gate.
 * 3. CREATING A TASK ALREADY COMPLETE is not resolved here — the insert context CLAMPS
 *    (`clampOnInsert`) but does no sibling lookup, so the refusal itself comes from
 *    `Prerequisite_Must_Be_Met_To_Complete`'s `ISNEW()` arm reading the clamped value. The
 *    consequence: an insert is refused whenever a key is present, WITHOUT regard to whether the
 *    prerequisite is actually complete. Strictly fail-closed, and harmless in this model because the
 *    fan-out creates every item `Not Started`. See `enforceOnUpdate` for the governor arithmetic
 *    behind not querying there.
 * 4. ✅ THE TWO-SAVE DISARM-THEN-COMPLETE IS NOW CLOSED — this entry is kept as the record of how,
 *    because the fix is not where anyone would look for it. Blanking or repointing the key on an
 *    OPEN item is refused up front by branch (B) of `refusalFor`, so the sequence never reaches its
 *    second save. Nothing downstream could have caught it: by the second save neither
 *    `Trigger.old` nor the validation rule's `BLANKVALUE(Blocked_By__c, PRIORVALUE(Blocked_By__c))`
 *    has a key left to resolve, and `Task` field history is not tracked, so it left no trace either.
 *    The two earlier proposals were both wrong and are recorded so they are not retried: field
 *    history only makes it visible after the fact, and "refuse any blanking save whose key resolves"
 *    would have refused the documented repair path (a completed item being tidied up). What made it
 *    free was widening the surviving-key rule from "while the transition is happening" to "while the
 *    row is open" — the resolution branch (B) needs is then already in hand, so it costs no extra
 *    query, no extra field and no validation-rule change.
 *    ⚠ RESIDUAL WITHIN THE FIX: while B2 is open, a principal without `Transaction_Prereq_Override`
 *    cannot change or remove B3's coordinate. See `refusalFor` for the five narrowings that keep
 *    repair, maintenance, the backfill and administrative work possible.
 * 4a. ✅ THE TWO-SAVE REOPEN-AND-ERASE IS NOW CLOSED (EXPLOIT C, found in the Phase 2 review while
 *    this gate was already LIVE). `update {Status='Not Started', Blocked_By__c=null}` then
 *    `update {Status='Completed'}` slipped every branch, with ordinary Edit access and no override:
 *    branch (A) declined because the save was LEAVING completion, branch (B) declined on
 *    `!wasClosed`. Closed by `pastTheGate` (was done AND still done) replacing `wasClosed` in BOTH
 *    the precedence rule and branch (B) — see the candidate loop in `enforceOnUpdate`.
 *    ✅ THE THREE-SAVE VARIANT IS A USER-ACCEPTED DECISION (2026-09-01), NOT AN OPEN DEFECT. THIS IS
 *    THE STANDING ANSWER IF IT IS RAISED AGAIN — do not "fix" it, and do not gate done-row
 *    maintenance on the override.
 *    The variant: clear the coordinate on a row that STAYS done (permitted — residual 6 below),
 *    reopen it (now no coordinate on either side, so not a candidate), complete it. Same end state
 *    as EXPLOIT C, one more save.
 *    WHY IT IS ACCEPTED RATHER THAN CLOSED, which is the part that makes this a decision and not a
 *    shrug — the two outcomes are NOT the same kind of thing:
 *      • EXPLOIT C let a row whose prerequisite was open reach a COMPLETED state it had not earned.
 *        That is the Story 28 threat model, and it is closed.
 *      • This variant operates on a row that was ALREADY LEGITIMATELY COMPLETE — it passed the gate
 *        when it was completed. Erasing its coordinate destroys the AUDIT SIGNAL (a completed B3
 *        carrying `Is_Prerequisite_Met__c = false` is the finding
 *        `scripts/backfill-task-blocked-by.apex` reports), but it completes nothing that was not
 *        already complete. Evidence loss on a settled row, not an unearned completion.
 *    THE COST OF CLOSING IT WAS THE DECIDING FACTOR: refusing coordinate changes on done rows too
 *    would break the backfill's own corrections, the Phase 4 re-link and
 *    `allowsClearingTheKeyOnAnAlreadyCompleteRow` for every principal without
 *    `Transaction_Prereq_Override` — i.e. it would make routine maintenance of a completed checklist
 *    an admin-only operation. (The one-clause form, recorded so nobody has to re-derive it: drop
 *    `!pastTheGate` from branch (B) and rely on the override for all maintenance.)
 *    MITIGATION OF RECORD: the FLS lockdown on the identity fields, which removes the UI, list-view,
 *    Data Loader and REST routes to step 1 and leaves only custom system-mode Apex — a deploy, not a
 *    data edit. Treat any change to those fields' FLS as a change to this control's threat model.
 * 4b. 🔴 STILL OPEN — RENUMBER THE PREREQUISITE ITSELF (three saves). NOT CLOSED IN CODE, and this
 *    entry is the record of why, not an oversight:
 *      (i)   set B2's OWN `Task_Sequence__c` to 99. B2 carries no `Blocked_By__c` on either side, so
 *            it leaves the candidate loop at the very first blank check and is COMPLETELY UNGUARDED
 *            by this class — there is nothing here that looks at a row's own identity fields.
 *      (ii)  B3's key `B|2` now resolves to nothing, so branch B declines (`prerequisite == null`)
 *            and the key can be cleared. That is the `allowsRepairingAnUnresolvableKeyOnAnOpenItem`
 *            path being used exactly as designed, after the attacker manufactured the state it
 *            exists to repair.
 *      (iii) complete B3. No key on either side, so no candidate, no check.
 *    CLOSING IT NEEDS A REVERSE LOOKUP — "is this row pointed at by an open sibling's key?" — asked
 *    for EVERY Task whose `Task_Sequence__c`, `Task_Group__c` or `Transaction_Deal__c` changes.
 *    Those rows carry no key, so they are precisely the ones the org-wide cost control exists to
 *    discard for free; the question cannot be answered from `Trigger.new`, and adding a query there
 *    puts one on a context that has none today and that the Day-0 fan-out cascade cannot afford
 *    (§8; ~41 firings). Inside Phase 0's budget it is judged un-closeable, and Phase 1's
 *    `Checklist_Item__c` model removes the premise entirely by making the link a real relationship.
 *    ⚠ WHAT ACTUALLY MITIGATES IT IS THE FLS LOCKDOWN, NOT THIS CLASS. With `Task_Sequence__c`,
 *    `Task_Group__c` and `Transaction_Deal__c` locked read-only on the checklist personas, step (i)
 *    is unavailable from the UI, a list view, Data Loader and the REST API. What remains is custom
 *    system-mode Apex, which is a deploy, not a data edit. Treat any change to those three fields'
 *    FLS as a change to this control's threat model.
 * 5. THE KEY IS NOT REFERENTIALLY ENFORCED — it is Text, because a Task lookup is undeployable. A
 *    key naming a row that does not exist (bad letter, wrong sequence, un-fanned-out deal) refuses
 *    the completion rather than allowing it, and there is no platform error at the moment the bad
 *    key is WRITTEN. `scripts/backfill-task-blocked-by.apex` therefore refuses to write a key whose
 *    target row it cannot find, and reports those deals instead of bricking them.
 * 6. `Is_Prerequisite_Met__c` IS LEFT AT ITS `false` DEFAULT FOR UNBLOCKED TASKS — it is NOT stamped
 *    `true` for them. Stamping every unblocked Task would mean touching EVERY Task in the org in a
 *    before context, which is exactly the org-wide cost control above. Nothing breaks, because
 *    `Prerequisite_Must_Be_Met_To_Complete` short-circuits on its surviving-key conjunct before it
 *    ever reads the checkbox. Do NOT "fix" this class to stamp every Task.
 *    (The field's `<description>` briefly claimed the opposite — "True when Blocked_By__c is blank,
 *    or when…" — and has since been corrected to match this. Read it as the second opinion, not as
 *    a spec this class must satisfy.)
 * 7. `Task_Group__c` IS PARSED FOR ITS LEADING LETTER, capped at ONE character. Two consequences,
 *    and the first is smaller than this entry used to claim:
 *    - AN ARBITRARY BAD SHAPE IS NOT REACHABLE. `Task_Group__c` is a RESTRICTED picklist, so
 *      "anything writes it in a different shape" cannot happen while the restriction stands — the
 *      platform refuses the value before this class sees it, which is a backstop, not a limitation.
 *      Do not relax the restriction to make a test easier; that trade was considered and refused.
 *    - THE ONE REAL CASE IS `H2`. It is the only value in the set with a two-character letter, so no
 *      prerequisite pair can ever be defined inside group H2 — both `groupLetterOf` and the key
 *      parser reject it, and such a pair would fail CLOSED (uncompletable), not merely un-gated. The
 *      note lives at `TaskFanoutService.PREREQUISITE_SEQUENCES`, which is where a pair gets added.
 *
 * @see force-app/main/default/classes/TaskRollupTriggerHandler.cls (sole production caller)
 * @see force-app/main/default/classes/TaskSelector.cls (the single read)
 * @see scripts/backfill-task-blocked-by.apex (seeds Blocked_By__c on live deals)
 * @see agent-output/design-transaction-fsd-gaps.md §5.1, §10
 */
public with sharing class TaskPrerequisiteService {

    /**
     * The Task statuses that mean "done", for the record BEING SAVED.
     *
     * 🔴 SOURCED FROM `standardValueSets/TaskStatus.standardValueSet-meta.xml`, WHICH IS COMMITTED
     * TO THIS REPO AND IS AUTHORITATIVE. Exactly one of its five values carries
     * `<closed>true</closed>`: `Completed`. (`Deferred` and `Waiting on someone else` are OPEN.)
     *
     * ⚠ WHY A CONSTANT AND NOT `Task.IsClosed` ON THE INCOMING RECORD. `IsClosed` is derived by the
     * platform from `Status` at save time. In a BEFORE context `Trigger.new[i].IsClosed` cannot be
     * relied on to reflect the NEW status, and if it reflects the OLD one then REOPENING a completed
     * B3 would read as "entering completion" and be refused — a false refusal that would make the
     * item permanently uncompletable-and-unreopenable. `IsClosed` IS used, and IS authoritative, for
     * the two records read from the database (the prerequisite, and `Trigger.old`).
     *
     * ⚠ MAINTENANCE COUPLING, STATED SO IT IS NOT DISCOVERED THE HARD WAY: if a new value with
     * `<closed>true</closed>` is ever added to that value set, it must be added HERE and to
     * `Prerequisite_Must_Be_Met_To_Complete`'s `ISPICKVAL(Status, 'Completed')` IN THE SAME CHANGE.
     *
     * 🔴 AND IT FAILS OPEN IN BOTH DIRECTIONS, NOT ONE. The gate uses two different completeness
     * tests on purpose — this constant for the record BEING SAVED, `IsClosed` for the queried
     * PREREQUISITE — and a new closed status breaks each of them differently:
     *   - DEPENDENT side: a dependent moved to `Signed Off` (say) is not in this Set, so
     *     `isEnteringCompletion` returns false and the item CLOSES WITH NO CHECK AT ALL.
     *   - PREREQUISITE side: the opposite, and quieter still. The prerequisite's `IsClosed` IS true
     *     for the new status, so the gate reads it as satisfied and OPENS — correct if the new
     *     status genuinely means "the phone call happened", and a silent bypass if it means
     *     something like `Cancelled` that the platform merely marks closed.
     * Neither failure throws. `TaskPrerequisiteServiceTest.completedStatusesMatchesTaskStatusMetadata`
     * turns the first half of this note into an assertion; the second half is unassertable from Apex
     * (nothing exposes the INTENT of a closed status) and is why it is written down here.
     */
    @TestVisible
    private static final Set<String> COMPLETED_STATUSES = new Set<String>{ 'Completed' };

    /**
     * Refusal shown when the prerequisite exists and is still open. Prerequisite Subject appended.
     *
     * 🔴 BOTH MESSAGE CONSTANTS ARE DELIBERATELY PURE ASCII, WITH NO `& < > " '`, AND THAT IS A
     * FUNCTIONAL REQUIREMENT — NOT HOUSE STYLE. `SObject.addError(String)` HTML-ESCAPES by default,
     * so an em-dash becomes `&mdash;` and a quotation mark becomes `&quot;` in the message the
     * platform actually stores. `asRefusal` recognises this class's own refusal by matching these
     * constants against `DmlException.getDmlMessage`, so a single escaped character would break the
     * match SILENTLY — the LWC would fall back to "Refresh the page and try again" on the one path a
     * human uses, which is the exact defect the translation exists to fix. It would also render as
     * literal entity text in the toast. Adding punctuation here is not cosmetic; keep it ASCII.
     */
    @TestVisible
    private static final String MSG_BLOCKED =
        'This step cannot be completed yet: the anti-fraud verification step it depends on is still '
        + 'open. Complete that step first, then return to this one. Waiting on: ';

    /**
     * Refusal shown when the prerequisite could not be read at all. FAILS CLOSED — for an anti-fraud
     * control, "I could not prove the verification happened" must mean "no", never "probably fine".
     * Reachable when the prerequisite row was deleted, or when record-level sharing hides it from the
     * running user (an individually reassigned checklist Task — see the class header's sharing note).
     */
    @TestVisible
    private static final String MSG_UNRESOLVED =
        'This step cannot be completed: the step it depends on could not be read. It may have been '
        + 'deleted, or you may not have access to it. Contact your administrator. This is an '
        + 'anti-fraud control and it will not be bypassed.';

    /**
     * Refusal shown when a save tries to DISARM a live gate — blanking or repointing
     * `Blocked_By__c` on an item that is still open while its current prerequisite is still open.
     * Stops the first save of the two-save bypass (disarm now, complete later), which nothing
     * downstream can catch: by the second save neither `Trigger.old` nor the validation rule's
     * `PRIORVALUE` has a key left to resolve.
     *
     * ASCII-only, for the reason given at `MSG_BLOCKED`.
     */
    @TestVisible
    private static final String MSG_DISARM =
        'The prerequisite on this step cannot be changed or removed while the anti-fraud '
        + 'verification it points to is still open. Complete that verification step first. If the '
        + 'reference itself is wrong, contact your administrator.';

    /**
     * Number of selector reads this class has performed in the current transaction.
     *
     * The governor assertion in `TaskPrerequisiteServiceTest` pins THIS rather than
     * `Limits.getQueries()`, because the trigger cascade also spends queries in `TaskRollupService`
     * and a whole-transaction delta cannot tell "one read per chunk" from "one read per record".
     * A counter incremented at the call site can.
     */
    @TestVisible
    private static Integer readCount = 0;

    /** Resets the read counter. Test-support only; production never needs it. */
    @TestVisible
    private static void resetReadCount() {
        readCount = 0;
    }

    /**
     * Enforces the prerequisite gate and maintains `Is_Prerequisite_Met__c`, on the records the
     * platform is already saving. Called from `TaskRollupTriggerHandler.beforeUpdate` only.
     *
     * REFUSES a Task that is ENTERING a completed status while its `Blocked_By__c` target is not
     * itself closed. "Entering" is load-bearing and is checked against the STORED prior record:
     *   - prior was already closed  -> not a transition -> never refused. This is what lets
     *     `scripts/backfill-task-blocked-by.apex` stamp historical rows where B3 is already complete
     *     and B2 never was, and what lets an unrelated edit (due date, comments, owner) to an
     *     already-complete item save normally.
     *   - prior was open, new status is closed -> the transition the control exists to police.
     *
     * MAINTAINS `Is_Prerequisite_Met__c` on EVERY blocked Task in the chunk, not only on the ones
     * transitioning. It costs nothing extra (same single query, same records) and it keeps the
     * denormalised backstop the validation rule reads accurate on every save of a blocked item.
     *
     * 🔴 THE INSERT CONTEXT DOES NO LOOKUP — BUT IT DOES CLAMP. See `clampOnInsert`.
     * The expensive half is skipped and the free half is not, and the two were conflated until
     * 2026-08-31 code review:
     *
     *   NO SIBLING LOOKUP ON INSERT — GOVERNOR ARITHMETIC, NOT AN OVERSIGHT. With the `Text(20)` key
     *   the fan-out DOES populate `Blocked_By__c` at insert (that is the shape's whole advantage), so
     *   an insert-context lookup would NOT be inert — it would fire on the Day-0 fan-out.
     *   `TaskFanoutService` inserts `CHUNK_SIZE x 82` Tasks in ONE statement, which the platform
     *   fires before-insert against in 200-row batches: at today's `CHUNK_SIZE = 100` that is 8,200
     *   rows and 41 firings, so 41 extra SOQL ON TOP OF the 41 SOQL + 41 DML the after-insert rollup
     *   already spends — 82 of the 100-query limit, to discover that a freshly created `Not Started`
     *   task is not being completed. Design §8 names exactly this cascade as the cost that must not
     *   be added, and this org has already had a Day-0 fan-out roll back once.
     *
     *   BUT THAT ARITHMETIC ARGUES AGAINST A QUERY, NOT AGAINST A NULL CHECK. This header used to
     *   say the insert path was "fail-closed by construction" because `Is_Prerequisite_Met__c` has
     *   `<defaultValue>false</defaultValue>`. THAT WAS NOT AIRTIGHT: a default value applies only
     *   when the field is ABSENT from the payload, so any writer that SUPPLIES
     *   `Is_Prerequisite_Met__c = true` — Data Loader with that column mapped, a Flow, an Apex
     *   `insert` — satisfied all four conjuncts of `Prerequisite_Must_Be_Met_To_Complete` and created
     *   a completed, ungated wire request. `clampOnInsert` overwrites the supplied value with false
     *   for any Task carrying a key, at one blank check and zero queries, which is what makes the
     *   validation rule's `ISNEW()` arm actually load-bearing.
     *
     * ⚠ The two halves are therefore NOT redundant and must not be "simplified" into one: the trigger
     * owns UPDATE (where it can read the sibling) and CLAMPS on insert; the validation rule owns the
     * INSERT REFUSAL, reading the clamped value. Deleting either one opens a real path. Asserted by
     * `TaskPrerequisiteServiceTest.refusesInsertingAnAlreadyCompleteBlockedItem` and
     * `.clampsSuppliedPrerequisiteMetOnInsert`.
     *
     * @param newList Trigger.new (Tasks). Null/empty-safe.
     * @param oldMap  Trigger.oldMap. Load-bearing TWICE, not once: it supplies the prior state for
     *                the transition test, AND the prior `Blocked_By__c` for the surviving-key
     *                candidate filter that closes the clear-and-complete bypass. A null map makes
     *                every completed-status record look like a transition and forfeits the prior key
     *                — fail-closed on the first, permissive on the second, which is why this method
     *                is trigger-only and the handler always passes `Trigger.oldMap`.
     * 🔴 THIS METHOD IS `public` AND IT MUTATES THE RECORDS YOU HAND IT. It sets
     * `Is_Prerequisite_Met__c` on every candidate, and it enforces ONLY via `SObject.addError`, which
     * the platform honours in a trigger and nowhere else. So a future non-trigger caller that passes
     * queried records and ignores the returned map would STAMP THE FLAG AND SAVE IT while refusing
     * nothing — writing the validation rule's own input from outside the control that is supposed to
     * compute it. IT IS TRIGGER-ONLY BY CONTRACT, not merely by current usage. `TaskRollupTriggerHandler`
     * is the sole production caller; the tests are the only other callers and they assert the
     * returned map instead of relying on the mutation. Any new caller must treat a non-empty return
     * as a refusal and must not commit the records.
     *
     * @return Refusal messages by Task Id — empty when nothing was refused, never null. The trigger
     *         handler ignores it; it exists so a unit test can assert the decision WITHOUT relying on
     *         `SObject.addError`, which is only meaningful inside a trigger.
     */
    public static Map<Id, String> enforceOnUpdate(List<Task> newList, Map<Id, Task> oldMap) {
        Map<Id, String> refusals = new Map<Id, String>();
        if (newList == null || newList.isEmpty()) {
            return refusals;
        }

        // ── THE ORG-WIDE COST CONTROL ──────────────────────────────────────────────────────────
        // Two blank checks per Task, evaluated FIRST so nothing else is computed for a Task that
        // carries no key on either side. Every Onboarding checklist item, every Broker Protection
        // pipeline Task, every EAC companion, every hand-created Activity and all 82 Day-0 rows
        // leave through that `continue` having spent no query, no DML and nothing that can throw.
        // Only B3 and I8 survive this filter.
        //
        // ═══════════════════════════════════════════════════════════════════════════════════════
        // 🔴 WHICH KEY THE GATE RESOLVES IS THE ENTIRE SECURITY CONTROL. TWO BYPASSES WERE FOUND
        //    HERE IN REVIEW; BOTH WERE ONE STATEMENT, AND BOTH DEFEATED THE VALIDATION RULE TOO.
        // ═══════════════════════════════════════════════════════════════════════════════════════
        // 1. BLANK IT (found 2026-08-31, first review). Filtering candidates on `Trigger.new` alone:
        //        update new Task(Id = b3Id, Status = 'Completed', Blocked_By__c = null);
        //    The row was filtered out before any check ran, and the rule's own
        //    `NOT(ISBLANK(Blocked_By__c))` read the new blank value and passed.
        // 0. MOVE THE DEAL (found 2026-08-31, THIRD review — EXPLOIT A, and the cheapest of the
        //    four). Listed first because it is the one that shows what the others have in common.
        //    `Blocked_By__c` is only HALF the coordinate; the prerequisite is the triple
        //    (deal, letter, sequence). Fixes 1 and 2 below hardened `letter|sequence` and left the
        //    deal being read straight off `Trigger.new` — so:
        //        update new Task(Id = b3Id, Status = 'Completed', Transaction_Deal__c = otherDealId);
        //    where `otherDealId` is any Transaction whose B2 is complete. The key half was correctly
        //    pinned to `B|2`; the QUERY was scoped to the other deal; that deal's completed B2 came
        //    back; `met` was true; the flag was stamped true; branch A skipped (met) and branch B
        //    skipped (`Blocked_By__c` was never touched). An optional second save put the deal back.
        //    THE LESSON, WRITTEN DOWN BECAUSE THREE FIXES IN A ROW MISSED IT: hardening one input of
        //    a multi-part identity just relocates the bypass to the parts still taken from
        //    `Trigger.new`. `survivingKey` and `survivingDealId` are ONE coordinate; move them
        //    together, and if a third component is ever added, it is pinned in the same breath.
        // 2. MOVE IT (found 2026-08-31, second review). The first fix used `new ?? prior`, so a
        //    NON-BLANK new value still won:
        //        update new Task(Id = b3Id, Status = 'Completed', Blocked_By__c = 'A|1');
        //    `A|1` resolves to a genuinely complete item on any real deal, so `met` came out true,
        //    `Is_Prerequisite_Met__c` was STAMPED TRUE, and the rule's `NOT(Is_Prerequisite_Met__c)`
        //    conjunct was then false as well. Strictly cheaper than blanking, and the
        //    self-reference guard does not fire because `A|1` is not the row itself.
        // Both are available to the exact personas who work this checklist (`DPEG_Task_Edit` grants
        // `editable=true` on the field), to any Apex/Flow/SYSTEM_MODE write regardless of FLS, and
        // leave no trace — `Task` field history is not tracked. That is the Story 28 threat model
        // verbatim, so neither is an acceptable residual.
        //
        // THE RULE THAT CLOSES ALL FOUR: **unless this save leaves the row PAST THE GATE, the
        // STORED COORDINATE WINS — BOTH HALVES.** `pastTheGate` = the row was done BEFORE the save
        // (`Trigger.old.IsClosed`, authoritative because it came from the database) AND is still
        // done AFTER it (`Status` in `COMPLETED_STATUSES`, because the incoming `IsClosed` is not
        // trustworthy). It decides:
        //   - NOT past the gate -> resolve `prior ?? new`, for the key AND the deal. The save cannot
        //     choose its own examiner. Covers an open row, a row being completed, and — the EXPLOIT C
        //     fix — a row being REOPENED. (`?? new` matters: an item GAINING its first key or its
        //     first deal, i.e. the backfill, has no prior half to pin.)
        //   - PAST the gate -> resolve `new ?? prior`. Done before and done after: ordinary
        //     maintenance, the backfill's own corrections and the Phase 4 re-link must not be
        //     refused.
        // This is deliberately WIDER than "while the transition is happening": resolving the stored
        // coordinate on every not-past-the-gate row is what also lets `refusalFor` recognise a
        // DISARMING save (branch B there) at ZERO extra cost — the resolution is already in hand.
        List<GateCandidate> candidates = new List<GateCandidate>();
        for (Task t : newList) {
            String priorKey = null;
            Id priorDealId = null;
            Boolean wasClosed = false;
            if (oldMap != null) {
                Task prior = oldMap.get(t.Id);
                if (prior != null) {
                    priorKey = prior.Blocked_By__c;
                    priorDealId = prior.Transaction_Deal__c;
                    wasClosed = prior.IsClosed == true;
                }
            }
            if (String.isBlank(t.Blocked_By__c) && String.isBlank(priorKey)) {
                continue;
            }

            GateCandidate candidate = new GateCandidate();
            candidate.record = t;
            candidate.priorKey = priorKey;
            candidate.priorDealId = priorDealId;
            candidate.entering = isEnteringCompletion(t, oldMap);
            // 🔴 `pastTheGate` REPLACED A BARE `wasClosed` ON 2026-08-31 (EXPLOIT C, THE FIFTH
            // SHAPE). "Already past the gate" is NOT a property of the stored record alone — it is a
            // property of the SAVE. A row that WAS done and is being REOPENED is not past anything;
            // it is walking back through the gate, and treating it as exempt is what let this work
            // with ordinary Edit access and no override:
            //     update new Task(Id = b3, Status = 'Not Started', Blocked_By__c = null); // save 1
            //     update new Task(Id = b3, Status = 'Completed');                         // save 2
            // Save 1 slipped EVERY branch: (A) declined because the row was LEAVING completion, not
            // entering it; (B) declined on `!wasClosed`, false for a row that was closed. Save 2 then
            // had a blank key on both sides, so the row was not even a candidate — and the validation
            // rule's `NOT(ISBLANK(BLANKVALUE(new, PRIORVALUE)))` was false for the same reason. Both
            // halves of the control gone, permanently, with no trace. The precondition is ordinary:
            // complete B2, complete B3, reopen B2 (unrestricted, because B2 carries no key of its
            // own).
            Boolean nowDone = COMPLETED_STATUSES.contains(t.Status);
            Boolean pastTheGate = wasClosed && nowDone;
            // Non-blank by construction: at least one of the two was non-blank to get here.
            candidate.survivingKey = pastTheGate
                ? (String.isNotBlank(t.Blocked_By__c) ? t.Blocked_By__c : priorKey)
                : (String.isNotBlank(priorKey) ? priorKey : t.Blocked_By__c);
            // 🔴 THE OTHER HALF OF THE COORDINATE, PINNED THE SAME WAY AND FOR THE SAME REASON.
            // `Blocked_By__c` only says `letter|sequence`; the prerequisite is identified by the
            // TRIPLE (deal, letter, sequence), and the deal came off `Trigger.new` until 2026-08-31
            // — so hardening the key half alone left EXPLOIT A wide open (see the bypass list
            // above). Same precedence rule, same justification.
            // ⚠ THE PRECEDENCE MUST MOVE WITH THE BRANCH-B GUARD, NOT JUST THE GUARD. Gating branch
            // B on `pastTheGate` while leaving the precedence on `wasClosed` would still let a
            // reopen-and-REPOINT (`Status='Not Started', Blocked_By__c='A|1'`) resolve the
            // attacker's key, stamp `Is_Prerequisite_Met__c = true` on the reopened row, and hand
            // save 2 a pre-armed flag.
            candidate.survivingDealId = pastTheGate
                ? (t.Transaction_Deal__c != null ? t.Transaction_Deal__c : priorDealId)
                : (priorDealId != null ? priorDealId : t.Transaction_Deal__c);
            candidate.pastTheGate = pastTheGate;
            candidates.add(candidate);
        }
        if (candidates.isEmpty()) {
            return refusals;
        }

        Map<Id, Task> prerequisiteByTaskId = resolvePrerequisites(candidates);

        for (GateCandidate candidate : candidates) {
            Task t = candidate.record;
            Task prerequisite = prerequisiteByTaskId.get(t.Id);
            // `IsClosed` IS authoritative here: this record came back from a query, so the platform
            // has already derived it from the stored Status. Contrast COMPLETED_STATUSES above,
            // which exists because the same field is NOT trustworthy on an unsaved record.
            Boolean met = prerequisite != null && prerequisite.IsClosed == true;

            // Denormalised backstop for the validation rule. A before-context assignment needs no
            // FLS grant of its own — measured in this org — so a freshly deployed field with zero
            // FieldPermissions cannot break an unrelated save through this line.
            // 🔴 AND IT IS WHY BYPASS 2 ABOVE WORKED: this stamp is the rule's own input, so a
            // resolution against an attacker-chosen key does not merely fail to refuse here, it
            // actively DISARMS the rule. The stamp is only ever as trustworthy as `survivingKey`.
            t.Is_Prerequisite_Met__c = met;

            String message = refusalFor(candidate, prerequisite, met);
            if (message == null) {
                continue;
            }
            refusals.put(t.Id, message);

            // `addError` is documented as valid in trigger context only. Guarded so the direct
            // unit tests (which have no trigger to run inside) assert the returned map instead of
            // depending on undefined behaviour. Every DML-driven test in
            // TaskPrerequisiteServiceTest exercises this line for real.
            if (Trigger.isExecuting) {
                t.addError(message);
            }
        }
        return refusals;
    }

    /**
     * The refusal message for one candidate, or null to allow the save. TWO branches, and they
     * answer different questions — do not collapse them.
     *
     * (A) COMPLETING WHILE UNMET. The primary control: the item is entering a completed status and
     *     its prerequisite is not closed (or could not be resolved at all, which fails closed).
     *
     * (B) DISARMING A LIVE GATE. The item is NOT being completed, is STILL OPEN, and this save MOVES
     *     EITHER HALF OF THE COORDINATE — `Blocked_By__c` or `Transaction_Deal__c` — while the
     *     stored coordinate resolves to an OPEN prerequisite. This is the first save of the two-save
     *     bypass: disarm now, complete in a separate save, at which point neither `Trigger.new` nor
     *     `Trigger.old` (nor the rule's `PRIORVALUE`) has anything left to resolve. Refusing the
     *     disarm is the only place that sequence can be stopped, and it costs nothing: the
     *     resolution is the one branch (A) already needed.
     *
     * ⚠ (B) IS DELIBERATELY NARROW, AND EACH NARROWING KEEPS SOMETHING WORKING:
     *   - `!pastTheGate` — an item that was done AND stays done is past the gate, so its coordinate
     *     stays editable. This is what keeps `scripts/backfill-task-blocked-by.apex`, the Phase 4
     *     re-link and ordinary maintenance working. ⚠ It is `pastTheGate`, NOT `wasClosed`: a row
     *     being REOPENED was closed but is not past anything, and exempting it was EXPLOIT C.
     *   - `prerequisite != null` — an UNRESOLVABLE coordinate (`B|99`, a renamed group letter, a deal
     *     whose prerequisite was never fanned out) stays REPAIRABLE. Without this the feature could
     *     brick the very data it depends on, with no route back.
     *   - `!met` — once the verification is done there is nothing left to protect, so re-keying a
     *     satisfied item is allowed.
     *   - `gateCoordinatesChanged` — an ordinary edit to an open B3 (due date, comments, owner)
     *     moves neither half and is untouched. In a before-update `Trigger.new` carries the STORED
     *     value for any field the caller did not write, so this is false for every unrelated save.
     *   - `!hasPrereqOverrideAccess()` — the administrative escape hatch, below.
     *
     * ⚠ THE CONSEQUENCE, STATED SO IT IS NOT MET AS A BUG: while B2 is open, a principal WITHOUT
     * `Transaction_Prereq_Override` cannot change or remove B3's coordinate on a row that is not
     * past the gate. That is the point of an armed control.
     *
     * 🔴 CORRECTION, 2026-08-31 (EXPLOIT C review). This paragraph used to end: "branch (A) has NO
     * such exemption and never will — the override permits maintaining the gate's coordinates, never
     * completing past an open prerequisite." THAT OVERCLAIMED, IN TWO DIRECTIONS, AND IS RETRACTED
     * RATHER THAN DELETED because it is the kind of sentence a reader trusts:
     *   - Branch (A) is unexemptible only AS A SINGLE SAVE. It refuses a completion whose coordinate
     *     resolves to an open prerequisite — but a row whose coordinate has already been REMOVED is
     *     not a candidate at all, so branch (A) never sees it. "Cannot complete past an open
     *     prerequisite" is true; "cannot ever reach a completed state while its prerequisite is
     *     open" is NOT, and the two were being conflated.
     *   - An OVERRIDE HOLDER can therefore blank the coordinate in one save and complete in the
     *     next. That is not a leak, it is what "may move a live gate" means and it is what makes the
     *     M5 mass clear possible — but it is a real consequence of granting the token and must not be
     *     described as impossible.
     * What IS unconditional: no single save may complete a row whose surviving coordinate resolves
     * to an open prerequisite, for any principal, on any path, including `SYSTEM_MODE`.
     *
     * 🔴 CORRECTION, 2026-08-31. This paragraph previously ended: "if the key itself is wrong, note
     * that a wrong key is by definition unresolvable and therefore already exempt." THAT IS FALSE,
     * and it mattered — a key can be wrong AND resolvable. If the pair table ever shipped
     * `B3 -> B|1`, every B3 in the org would point at a real, existing B1; while B1 is open the row
     * would be neither completable (branch A) nor repairable (branch B), for EVERY principal and
     * every path including `SYSTEM_MODE`, because a before trigger runs regardless of access level.
     * Only the `prerequisite == null` case is self-exempting. The wrong-but-resolvable case is
     * precisely why `Transaction_Prereq_Override` exists, alongside the M5 mass key-clear and
     * Phase 1's renumbering — see that token's Javadoc in
     * `TransactionActionPermissionService`.
     * ⚠ `FeatureManagement.checkPermission` returns false for an UNDEPLOYED permission and never
     * throws, so if this class ships without the custom permission and its admin-only permission
     * set, the escape hatch silently does not exist and every coordinate change on an open row is
     * refused with nothing explaining why. They belong in the SAME deploy.
     *
     * @param candidate   The Task being saved, with both halves of its surviving/prior coordinate
     *                    and its prior state.
     * @param prerequisite The resolved prerequisite, or null when the surviving key resolved to
     *                     nothing.
     * @param met         Whether that prerequisite is closed.
     * @return The user-facing refusal, or null when the save is allowed.
     */
    private static String refusalFor(GateCandidate candidate, Task prerequisite, Boolean met) {
        if (candidate.entering && !met) {
            // DISPLAY ONLY. The Subject is read to NAME the blocking step for the user; no branch
            // in this class reads it. See the class header's RISK 1 note. Falls back to a generic
            // phrase rather than interpolating the literal "null" into a user-facing error.
            // Unquoted on purpose: `addError` HTML-escapes, so wrapping the subject in `"` would
            // render as `&quot;` in the toast. `Waiting on: <subject>.` reads fine without them.
            return prerequisite == null
                ? MSG_UNRESOLVED
                : MSG_BLOCKED
                    + (String.isBlank(prerequisite.Subject)
                        ? 'the preceding checklist item'
                        : prerequisite.Subject)
                    + '.';
        }
        if (!candidate.pastTheGate && !met && prerequisite != null
                && gateCoordinatesChanged(candidate)
                && !TransactionActionPermissionService.hasPrereqOverrideAccess()) {
            return MSG_DISARM;
        }
        return null;
    }

    /**
     * True when this save moves EITHER HALF of an existing gate coordinate — `Blocked_By__c`
     * (blanked or repointed) or `Transaction_Deal__c` (re-parented). Gaining a half for the first
     * time is not a change; that is the backfill and the fan-out.
     *
     * ⚠ IT COVERS THE DEAL, NOT JUST THE KEY, AND THAT IS DELIBERATE. The prerequisite is identified
     * by the TRIPLE (deal, letter, sequence). A rule that guarded only `Blocked_By__c` would leave
     * re-parenting as an equivalent disarm — which is exactly the asymmetry that produced EXPLOIT A
     * one review pass after the key half was hardened. One coordinate, one rule.
     *
     * The key half is compared case-insensitively and trimmed, matching how `resolvePrerequisites`
     * normalises it: a save that only re-cases or re-spaces the key is not disarming anything, and
     * refusing it would be a false positive on a no-op.
     *
     * @param candidate The candidate under examination.
     * @return true when a previously-set key or deal is being blanked, repointed or re-parented.
     */
    private static Boolean gateCoordinatesChanged(GateCandidate candidate) {
        // KEY HALF. Blanked or repointed. Gaining a key for the first time is not a change — that is
        // the backfill and the fan-out, and refusing it would stop the feature being installable.
        if (String.isNotBlank(candidate.priorKey)) {
            String currentKey = candidate.record.Blocked_By__c == null
                ? ''
                : candidate.record.Blocked_By__c.trim();
            if (!currentKey.equalsIgnoreCase(candidate.priorKey.trim())) {
                return true;
            }
        }
        // SCOPE HALF. Re-parenting an open gated item to another Transaction moves the coordinate
        // just as effectively as editing the key, so it is the same disarm and gets the same answer.
        // Pinning `survivingDealId` alone closes only the ONE-SAVE version (the resolution ignores
        // the new deal, so branch A refuses the completion); without this, re-parent-now /
        // complete-later would work exactly like the two-save key disarm. It also prevents the pin
        // persisting a flag computed against a deal the row no longer belongs to.
        // Gaining a deal for the first time is not a change, mirroring the key half.
        if (candidate.priorDealId != null
                && candidate.record.Transaction_Deal__c != candidate.priorDealId) {
            return true;
        }
        return false;
    }

    /**
     * One Task under examination, with everything the gate decided about it BEFORE any query — so
     * the verdict loop cannot silently re-derive a different answer from the one the resolution was
     * performed against. Built once in `enforceOnUpdate`; there is exactly one construction site.
     */
    private class GateCandidate {
        /** The Task as it is being saved (a `Trigger.new` member). */
        Task record;
        /** `Blocked_By__c` as STORED, from `Trigger.old`. Null/blank when the item had no key. */
        String priorKey;
        /** `Transaction_Deal__c` as STORED, from `Trigger.old`. Null when the item had no deal. */
        Id priorDealId;
        /**
         * The row was done BEFORE this save AND is still done AFTER it. THE ONLY STATE IN WHICH THIS
         * SAVE MAY RE-AIM THE GATE AT SOMETHING ELSE.
         *
         * 🔴 NOT the same as `wasClosed`, and the difference is EXPLOIT C. A row being REOPENED was
         * closed but is not past anything — it is walking back through the gate, and exempting it let
         * a two-save reopen-and-erase remove the coordinate with ordinary Edit access. Anywhere this
         * class asks "is this row past the gate?", it must ask THIS, never `wasClosed`.
         */
        Boolean pastTheGate;
        /** Open -> completed transition, per `isEnteringCompletion`. */
        Boolean entering;
        /** The key half of the coordinate: stored-wins unless the row is past the gate. Never blank. */
        String survivingKey;
        /**
         * The scope half of the coordinate: stored-wins unless past the gate. May be null (an
         * item with no deal on either side, which resolves to nothing and fails closed).
         * 🔴 `survivingKey` AND `survivingDealId` ARE ONE COORDINATE AND MUST MOVE TOGETHER.
         * Hardening either alone leaves the other as the bypass — that is literally how EXPLOIT A
         * survived the fix for the blank/repoint pair.
         */
        Id survivingDealId;
    }

    /**
     * Clamps `Is_Prerequisite_Met__c` to false on any Task being CREATED with a `Blocked_By__c`.
     * Called from `TaskRollupTriggerHandler.beforeInsert`.
     *
     * 🔴 WHY THIS IS NOT COVERED BY THE FIELD'S DEFAULT VALUE. `<defaultValue>false</defaultValue>`
     * applies only when the field is ABSENT from the insert payload. A writer that SUPPLIES
     * `Is_Prerequisite_Met__c = true` — Data Loader with the column mapped, a Flow assignment, an
     * Apex `insert` — satisfied every conjunct of `Prerequisite_Must_Be_Met_To_Complete` and created
     * a completed, ungated wire request in one statement. Overwriting the supplied value is the only
     * thing that makes the rule's `ISNEW()` arm mean anything.
     *
     * ⚠ NO LOOKUP HERE, DELIBERATELY, AND THE ASYMMETRY IS THE POINT. This does NOT resolve the
     * prerequisite — that would put a query on the Day-0 fan-out's before-insert cascade (41 extra
     * SOQL; the arithmetic is at `enforceOnUpdate`). Clamping to false is strictly fail-closed
     * without needing to know the sibling's state: a genuinely legitimate creation of an
     * already-complete blocked item does not exist in this model (the fan-out creates everything
     * `Not Started`), and if one ever did, it would be refused loudly rather than admitted silently.
     *
     * ⚠ COST FOR THE REST OF THE ORG: one blank check per Task, no query, no DML — the same bound
     * `OnboardingTaskDomain.stampCompletion` already carries in this context.
     *
     * @param newList Trigger.new (Tasks). Null/empty-safe.
     */
    public static void clampOnInsert(List<Task> newList) {
        if (newList == null || newList.isEmpty()) {
            return;
        }
        for (Task t : newList) {
            if (String.isNotBlank(t.Blocked_By__c)) {
                t.Is_Prerequisite_Met__c = false;
            }
        }
    }

    /**
     * Raised by `asRefusal` so the LWC boundary can surface a prerequisite refusal VERBATIM instead
     * of the controller's generic "This task could not be updated. Refresh the page and try again."
     *
     * 🔴 WHY A TRANSLATION AND NOT A THROW. The refusal itself must stay an `addError` on the record:
     * a thrown exception from a before trigger aborts the WHOLE transaction, which would turn a
     * partial-success `Database.update(list, false)` of 251 checklist items into an all-or-nothing
     * one. So the platform hands callers a `DmlException`, and `TransactionTaskService` translates it
     * back into this type. The translation lives beside the message constants it matches, in this
     * class, so the two cannot drift — a matcher in the controller keyed on a copied string would.
     */
    public class PrerequisiteNotMetException extends Exception {}

    /**
     * Recognises this class's own refusal inside a `DmlException` and re-types it.
     *
     * Matched against `MSG_BLOCKED` / `MSG_UNRESOLVED` / `MSG_DISARM` — the very constants that
     * produced the text — rather than a marker token embedded in the user-facing message. A marker
     * would either leak into the message every non-LWC caller sees (Data Loader, REST, Flow) or need
     * stripping in two places.
     * ⚠ ADD ANY NEW REFUSAL CONSTANT TO THIS LIST IN THE SAME CHANGE. A missing entry does not throw
     * — the refusal simply reverts to the controller's generic "Refresh the page and try again", on
     * the one path a human uses, with nothing in the log to explain it.
     *
     * @param e The DmlException raised by a save this trigger refused; null-safe.
     * @return A `PrerequisiteNotMetException` carrying the user-facing text, or null when `e` is
     *         something else entirely — in which case the caller must NOT surface it (it could be
     *         any platform failure, and this org's controllers deliberately never leak raw DML text).
     */
    public static PrerequisiteNotMetException asRefusal(DmlException e) {
        if (e == null) {
            return null;
        }
        for (Integer i = 0; i < e.getNumDml(); i++) {
            String dmlMessage = e.getDmlMessage(i);
            if (String.isBlank(dmlMessage)) {
                continue;
            }
            if (dmlMessage.contains(MSG_BLOCKED)
                || dmlMessage.contains(MSG_UNRESOLVED)
                || dmlMessage.contains(MSG_DISARM)) {
                return new PrerequisiteNotMetException(dmlMessage);
            }
        }
        return null;
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONLY METHOD IN THIS FEATURE THAT KNOWS THE SHAPE OF `Blocked_By__c`.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Blocked_By__c` is `Text(20)` holding `<GroupLetter>|<Sequence>` (`B|2`, `I|7`) — a lookup is
     * undeployable against Task on this platform; see the class header for the measured error. The
     * prerequisite is the SIBLING checklist Task under the same `Transaction_Deal__c` whose
     * `Task_Group__c` starts with that letter and whose `Task_Sequence__c` equals that number.
     *
     * The return value is keyed on the BLOCKED Task's own Id, never on the key or on a prerequisite
     * reference, so `enforceOnUpdate` stays completely shape-blind. That isolation is not
     * theoretical: this class was first written against the self-lookup the design specified, and
     * converting it to the shape the platform actually permits changed THIS METHOD and one selector
     * signature. Nothing else.
     *
     * AT MOST ONE QUERY, whatever the chunk size — never a function of row count, which is the whole
     * point of the feature's governor budget. It is ZERO when every key in the chunk is unparseable,
     * because there would be nothing to look for; those rows still refuse. `readCount` is incremented
     * at the call site so the test can pin both facts directly (see the field's Javadoc).
     *
     * 🔴 UNRESOLVED IS NOT "MET". Four things resolve to nothing, and every one of them is left
     * ABSENT from the returned map so the caller refuses:
     *   - a malformed or unparseable key (typo, renamed group letter, truncated at 20 chars);
     *   - a blocked Task with no `Transaction_Deal__c` (nothing to search within);
     *   - a deal whose prerequisite row was never fanned out;
     *   - a prerequisite hidden from the running user by record-level sharing (SYSTEM_MODE lifts
     *     CRUD/FLS, never sharing).
     * `Task_Group__c` is parsed for its LEADING LETTER only. That field is written by
     * `TaskFanoutService` as `Letter__c + '. ' + Group_Name__c` — a STRUCTURED value composed from
     * CMDT, not the free-text `Subject`. Design §12 item 9 names it as the correct key. This is not
     * the subject parsing the class header prohibits, and it must not become it.
     *
     * @param candidates Tasks carrying a key on one side or the other, each with BOTH halves of its
     *                   coordinate already decided. Never null/empty (caller-checked).
     *                   🔴 THE INVARIANT, WHICH IS ABOUT THE WHOLE COORDINATE AND NOT JUST THE KEY:
     *                   this method resolves from `candidate.survivingKey` AND
     *                   `candidate.survivingDealId`, and MUST NOT read `record.Blocked_By__c` OR
     *                   `record.Transaction_Deal__c`. Both come off `Trigger.new`, i.e. both are
     *                   attacker-supplied. The narrower version of this invariant — naming only the
     *                   key — is what let EXPLOIT A through: it forbade reading the key two lines
     *                   before the code read the deal. `record` is used here for its `Id` only.
     * @return The prerequisite Task for each candidate, keyed by the BLOCKED Task's Id. Entries are
     *         omitted where the prerequisite could not be resolved. Empty, never null.
     */
    private static Map<Id, Task> resolvePrerequisites(List<GateCandidate> candidates) {
        // Parse every key ONCE, up front, so the loop below and the indexing loop agree by
        // construction and the parse cannot drift between them.
        Map<Id, String> parsedKeyByTaskId = new Map<Id, String>();
        Set<Id> dealIds = new Set<Id>();
        Set<Decimal> sequences = new Set<Decimal>();

        for (GateCandidate candidate : candidates) {
            // 🔴 BOTH HALVES COME FROM THE CANDIDATE, NEVER FROM `candidate.record`. The deal read
            // `t.Transaction_Deal__c` here until 2026-08-31 and that WAS exploit A: the key half was
            // pinned while the scope half was still attacker-supplied, so re-parenting the save to a
            // deal whose B2 is complete resolved a satisfied prerequisite belonging to someone else.
            if (candidate.survivingDealId == null) {
                continue;
            }
            List<String> parts = candidate.survivingKey.trim().split('\\|');
            if (parts.size() != 2) {
                continue;
            }
            String letter = parts[0].trim().toUpperCase();
            String sequenceText = parts[1].trim();
            // Single letter, matching what `groupLetterOf` extracts from the candidate side — a key
            // whose letter half cannot possibly match is rejected here rather than widening the query.
            if (letter.length() != 1 || !sequenceText.isNumeric()) {
                continue;
            }
            Decimal sequence = Decimal.valueOf(sequenceText);
            parsedKeyByTaskId.put(
                candidate.record.Id, indexKey(candidate.survivingDealId, letter, sequence)
            );
            dealIds.add(candidate.survivingDealId);
            sequences.add(sequence);
        }

        Map<Id, Task> byBlockedTaskId = new Map<Id, Task>();
        if (parsedKeyByTaskId.isEmpty()) {
            // Every key was unusable. Refuse without querying — nothing could be resolved anyway.
            return byBlockedTaskId;
        }

        readCount++;
        Map<String, Task> siblingByKey = new Map<String, Task>();
        for (Task sibling : TaskSelector.selectChecklistByDealsAndSequences(dealIds, sequences)) {
            String siblingLetter = groupLetterOf(sibling.Task_Group__c);
            if (siblingLetter == null) {
                continue;
            }
            siblingByKey.put(
                indexKey(sibling.Transaction_Deal__c, siblingLetter, sibling.Task_Sequence__c),
                sibling
            );
        }

        for (GateCandidate candidate : candidates) {
            Id taskId = candidate.record.Id;
            Task prerequisite = siblingByKey.get(parsedKeyByTaskId.get(taskId));
            if (prerequisite != null && prerequisite.Id != taskId) {
                // `prerequisite.Id != taskId` guards a self-referencing key (`B|3` on item B3),
                // which would otherwise let an item gate itself and pass the moment it completed.
                byBlockedTaskId.put(taskId, prerequisite);
            }
        }
        return byBlockedTaskId;
    }

    /**
     * The single composed index key, used for BOTH sides of the match so they cannot diverge.
     *
     * @param dealId   `Transaction_Deal__c` scoping the search.
     * @param letter   Upper-case group letter.
     * @param sequence `Task_Sequence__c`; normalised to an Integer because the field is
     *                 `precision 3, scale 0` and a Decimal's string form would otherwise depend on
     *                 how it was constructed.
     * @return The composite key.
     */
    private static String indexKey(Id dealId, String letter, Decimal sequence) {
        return dealId + '|' + letter + '|' + String.valueOf(sequence.intValue());
    }

    /**
     * The leading group letter of a `Task_Group__c` value such as `"B. Earnest Money Wire"`.
     *
     * 🔴 THE ONE-CHARACTER RULE HAS A REAL CONSEQUENCE, NOT JUST A DEFENSIVE ONE. `Task_Group__c` is
     * a RESTRICTED picklist, and exactly one of its eleven values has a two-character letter half:
     * `H2. Tenant Interviews & Estoppels`. So this returns null for every H2 row, which combined with
     * the identical one-character rule in the key parser means **no prerequisite pair can ever be
     * defined inside group H2** — see `TaskFanoutService.PREREQUISITE_SEQUENCES`, where such a pair
     * would be added and where the consequence is spelled out. Widening the parse means widening it
     * on BOTH sides together.
     *
     * ⚠ Because the picklist is restricted, a null return can never change a gate DECISION today:
     * the only value it rejects is one that no resolvable key can name. The guard is kept as defence
     * in case the restriction is ever relaxed, and it IS exercised —
     * `TaskPrerequisiteServiceTest.unparseableSiblingDoesNotShadowTheRealPrerequisite` uses a real H2
     * row to cover the skip and to exclude a sequence-only sibling match. Do not replace the
     * `length() == 1` test with something looser on the strength of "it can never fire".
     *
     * @param taskGroup The `Task_Group__c` value; null/blank-safe.
     * @return The upper-case single letter, or null when the value is not in the shape
     *         `TaskFanoutService` writes (in which case the row is skipped, never guessed at).
     */
    private static String groupLetterOf(String taskGroup) {
        if (String.isBlank(taskGroup)) {
            return null;
        }
        String letter = taskGroup.substringBefore('.').trim();
        return letter.length() == 1 ? letter.toUpperCase() : null;
    }

    /**
     * True when this save moves the Task from an open state into a completed one.
     *
     * The NEW state is tested against `COMPLETED_STATUSES` (the incoming `IsClosed` is not
     * trustworthy — see that constant's Javadoc). The PRIOR state is tested with `IsClosed` on the
     * `Trigger.old` record, which came from the database and therefore is.
     *
     * @param t      The Task as it is being saved.
     * @param oldMap Trigger.oldMap; null-safe.
     * @return true only for an open -> completed transition.
     */
    private static Boolean isEnteringCompletion(Task t, Map<Id, Task> oldMap) {
        if (!COMPLETED_STATUSES.contains(t.Status)) {
            return false;
        }
        Task prior = oldMap == null ? null : oldMap.get(t.Id);
        if (prior == null) {
            // No prior state to compare against. Treat as a transition: fail closed.
            return true;
        }
        return prior.IsClosed != true;
    }
}
