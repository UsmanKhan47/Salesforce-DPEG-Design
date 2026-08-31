// ═══════════════════════════════════════════════════════════════════════════════════════════
// BACKFILL — Opportunity.Stage_Entry_Date__c on OPEN deals that have none.
// Design: agent-output/design-requirements.md §2 ITEM 2 (Q4 = backfill), RESIDUAL-6.
//
// Run ONCE, immediately after OpportunityStageEntryService goes live. From that moment the
// before-trigger stamps every genuine stage transition, so the only deals that can still have a
// null date are ones that have not been saved since the deploy. Re-running is harmless (the WHERE
// clause excludes anything already stamped), but it is not intended to be a recurring job.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 WHAT THIS WRITES IS AN APPROXIMATION, NOT HISTORY. DO NOT PRESENT IT AS HISTORY.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// It writes `LastModifiedDate.date()`. `LastModifiedDate` is the last edit of ANY KIND — an
// amount correction, an owner reassignment, a description tweak, an approval field update, a seed
// script, this backfill's own sibling scripts. It is NOT the date the deal entered its current
// stage, and there is no field anywhere in this org that records that for a pre-existing row.
// Field history is not a usable substitute either: `Opportunity.StageName` history exists only
// where tracking was enabled and only within the retention window, and it cannot be read for the
// deals that most need a value.
//
// The consequence, stated plainly so nobody has to rediscover it: on day 1 the
// `Days_In_Stage__c` figure for a backfilled deal UNDERSTATES how long that deal has really been
// stuck, sometimes by months, because any unrelated edit resets the proxy. That is design
// RESIDUAL-6, it is accepted, and it self-corrects the first time each deal genuinely changes
// stage. Until then:
//   - do not quote a backfilled Days In Stage to a stakeholder as elapsed time in stage;
//   - expect the Item 4 stalled-deal reminder to UNDER-report during its first weeks, never to
//     over-report — a false silence, not a false alarm, which is the safer direction.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 PRECONDITIONS. THIS SCRIPT CANNOT SATISFY THEM ITSELF — CHECK BOTH BEFORE RUNNING.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 1. GATE PS-1 MUST HAVE SHIPPED, AND THE RUNNER MUST HOLD ONE OF THE GRANTING SETS.
//    The design brief for this script said "SYSTEM_MODE". THAT IS NOT AVAILABLE HERE and the
//    refusal is recorded verbatim rather than quietly downgraded:
//
//        Cannot use SYSTEM_MODE access level in anonymous execution of Apex
//
//    — which applies to `WITH SYSTEM_MODE` in static SOQL AND to `AccessLevel.SYSTEM_MODE` in
//    `Database.query` / `Database.update`. There is no `without sharing` in anonymous Apex
//    either. So this file runs in the runner's own context and both enforcement layers the brief
//    assumed away are back:
//
//      FLS   — a Metadata-API-deployed field arrives with ZERO FieldPermissions rows for anyone,
//              System Administrator included. Until `Stage_Entry_Date__c` is granted through
//              `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` / `DPEG_Opportunity_View`
//              (GATE PS-1), the field is not merely denied — it is ABSENT from the running
//              user's schema, and this script WILL NOT COMPILE. `sf apex run` fails on the field
//              name before executing a single statement. That is the expected symptom of running
//              this too early; it is not a typo in the script.
//      SHARING — NOT a constraint here, and this line previously said the opposite. It read
//              "`Opportunity` OWD is Private in this org", inherited verbatim from the task
//              brief. THAT IS WRONG, and it is retracted rather than quietly deleted because
//              the same false premise reached three other files this session before it was
//              caught. MEASURED against `usman-dpeg` on 2026-08-31 via the Tooling API —
//              `SELECT InternalSharingModel FROM EntityDefinition WHERE DeveloperName =
//              'Opportunity'` — returns **`ReadWrite`** (external `Private`). The same
//              measurement is recorded at `OpportunitySelector.aggregateDealCountsByBroker`,
//              `OpportunitySelector.queryCallForOffersAlerts` and in
//              `BrokerCounterRecalcBatch`'s OWD table. Every INTERNAL principal therefore
//              already holds read AND write on every deal, so this update cannot silently
//              stamp a subset for a sharing reason and no `Modify All Data` is needed for one.
//              ⚠ Do not read this as "sharing never matters to a backfill" — it is a fact
//              about THIS object. `NDA__c` and `Lead` are genuinely `Private`, and a script
//              touching either would need this question asked again, not this answer reused.
//
//    ⇒ RUN AS: any internal user holding a permission set that grants EDIT on
//      Opportunity.Stage_Entry_Date__c. In practice that is a System Administrator with GATE
//      PS-1 assigned. The FLS grant is the ONLY hard precondition — it is what makes the script
//      compile at all — and, `Opportunity` being `ReadWrite`, it is also sufficient.
//
// 2. `OpportunityStageEntryService` MUST ALREADY BE DEPLOYED. If it is not, an unrelated edit to
//    one of these deals before it ships will not stamp, and the population this script has
//    already "fixed" starts drifting again with no signal.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS UPDATE DOES NOT FIGHT THE NEW TRIGGER
// ═══════════════════════════════════════════════════════════════════════════════════════════
// Each shell record carries only `Id` and `Stage_Entry_Date__c`. `StageName` is untouched, so
// `OpportunityStageEntryService.stampStageEntryDates` sees prior stage == new stage, treats the
// save as a non-entry, and leaves the value this script wrote exactly as written. The same
// property means none of the ISCHANGED-gated stage validation rules
// (`No_Backward_Stage_Movement`, `NDA_Signed_Before_Deal_Progression`,
// `Underwriting_Approved_Before_LOI`, `Rejection_Reason_Required_On_Dead`) can fire, and
// `DealFolderService` performs no claim and enqueues nothing.
//
// `allOrNone = false` per the brief: one deal blocked by an unrelated validation rule or by
// sharing must not cost the other 400 their stamp. Every error on every failed row is printed —
// a validation failure and an access refusal arrive together, and reporting only the first sends
// the reader at the wrong precondition.
// ═══════════════════════════════════════════════════════════════════════════════════════════

