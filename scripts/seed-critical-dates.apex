// Seed Critical_Date__c so the Transaction Dashboard's "Critical Dates — Countdown" component
// renders. NON-DESTRUCTIVE and re-runnable: zero deletes, zero updates, one insert.
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────────────────
// The report (force-app/main/default/reports/Transactions/Critical_Dates_Countdown.report-meta.xml)
// and the dashboard component are both correct. `Critical_Date__c` simply had ZERO rows on
// usman-dpeg and no seed script for the object existed anywhere in scripts/. Pure data gap.
//
// ── WHAT FIRES WHEN THIS INSERTS (verified 2026-08-29) ────────────────────────────────────
// NOTHING. Critical_Date__c has:
//   • no Apex trigger        — force-app/main/default/triggers/ contains none for this object
//   • no record-triggered Flow — grep of flows/ for "Critical_Date" returns nothing
//   • no validation rules / workflows — the object folder holds only object-meta.xml + fields/
// The three Transaction__c flows (Transaction_Task_Fanout, Transaction_Opened_Notify,
// Transaction_Complete_Close) are record-triggered on Transaction__c. This script never inserts
// or updates a Transaction__c, and inserting a CHILD does not re-fire a parent record-triggered
// flow, so the ~82-Task Day-0 fan-out is NOT triggered here. Expect no async work at all.
//
// ── 🔴 SIDE EFFECT ON OTHER SCRIPTS: Transaction deletes become RESTRICTED ────────────────
// Critical_Date__c.Transaction__c is a Lookup with <deleteConstraint>Restrict</deleteConstraint>
// AND <required>true</required>. Once rows exist here, any attempt to delete a parent
// Transaction__c that has Critical Dates FAILS with DELETE_FAILED. That directly affects
// `scripts/seed-transactions.apex` line 31 (`delete [SELECT Id FROM Transaction__c];`) — it will
// now throw on a rebuilt scratch org unless Critical Dates are cleared first. It is already
// guarded to IsSandbox == true so it cannot run on usman-dpeg, but do not be surprised by it on a
// scratch rebuild. This script does NOT weaken that; deleting rows is out of scope by design.
//
// ── FIELDS (verified against force-app/main/default/objects/Critical_Date__c/fields/) ─────
//   Due_Date__c      Date,   required=true   — written
//   Type__c          Picklist, restricted=TRUE, exactly five values (see PLAN table) — written
//   Transaction__c   Lookup(Transaction__c), required=TRUE, deleteConstraint=Restrict — written
//   Days_Until__c    FORMULA  Due_Date__c - TODAY()            — NEVER written; read after requery
//   Deal_Name__c     FORMULA  Transaction__r.Property_Name__c  — NEVER written; read after requery
// ⚠ Type__c is a RESTRICTED picklist and restricted picklists ARE enforced by DML on this project
// (measured repeatedly). Every literal in the PLAN table below must be byte-identical to one of:
//   Closing Date | Feasibility End | Insurance Binding | Loan Commitment | Earnest Money Due
// A stale literal is a hard row-level insert failure, not a coercion. The insert below uses
// allOrNone = false and logs every failure explicitly so such a failure cannot pass unnoticed.
// ⚠ Both formulas are NULL on an in-memory sObject. The summary at the bottom therefore REQUERIES
// rather than reading them off the inserted list.
//
// ── TWO REPORT CONSTRAINTS THAT SHAPE THE DATA ────────────────────────────────────────────
// (a) The report filters `Due_Date__c >= TODAY`, so a row with a past due date is INVISIBLE.
//     Almost every row below is deliberately in the future. The exceptions are the PINNED rows —
//     see (c) — and the script logs each one it creates in the past so an "empty-looking" report
//     is never a mystery.
// (b) Deal_Name__c is a spanning formula, so it renders blank unless Transaction__c is populated
//     AND that Transaction has Property_Name__c. Transaction__c is required here, so every row
//     has a parent by construction; the query below additionally only matches transactions found
//     BY Property_Name__c, so a blank Deal column is impossible for rows this script creates.
// (c) The report sorts Days_Until__c ascending, so the nearest dates lead. The six nearest rows
//     are deliberately the demo-interesting ones and are all UNPINNED types (see below), which
//     means their urgency is guaranteed regardless of what the org's Transaction dates say.
//
// ── PINNING: the dashboard must not contradict the deal record ────────────────────────────
// Two of the five types have a Transaction__c field that is the authoritative source of the same
// date. Where that field is populated the Critical Date MATCHES it; the PLAN table's day offset is
// only a FALLBACK for when it is null:
//   'Closing Date'    ⇐ Transaction__c.Target_Close_Date__c
//   'Feasibility End' ⇐ Transaction__c.Feasibility_Deadline__c
// The brief only required this for Closing Date. Feasibility_Deadline__c exists and is exactly the
// same situation, so the same rule is applied — a Feasibility End that disagrees with the deal's
// own feasibility deadline is the same defect as a contradictory Closing Date.
// CONSEQUENCE, ACCEPTED DELIBERATELY: if a transaction's Target_Close_Date__c or
// Feasibility_Deadline__c is already in the past, the matching row lands in the past and does not
// appear in the report. That is correct — the fix for it is the Transaction's own date field, not
// this script. Every such row is called out by name in the PAST-DATED block of the summary.
//
// ── COHERENCE GATES (evaluated at runtime against each Transaction's real values) ─────────
//   Stage__c = 'Closed' or 'Post-Closing', or Status__c = 'Closed'  → the whole transaction is
//       skipped. A closed / post-closing deal has no UPCOMING critical dates; TXN-0267 Sunridge
//       Marketplace and TXN-0277 Pasadena Industrial are the two known Closed deals and get zero
//       rows. They are intentionally absent from the PLAN table as well, so this gate is a
//       belt-and-braces check against stage drift, not the primary mechanism.
//   Stage__c = 'Closing Prep' and type = 'Feasibility End' → row dropped. By closing prep the
//       feasibility period has demonstrably ended.
//   Loan_Required__c != true and type = 'Loan Commitment' → row dropped. No loan, no loan
//       commitment deadline. (The field defaults to true, so this normally drops nothing.)
//   Feasibility_Missed__c = true and type = 'Feasibility End' → row dropped. A future feasibility
//       end on a deal that already missed feasibility is a contradiction.
// NOT gated, deliberately: 'Earnest Money Due' is NOT suppressed when EM_Wired_Date__c is already
// populated. Additional / hard-money deposits after the initial wire are normal in CRE, so a
// second Earnest Money Due on a deal that has already wired reads correctly. Suppressing it would
// have gutted the near-term countdown, since most seeded deals already have EM_Wired_Date__c set.
//
// ── IDEMPOTENCY ───────────────────────────────────────────────────────────────────────────
// Keyed on (Transaction Id + Type__c) rather than a coarse "any rows exist?" early exit. Chosen
// over the early exit because it is strictly safer AND self-healing: a partially failed run, or a
// later addition to the PLAN table, is repaired by simply re-running. A second identical run
// inserts nothing. The same key also enforces rule "no two rows of the same Type for the same
// Transaction" WITHIN this run, so a typo duplicating a PLAN line cannot produce a duplicate.
//
// ── SHARING NOTE ──────────────────────────────────────────────────────────────────────────
// Critical_Date__c OWD is Private, so rows are owned by whoever runs this. Both DPEG_Transaction_View
// and DPEG_Transaction_Edit grant viewAllRecords=true on Critical_Date__c, so any user holding a
// Transaction permission set sees these rows regardless of owner. If the dashboard renders empty
// for a specific viewer AFTER this runs, check that the dashboard's runningUser holds one of those
// two permission sets before suspecting the data.
//
// ── DEMO NARRATIVE — RETUNE HERE, NOT IN THE CODE BELOW ───────────────────────────────────
// Format:  Property_Name__c | Type__c | fallback day offset from Date.today()
// 29 planned rows across 9 non-closed deals (2-4 each). Offsets chosen so that, after sorting:
//   +3 .. +10   → 6 rows, ALL unpinned types (guaranteed future, guaranteed visible) = the lead
//   +14 .. +41  → 13 rows at 2-6 weeks
//   Closing Date rows (9) pin to Target_Close_Date__c, falling back to +52 .. +120 (~2-4 months)
// ⚠ Governor shape: one query for Transactions, one for existing rows, ONE insert for the whole
// collection, then read-only summary queries. No SOQL and no DML inside any loop.

