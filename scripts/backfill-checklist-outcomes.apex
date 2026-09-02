// Backfill the Phase 5 DERIVED outcomes onto deals whose A5 / B5 were completed BEFORE Phase 5
// existed — i.e. every deal the Phase 4 migration carried over from the legacy Task model.
// RE-RUNNABLE and IDEMPOTENT. No deletes. Writes only through `ChecklistOutcomeService`.
//
// ╔═════════════════════════════════════════════════════════════════════════════════════════╗
// ║ 🔴 READ THIS BEFORE RUNNING. THIS SCRIPT IS THE STEP THAT MAKES THE PHASE 4 MIGRATION    ║
// ║    PARTLY IRREVERSIBLE. NOTHING BEFORE IT IS.                                            ║
// ╚═════════════════════════════════════════════════════════════════════════════════════════╝
// `ChecklistMigrationService.rollback()` describes itself as CHEAP and TOTAL, and Phase 4's design
// §6 says the outcome objects "need no reversal". BOTH ARE TRUE OF THE MIGRATION ON ITS OWN, AND
// BOTH BECOME FALSE ONCE THIS SCRIPT HAS RUN — because this script is the sanctioned post-M1 step
// that both documents prescribe. The rollback still removes every `Checklist__c` and
// `Checklist_Item__c` it created; it CANNOT remove what this script wrote, because this script
// writes to the DEAL and to a different object entirely.
//
// WHAT SURVIVES A FULL PHASE 4 ROLLBACK, ON EVERY DEAL THIS SCRIPT TOUCHED. None of it existed on
// the legacy Task model, so none of it can be reconciled back to a pre-migration state:
//   1. `Critical_Date__c` ROWS — PERMANENT. `Critical_Date__c.Transaction__c` is `required=true`
//      with `deleteConstraint=Restrict`, so the deal can never be deleted again either. These are
//      precisely the rows design GATE-B3 is about, and GATE-B3 is still open.
//   2. `Transaction__c.Earnest_Money_Sent__c = true` — no writer sets it back.
//   3. `Transaction__c.Earnest_Money_Sent_Date__c` — stamped with THE DAY THIS SCRIPT RAN, not the
//      day the wire actually went out. That date is wrong the moment it is written, and it is
//      wrong in a field that reads like history.
//   4. `Transaction__c.Is_Earnest_At_Risk__c` — flipped, and read by the portfolio KPI.
//
// 🔴 AND (3) CANNOT BE REPAIRED BY RE-RUNNING, WHICH IS THE STING. `ChecklistOutcomeService
// .buildDealWrites` stamps `Earnest_Money_Sent_Date__c` ONLY WHEN IT IS BLANK — a deliberate rule
// that exists to stop a re-run overwriting the real wire date with today's. The consequence is
// that the ONE residue a second migration could otherwise correct is specifically protected
// against correction. Repairing it means clearing the field by hand (or by a targeted script)
// FIRST, and knowing the real date to put back.
//
// ⇒ RUN THIS ONLY AFTER M2's RECONCILIATION REPORT HAS GATED THE CUTOVER, i.e. once somebody has
//   confirmed the migrated data is right and the rollback is no longer the expected path. Running
//   it early converts a decision that was still reversible into one that is not.
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────────────────
// `ChecklistOutcomeService.applyForCompletedItems` runs when a user COMPLETES an item. The Phase 4
// migration does not complete anything — it INSERTS `Checklist_Item__c` rows that are already
// `Completed`, carrying history forward. So a migrated deal whose B5 was ticked months ago has:
//   • `Earnest_Money_Sent__c`      = false  (nothing ever stamped it)
//   • `Earnest_Money_Sent_Date__c` = null
//   • `Is_Earnest_At_Risk__c`      = false  (nothing ever derived it)
//   • no `Critical_Date__c` rows            (A5 never ran its projection)
// 🔴 THE CONSEQUENCE IS A SILENTLY WRONG NUMBER, NOT A VISIBLE ERROR. `TransactionController
// .getKpis` sums `Earnest_Money__c` where `Is_Earnest_At_Risk__c`, so on cutover day the portfolio
// tile reads ZERO EARNEST AT RISK across the whole book — on exactly the deals it exists to
// surface, with nothing anywhere reporting a problem. That is the RISK-1 failure shape (fail
// silent, in the safe-looking direction) reproduced one module over.
//
// ── 🔴 WHY THIS IS A SCRIPT AND NOT A CALL INSIDE `ChecklistMigrationService` ─────────────
// User decision, 2026-09-02: the deliberate, separately-run form was chosen over widening the
// migration transaction. Three reasons it is the right shape:
//   1. THE MIGRATION MUST STAY CHEAPLY REVERSIBLE. Its documented rollback is "delete the
//      `Checklist__c` rows and reset the flag; the old Tasks are untouched". Applying outcomes
//      inside it writes `Transaction__c` fields and creates `Critical_Date__c` rows — and a
//      Critical Date makes its Transaction PERMANENTLY UNDELETABLE (`deleteConstraint=Restrict`).
//      That would convert a reversible migration into an irreversible one.
//   2. GOVERNOR BUDGET. The migration's per-chunk cost is derived and pinned. Adding an outcome
//      pass (1 SOQL + 1 DML, plus 2 SOQL + 1 DML wherever an A5 appears) moves numbers its own
//      tests assert exactly.
//   3. SEQUENCING. This can be run AFTER the migration's reconciliation report has gated the
//      cutover — i.e. once somebody has confirmed the migrated data is right — rather than before.
//
// ── WHAT IT DOES ──────────────────────────────────────────────────────────────────────────
// PASS 1 — OUTCOMES. Every completed item at coordinate A5 or B5 is handed to
//   `applyForCompletedItems`, which stamps `Earnest_Money_Sent__c` / `Earnest_Money_Sent_Date__c`
//   for B5 and projects Critical Dates for A5. Both halves are idempotent: the earnest date is
//   stamped only when blank, and `CriticalDateService` keys on `(Transaction + Type)`.
// PASS 2 — AT-RISK ONLY. Deals that already read `Earnest_Money_Sent__c = true` but were not in
//   pass 1 (an old data load, or a B5 that pass 1 stamped a moment ago) still need
//   `Is_Earnest_At_Risk__c` derived. One item per deal is enough: `applyForCompletedItems`
//   refreshes the flag for EVERY deal it can resolve, whether or not the item is a derived one.
//
// ── 🔴 WHAT THIS WILL DO TO THE ORG, STATED BEFORE YOU RUN IT ────────────────────────────
// • It CREATES `Critical_Date__c` ROWS, and every deal that gets one BECOMES PERMANENTLY
//   UNDELETABLE (`Critical_Date__c.Transaction__c` is `required=true` +
//   `deleteConstraint=Restrict`). That is design GATE-B3 and it is still open. On a scratch org
//   this breaks `scripts/seed-transactions.apex:31`'s `delete [SELECT Id FROM Transaction__c]`.
//   ⇒ DO NOT RUN THIS ON A SCRATCH ORG YOU INTEND TO REBUILD WITH THE SEED SCRIPTS.
// • It UPDATES `Transaction__c`, which fires `TransactionTrigger`. The gate arms there are change-
//   gated on `Opportunity__c` and the closed boundary, neither of which this touches, so the
//   per-write cost stays at zero — but `Transaction__c` has `enableHistory=true`, so every stamp
//   lands in field history. That is useful: it makes this backfill auditable after the fact.
// • It does NOT touch `Checklist_Item__c` at all, so it cannot trip the wire-fraud gate, and it
//   does NOT touch the legacy Task model.
//
// ── 🔴 THIS SCRIPT MUST USE THE SINGLE-ARGUMENT `applyForCompletedItems(Set<Id>)` ────────
// That overload treats every DONE item as newly done, which is EXACTLY what a backfill needs and
// is the only reason it can work at all: every item it processes was completed BEFORE Phase 5
// existed, so under the transition-gated overload (`applyForCompletedItems(ids, priorByItemId)`)
// every one of them would look like a re-save and be skipped. Passing a prior map here — or
// "tidying" these two calls into the two-argument form — turns the whole script into a silent
// no-op that logs success and leaves the cutover-day KPI reading zero.
// It must also run with `ChecklistOutcomeService.suppressOutcomeApplication` FALSE, which is the
// default; the migration sets it around its own DML precisely so this script is the thing that
// applies the outcomes afterwards.
//
// ── LIMITS AND RE-RUNNING ────────────────────────────────────────────────────────────────
// Anonymous Apex gets the ordinary synchronous limits (100 SOQL, 150 DML). Each chunk costs
// ~2 statements, or ~5 where an A5 is present, so `CHUNK_SIZE` x `MAX_CHUNKS` is sized well
// inside them. If there is more work than one run can do, the script says so and you run it again
// — it is idempotent, so a second run over already-done deals is a no-op that spends reads only.

