// ═══════════════════════════════════════════════════════════════════════════════════════════
// DEMO PROGRESS SEED — Property Management onboarding checklists (ONB-0008 .. ONB-0013).
//
// PURPOSE. All six onboardings were fanned out with 45 checklist Tasks each and every one reads
// Tasks_Complete__c = 0, so the checklist UI shows 0/45 six times and looks unstarted/broken.
// This script walks each checklist IN ITS NATURAL ORDER and marks a different share of it
// Complete / In Progress / Blocked, so the demo shows a real spread of states.
//
// NON-DESTRUCTIVE. Zero deletes, zero inserts. It UPDATES existing Tasks and existing
// Onboarding__c rows only. Run with:
//     sf apex run --file scripts/seed-onboarding-progress.apex
//
// ⚠ NO IsSandbox GUARD, DELIBERATELY. The guards on other seed scripts in this folder exist to
// stop an unfiltered `delete [SELECT ...]` running against a live org. This script deletes
// nothing and is INTENDED to run against the live demo org (usman-dpeg, IsSandbox = false), so
// such a guard would only block the thing it is being asked to do. The safety here is the
// pre-flight assert block below, which runs BEFORE any DML — and an uncaught exception in an
// anonymous block rolls the whole transaction back.
//
// ───────────────────────────────────────────────────────────────────────────────────────────
// 🔴 CORRECTION TO THE BRIEF — THE ROLLUP *IS* TRIGGER-DRIVEN NOW.
// The brief said "the rollup is NOT trigger-driven for this path, it is called imperatively (see
// OnboardingService.completeTask)". That was true until 2026-08-22 and is now false on both
// halves: TaskRollupTriggerHandler routes Onboarding__c on all four AFTER contexts, and
// OnboardingService.completeTask no longer calls recalc at all (its header records the removal —
// "keeping the explicit call would recompute twice per click").
// So the single `update` of the Task collection below already fires
// OnboardingTaskRollupService.recalc by itself. The explicit recalc call is kept anyway, as the
// brief asked, because it is IDEMPOTENT (recalc zeroes the twelve counters and re-derives them
// from a fresh selector read) and because it also covers ONB-0013, whose Tasks this script never
// touches. Cost of the redundancy: one extra SOQL + one extra DML. That is the whole price.
// ───────────────────────────────────────────────────────────────────────────────────────────
//
// FIELD / VALUE PROVENANCE — every literal below was read out of repo metadata, not guessed:
//   Task.Onboarding__c ............ objects/Activity/fields/Onboarding__c.field-meta.xml (Lookup)
//   Task.Onboarding_Status__c ..... objects/Activity/fields/Onboarding_Status__c.field-meta.xml
//                                   RESTRICTED: Not Started | In Progress | Complete | Blocked |
//                                   Not Applicable. Only 'Complete' / 'In Progress' / 'Blocked'
//                                   are written here.
//   Task.Onboarding_Category__c ... objects/Activity/fields/Onboarding_Category__c.field-meta.xml
//                                   RESTRICTED, 7 values — READ ONLY here, never written.
//   Task.Task_Sequence__c ......... objects/Activity/fields/Task_Sequence__c.field-meta.xml
//                                   Number(3,0). Set by OnboardingFanoutService.buildTask from
//                                   Onboarding_Task_Def__mdt.Sequence__c, which is GLOBAL 1..45
//                                   laid out in category order (see scripts/load-onboarding-task-
//                                   defs.apex: Property Set up 1-7, Unit & Tenant Setup 8-21,
//                                   Vendor & Expense Management 22-29, NNN Reconciliation &
//                                   Billing Setup 30-35, Tenant Communication & Transition 36-41,
//                                   Performance Tracking 42, Leasing 43-45).
//                                   ⇒ ORDER BY Task_Sequence__c IS the checklist's natural order.
//                                   That is why completion here is a contiguous PREFIX and never
//                                   scattered holes.
//   Task.Blocked_Reason__c ........ objects/Activity/fields/Blocked_Reason__c.field-meta.xml
//                                   Text(255) — free text, nothing to validate against.
//   Onboarding__c.Stage__c ........ objects/Onboarding__c/fields/Stage__c.field-meta.xml
//                                   RESTRICTED, 8 values: the 7 Onboarding_Category__c values
//                                   CHARACTER-FOR-CHARACTER, plus 'Onboarding Complete'.
//                                   ⇒ this script never types a stage literal at all. It reads
//                                   the CATEGORY off the last completed Task and writes that. A
//                                   value that came out of the picklist cannot be a typo, and the
//                                   stage is then guaranteed to agree with the progress shown.
//                                   Onboarding__c has NO record types (no recordTypes/ directory
//                                   under objects/Onboarding__c), so there is no record-type
//                                   picklist subset that could reject an otherwise-valid value.
//
// ⚠ Task.STATUS vs Task.ONBOARDING_STATUS__C — BOTH MATTER, AND THEY ARE DIFFERENT AXES.
//   OnboardingTaskRollupService.recalc and OnboardingController.getChecklist both read
//   Onboarding_Status__c ONLY — that is the authoritative field for the counters and the UI.
//   But OnboardingService.completeTask (the real click path) writes BOTH
//   Onboarding_Status__c = 'Complete' AND the standard Status = 'Completed', so a completed row
//   seeded here must carry both or it would not match a genuinely clicked one.
//   'Completed' is verified in standardValueSets/TaskStatus.standardValueSet-meta.xml.
//   🔴 Status is deliberately NOT written on the In Progress / Blocked rows. The fan-out set them
//   to OnboardingFanoutService.DEFAULT_TASK_STATUS = 'Open', and 'Open' is NOT present in this
//   repo's TaskStatus.standardValueSet-meta.xml (that file is stale relative to the org — the
//   fan-out demonstrably succeeded with it). Rather than re-type an unverifiable literal, those
//   rows keep whatever the fan-out gave them, which is exactly the state an untouched checklist
//   item is already in.
//
// ⚠ Task.Onboarding_Completed_Date__c IS NOT WRITTEN HERE, ON PURPOSE.
//   OnboardingTaskDomain.stampCompletion sets it in the Task BEFORE-UPDATE context for every row
//   entering 'Complete' (and clears it for every row leaving). Writing it here would be at best
//   redundant and at worst a fight with the domain rule. Task.ActivityDate is likewise untouched:
//   it IS the checklist item's due date, and overwriting it on completion is the exact defect
//   OnboardingTaskDomain was created to fix.
//
// GOVERNOR SHAPE: 2 SOQL up front + 1 Task DML (~130 rows = a single 200-row trigger batch, so
// ONE trigger-side recalc: +1 SOQL +1 DML) + the explicit recalc (+1 SOQL +1 DML) + 1 narrow
// Onboarding DML + 1 read-back SOQL. No DML and no SOQL inside any loop. Nowhere near a limit.
// ═══════════════════════════════════════════════════════════════════════════════════════════