List<String> plan = new List<String>();

// Magnolia Crossing — 4 rows, leads the countdown at +3
plan.addAll(new List<String>{
    'Magnolia Crossing|Earnest Money Due|3',
    'Magnolia Crossing|Insurance Binding|21',
    'Magnolia Crossing|Loan Commitment|45',
    'Magnolia Crossing|Closing Date|70'
});

// Copperfield Town Center — 3 rows
plan.addAll(new List<String>{
    'Copperfield Town Center|Earnest Money Due|4',
    'Copperfield Town Center|Feasibility End|26',
    'Copperfield Town Center|Closing Date|95'
});

// Cypress Grove MF — 4 rows
plan.addAll(new List<String>{
    'Cypress Grove MF|Insurance Binding|5',
    'Cypress Grove MF|Feasibility End|19',
    'Cypress Grove MF|Loan Commitment|33',
    'Cypress Grove MF|Closing Date|86'
});

// Beltway Plaza — 3 rows
plan.addAll(new List<String>{
    'Beltway Plaza|Earnest Money Due|7',
    'Beltway Plaza|Insurance Binding|29',
    'Beltway Plaza|Closing Date|52'
});

// Memorial City Office — 3 rows
plan.addAll(new List<String>{
    'Memorial City Office|Insurance Binding|9',
    'Memorial City Office|Loan Commitment|38',
    'Memorial City Office|Closing Date|102'
});