// ═══════════════════════════════════════════════════════════════════════════════════════════
// Tunables
// ═══════════════════════════════════════════════════════════════════════════════════════════

// Deals per `applyForCompletedItems` call. The service is bulk-safe (ONE item read and ONE deal
// update per call regardless of size), so this is bounded by DML ROWS, not statements.
final Integer CHUNK_SIZE = 100;

// Chunks per run, per pass. 8 x ~5 statements = ~40, leaving headroom under the 100-SOQL ceiling
// for the two candidate queries and the summary.
final Integer MAX_CHUNKS = 8;

// The two derived coordinates. ⚠ KEYED ON (letter, sequence), NEVER ON SUBJECT TEXT — the same
// rule `ChecklistCaptureDefProvider` follows, and for the same reason: a retitled item must not
// silently drop out of the backfill.
final Set<String> DERIVED_LETTERS = new Set<String>{ 'A', 'B' };
final Decimal DERIVED_SEQUENCE = 5;

// `ChecklistItemDomain.isDone` is a TWO-VALUE test. A wire item that was VERIFIED is done, and a
// `Flag__c = 'Completed'` filter alone would silently undercount.
final Set<String> DONE_FLAGS = new Set<String>{ 'Completed', 'Verified' };

System.debug(LoggingLevel.ERROR, '════ PHASE 5 OUTCOME BACKFILL START ═══════════════════════');