// PROFILES. Row = { onboardingName, completeFraction, inProgressCount, blockedCount, blockedReason }
// The completion COUNT is derived from the fraction x the row's ACTUAL Task count, so the script
// still behaves sensibly if an onboarding turns out not to have exactly 45 rows.
List<List<Object>> profiles = new List<List<Object>>{
    // near-complete — ~89% (40/45): complete 1-40, In Progress 41-43, Blocked 44, Not Started 45
    new List<Object>{ 'ONB-0008', 0.89, 3, 1, 'Awaiting brokerage marketing package before listings go live' },
    // well advanced — ~71% (32/45): complete 1-32, In Progress 33-36, Blocked 37
    new List<Object>{ 'ONB-0009', 0.71, 4, 1, 'Awaiting final ACH and lockbox details from treasury' },
    // mid           — ~49% (22/45): complete 1-22, In Progress 23-25, none blocked
    new List<Object>{ 'ONB-0010', 0.49, 3, 0, null },
    // early         — ~31% (14/45): complete 1-14, In Progress 15-16, Blocked 17
    new List<Object>{ 'ONB-0011', 0.31, 2, 1, 'Awaiting seller closing statement' },
    // just started  — ~11% (5/45):  complete 1-5,  In Progress 6-7
    new List<Object>{ 'ONB-0012', 0.11, 2, 0, null },
    // untouched     — 0%. Listed ONLY so recalc runs over it and the read-back prints it. No Task
    //                 belonging to ONB-0013 is modified, so its "not started" state is genuine.
    new List<Object>{ 'ONB-0013', 0.00, 0, 0, null }
};