// Whispering Pines Commerce Park — 3 rows
plan.addAll(new List<String>{
    'Whispering Pines Commerce Park|Earnest Money Due|10',
    'Whispering Pines Commerce Park|Feasibility End|23',
    'Whispering Pines Commerce Park|Closing Date|75'
});

// Spring Branch Ranch Land — 3 rows
plan.addAll(new List<String>{
    'Spring Branch Ranch Land|Earnest Money Due|14',
    'Spring Branch Ranch Land|Feasibility End|35',
    'Spring Branch Ranch Land|Closing Date|120'
});

// Round Rock Premium Outparcels — 3 rows
plan.addAll(new List<String>{
    'Round Rock Premium Outparcels|Insurance Binding|16',
    'Round Rock Premium Outparcels|Loan Commitment|41',
    'Round Rock Premium Outparcels|Closing Date|110'
});

// Leon Valley Shopping Center — 3 rows
plan.addAll(new List<String>{
    'Leon Valley Shopping Center|Loan Commitment|18',
    'Leon Valley Shopping Center|Insurance Binding|30',
    'Leon Valley Shopping Center|Closing Date|64'
});

// ── The five allowed Type__c values, restated so a stale PLAN literal is caught BEFORE any DML.
Set<String> allowedTypes = new Set<String>{
    'Closing Date', 'Feasibility End', 'Insurance Binding', 'Loan Commitment', 'Earnest Money Due'
};

Date runDate = Date.today();

// ── Resolve Transactions by Property_Name__c. No hardcoded Ids anywhere. ──────────────────
Set<String> plannedDeals = new Set<String>();
for (String line : plan) {
    plannedDeals.add(line.split('\\|')[0]);
}

Map<String, Transaction__c> txnByDeal = new Map<String, Transaction__c>();
List<String> ambiguousDeals = new List<String>();
for (Transaction__c t : [
    SELECT Id, Name, Property_Name__c, Stage__c, Status__c,
           Target_Close_Date__c, Feasibility_Deadline__c, Contract_Executed_Date__c,
           Loan_Required__c, Feasibility_Missed__c, EM_Wired_Date__c
    FROM Transaction__c
    WHERE Property_Name__c IN :plannedDeals
    ORDER BY Name ASC
]) {
    if (txnByDeal.containsKey(t.Property_Name__c)) {
        // Property_Name__c is not unique. First (lowest TXN number) wins; the rest are reported.
        ambiguousDeals.add(t.Name + ' / ' + t.Property_Name__c);
    } else {
        txnByDeal.put(t.Property_Name__c, t);
    }
}

// ── Existing rows, for the (Transaction + Type) idempotency key. ──────────────────────────
Set<Id> txnIds = new Set<Id>();
for (Transaction__c t : txnByDeal.values()) {
    txnIds.add(t.Id);
}

