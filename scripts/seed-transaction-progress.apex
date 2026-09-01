// ═══════════════════════════════════════════════════════════════════════════════════════════
// DEMO PROGRESS + DISPLAY REPAIR — Transaction__c (TXN-0267 .. TXN-0277).
//
// TWO PROBLEMS, ONE SCRIPT:
//   1. The six ORGANIC transactions (TXN-0267..0272) render as blank-named rows in the Active
//      Transactions list, with mostly-null Contract_Value__c and an undifferentiated 'Low' risk.
//   2. Every transaction reads Tasks_Complete__c = 0, so all eleven show "0 / 82".
//
// NON-DESTRUCTIVE. Zero deletes, zero inserts. Existing Tasks and existing Transaction__c rows
// are UPDATED only, and every repair in Problem 1 is applied ONLY WHERE THE FIELD IS CURRENTLY
// BLANK, so nothing a human typed is overwritten. Run with:
//     sf apex run --file scripts/seed-transaction-progress.apex
//
// ⚠ NO IsSandbox GUARD, DELIBERATELY — same reasoning as scripts/seed-onboarding-progress.apex.
// The guards on the destructive seed scripts in this folder exist to stop an unfiltered
// `delete [SELECT ...]`. This script deletes nothing and is MEANT to run against the live demo
// org (usman-dpeg, IsSandbox = false). The safety here is the pre-flight block, which runs before
// any DML; an uncaught exception in an anonymous block rolls the whole transaction back.
//
// ═══ 🔴 THE ONE THING THIS SCRIPT MUST NEVER DO: SET Status__c = 'Closed' ═══
// flows/Transaction_Complete_Close.flow-meta.xml is RecordAfterSave / CreateAndUpdate with entry
// criteria `Status__c EqualTo 'Closed' AND Opportunity__c IsNull false`. Meeting it fires a
// Chatter post to the Acquisitions_Team group AND writes the parent Opportunity to
// StageName = 'Closed Won' / Deal_Category__c = 'Closed' / Deal_Status__c = 'Asset Under
// Management'. Nothing below writes Status__c at all — TXN-0267 is Status__c 'Active' with
// Stage__c 'Closed' (two different fields; see objects/Transaction__c/fields/Status__c and
// Stage__c). Do not "tidy" that by closing it out.
// The other two Transaction flows are safe here: Transaction_Opened_Notify is Create-only, and
// Transaction_Task_Fanout requires `Tasks_Fanned_Out__c = false` (already true on all eleven, so
// no second fan-out can be provoked by these updates).
//
// ───────────────────────────────────────────────────────────────────────────────────────────
// PROBLEM 2 — WHY THE HONEST ROUTE IS THE ONLY ROUTE.
// TaskRollupService.recalc OWNS Transaction__c.Tasks_Complete__c / Tasks_Overdue__c /
// Wire_Open_Risks__c, and TaskRollupTrigger calls it on all four AFTER contexts of Task. Any
// hand-written Tasks_Complete__c is therefore overwritten by the next Task DML. So this script
// completes REAL Tasks and lets the rollup derive the number.
//
// 🔴 THE COMPLETION SIGNAL FOR A TRANSACTION TASK IS THE STANDARD `Task.Status`, NOT a custom
// field. TaskRollupService counts `if (t.IsClosed)`, and IsClosed is derived from Status via the
// standardValueSet's `closed` flag. TransactionTaskService writes exactly `Status = 'Completed'`
// (and 'Not Started' to un-complete), and TaskFanoutService creates the rows with
// `Status = 'Not Started'`. All three literals are verified present in
// standardValueSets/TaskStatus.standardValueSet-meta.xml, where 'Completed' is the only value
// carrying `<closed>true</closed>`.
// ⚠ This is DIFFERENT from the onboarding checklist, which is driven by the custom
// Task.Onboarding_Status__c. Do not copy one convention onto the other. These Tasks carry a null
// Onboarding__c, so TaskRollupTriggerHandler's onboarding branch costs nothing on this run.
//
// CHECKLIST ORDER = Task_Group__c, THEN Task_Sequence__c — AND ORDERING BY SEQUENCE ALONE IS
// WRONG HERE. scripts/load-transaction-task-defs.apex restarts Sequence__c inside every group
// (A:1..n, B:1..n, ... J:1..15), unlike the onboarding checklist whose sequence is global 1..45.
// TaskFanoutService writes `Task_Group__c = Letter__c + '. ' + Group_Name__c` ("A. ...", "B. ..."
// through "J. ..."), so an alphabetical sort on that text field IS the group order for the ten
// single-letter groups that exist. TransactionTaskController buckets the rows by Task_Group__c
// for display. Completion below is therefore a contiguous prefix of (group, sequence) — an
// evenly-progressing checklist, not holes scattered through it.
//
// ⚠ Tasks_Total__c IS NOT WRITTEN AND MUST NOT BE. TaskFanoutService writes the count actually
// created for THAT transaction, gated by that row's own condition fields (Loan_Required__c and
// friends), so the denominator legitimately differs between rows — 82 is not a constant. Every
// count below is derived from each transaction's OWN queried Task count for the same reason.
//
// ───────────────────────────────────────────────────────────────────────────────────────────
// PROBLEM 1 — FIELD PROVENANCE. Every field name was read out of repo metadata, not guessed:
//   Transaction__c.Property_Name__c ... Text(120). objects/Transaction__c/fields/. NOTHING in the
//        application populates it — ContractExecutionService (line ~336) inserts each Transaction
//        with the `Property__c` LOOKUP and never the text twin, which is exactly why these six are
//        blank. TransactionController.propertyNameOf already coalesces lookup-then-text for the
//        LWC, but its own header records the gap this script actually closes: FIVE report files
//        (Open_Transactions, Closing_In_30_Days, Financing_Active, Transactions_By_Stage,
//        Completion_By_Deal) read Property_Name__c DIRECTLY and cannot traverse the lookup.
//        ⇒ stamping the text field is what makes the name appear in the REPORTS too.
//   Transaction__c.Property__c ....... Lookup -> Property__c. Property__c's name field is the
//        STANDARD `Name`, labelled "Property Name" (objects/Property__c/Property__c.object-meta
//        .xml <nameField>) — so it is `Property__r.Name`, NOT `Property__r.Property_Name__c`.
//   Transaction__c.Opportunity__c .... Lookup -> Opportunity. Set on every organic row (it is the
//        record ContractExecutionService was handed off from), so a name source always exists.
//   Transaction__c.Contract_Value__c . Currency(18,2). ContractExecutionService fills it from
//        `Opportunity.Primary_Contract__r.Contract_Value__c` (Primary_Contract__c ->
//        Contract_Review__c, which does carry Contract_Value__c) — null whenever the deal had no
//        primary contract, which is why four of the six are null.
//   Transaction__c.Risk__c ........... RESTRICTED picklist, exactly four values:
//        Low (default) | Watch | High | Closed. Nothing else deploys.
//   Transaction__c.Status__c ......... RESTRICTED: Draft | Active | Closed.  NOT WRITTEN (see above).
//   Transaction__c.Stage__c .......... RESTRICTED: Open Contract | Due Diligence | Closing Prep |
//        Post-Closing | Closed.  NOT WRITTEN by this script — the stage spread already varies.
//   Task.Transaction_Deal__c ......... objects/Activity/fields/Transaction_Deal__c.field-meta.xml
//   Task.Task_Group__c / Task_Sequence__c ... objects/Activity/fields/ (Text(80) / Number(3,0))
//   Transaction__c has NO record types and NO Apex trigger, so no record-type picklist subset and
//   no additional cascade beyond the three flows named above.
//
// ⚠ ONE FABRICATED VALUE CLASS, FLAGGED RATHER THAN HIDDEN. Where Contract_Value__c is null AND
// neither real source (Primary_Contract__r.Contract_Value__c, then Opportunity.Amount) yields a
// number, this script writes a plausible demo figure from the profile table below so the pipeline
// KPI is not dragged down by nulls. Those four numbers are INVENTED — they are listed explicitly,
// per row, so they are auditable and easy to delete. Every other value written here is copied
// from a real related record.
//
// GOVERNOR SHAPE: 2 SOQL up front (11 Transactions, ~900 Tasks — well inside the 50,000 query-row
// limit) + 1 Task DML of ~380 rows (2 x 200-row after-update batches, so 2 trigger-side recalcs =
// +2 SOQL +2 DML) + 1 explicit recalc (+1 SOQL +1 DML) + 1 narrow Transaction DML of <= 11 rows
// + 1 read-back SOQL. ~380 DML rows against the 10,000 limit. No SOQL and no DML inside any loop.
// ⇒ ALL ELEVEN TRANSACTIONS FIT COMFORTABLY IN ONE TRANSACTION; no scoping-down is needed.
// ═══════════════════════════════════════════════════════════════════════════════════════════

