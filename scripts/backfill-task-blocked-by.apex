// ═══════════════════════════════════════════════════════════════════════════════════════════
// BACKFILL — Task.Blocked_By__c on the checklist Tasks of ALL LIVE DEALS.
// Phase 0 of the Transaction FSD gap closure, step 4.
// Design: agent-output/design-transaction-fsd-gaps.md §5.1 (mechanism) and §10 (Phase 0).
// Enforced by: TaskPrerequisiteService (before-update trigger gate) + the
//              Is_Prerequisite_Met__c validation rule.
//
// WHAT IT DOES: links each dependent wire item to the anti-fraud verification item that must
// complete first, on deals that were fanned out BEFORE the field existed.
//     B3 (Send wire request to accounting with verified instructions)   -> B2 (Call title company
//                                                    to verbally verify wiring instructions)
//     I8 (Send closing wire to title company with verified instructions) -> I7 (Verify wiring
//                                                              instructions by phone)
// Run ONCE, after the field, the validation rule, TaskPrerequisiteService AND the
// TaskFanoutService stamp are all live.
//
// ⚠ THIS SCRIPT COVERS EXISTING DEALS ONLY, AND IT IS HALF OF THE CONTROL, NOT ALL OF IT. New deals
// get their key from `TaskFanoutService` at fan-out (`tk.Blocked_By__c = blockedByKeyFor(...)`,
// pinned by `TaskFanoutServiceTest.fanOutStampsWireFraudPrereqKeys`). Until 2026-08-31 code review,
// this file claimed "from then on the fan-out seeds the link at creation" while NOTHING in
// `TaskFanoutService` wrote the field — the gate would have been retro-only, live for backfilled
// deals and silently absent on every deal created afterwards. Do not run this expecting it to
// protect anything created after it finishes.
//
// Re-running is harmless — rows already pointing at the right prerequisite are skipped, so a second
// run reports 0 stamped.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 IT MATCHES ON Task_Group__c + Task_Sequence__c. NEVER ON Subject.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// This is not a style choice, it is RISK 1 in the design. TaskRollupService.cls:48 already derives
// Wire_Open_Risks__c from `Subject.toLowerCase().contains('anti-fraud')` and
// transactionTaskGroups.js:11 re-derives CRITICAL by regex on the same string — two parsers of a
// free-text field, neither of which throws when it stops matching; they silently return zero. A
// third parser here would put a fraud control on the same footing. It also would not work: a naive
// `contains('critical')` wrongly matches A4 ("Receive critical dates from title company") and A5
// ("Log critical dates into Salesforce deal record").
// The GROUP LETTER is parsed out of Task_Group__c, which TaskFanoutService writes as
// `Letter__c + '. ' + Group_Name__c` (e.g. "B. Earnest Money Wire"). That is a STRUCTURED field
// written by code from CMDT, not the free-text Subject, and design §12 item 9 names it as the
// correct key. Rows whose group letter cannot be parsed are COUNTED AND REPORTED, never guessed at.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 PRECONDITIONS. THIS SCRIPT CANNOT SATISFY THEM ITSELF — CHECK ALL FOUR BEFORE RUNNING.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 1. RUN AS A SYSTEM ADMINISTRATOR. Not a preference — a platform constraint. This script UPDATES
//    Task, and Task object EDIT is UN-GRANTABLE by permission set on this org's platform:
//    `ObjectPermissions.SobjectType` is a restricted picklist that excludes Task / Event / Activity,
//    and a permission set carrying such a block DEPLOYS GREEN and is then silently discarded
//    (measured 2026-08-28; see the removal note in permissionsets/DPEG_Task_Edit). The only principal
//    that can update a Task here is one with "Modify All Data". That is also exactly why
//    TransactionTaskService authorizes with a custom permission and writes in SYSTEM_MODE.
//
// 2. `AccessLevel.SYSTEM_MODE` IS NOT AVAILABLE HERE, and the refusal is recorded rather than
//    quietly worked around:
//        Cannot use SYSTEM_MODE access level in anonymous execution of Apex
//    — which applies to `WITH SYSTEM_MODE` in static SOQL AND to `AccessLevel.SYSTEM_MODE` in
//    Database methods. There is no `without sharing` in anonymous Apex either. So this runs in the
//    runner's own context, and precondition 1 is what makes that context sufficient.
//
// 3. THE RUNNER MUST HOLD `DPEG_Task_Edit`, WHICH IS WHERE `Task.Blocked_By__c` IS GRANTED
//    (`editable=true`; `Task.Is_Prerequisite_Met__c` is `readable`-only there, deliberately, and this
//    script never writes it — the trigger does, and a before-context assignment needs no FLS grant).
//    A Metadata-API-deployed custom field arrives with ZERO FieldPermissions rows for anyone, System
//    Administrator included, and "Modify All Data" does not supply FLS. Until the set is DEPLOYED AND
//    ASSIGNED the field is not merely denied, it is ABSENT from the running user's schema, and THIS
//    SCRIPT WILL NOT COMPILE — `sf apex run` fails on the field name before executing a single
//    statement. That is the expected symptom of running this too early; it is not a typo.
//
// 4. `TaskPrerequisiteService` MUST ALREADY BE DEPLOYED — and note that this script DEPENDS on its
//    "entering completion" rule to succeed. See the next block.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS UPDATE IS NOT REFUSED BY THE GATE IT IS SEEDING
// ═══════════════════════════════════════════════════════════════════════════════════════════
// On a live deal it is entirely normal to find B3 ALREADY COMPLETE while B2 was never completed —
// that is the unenforced history this whole phase exists to end. Writing Blocked_By__c onto such a
// row fires TaskRollupTrigger's before-update context, which runs the new gate against it.
// It is NOT refused, because TaskPrerequisiteService refuses only a TRANSITION into a completed
// status: `Trigger.old` is already closed here, `Status` is not being written at all, so the record
// is not entering completion and passes through. The gate still stamps Is_Prerequisite_Met__c
// correctly (false for those rows), which is a BONUS of running the backfill through the trigger
// rather than around it — the validation-rule backstop is seeded in the same pass.
// ⚠ CONSEQUENCE, STATED PLAINLY: this backfill does NOT retroactively invalidate wires that were
// already sent without a verbal verification. It cannot and should not — the money has moved. It
// makes those rows VISIBLE (Is_Prerequisite_Met__c = false on a completed B3 is a reportable audit
// finding) and it stops the NEXT one. If the business wants the historical set reviewed, report on
// `Blocked_By__c != '' AND IsClosed = true AND Is_Prerequisite_Met__c = false` after this runs.
//
// 🔴 THE ORDERING THIS SCRIPT USES IS ALSO THE RULE FOR ANY BULK RE-LOAD OF HISTORICAL TASKS.
// INSERT WITH A BLANK Blocked_By__c, STAMP THE KEY IN A SECOND PASS. TaskPrerequisiteService
// .clampOnInsert forces Is_Prerequisite_Met__c to false on any Task CREATED with a key, and the
// validation rule's ISNEW() arm then refuses it if it is also Completed — WITHOUT consulting the
// prerequisite's real state, because the insert context performs no lookup by design (a lookup
// there would cost ~41 queries on the Day-0 fan-out cascade). So a loader that recreates a
// completed B3/I8 WITH its key in one statement fails, and allOrNone=false drops exactly those
// rows silently. Recorded in the migration notes too: design doc §7, migration risk 8.
//
// ⚠ TRIGGER CASCADE COST. Each updated Task also fires the after-update rollup, which spends
// 1 SOQL + 1 DML per 200-row chunk against Transaction__c. At two rows per deal that is one chunk
// per 100 deals. The LIMIT guard below is what keeps that arithmetic true.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 FIELD SHAPE — `Blocked_By__c` IS `Text(20)` HOLDING `<GroupLetter>|<Sequence>` (e.g. "B|2").
// ═══════════════════════════════════════════════════════════════════════════════════════════
// NOT a lookup, and not by choice: a CustomField with referenceTo=Task fails deploy on this platform
// with "referenceTo value of 'Task' does not resolve to a valid sObject type" (measured against
// usman-dpeg, 2026-08-31). TaskPrerequisiteService resolves the key against SIBLING Tasks sharing the
// same Transaction_Deal__c. Everything shape-specific in this script is confined to the one block
// marked "SHAPE-AWARE BLOCK" below.
//
// ⚠ THIS SCRIPT STILL LOOKS THE PREREQUISITE ROW UP, EVEN THOUGH THE KEY COULD BE COMPOSED BLIND.
// Composing "B|2" needs no query at all — but a key naming a row that does not exist makes its
// dependent PERMANENTLY UNCOMPLETABLE, because the runtime gate treats unresolved as unmet and fails
// closed. That is the correct direction at runtime and the wrong thing to CREATE here. So the script
// writes a key only where it has seen the target row, and REPORTS the deals where it could not
// (partially fanned-out or hand-edited deals) rather than bricking their checklist.
// ═══════════════════════════════════════════════════════════════════════════════════════════