// 🔴 SUPPRESSION MUST BE OFF. A static dies with its transaction, so this can only be true if
// something in THIS anonymous-Apex execution turned it on — but the check costs nothing and the
// failure it catches is total and silent: every call below would return immediately, every counter
// would read zero, and the summary would report a clean run over a book it never touched.
if (ChecklistOutcomeService.isOutcomeApplicationSuppressed()) {
    System.debug(LoggingLevel.ERROR, 'BACKFILL 🔴 ABORTING — outcome application is SUPPRESSED. '
        + 'This script exists precisely to apply what the migration deliberately did not. Running '
        + 'it suppressed would do nothing and say it succeeded.');
    throw new System.IllegalArgumentException(
        'ChecklistOutcomeService outcome application is suppressed; backfill aborted.');
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// PASS 1 — outcomes for completed A5 / B5
// ═══════════════════════════════════════════════════════════════════════════════════════════

List<Checklist_Item__c> derivedItems = [
    SELECT Id, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c
    FROM Checklist_Item__c
    WHERE Flag__c IN :DONE_FLAGS
      AND Sequence__c = :DERIVED_SEQUENCE
      AND Checklist__r.Group_Letter__c IN :DERIVED_LETTERS
      AND Checklist__r.Transaction__c != NULL
    ORDER BY Checklist__r.Transaction__c ASC, Id ASC
];

System.debug(LoggingLevel.ERROR, 'BACKFILL pass 1 candidates (completed A5/B5 items): '
    + derivedItems.size());

Set<Id> dealsTouched = new Set<Id>();
List<Id> pass1Ids = new List<Id>();
for (Checklist_Item__c item : derivedItems) {
    pass1Ids.add(item.Id);
    dealsTouched.add(item.Checklist__r.Transaction__c);
}

Integer pass1Chunks = 0;
Integer pass1Applied = 0;
Integer pass1Unreadable = 0;
for (Integer i = 0; i < pass1Ids.size() && pass1Chunks < MAX_CHUNKS; i += CHUNK_SIZE) {
    Integer end = Math.min(i + CHUNK_SIZE, pass1Ids.size());
    Set<Id> chunk = new Set<Id>();
    for (Integer j = i; j < end; j++) {
        chunk.add(pass1Ids[j]);
    }
    try {
        ChecklistOutcomeService.applyForCompletedItems(chunk);
        // 🔴 THE SERVICE COUNTER, NEVER `chunk.size()`. Adding the INPUT size here reports success
        // for items the service never read — a sharing-filtered or short read returns silently and
        // this loop would log a clean run over deals it did nothing to.
        pass1Applied += ChecklistOutcomeService.lastRunConsideredItems();
        pass1Unreadable += ChecklistOutcomeService.lastRunUnreadableItems();
    } catch (Exception e) {
        // Logged and continued deliberately. One bad deal must not strand the rest of the book,
        // and the script is idempotent so the failed chunk is picked up by the next run.
        System.debug(LoggingLevel.ERROR, 'BACKFILL 🔴 pass 1 chunk starting at ' + i
            + ' FAILED: ' + e.getTypeName() + ': ' + e.getMessage());
    }
    pass1Chunks++;
}

Integer pass1Remaining = pass1Ids.size() - pass1Applied;
System.debug(LoggingLevel.ERROR, 'BACKFILL pass 1 applied ' + pass1Applied + ' item(s) across '
    + pass1Chunks + ' chunk(s); ' + pass1Remaining + ' remaining');

// ═══════════════════════════════════════════════════════════════════════════════════════════
// PASS 2 — at-risk refresh for deals with earnest money already sent
// ═══════════════════════════════════════════════════════════════════════════════════════════
// ⚠ THIS PASS IS NOT REDUNDANT WITH PASS 1. A deal can carry `Earnest_Money_Sent__c = true` from
// an old data load, or from pass 1 stamping it a moment ago, without having a completed B5 that
// pass 1 would have caught — and `Is_Earnest_At_Risk__c` is derived from the SENT flag plus the
// feasibility posture, not from the item. Without this the cutover-day KPI is still wrong for
// exactly those deals.

Set<Id> sentDeals = new Set<Id>();
for (Transaction__c deal : [
    SELECT Id FROM Transaction__c WHERE Earnest_Money_Sent__c = true
]) {
    sentDeals.add(deal.Id);
}
System.debug(LoggingLevel.ERROR, 'BACKFILL pass 2 deals with earnest money sent: '
    + sentDeals.size());

// ONE item per deal is enough — the service refreshes at-risk for every deal it can resolve,
// whether or not the item carries a derived coordinate.
Map<Id, Id> anyItemByDeal = new Map<Id, Id>();
for (Checklist_Item__c item : [
    SELECT Id, Checklist__r.Transaction__c
    FROM Checklist_Item__c
    WHERE Checklist__r.Transaction__c IN :sentDeals
    ORDER BY Checklist__r.Transaction__c ASC, Id ASC
]) {
    // First one seen per deal wins; the ORDER BY makes that deterministic across runs.
    if (!anyItemByDeal.containsKey(item.Checklist__r.Transaction__c)) {
        anyItemByDeal.put(item.Checklist__r.Transaction__c, item.Id);
    }
}

List<Id> pass2Ids = new List<Id>();
for (Id dealId : anyItemByDeal.keySet()) {
    pass2Ids.add(anyItemByDeal.get(dealId));
}

Integer pass2Chunks = 0;
Integer pass2Applied = 0;
Integer pass2Unreadable = 0;
for (Integer i = 0; i < pass2Ids.size() && pass2Chunks < MAX_CHUNKS; i += CHUNK_SIZE) {
    Integer end = Math.min(i + CHUNK_SIZE, pass2Ids.size());
    Set<Id> chunk = new Set<Id>();
    for (Integer j = i; j < end; j++) {
        chunk.add(pass2Ids[j]);
    }
    try {
        ChecklistOutcomeService.applyForCompletedItems(chunk);
        // The service counter, for the same reason as pass 1 above.
        pass2Applied += ChecklistOutcomeService.lastRunConsideredItems();
        pass2Unreadable += ChecklistOutcomeService.lastRunUnreadableItems();
    } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, 'BACKFILL 🔴 pass 2 chunk starting at ' + i
            + ' FAILED: ' + e.getTypeName() + ': ' + e.getMessage());
    }
    pass2Chunks++;
}