// PROFILES. Row = { txnName, completeFraction, riskOverride (null = leave alone),
//                   fallbackContractValue (null = never fabricate) }
//
// completeFraction is applied to that row's OWN Task count (see the Tasks_Total__c note above).
// riskOverride / fallbackContractValue are populated only for the six ORGANIC rows; the five
// seeded rows (TXN-0273..0277) already carry deliberate values and are left untouched on both.
List<List<Object>> profiles = new List<List<Object>>{
    // ── the six organic rows created by ContractExecutionService ──────────────────────────────
    // ⚠ The fabricated values are written as DECIMAL literals (trailing .00) on purpose. They are
    // read back with `(Decimal) pr[3]`, and casting an Object whose runtime type is Integer to
    // Decimal throws a TypeException — Apex's implicit Integer->Decimal widening does not apply
    // to an explicit downcast out of Object.
    new List<Object>{ 'TXN-0267', 0.95, 'Closed', 12400000.00 },  // Stage 'Closed' -> Risk 'Closed'
    new List<Object>{ 'TXN-0268', 0.15, 'Low',    null        },  // already has 8.35M
    new List<Object>{ 'TXN-0269', 0.22, 'Watch',  null        },  // already has 31.0M
    new List<Object>{ 'TXN-0270', 0.10, 'Low',     9600000.00 },
    // 0.00 = the deliberately UNTOUCHED checklist (the "not started" state, demonstrable). Its
    // Problem 1 display repair still applies — that is a blank-field fix, not checklist progress.
    new List<Object>{ 'TXN-0271', 0.00, 'High',   22800000.00 },
    new List<Object>{ 'TXN-0272', 0.30, 'Watch',  14200000.00 },
    // ── the five seeded rows: checklist progress only, no field repair ────────────────────────
    new List<Object>{ 'TXN-0273', 0.45, null, null },
    new List<Object>{ 'TXN-0274', 0.80, null, null },
    new List<Object>{ 'TXN-0275', 0.72, null, null },
    new List<Object>{ 'TXN-0276', 0.55, null, null },
    new List<Object>{ 'TXN-0277', 0.35, null, null }
};