// ══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 REPOINTED 2026-08-31 (Phase 2). THE PINNED AND COHERENCE RULES NOW LIVE IN
//    `CriticalDateService`, LIFTED VERBATIM FROM THIS FILE. THIS SCRIPT NO LONGER OWNS THEM.
// ══════════════════════════════════════════════════════════════════════════════════════════
// This file WAS the specification for the auto-create service, and the reasoning above it is the
// reasoning the service now implements: `Closing Date` pins to `Target_Close_Date__c`,
// `Feasibility End` pins to `Feasibility_Deadline__c`, closed / post-closing deals are skipped, and
// the key is `(Transaction + Type)`. Keeping two copies of that logic is how they silently diverge —
// so the service is called FIRST and this script's own PLAN table is now demo garnish on top of it.
//
// HOW THE TWO COMPOSE, WITHOUT ANY NEW COORDINATION:
//   • The service creates every PINNED row (Closing Date, Feasibility End) that the deal record
//     itself justifies, applying the coherence gates.
//   • Those rows are then picked up by the `existingKeys` query immediately below, so the PLAN
//     table's own `Closing Date` / `Feasibility End` lines are reported as skipped-duplicate by the
//     idempotency guard that was already here. No line of the loop below had to change.
//   • The PLAN table still creates the types the deal record has NO source field for —
//     `Insurance Binding`, `Earnest Money Due`, and `Loan Commitment` until `Loan__c` is wired in
//     Phase 5. Those are DEMO DATA with a fabricated offset, which is exactly why they do not belong
//     in the service: the service PROJECTS the deal record and never invents a deadline.
// ⚠ The service runs in the RUNNER'S sharing context here (anonymous Apex cannot use SYSTEM_MODE),
//   so run this as an administrator or the pinned rows are created only for deals you can see.
Integer projected = CriticalDateService.ensureFor(txnIds);
System.debug(LoggingLevel.ERROR, 'CRITDATE pinned rows created by CriticalDateService :: ' + projected);

Set<String> existingKeys = new Set<String>();
if (!txnIds.isEmpty()) {
    for (Critical_Date__c cd : [
        SELECT Transaction__c, Type__c FROM Critical_Date__c WHERE Transaction__c IN :txnIds
    ]) {
        existingKeys.add(String.valueOf(cd.Transaction__c) + '|' + cd.Type__c);
    }
}

// ── Build the collection. Pure in-memory: no SOQL, no DML in this loop. ───────────────────
List<Critical_Date__c> toInsert = new List<Critical_Date__c>();
List<String> insertLabels = new List<String>();   // parallel to toInsert, for per-row error reporting
Map<String, Integer> plannedByType = new Map<String, Integer>();

List<String> missingDeals = new List<String>();
List<String> skippedClosed = new List<String>();
List<String> skippedDuplicate = new List<String>();
List<String> skippedIncoherent = new List<String>();
List<String> badTypeLiterals = new List<String>();
List<String> pastDated = new List<String>();
List<String> pinnedRows = new List<String>();
Set<String> claimedKeys = new Set<String>(existingKeys);
Set<String> reportedMissing = new Set<String>();
Set<String> reportedClosed = new Set<String>();

