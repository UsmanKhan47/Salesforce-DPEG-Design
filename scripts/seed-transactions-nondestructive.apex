// Seed the 5 Transactions shown in both mockups (KPI row + table) and the record page —
// NON-DESTRUCTIVE VARIANT of scripts/seed-transactions.apex, safe to run on usman-dpeg.
// ⚠ FOUR are Active. The fifth (Pasadena Industrial) is Stage__c='Closed' and, since 2026-08-31,
// Status__c='Closed' too, so the Active-Transactions KPI counts FOUR of these. See its own row.
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────────────────
// seed-transactions.apex does `delete [SELECT Id FROM Transaction__c];` — every Transaction row
// in the org, not just its own demo rows — and therefore carries a refuse-to-run guard asserting
// Organization.IsSandbox == true. `usman-dpeg` is a TRIAL Enterprise Edition org with
// IsSandbox = false holding real data, so that script correctly REFUSES to run there.
// ⚠ DO NOT WEAKEN OR REMOVE THAT GUARD, and do not "fix" the original by copying this file's
// approach over it. This file is the additive alternative; the original stays as-is.
//
// This variant has NO guard and NO delete, because it deletes nothing. It is idempotent by
// Transaction__c.Property_Name__c: it queries the five demo names, skips any that already exist,
// and inserts only the missing ones. Re-running it after a full run inserts nothing.
//
// ── 🔴 2026-09-03: THIS BLOCK IS ABOUT THE PRE-A7 FLOW AND IS NOW HALF WRONG. READ FIRST. ──
// `Transaction_Task_Fanout` was repointed onto `ChecklistFanoutService` and its second entry
// filter moved from `Tasks_Fanned_Out__c = false` to `Checklist_Fanned_Out__c = false`. Every row
// below sets Contract_Executed_Date__c and leaves BOTH flags at their default false, so each
// insert still fires the flow — but what it now creates is `Checklist__c` + `Checklist_Item__c`
// rows (~96 per deal), NOT `Task` rows. Consequences for this script, in order of how badly they
// mislead: (1) no Task is created by the insert at all, so the `Tasks_Complete__c` discussion
// below is now about a rollup driven by ChecklistRollupService rather than TaskRollupService — the
// conclusion ("hand-set values are rollup-owned and will be overwritten") is UNCHANGED, only the
// writer moved; (2) the ~82/~410 Task figures below describe a code path this script no longer
// takes; (3) `scripts/fanout-seeded-transactions.apex` is now a LEGACY-model tool and running it
// after this script puts the same deals on BOTH models — read its header before doing so.
// Everything below is left as written because it is still the correct account of the ROW DATA.
// ───────────────────────────────────────────────────────────────────────────────────────
//
// ── ⚠ INSERTING THESE FIRES THE TASK FAN-OUT: ~82 TASKS PER TRANSACTION, UP TO ~410 TOTAL ──
// `Transaction_Task_Fanout` is an ACTIVE record-triggered flow (Contract_Executed_Date__c != null
// AND Tasks_Fanned_Out__c = false, RecordAfterSave, CreateAndUpdate). Every row below sets
// Contract_Executed_Date__c and Tasks_Fanned_Out__c defaults to false, so each row inserted here
// triggers TaskFanoutService.fanOut -> TaskFanoutQueueable -> the Day-0 checklist. That is ~82
// Tasks per Transaction (Loan_Required__c is NOT set below, so the conditional Financing group is
// excluded and the real figure is somewhat lower — run scripts/fanout-seeded-transactions.apex
// afterwards if the full 82-task checklist is wanted). A full 5-deal run therefore creates
// several hundred Tasks, asynchronously, seconds after this script returns. EXPECTED, stated here
// so nobody is surprised. Because the fan-out is skipped for rows this script skips, a re-run
// creates no additional Tasks.
//
// ⚠ SIDE EFFECT OF THAT FAN-OUT, INHERITED FROM seed-transactions.apex AND DELIBERATELY NOT
// "FIXED" HERE: the hand-set `Tasks_Complete__c` values below (42 / 61 / 71 / 8 / 75) are
// ROLLUP-OWNED. TaskRollupTrigger fires on the checklist Task insert and TaskRollupService.recalc
// overwrites Tasks_Complete__c with the real completed-Task count, which for a freshly fanned-out
// deal is 0. The "N / 82" highlights tile will therefore read 0 shortly after this runs. They are
// seeded anyway so this file stays a faithful copy of the tuned original; if the mockup's
// per-deal task counts are needed on screen, set them with a SEPARATE update AFTER the fan-out
// has committed, never on this insert.
//
// ── DEMO NARRATIVE — DO NOT RETUNE THESE NUMBERS ──────────────────────────────────────────
//   Prices: 31.5 + 52.2 + 18.9 + 41.7 + 14.4 = $158.7M → KPI "In Contract" rounds to $159M
//   TTC spans (Target − Executed): 70 + 55 + 60 + 75 + 60 = 320 / 5 = 64d avg
//   Earnest at risk: 0.9M (Magnolia) + 1.5M (Cypress) = $2.4M
//   Wire approvals due: Magnolia + Beltway = 2 ; Missed feasibility YTD = 0
//   EM Wired Date = Contract Executed + 4d (drives the EM Wired highlights tile)
// ⚠ Both aggregates only hold if ALL FIVE rows are present. If a partial run leaves some of these
// names already in the org with DIFFERENT values, the KPI will not read $159M / 64d — check the
// skip list this script logs at the end before demoing.
Date toughDay = Date.today();