Map<String, List<Object>> profileByName = new Map<String, List<Object>>();
for (List<Object> p : profiles) {
    profileByName.put((String) p[0], p);
}

// ── 1. Resolve the transactions, with every repair source in one query ───────────────────────
Map<Id, Transaction__c> txns = new Map<Id, Transaction__c>([
    SELECT Id, Name, Status__c, Stage__c, Risk__c, Property_Name__c, Contract_Value__c,
           Tasks_Fanned_Out__c, Property__c, Property__r.Name,
           Opportunity__c, Opportunity__r.Name, Opportunity__r.Amount,
           Opportunity__r.Property__c, Opportunity__r.Property__r.Name,
           Opportunity__r.Primary_Contract__c, Opportunity__r.Primary_Contract__r.Contract_Value__c
    FROM Transaction__c
    WHERE Name IN :profileByName.keySet()
]);
Map<String, Id> idByName = new Map<String, Id>();
for (Transaction__c tx : txns.values()) {
    idByName.put(tx.Name, tx.Id);
}
System.assert(!idByName.isEmpty(),
    'Resolved ZERO Transaction__c rows for ' + profileByName.keySet()
    + '. Nothing has been changed.');
// A name that has drifted is reported loudly rather than aborting an hour before a demo; the
// read-back at the end prints exactly which rows were actually touched, so a partial run cannot
// be mistaken for a full one.
for (String nm : profileByName.keySet()) {
    if (!idByName.containsKey(nm)) {
        System.debug(LoggingLevel.ERROR,
            'WARNING: ' + nm + ' was not found and is being SKIPPED entirely.');
    }
}

// ── 2. Read every checklist Task, in checklist order ─────────────────────────────────────────
// ORDER BY Transaction_Deal__c groups the rows; Task_Group__c ("A. ..." .. "J. ...") then
// Task_Sequence__c is the checklist order (see the header — sequence alone would interleave the
// groups); Id is a deterministic tie-break so equal keys cannot shuffle between runs.
List<Task> allTasks = [
    SELECT Id, Transaction_Deal__c, Task_Group__c, Task_Sequence__c, Subject, Status, IsClosed
    FROM Task
    WHERE Transaction_Deal__c IN :txns.keySet()
    ORDER BY Transaction_Deal__c, Task_Group__c NULLS LAST, Task_Sequence__c NULLS LAST, Id
];