// ── THE PREREQUISITE PAIRS LIVE IN `TaskFanoutService.PREREQUISITE_SEQUENCES`, NOT HERE.
// This script deliberately holds NO copy of the pair table and calls
// `TaskFanoutService.blockedByKeyFor(letter, sequence)` instead. Two copies of a fraud-control
// definition that can silently disagree is precisely the failure this feature exists to remove: if
// the backfill and the fan-out gated different items, live deals and new deals would be protected
// differently and nothing would report it. Adding a third pair is one line in that class.

// Every checklist Task on every deal that has one. Checklist Tasks attach via the custom
// Transaction_Deal__c lookup (not WhatId) and always carry a Task_Group__c — the same WHERE
// TaskSelector.selectChecklistByTransactionDealIds uses. Both the dependent AND the prerequisite
// rows are needed, so the query is not narrowed to the pair sequences: the prerequisite has to be
// findable to be linked to.
//
// 🔴 LIMIT 40000 IS A GOVERNOR GUARD WITH DELIBERATE HEADROOM, NOT A PAGE SIZE. The transaction's
// query-ROW budget is 50,000 and this script is NOT the only reader in it: every Task it updates
// fires TaskRollupTrigger, whose before-update context runs TaskPrerequisiteService's own per-chunk
// read and whose after-update context runs TaskRollupService's. Querying the full 50,000 here would
// leave those with nothing, and they would throw PARTWAY THROUGH the update — a partial stamp, in a
// script whose "re-running is a no-op" promise would then paper over the gap. 10,000 rows of
// headroom keeps the cascade solvent.
List<Task> checklist = [
    SELECT Id, Transaction_Deal__c, Task_Group__c, Task_Sequence__c, Status, IsClosed, Blocked_By__c
    FROM Task
    WHERE Transaction_Deal__c != null
      AND Task_Group__c != null
      AND Task_Sequence__c != null
    ORDER BY Transaction_Deal__c, Task_Group__c, Task_Sequence__c
    LIMIT 40000
];