Integer pass2Remaining = pass2Ids.size() - pass2Applied;
System.debug(LoggingLevel.ERROR, 'BACKFILL pass 2 refreshed ' + pass2Applied + ' deal(s) across '
    + pass2Chunks + ' chunk(s); ' + pass2Remaining + ' remaining');

// ═══════════════════════════════════════════════════════════════════════════════════════════
// SUMMARY — REQUERIED, never read off in-memory rows
// ═══════════════════════════════════════════════════════════════════════════════════════════

Integer sentNow = [SELECT COUNT() FROM Transaction__c WHERE Earnest_Money_Sent__c = true];
Integer atRiskNow = [SELECT COUNT() FROM Transaction__c WHERE Is_Earnest_At_Risk__c = true];
Integer criticalDatesNow = [SELECT COUNT() FROM Critical_Date__c];

System.debug(LoggingLevel.ERROR, 'BACKFILL ── RESULT ───────────────────────────────────────');
System.debug(LoggingLevel.ERROR, 'BACKFILL deals with Earnest Money Sent : ' + sentNow);
System.debug(LoggingLevel.ERROR, 'BACKFILL deals with Earnest At Risk    : ' + atRiskNow);
System.debug(LoggingLevel.ERROR, 'BACKFILL Critical_Date__c rows in org  : ' + criticalDatesNow);
System.debug(LoggingLevel.ERROR, 'BACKFILL SOQL used ' + Limits.getQueries() + '/'
    + Limits.getLimitQueries() + ', DML ' + Limits.getDmlStatements() + '/'
    + Limits.getLimitDmlStatements());