for (String line : plan) {
    List<String> parts = line.split('\\|');
    String dealName = parts[0];
    String cdType = parts[1];
    Integer fallbackOffset = Integer.valueOf(parts[2]);

    if (!allowedTypes.contains(cdType)) {
        // Restricted picklist — refuse before DML rather than eat a row-level insert failure.
        badTypeLiterals.add(dealName + ' -> "' + cdType + '"');
        continue;
    }

    Transaction__c t = txnByDeal.get(dealName);
    if (t == null) {
        if (reportedMissing.add(dealName)) {
            missingDeals.add(dealName);
        }
        continue;
    }

    // Gate 1 — closed / post-closing deals have no upcoming critical dates.
    if (t.Stage__c == 'Closed' || t.Stage__c == 'Post-Closing' || t.Status__c == 'Closed') {
        if (reportedClosed.add(dealName)) {
            skippedClosed.add(t.Name + ' ' + dealName
                + ' (Stage=' + t.Stage__c + ', Status=' + t.Status__c + ')');
        }
        continue;
    }

    // Gate 2 — type must be coherent with the deal's own state.
    if (cdType == 'Feasibility End' && t.Stage__c == 'Closing Prep') {
        skippedIncoherent.add(t.Name + ' ' + dealName + ' | Feasibility End (Stage=Closing Prep)');
        continue;
    }
    if (cdType == 'Feasibility End' && t.Feasibility_Missed__c == true) {
        skippedIncoherent.add(t.Name + ' ' + dealName + ' | Feasibility End (Feasibility_Missed__c=true)');
        continue;
    }
    if (cdType == 'Loan Commitment' && t.Loan_Required__c != true) {
        skippedIncoherent.add(t.Name + ' ' + dealName + ' | Loan Commitment (Loan_Required__c=false)');
        continue;
    }

    // Gate 3 — idempotency + "no two rows of the same Type for the same Transaction".
    String key = String.valueOf(t.Id) + '|' + cdType;
    if (claimedKeys.contains(key)) {
        skippedDuplicate.add(t.Name + ' ' + dealName + ' | ' + cdType);
        continue;
    }
    claimedKeys.add(key);

    // Due date — PIN to the Transaction's own field where one is authoritative.
    Date due;
    if (cdType == 'Closing Date' && t.Target_Close_Date__c != null) {
        due = t.Target_Close_Date__c;
        pinnedRows.add(t.Name + ' ' + dealName + ' | Closing Date -> Target_Close_Date__c ' + due);
    } else if (cdType == 'Feasibility End' && t.Feasibility_Deadline__c != null) {
        due = t.Feasibility_Deadline__c;
        pinnedRows.add(t.Name + ' ' + dealName + ' | Feasibility End -> Feasibility_Deadline__c ' + due);
    } else {
        due = runDate.addDays(fallbackOffset);
    }

    if (due < runDate) {
        pastDated.add(t.Name + ' ' + dealName + ' | ' + cdType + ' | ' + due
            + ' (' + due.daysBetween(runDate) + 'd ago — WILL NOT APPEAR in the report)');
    }

    toInsert.add(new Critical_Date__c(
        Transaction__c = t.Id,
        Type__c        = cdType,
        Due_Date__c    = due
    ));
    insertLabels.add(t.Name + ' ' + dealName + ' | ' + cdType + ' | ' + due);

    Integer n = plannedByType.get(cdType);
    plannedByType.put(cdType, (n == null ? 0 : n) + 1);
}

// ── ONE DML for the whole collection. allOrNone=false so a single bad row cannot discard the
//    other 28 — every failure is logged below, so a partial result is never silent.
Integer created = 0;
List<String> failures = new List<String>();
if (!toInsert.isEmpty()) {
    Database.SaveResult[] results = Database.insert(toInsert, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            created++;
        } else {
            String msg = '';
            for (Database.Error e : results[i].getErrors()) {
                msg += e.getStatusCode() + ': ' + e.getMessage() + ' ' + e.getFields() + ' ';
            }
            failures.add(insertLabels[i] + '  ==> ' + msg);
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════════════
// SUMMARY — a silent no-op must be impossible to mistake for success.
// Formula fields are null on the in-memory rows, so everything below REQUERIES.
// ══════════════════════════════════════════════════════════════════════════════════════════
System.debug(LoggingLevel.ERROR, '════ CRITDATE SEED ════════════════════════════════════════');
System.debug(LoggingLevel.ERROR, 'CRITDATE run date (Date.today())      :: ' + runDate);
System.debug(LoggingLevel.ERROR, 'CRITDATE planned rows in PLAN table   :: ' + plan.size());
System.debug(LoggingLevel.ERROR, 'CRITDATE transactions resolved by name:: ' + txnByDeal.size()
    + ' of ' + plannedDeals.size() + ' planned deal names');
System.debug(LoggingLevel.ERROR, 'CRITDATE rows attempted               :: ' + toInsert.size());
System.debug(LoggingLevel.ERROR, 'CRITDATE ROWS CREATED                 :: ' + created);

if (!failures.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE 🔴 INSERT FAILURES (' + failures.size() + '):');
    for (String f : failures) {
        System.debug(LoggingLevel.ERROR, 'CRITDATE   FAIL ' + f);
    }
}
if (!badTypeLiterals.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE 🔴 PLAN TABLE HAS TYPE LITERALS NOT IN THE RESTRICTED '
        + 'PICKLIST (' + badTypeLiterals.size() + ') — these were refused BEFORE the insert: '
        + badTypeLiterals);
}
if (!missingDeals.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE ⚠ no Transaction found for Property_Name__c ('
        + missingDeals.size() + '): ' + missingDeals);
}
if (!ambiguousDeals.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE ⚠ duplicate Property_Name__c — lowest TXN number used, '
        + 'these ignored: ' + ambiguousDeals);
}
if (!skippedClosed.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE skipped (closed / post-closing deal, no upcoming '
        + 'critical dates): ' + skippedClosed);
}
if (!skippedIncoherent.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE skipped (type incoherent with deal state, '
        + skippedIncoherent.size() + '): ' + skippedIncoherent);
}
if (!skippedDuplicate.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE skipped (Transaction+Type already present — this is '
        + 'the idempotency guard doing its job on a re-run, ' + skippedDuplicate.size() + '): '
        + skippedDuplicate);
}
if (!pinnedRows.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE pinned to the Transaction\'s own date field ('
        + pinnedRows.size() + '):');
    for (String p : pinnedRows) {
        System.debug(LoggingLevel.ERROR, 'CRITDATE   PIN  ' + p);
    }
}
if (!pastDated.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE ⚠ PAST-DATED ROWS (' + pastDated.size()
        + ') — created faithfully because the Transaction\'s own field says so, but the report '
        + 'filters Due_Date__c >= TODAY so they are INVISIBLE. Fix the Transaction date, not this script:');
    for (String p : pastDated) {
        System.debug(LoggingLevel.ERROR, 'CRITDATE   PAST ' + p);
    }
}