// 🔴 STOP. Do not fall through to the update. Until 2026-08-31 code review this logged and then
// carried on, which is the worst of both: the operator is told the population does not fit AND the
// script stamps a partial, arbitrary (ORDER BY) subset of it anyway. Refusing to write leaves the
// org exactly as it was, which is the only state a re-run can reason about.
if (checklist.size() == 40000) {
    System.debug(LoggingLevel.ERROR,
        'backfill-task-blocked-by: ABORTED WITHOUT WRITING ANYTHING. The query hit its 40000 LIMIT, '
        + 'so this population does NOT fit one anonymous transaction. Convert this to a Batch class '
        + '(Database.executeBatch(batch, 200)) rather than re-running the script — a partial stamp '
        + 'here would be invisible afterwards, because a re-run cannot distinguish "not reached yet" '
        + 'from "correctly has no prerequisite".');
    return;
}

// Index every checklist row by deal + group letter + sequence, and count the rows whose group
// letter could not be parsed so a malformed Task_Group__c is REPORTED rather than silently skipped.
Map<String, Task> bySequenceKey = new Map<String, Task>();
Integer unparsableGroup = 0;
for (Task t : checklist) {
    String letter = t.Task_Group__c.substringBefore('.').trim();
    if (String.isBlank(letter) || letter.length() != 1) {
        unparsableGroup++;
        continue;
    }
    bySequenceKey.put(
        t.Transaction_Deal__c + '|' + letter.toUpperCase() + '|' + t.Task_Sequence__c.intValue(),
        t
    );
}

List<Task> stamps = new List<Task>();
Integer alreadyCorrect = 0;
Integer prerequisiteMissing = 0;
Integer completedWithoutVerification = 0;

for (Task t : checklist) {
    String letter = t.Task_Group__c.substringBefore('.').trim();
    if (String.isBlank(letter) || letter.length() != 1) {
        continue; // already counted above
    }
    letter = letter.toUpperCase();

    // The ONE definition of which items are gated, shared with the fan-out. Null = not a gated item.
    String targetValue = TaskFanoutService.blockedByKeyFor(letter, t.Task_Sequence__c);
    if (targetValue == null) {
        continue;
    }

    // ══ SHAPE-AWARE BLOCK — the ONLY part of this script that knows what Blocked_By__c holds. ══
    // Confirm the prerequisite ROW exists on this deal before writing the key: a key naming a row
    // that does not exist would permanently brick the dependent, because the runtime gate treats
    // unresolved as unmet and fails closed (see the header).
    // The index is keyed `<deal>|<LETTER>|<SEQ>` and the key IS `<LETTER>|<SEQ>`, so the lookup is a
    // plain concatenation — no second parse, and the row verified here is BY CONSTRUCTION the row
    // TaskPrerequisiteService will resolve at runtime.
    Task prerequisite = bySequenceKey.get(t.Transaction_Deal__c + '|' + targetValue);
    if (prerequisite == null) {
        // The dependent item exists but its prerequisite does not — a partially fanned-out or
        // hand-edited deal. Reported, never guessed at, and never linked to a row on another deal.
        prerequisiteMissing++;
        continue;
    }
    // ══ END SHAPE-AWARE BLOCK ══════════════════════════════════════════════════════════════════

    if (t.Blocked_By__c == targetValue) {
        alreadyCorrect++;
        continue;
    }
    // Audit signal, computed before the write so it reflects the pre-backfill world: a wire request
    // that is already closed while its verbal verification never was. See the header.
    if (t.IsClosed == true && prerequisite.IsClosed != true) {
        completedWithoutVerification++;
    }

    // Shell record: Id + the one field. Status is NOT written, which is what keeps this out of
    // TaskPrerequisiteService's "entering completion" branch (header, "WHY THIS UPDATE IS NOT
    // REFUSED"). Do not add Status here to "tidy up" historical rows — that WOULD be refused, and
    // rightly so.
    stamps.add(new Task(Id = t.Id, Blocked_By__c = targetValue));
}