// 🔴 THE SILENT-SUCCESS CANARY. `applyForCompletedItems` returns quietly when its read comes back
// short or empty — the natural sharing failure on this path — and every other counter stays at
// zero, which is indistinguishable from "nothing to do". These two numbers come from the SERVICE,
// not from the sizes this script passed in, so a run that touched nothing cannot report success.
Integer unreadable = pass1Unreadable + pass2Unreadable;
if (unreadable > 0) {
    System.debug(LoggingLevel.ERROR, 'BACKFILL 🔴 ' + unreadable + ' item(s) WERE ASKED FOR BUT '
        + 'COULD NOT BE READ (pass 1: ' + pass1Unreadable + ', pass 2: ' + pass2Unreadable + '). '
        + 'THOSE DEALS WERE NOT BACKFILLED. This is a SHARING or visibility problem, not a data '
        + 'problem: the runner must hold Edit-level access to every deal being backfilled. '
        + 'Re-running as-is will skip them again. Do NOT declare the cutover clean.');
} else {
    System.debug(LoggingLevel.ERROR,
        'BACKFILL ✅ every item asked for was readable (0 unreadable).');
}

if (pass1Remaining > 0 || pass2Remaining > 0) {
    System.debug(LoggingLevel.ERROR, 'BACKFILL ⚠ MORE WORK REMAINS (' + pass1Remaining
        + ' item(s), ' + pass2Remaining + ' deal(s)). RUN THIS SCRIPT AGAIN — it is idempotent, '
        + 'so re-running over already-backfilled deals spends reads and writes nothing.');
} else {
    System.debug(LoggingLevel.ERROR, 'BACKFILL ✅ nothing left to do.');
}

// 🔴 THE ONE NUMBER TO ACTUALLY CHECK. `atRiskNow` being ZERO on a book that has closed deals with
// expired feasibility is the failure this whole script exists to prevent — and it looks identical
// to a healthy org with no at-risk deposits. Cross-check it against the deals you KNOW are past
// feasibility with money wired before declaring the cutover clean. A green run is not proof.
if (atRiskNow == 0 && sentNow > 0) {
    System.debug(LoggingLevel.ERROR, 'BACKFILL ⚠ ' + sentNow + ' deal(s) have earnest money sent '
        + 'but NONE reads at risk. That is legitimate only if every one of them is still inside '
        + 'its feasibility window or has already closed. VERIFY IT — do not assume it.');
}
System.debug(LoggingLevel.ERROR, '════ PHASE 5 OUTCOME BACKFILL END ═════════════════════════');