Map<Id, List<Task>> tasksByTxn = new Map<Id, List<Task>>();
for (Id tid : txns.keySet()) {
    tasksByTxn.put(tid, new List<Task>());
}
for (Task tk : allTasks) {
    tasksByTxn.get(tk.Transaction_Deal__c).add(tk);
}

// ── 3. Pre-flight checks — all of them run BEFORE the first DML ──────────────────────────────
for (Id tid : txns.keySet()) {
    Transaction__c chk = txns.get(tid);
    Integer chkTotal = tasksByTxn.get(tid).size();
    if (chkTotal == 0) {
        System.debug(LoggingLevel.ERROR, 'WARNING: ' + chk.Name
            + ' has no checklist Tasks (Tasks_Fanned_Out__c = ' + chk.Tasks_Fanned_Out__c
            + '?) — its completion profile will be a no-op.');
    }
    // Guards the header's volume argument rather than trusting it: if the data has grown, fail
    // here with a readable message instead of at row 10,001 of a half-applied DML.
    System.assert(chkTotal <= 200,
        chk.Name + ' carries ' + chkTotal + ' checklist Tasks — far more than the ~82 this script '
        + 'was sized against. Re-do the volume arithmetic in the header before running. '
        + 'Nothing has been changed.');
}

// ── 4. Build the Task updates — a contiguous (group, sequence) prefix per transaction ────────
List<Task> taskUpdates = new List<Task>();

for (Id tid : txns.keySet()) {
    List<Object> prof = profileByName.get(txns.get(tid).Name);
    if (prof == null) {
        continue;
    }
    List<Task> ordered = tasksByTxn.get(tid);
    // setScale(0, HALF_UP).intValue() rather than Math.round(): Math.round is overloaded on
    // Decimal vs Double with different return types (Integer vs Long), so the coercion would
    // depend on which overload the compiler picks. Decimal.setScale/intValue is unambiguous.
    Integer completeCount =
        (((Decimal) prof[1]) * ordered.size()).setScale(0, System.RoundingMode.HALF_UP).intValue();

    for (Integer i = 0; i < completeCount; i++) {
        Task src = ordered[i];
        // Already closed (TXN-0267 has two) — skip, so the DML carries only real changes.
        if (src.IsClosed) {
            continue;
        }
        // Narrow, freshly-built sObject: Id + the one field being changed. The queried record is
        // never re-sent, so nothing this script read can overwrite a concurrent value.
        taskUpdates.add(new Task(Id = src.Id, Status = 'Completed'));
    }
    // ⚠ Rows PAST the prefix are deliberately left exactly as they are — never reset to
    // 'Not Started'. Un-completing a Task somebody genuinely finished would not be
    // non-destructive, and it is not needed: they are already 'Not Started' from the fan-out.
}

// ── 5. ONE DML for every Task across every transaction ───────────────────────────────────────
if (!taskUpdates.isEmpty()) {
    update taskUpdates;
}

// ── 6. Let the rollup derive the counters ────────────────────────────────────────────────────
// TaskRollupTrigger already fired recalc once per 200-row batch of the update above. This call is
// kept because it is idempotent (recalc re-derives all three counters from a fresh selector read)
// and because it is what covers TXN-0271, whose Tasks were never touched.
TaskRollupService.recalc(txns.keySet());

// ── 7. Problem 1: repair the display fields — narrow sObjects, AFTER the rollup ──────────────
// 🔴 Id + only the repaired fields. Step 1 deliberately does NOT select Tasks_Complete__c /
// Tasks_Overdue__c / Wire_Open_Risks__c, and these updates are built as fresh sObjects rather
// than mutations of the queried rows — two independent reasons why nothing this script read can
// write back over the counters recalc has just recomputed in step 6.
List<Transaction__c> repairs = new List<Transaction__c>();
List<String> fabricated = new List<String>();