// Per-Type counts, read back from the org (not from memory) across the seeded transactions.
Map<String, Integer> orgByType = new Map<String, Integer>();
Integer orgTotal = 0;
Integer orgUpcoming = 0;
if (!txnIds.isEmpty()) {
    for (Critical_Date__c cd : [
        SELECT Type__c, Due_Date__c FROM Critical_Date__c WHERE Transaction__c IN :txnIds
    ]) {
        orgTotal++;
        if (cd.Due_Date__c >= runDate) {
            orgUpcoming++;
        }
        Integer n = orgByType.get(cd.Type__c);
        orgByType.put(cd.Type__c, (n == null ? 0 : n) + 1);
    }
}
System.debug(LoggingLevel.ERROR, 'CRITDATE ── count per Type (all rows now on the seeded deals) ──');
for (String ty : allowedTypes) {
    Integer orgN = orgByType.get(ty);
    Integer newN = plannedByType.get(ty);
    System.debug(LoggingLevel.ERROR, 'CRITDATE   ' + ty.rightPad(20) + ' in org: '
        + (orgN == null ? 0 : orgN) + '   (created this run: ' + (newN == null ? 0 : newN) + ')');
}
System.debug(LoggingLevel.ERROR, 'CRITDATE total Critical_Date__c on seeded deals :: ' + orgTotal
    + '  |  of which upcoming (Due_Date__c >= TODAY, i.e. VISIBLE in the report) :: ' + orgUpcoming);
System.debug(LoggingLevel.ERROR, 'CRITDATE total Critical_Date__c org-wide        :: '
    + [SELECT COUNT() FROM Critical_Date__c]);

// The 5 nearest upcoming rows — exactly what the report's top 5 lines will read.
// ORDER BY Due_Date__c ASC is equivalent to the report's Days_Until__c ASC (Days_Until__c is
// literally Due_Date__c - TODAY()), and avoids sorting on a formula.
System.debug(LoggingLevel.ERROR, 'CRITDATE ── 5 NEAREST UPCOMING (what the countdown will show) ──');
List<Critical_Date__c> nearest = [
    SELECT Name, Deal_Name__c, Type__c, Due_Date__c, Days_Until__c
    FROM Critical_Date__c
    WHERE Due_Date__c >= TODAY
    ORDER BY Due_Date__c ASC
    LIMIT 5
];
if (nearest.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'CRITDATE 🔴 NONE. The report WILL STILL RENDER EMPTY. '
        + 'Either nothing was created, or every row landed in the past — read the blocks above.');
} else {
    for (Critical_Date__c cd : nearest) {
        System.debug(LoggingLevel.ERROR, 'CRITDATE   '
            + String.valueOf(cd.Deal_Name__c).rightPad(32)
            + ' | ' + String.valueOf(cd.Type__c).rightPad(18)
            + ' | due ' + cd.Due_Date__c
            + ' | Days Until ' + cd.Days_Until__c
            + ' | ' + cd.Name);
    }
}
System.debug(LoggingLevel.ERROR, '════ CRITDATE SEED END ════════════════════════════════════');