System.debug(LoggingLevel.INFO,
    'backfill-task-blocked-by: scanned=' + checklist.size()
    + ' toStamp=' + stamps.size()
    + ' alreadyCorrect=' + alreadyCorrect
    + ' prerequisiteMissing=' + prerequisiteMissing
    + ' unparsableGroup=' + unparsableGroup);

Integer stamped = 0;
Integer failed = 0;
if (!stamps.isEmpty()) {
    // allOrNone = false: one Task blocked by an unrelated validation rule, a record lock or a
    // sharing refusal must not cost every other deal its link. NOT SYSTEM_MODE — unavailable in
    // anonymous Apex, see precondition 2.
    List<Database.SaveResult> results = Database.update(stamps, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            stamped++;
            continue;
        }
        failed++;
        // EVERY error on the row, not getErrors()[0] — an access refusal and a validation failure
        // arrive together, and reporting only the first sends the reader at the wrong precondition.
        for (Database.Error err : results[i].getErrors()) {
            System.debug(LoggingLevel.ERROR,
                'backfill-task-blocked-by: FAILED ' + stamps[i].Id + ' — '
                + err.getStatusCode() + ': ' + err.getMessage()
                + ' [fields: ' + err.getFields() + ']');
        }
    }
}

System.debug(LoggingLevel.INFO,
    'backfill-task-blocked-by: COMPLETE. stamped=' + stamped + ' failed=' + failed
    + '. Re-running is a no-op: every row stamped here will report as alreadyCorrect next time.');

if (failed > 0) {
    System.debug(LoggingLevel.ERROR,
        'backfill-task-blocked-by: ' + failed + ' row(s) did not stamp. Read the getStatusCode() '
        + 'values printed above; they name the cause per row. TWO causes are EXPECTED here and are '
        + 'not defects: (1) a row that already carried a DIFFERENT non-blank key, is still OPEN, and '
        + 'whose stored key resolves to an OPEN prerequisite - TaskPrerequisiteService refuses that '
        + 'repoint on purpose (it is the disarm shape of the wire-fraud bypass). Complete or cancel '
        + 'the verification step on those deals, then re-run. (2) a row blocked by an unrelated '
        + 'validation rule or an ENTITY_IS_LOCKED pending approval, which is retryable. A row that '
        + 'had NO key before cannot hit cause 1 - gaining a first key is never a repoint.');
}

if (completedWithoutVerification > 0) {
    System.debug(LoggingLevel.WARN,
        'backfill-task-blocked-by: AUDIT FINDING — ' + completedWithoutVerification + ' wire-request '
        + 'item(s) are ALREADY COMPLETE while the anti-fraud verification they depend on is NOT. '
        + 'These are historical; this backfill deliberately does not reverse them (the money has '
        + 'moved) and does not refuse them (no status transition is being made). Report on '
        + 'Blocked_By__c != \'\' AND IsClosed = true AND Is_Prerequisite_Met__c = false and take it '
        + 'to the business — this is exactly the exposure Story 28 was raised about.');
}

if (prerequisiteMissing > 0) {
    System.debug(LoggingLevel.WARN,
        'backfill-task-blocked-by: ' + prerequisiteMissing + ' dependent item(s) have NO prerequisite '
        + 'row on their own deal, so they were left unlinked and are STILL UNGATED. Cause is almost '
        + 'always a partially fanned-out or hand-edited deal. Re-run after repairing those deals — '
        + 'do NOT link them to a prerequisite on a different Transaction.');
}

if (unparsableGroup > 0) {
    System.debug(LoggingLevel.WARN,
        'backfill-task-blocked-by: ' + unparsableGroup + ' Task(s) have a Task_Group__c that does not '
        + 'start with a single group letter followed by ".". TaskFanoutService always writes '
        + '"<Letter>. <Group Name>", so these were created or edited by something else. They were '
        + 'skipped, not guessed at. Inspect them before assuming the count is harmless.');
}