for (Id tid : txns.keySet()) {
    Transaction__c txRow = txns.get(tid);
    List<Object> pr = profileByName.get(txRow.Name);
    if (pr == null) {
        continue;
    }
    Transaction__c fix = new Transaction__c(Id = tid);
    Boolean changed = false;

    // (a) PROPERTY NAME — only when blank. Source order: the transaction's own Property lookup,
    //     then the source Opportunity's Property lookup, then the Opportunity's own name. Each
    //     hop is guarded: a null lookup means the __r is null.
    if (String.isBlank(txRow.Property_Name__c)) {
        String resolvedName = null;
        if (txRow.Property__c != null && txRow.Property__r != null
                && String.isNotBlank(txRow.Property__r.Name)) {
            resolvedName = txRow.Property__r.Name;
        } else if (txRow.Opportunity__c != null && txRow.Opportunity__r != null
                && txRow.Opportunity__r.Property__c != null && txRow.Opportunity__r.Property__r != null
                && String.isNotBlank(txRow.Opportunity__r.Property__r.Name)) {
            resolvedName = txRow.Opportunity__r.Property__r.Name;
        } else if (txRow.Opportunity__c != null && txRow.Opportunity__r != null
                && String.isNotBlank(txRow.Opportunity__r.Name)) {
            // The deal name, not a property name — but it is a REAL related value rather than an
            // invention, and it is what a user would recognise the row by.
            resolvedName = txRow.Opportunity__r.Name;
        }
        if (resolvedName != null) {
            // Property_Name__c is Text(120); every source above is <= 120 in practice, but a
            // silent DML failure on a demo script is not worth the risk.
            fix.Property_Name__c = resolvedName.length() > 120
                ? resolvedName.substring(0, 120)
                : resolvedName;
            changed = true;
        } else {
            System.debug(LoggingLevel.ERROR, 'WARNING: ' + txRow.Name
                + ' has no Property lookup and no Opportunity to take a name from — '
                + 'Property_Name__c left blank rather than invented.');
        }
    }

    // (b) CONTRACT VALUE — only when null. Real sources first; the profile's figure is the last
    //     resort and is reported as fabricated.
    if (txRow.Contract_Value__c == null) {
        Decimal resolvedValue = null;
        if (txRow.Opportunity__c != null && txRow.Opportunity__r != null
                && txRow.Opportunity__r.Primary_Contract__c != null
                && txRow.Opportunity__r.Primary_Contract__r != null
                && txRow.Opportunity__r.Primary_Contract__r.Contract_Value__c != null) {
            resolvedValue = txRow.Opportunity__r.Primary_Contract__r.Contract_Value__c;
        } else if (txRow.Opportunity__c != null && txRow.Opportunity__r != null
                && txRow.Opportunity__r.Amount != null && txRow.Opportunity__r.Amount > 0) {
            resolvedValue = txRow.Opportunity__r.Amount;
        } else if (pr[3] != null) {
            resolvedValue = (Decimal) pr[3];
            fabricated.add(txRow.Name + '=' + resolvedValue);
        }
        if (resolvedValue != null) {
            fix.Contract_Value__c = resolvedValue;
            changed = true;
        }
    }

    // (c) RISK — profile override only (the five seeded rows carry null here and are skipped).
    //     Values are constrained to the four in Risk__c's restricted value set.
    if (pr[2] != null && (String) pr[2] != txRow.Risk__c) {
        fix.Risk__c = (String) pr[2];
        changed = true;
    }

    if (changed) {
        repairs.add(fix);
    }
}

if (!repairs.isEmpty()) {
    update repairs;
}

// ── 8. Read back and print. A silent no-op cannot survive this. ──────────────────────────────
System.debug(LoggingLevel.ERROR, '=== seed-transaction-progress: '
    + taskUpdates.size() + ' Tasks completed, ' + repairs.size() + ' Transactions repaired ===');
if (!fabricated.isEmpty()) {
    System.debug(LoggingLevel.ERROR,
        'FABRICATED Contract_Value__c (no real source existed, see header): ' + fabricated);
}
for (Transaction__c shown : [
    SELECT Name, Property_Name__c, Contract_Value__c, Risk__c,
           Status__c, Stage__c, Tasks_Complete__c, Tasks_Total__c, Tasks_Overdue__c
    FROM Transaction__c
    WHERE Id IN :txns.keySet()
    ORDER BY Name
]) {
    System.debug(LoggingLevel.ERROR, shown.Name
        + ' | Property: ' + shown.Property_Name__c
        + ' | Value: ' + shown.Contract_Value__c
        + ' | Risk: ' + shown.Risk__c
        + ' | ' + shown.Status__c + '/' + shown.Stage__c
        + ' | Tasks ' + shown.Tasks_Complete__c + '/' + shown.Tasks_Total__c
        + ' | Overdue: ' + shown.Tasks_Overdue__c);
}