// Open deals only. `IsClosed` is the standard field and is true for both Closed Won and
// Dead/Pass, so this matches Days_In_Stage__c's own IF(IsClosed, 0, ...) branch: a closed deal
// reads 0 regardless and gains nothing from a stamp. LIMIT is a deliberate governor guard - if
// the run reports exactly 10000 candidates, the population is larger than one anonymous
// transaction can carry and this needs to become a Batch class instead.
List<Opportunity> candidates = [
    SELECT Id, StageName, LastModifiedDate
    FROM Opportunity
    WHERE IsClosed = false
      AND Stage_Entry_Date__c = null
    ORDER BY LastModifiedDate
    LIMIT 10000
];

List<Opportunity> stamps = new List<Opportunity>();
for (Opportunity o : candidates) {
    stamps.add(new Opportunity(
        Id = o.Id,
        // .date() converts the DateTime to a Date in the RUNNING USER'S timezone. A deal last
        // touched late in the evening can therefore land a day either side of what another user
        // sees. At a whole-day granularity feeding a multi-day stalled threshold that is noise,
        // not error - but it is one more reason the day-1 numbers are an approximation.
        Stage_Entry_Date__c = o.LastModifiedDate.date()
    ));
}

System.debug(LoggingLevel.INFO,
    'backfill-opp-stage-entry-date: ' + candidates.size()
    + ' open deals have no Stage_Entry_Date__c and will be stamped from LastModifiedDate.');

if (candidates.size() == 10000) {
    System.debug(LoggingLevel.ERROR,
        'backfill-opp-stage-entry-date: the query hit its 10000 LIMIT. This population does NOT '
        + 'fit one anonymous transaction - STOP and convert this to a Batch class rather than '
        + 're-running the script repeatedly.');
}

Integer stamped = 0;
Integer failed = 0;
if (!stamps.isEmpty()) {
    // allOrNone = false. NOT SYSTEM_MODE - see precondition 1; it is unavailable in anonymous Apex.
    List<Database.SaveResult> results = Database.update(stamps, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            stamped++;
            continue;
        }
        failed++;
        // EVERY error on the row, not getErrors()[0].
        for (Database.Error err : results[i].getErrors()) {
            System.debug(LoggingLevel.ERROR,
                'backfill-opp-stage-entry-date: FAILED ' + stamps[i].Id + ' - '
                + err.getStatusCode() + ': ' + err.getMessage()
                + ' [fields: ' + err.getFields() + ']');
        }
    }
}

System.debug(LoggingLevel.INFO,
    'backfill-opp-stage-entry-date: COMPLETE. candidates=' + candidates.size()
    + ' stamped=' + stamped + ' failed=' + failed
    + '. Every stamped value is a LastModifiedDate PROXY, not real stage-entry history (RESIDUAL-6).');

if (failed > 0) {
    System.debug(LoggingLevel.ERROR,
        'backfill-opp-stage-entry-date: ' + failed + ' rows did not stamp. Read the '
        + 'getStatusCode() values printed above - they name the cause per row. Sharing is NOT a '
        + 'candidate: Opportunity internal OWD is ReadWrite (measured 2026-08-31), so no row was '
        + 'skipped for being owned by someone else. The likely causes are the FLS precondition in '
        + 'this file\'s header (INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY / '
        + 'INSUFFICIENT_ACCESS_OR_READONLY on the field), a validation rule on the individual '
        + 'deal, or a record locked by a pending approval (UNABLE_TO_LOCK_ROW / '
        + 'ENTITY_IS_LOCKED) - that last one is retryable and is not a defect.');
}