Map<String, List<Object>> profileByName = new Map<String, List<Object>>();
for (List<Object> p : profiles) {
    profileByName.put((String) p[0], p);
}

// ── 1. Resolve the six onboardings ───────────────────────────────────────────────────────────
Map<Id, Onboarding__c> onboardings = new Map<Id, Onboarding__c>([
    SELECT Id, Name, Stage__c
    FROM Onboarding__c
    WHERE Name IN :profileByName.keySet()
]);
Map<String, Id> idByName = new Map<String, Id>();
for (Onboarding__c o : onboardings.values()) {
    idByName.put(o.Name, o.Id);
}
System.assertEquals(profileByName.size(), idByName.size(),
    'Expected to resolve ' + profileByName.size() + ' Onboarding__c rows by Name but found '
    + idByName.size() + ': ' + idByName.keySet() + '. Nothing has been changed.');

// ── 2. Read every checklist Task, in checklist order ─────────────────────────────────────────
// ORDER BY Onboarding__c groups the rows; Task_Sequence__c is the checklist order (see header);
// Id is a deterministic tie-break so a null or duplicated sequence cannot shuffle between runs.
List<Task> allTasks = [
    SELECT Id, Onboarding__c, Task_Sequence__c, Onboarding_Category__c, Onboarding_Status__c
    FROM Task
    WHERE Onboarding__c IN :onboardings.keySet()
    ORDER BY Onboarding__c, Task_Sequence__c NULLS LAST, Id
];

Map<Id, List<Task>> tasksByOnboarding = new Map<Id, List<Task>>();
for (Id oid : onboardings.keySet()) {
    tasksByOnboarding.put(oid, new List<Task>());
}
for (Task t : allTasks) {
    tasksByOnboarding.get(t.Onboarding__c).add(t);
}

// ── 3. Pre-flight assertions — every one of them runs BEFORE the first DML ───────────────────
for (String nm : profileByName.keySet()) {
    List<Object> p = profileByName.get(nm);
    Integer total = tasksByOnboarding.get(idByName.get(nm)).size();
    // setScale(0, HALF_UP).intValue() rather than Math.round(): Math.round is overloaded on
    // Decimal vs Double with different return types (Integer vs Long) and the coercion here would
    // depend on which overload the compiler picks. Decimal.setScale/intValue is unambiguous.
    Integer wantComplete = (((Decimal) p[1]) * total).setScale(0, System.RoundingMode.HALF_UP).intValue();
    Integer wantTouched = wantComplete + (Integer) p[2] + (Integer) p[3];
    System.assert(total > 0,
        nm + ' has no checklist Tasks at all — has the fan-out run? Nothing has been changed.');
    System.assert(wantTouched <= total,
        nm + ' profile wants to touch ' + wantTouched + ' Tasks but only ' + total
        + ' exist. Adjust the profile. Nothing has been changed.');
    if (total != 45) {
        System.debug(LoggingLevel.ERROR, 'WARNING: ' + nm + ' has ' + total
            + ' checklist Tasks, not the expected 45. Proceeding on the actual count.');
    }
}

// ── 4. Build the Task updates — one contiguous prefix per onboarding, never scattered ────────
List<Task> taskUpdates = new List<Task>();
Map<Id, String> reachedCategoryByOnboarding = new Map<Id, String>();