Date dMagnolia = Date.newInstance(2026, 7, 17);
Date dCypress  = Date.newInstance(2026, 8, 4);
Date dBeltway  = Date.newInstance(2026, 5, 2);
Date dMemorial = Date.newInstance(2026, 9, 30);
Date dPasadena = Date.newInstance(2026, 4, 3);

List<Transaction__c> candidates = new List<Transaction__c>{
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Magnolia Crossing',
        Stage__c = 'Due Diligence', Risk__c = 'Watch', Owner_Name__c = 'Danish',
        Contract_Value__c = 31500000, Tasks_Complete__c = 42,
        Target_Close_Date__c = dMagnolia, Contract_Executed_Date__c = dMagnolia.addDays(-70),
        EM_Wired_Date__c = dMagnolia.addDays(-66),
        Earnest_Money__c = 900000, Is_Earnest_At_Risk__c =true, Is_Wire_Approval_Due__c =true,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Cypress Grove MF',
        Stage__c = 'Closing Prep', Risk__c = 'High', Owner_Name__c = 'Danish',
        Contract_Value__c = 52200000, Tasks_Complete__c = 61,
        Target_Close_Date__c = dCypress, Contract_Executed_Date__c = dCypress.addDays(-55),
        EM_Wired_Date__c = dCypress.addDays(-51),
        Earnest_Money__c = 1500000, Is_Earnest_At_Risk__c =true, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Beltway Plaza',
        Stage__c = 'Closing Prep', Risk__c = 'Low', Owner_Name__c = 'Danish',
        Contract_Value__c = 18900000, Tasks_Complete__c = 71,
        Target_Close_Date__c = dBeltway, Contract_Executed_Date__c = dBeltway.addDays(-60),
        EM_Wired_Date__c = dBeltway.addDays(-56),
        Earnest_Money__c = 500000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =true,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Memorial City Office',
        Stage__c = 'Open Contract', Risk__c = 'Low', Owner_Name__c = 'Danish',
        Contract_Value__c = 41700000, Tasks_Complete__c = 8,
        Target_Close_Date__c = dMemorial, Contract_Executed_Date__c = dMemorial.addDays(-75),
        EM_Wired_Date__c = dMemorial.addDays(-71),
        Earnest_Money__c = 600000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    // 🔴 Status__c = 'Closed', NOT 'Active' (changed 2026-08-31, Gap 2) — mirrors the same change
    // in scripts/seed-transactions.apex, which this file is a faithful copy of. This is the one
    // CLOSED demo deal (Stage__c='Closed', Risk__c='Closed') and it carried Status__c='Active' in
    // the same row. The new before-save flow Transaction_Stage_Closed_Sets_Status assigns 'Closed'
    // on INSERT (CreateAndUpdate) regardless of this literal, so keeping 'Active' would not have
    // preserved the old behaviour — only made the source disagree with the row.
    //
    // ⚠ THIS ROW STILL FANS OUT. Transaction_Task_Fanout keys on Contract_Executed_Date__c and
    // Tasks_Fanned_Out__c, NOT on Status__c, so a Closed Status does not suppress the ~82-Task
    // Day-0 checklist on insert. What DOES change is scripts/fanout-seeded-transactions.apex,
    // whose locator is `WHERE Status__c = 'Active'`: it now sees FOUR rows and will not re-arm
    // this one for the full 82-task run. Correct for a closed deal, but it is a change.
    //
    // ⚠ NO Opportunity__c, DELIBERATELY. Transaction_Complete_Close fires on Status__c='Closed'
    // AND Opportunity__c != null and closes the parent deal, which mints a Property Asset via
    // PropertyAssetService.ensureOnClosedWon and posts to Acquisitions_Team. Adding a parent here
    // would run that whole cascade from a seed insert.
    new Transaction__c(Status__c = 'Closed', Property_Name__c = 'Pasadena Industrial',
        Stage__c = 'Closed', Risk__c = 'Closed', Owner_Name__c = 'Danish',
        Contract_Value__c = 14400000, Tasks_Complete__c = 75,
        Target_Close_Date__c = dPasadena, Contract_Executed_Date__c = dPasadena.addDays(-60),
        EM_Wired_Date__c = dPasadena.addDays(-56),
        Earnest_Money__c = 300000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false)
};

// ── Idempotency: skip any demo deal already present, by Property_Name__c ──────────────────
Set<String> wanted = new Set<String>();
for (Transaction__c t : candidates) {
    wanted.add(t.Property_Name__c);
}
Set<String> alreadyThere = new Set<String>();
for (Transaction__c existing : [
    SELECT Property_Name__c FROM Transaction__c WHERE Property_Name__c IN :wanted
]) {
    alreadyThere.add(existing.Property_Name__c);
}

List<Transaction__c> toInsert = new List<Transaction__c>();
List<String> skipped = new List<String>();
for (Transaction__c t : candidates) {
    if (alreadyThere.contains(t.Property_Name__c)) {
        skipped.add(t.Property_Name__c);
    } else {
        toInsert.add(t);
    }
}

if (!toInsert.isEmpty()) {
    insert toInsert;   // fires Transaction_Task_Fanout for each inserted row
}

System.debug(LoggingLevel.ERROR, 'TXNSEED inserted :: ' + toInsert.size()
    + ' | skipped (already existed) :: ' + skipped.size() + ' ' + skipped);
System.debug(LoggingLevel.ERROR, 'TXNSEED demo deals now in org :: '
    + [SELECT COUNT() FROM Transaction__c WHERE Property_Name__c IN :wanted]
    + ' of 5 (all 5 required for the $159M / 64d KPIs)');
System.debug(LoggingLevel.ERROR, 'TXNSEED total Transaction__c rows (nothing was deleted) :: '
    + [SELECT COUNT() FROM Transaction__c]);