for (String pname : profileByName.keySet()) {
    List<Object> prof = profileByName.get(pname);
    Id onbId = idByName.get(pname);
    List<Task> ordered = tasksByOnboarding.get(onbId);

    // Identical rounding to the pre-flight check above — see the note there.
    Integer completeCount =
        (((Decimal) prof[1]) * ordered.size()).setScale(0, System.RoundingMode.HALF_UP).intValue();
    Integer inProgressCount = (Integer) prof[2];
    Integer blockedCount = (Integer) prof[3];
    String reason = (String) prof[4];

    for (Integer i = 0; i < ordered.size(); i++) {
        Task src = ordered[i];
        // Narrow, freshly-built sObjects: Id plus ONLY the fields being changed. The queried
        // record is never re-sent, so nothing this script read can overwrite a value the
        // before-update trigger (OnboardingTaskDomain.stampCompletion) sets on the same save.
        if (i < completeCount) {
            taskUpdates.add(new Task(
                Id = src.Id,
                Onboarding_Status__c = 'Complete',
                Status = 'Completed'
            ));
            // The stage this onboarding has reached = the category of the LAST completed item.
            reachedCategoryByOnboarding.put(onbId, src.Onboarding_Category__c);
        } else if (i < completeCount + inProgressCount) {
            taskUpdates.add(new Task(
                Id = src.Id,
                Onboarding_Status__c = 'In Progress'
            ));
        } else if (i < completeCount + inProgressCount + blockedCount) {
            taskUpdates.add(new Task(
                Id = src.Id,
                Onboarding_Status__c = 'Blocked',
                Blocked_Reason__c = reason
            ));
        }
        // else: leave the row exactly as the fan-out created it ('Not Started').
    }
}

// ── 5. ONE DML for every Task across all six onboardings ─────────────────────────────────────
// ~130 rows ⇒ a single 200-row after-update trigger batch ⇒ exactly one trigger-side recalc.
if (!taskUpdates.isEmpty()) {
    update taskUpdates;
}

// ── 6. The explicit recalc the brief asked for (see the header: the trigger also fires it, and
//      recalc is idempotent). This call is what covers ONB-0013, whose Tasks were never touched.
OnboardingTaskRollupService.recalc(onboardings.keySet());

// ── 7. Advance Stage__c — narrow sObjects, AFTER the recalc ──────────────────────────────────
// 🔴 Id + Stage__c ONLY. The Onboarding__c records queried in step 1 carry counter values that
// recalc has just made stale; re-sending one of those records would overwrite the very numbers
// this script exists to move. The stage value is a category read off a Task, so it cannot be a
// typo and cannot be a value Stage__c does not have.
List<Onboarding__c> stageUpdates = new List<Onboarding__c>();
for (Id stageOid : reachedCategoryByOnboarding.keySet()) {
    String reached = reachedCategoryByOnboarding.get(stageOid);
    if (String.isNotBlank(reached) && reached != onboardings.get(stageOid).Stage__c) {
        stageUpdates.add(new Onboarding__c(Id = stageOid, Stage__c = reached));
    }
}
if (!stageUpdates.isEmpty()) {
    update stageUpdates;
}

// ── 8. Read back and print. A silent no-op cannot survive this. ──────────────────────────────
System.debug(LoggingLevel.ERROR, '=== seed-onboarding-progress: '
    + taskUpdates.size() + ' Tasks updated, ' + stageUpdates.size() + ' Stage values advanced ===');
for (Onboarding__c shown : [
    SELECT Name, Stage__c, Tasks_Complete__c, Tasks_Total__c, Tasks_In_Progress__c,
           Tasks_Blocked__c, Tasks_Not_Started__c, Completion_Pct__c
    FROM Onboarding__c
    WHERE Id IN :onboardings.keySet()
    ORDER BY Name
]) {
    System.debug(LoggingLevel.ERROR, shown.Name
        + ' | Stage: ' + shown.Stage__c
        + ' | ' + shown.Tasks_Complete__c + '/' + shown.Tasks_Total__c
        + ' (' + shown.Completion_Pct__c + '%)'
        + ' | In Progress: ' + shown.Tasks_In_Progress__c
        + ' | Blocked: ' + shown.Tasks_Blocked__c
        + ' | Not Started: ' + shown.Tasks_Not_Started__c);
}
