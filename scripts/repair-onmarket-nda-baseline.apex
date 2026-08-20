/**
 * ONE-TIME DATA REPAIR — baseline buyer NDAs for ON-MARKET dispositions that predate the
 * 2026-08-19 flow redesign. Authored with the redesign code review; NOT YET EXECUTED.
 *
 * Run:  sf apex run --file scripts/repair-onmarket-nda-baseline.apex --target-org usman-dpeg
 * Then read the per-row log and the final "REPAIR VERDICT" line.
 *
 * ⚠ DEPENDENCY — `DispositionDomain` MUST BE DEPLOYED FIRST. STEP 5 below calls
 * `DispositionDomain.recordTypeNameOf(d)` and reads `DispositionDomain.RT_OFF_MARKET` to decide
 * which candidates are out of scope. Anonymous Apex compiles against the ORG's classes, not this repo,
 * so if that class has not deployed the whole script fails to compile with
 * `Variable does not exist: DispositionDomain` and nothing runs. Deploy
 * `force-app/main/default/classes/DispositionDomain.cls` (and the rest of the redesign) before
 * running this. Deliberately NOT re-implemented locally: a second copy of that helper with its own
 * Master/unset default is the exact C-2 defect the class was created to end.
 *
 * =====================================================================================
 * 🔴 SCOPE — FIVE NAMED ROWS, AND THE ALLOW-LIST IS THE SAFETY MECHANISM
 * =====================================================================================
 * The query below is bound to `Name IN ('DISP-0003','DISP-0007','DISP-0008','DISP-0009',
 * 'DISP-0010')` — the exact five rows measured on usman-dpeg on 2026-08-19 (three at
 * `Active Listing`, two at `Closing`). It is NOT a general "repair everything that looks like
 * this" sweep, and it must not be turned into one.
 *
 * WHY AN EXPLICIT LIST RATHER THAN A STAGE FILTER. The script's whole justification is that these
 * rows "were created while NDAs were an off-market-only concept" — a statement about WHEN a row was
 * created, which no stage/count predicate can express. This script runs AFTER the redesign deploys,
 * and in that window `Advance_to_NDA`, `Advance_to_Release_Materials` and the D-1 approval
 * auto-advance are all live and can move BRAND-NEW rows into any gated stage. A row that reaches
 * `Release Materials` tomorrow with `NDA_Count__c = 0` is not a pre-redesign casualty — it is a
 * live deal whose NDAs genuinely have not been collected, and stamping it with a Signed NDA
 * labelled "signed before Salesforce tracking" would be FABRICATING A SIGNATURE THAT DOES NOT
 * EXIST and opening the release gate on it. The stage filter is retained as a second, narrowing
 * condition only; the name list is what makes the blast radius knowable.
 *
 * ⚠ IF THIS IS RUN LATER THAN 2026-08-19, RE-MEASURE FIRST. The five names are a snapshot. Run it
 * with PREVIEW_ONLY = true (the default, see below), read the PLAN lines, and confirm each named
 * row is still the row you mean before flipping the flag.
 *
 * =====================================================================================
 * 🔴 `NDA` IS NOT A GATED STAGE AND MUST NEVER BE ADDED TO `GATED_STAGES`
 * =====================================================================================
 * `All_NDAs_Signed_Before_Progression`'s OR list is Release Materials, Active Listing, Offer
 * Selection, LOI, PSA, Closing, Sale Closes. `NDA` IS ABSENT BY DESIGN — the rule gates entry to
 * every stage FROM NDA ONWARD, i.e. the stages after it, not NDA itself. A disposition sitting AT
 * `NDA` with `NDA_Count__c = 0` is therefore not blocked and is not broken: it is the CORRECT,
 * EXPECTED state of a deal that has reached the NDA stage and is still out collecting real
 * signatures. Backfilling it would stamp a Signed NDA on a deal nobody has signed and open the
 * release gate for it. If a future stage is added AFTER NDA it goes in both the validation rule's
 * OR list and `GATED_STAGES`; `NDA` itself does not.
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * `PREVIEW_ONLY` defaults to **true**. In that mode the script resolves the record type, queries
 * the candidates, applies every skip rule and prints a full PLAN line per row — then STOPS before
 * `Database.insert` and returns. No DML of any kind. Flip it to false only after reading the
 * PREVIEW output and agreeing with every PLAN line. This exists because the PLAN lines are
 * `System.debug` in the SAME transaction as the insert: without the flag there is no way to see
 * the plan except by having already executed it.
 *
 * =====================================================================================
 * 🔴 WHY THIS EXISTS — A VALIDATION RULE CHANGED SCOPE UNDER LIVE DATA
 * =====================================================================================
 * `Disposition__c.All_NDAs_Signed_Before_Progression` used to carry a record-type term that
 * scoped it to Off_Market. The 2026-08-19 client redefinition made NDA a stage on BOTH paths, so
 * that term was REMOVED — correctly, because an on-market deal now collects NDAs from interested
 * parties before materials are released, and leaving the term in would have disabled the gate on
 * the path with the larger buyer population.
 *
 * The rule's own XML comment names the consequence: "The three live On_Market rows at Active
 * Listing and the two at Closing are in scope the moment anyone advances them." Those five rows
 * were created while NDAs were an off-market-only concept, so they carry `NDA_Count__c = 0` — and
 * the rule's FIRST clause, `BLANKVALUE(NDA_Count__c, 0) = 0`, is a BLOCKING condition on purpose
 * ("collecting nothing is not the same as collecting everything"). Every forward stage from NDA
 * onward is therefore closed to them until an NDA exists and reads Signed.
 *
 * 🔴 THE TWO AT `Closing` FAIL SILENTLY, WHICH IS THE REAL REASON THIS SCRIPT IS URGENT. Their
 * next hop is not a button — it is the D-1 approval auto-advance. `Closing_Approval` is approved,
 * `finalApprovalActions` sets `Approval_Advance_Pending__c = true`, the trigger enqueues
 * `DispositionApprovalAdvanceQueueable`, and its `Database.update(..., false,
 * AccessLevel.SYSTEM_MODE)` is REFUSED by this validation rule (SYSTEM_MODE lifts CRUD and FLS,
 * never a validation rule) with `allOrNone = false` and results deliberately uninspected. Net
 * effect: the approval reads Approved, the stage never moves, `Approval_Advance_Pending__c` stays
 * stuck true, and NOTHING on the page says why — that field has no FLS for anyone and is not on a
 * layout. The three at `Active Listing` at least fail loudly, because a human is pressing Advance
 * and gets the rule's error message.
 *
 * =====================================================================================
 * 🔴 A DECLINED NDA DOES **NOT** SATISFY THIS GATE — DO NOT "FIX" A ROW THAT WAY
 * =====================================================================================
 * `NDA_Signed_Rollup`'s `Is_Row_Signed` decision counts a Declined row toward NEITHER counter
 * (decision D20/C2). So a disposition whose only NDA is Declined records `NDA_Count__c = 0` and
 * the first clause of the rule STILL BLOCKS IT — that clause is not an oversight, it is what
 * catches exactly this case. Only a row whose `Status__c = 'Signed'` moves both counters, which is
 * why this script creates the NDA already Signed rather than creating it `Not Sent` and leaving a
 * human to work it. Creating a Declined placeholder would look like a repair and change nothing.
 *
 * =====================================================================================
 * WHAT IT CREATES, AND WHY EACH FIELD
 * =====================================================================================
 *   RecordTypeId         `Disposition_NDA` — the sell-side type. Mandatory: the acquisition type
 *                        does not expose `Party_Role__c` and restricts `Signed` differently.
 *   Disposition__c       the parent. This is ALSO the rollup flow's entry condition
 *                        (`Disposition__c IS NOT NULL`), so an NDA without it changes no counter.
 *   Party_Role__c        'Buyer'. DPEG collects one NDA from the prospective buyer and one from
 *                        the introducing broker; the buyer's is the one the gate is about, and it
 *                        is also this record type's own default.
 *   Status__c            'Signed'. See the Declined note above — this is the ONLY value that
 *                        moves `Signed_NDA_Count__c`.
 *   Date_Signed__c       BACKDATED, not TODAY(). `Listing_Date__c` where the disposition has one
 *                        (materials were released on that date, so the buyer NDA necessarily
 *                        preceded it); the disposition's own creation date otherwise. A future- or
 *                        today-dated signature on a deal that has been at Closing for weeks is a
 *                        lie that outlives this script.
 *                        ⚠ The date MUST be supplied here. `NDA_Signed_Status_Sync` is a
 *                        before-save flow that stamps `Date_Signed__c = TODAY()` when Status
 *                        reaches 'Signed' with a BLANK date, and never overwrites a supplied one —
 *                        so omitting it silently produces today's date.
 *   Counterparty_Name__c a self-identifying label, so these five rows are findable later by
 *                        anyone asking "why does this deal have an NDA nobody remembers".
 *   Notes__c             the same explanation on the record itself.
 *
 * NOT SET, DELIBERATELY:
 *   NDA_Signed__c        DERIVED. `NDA_Signed_Status_Sync` latches it true from Status in the same
 *                        save. Writing it here would be a second source of truth for one fact.
 *   NDA_Expiry_Date__c / Is_Non_Expiring__c
 *                        Left blank. `NdaSelector`'s expiry-alert query requires
 *                        `NDA_Expiry_Date__c != NULL` AND `Opportunity__c != NULL`; these rows
 *                        satisfy neither, so they cannot generate expiry alerts. Inventing an
 *                        expiry date would.
 *   Method__c            Unknown and unknowable for a document signed outside Salesforce. Blank is
 *                        honest; 'Wet Sign' would be a guess recorded as a fact.
 *
 * =====================================================================================
 * IDEMPOTENCY
 * =====================================================================================
 * Safe to re-run. The skip test is THE EXISTENCE OF AN NDA CHILD, not `NDA_Count__c` — the counter
 * is maintained by a flow whose fault connector deliberately SWALLOWS `ENTITY_IS_LOCKED` and
 * leaves the count stale, so trusting the counter alone could create a second NDA on a disposition
 * that already has one. A re-run after a successful run creates zero rows and still prints the
 * verification block.
 *
 * ⚠ APPROVAL LOCKS ARE DETECTED AND REPORTED, NOT WORKED AROUND. If a target disposition has a
 * PENDING approval its record is locked (`recordEditability = AdminOnly` on all three
 * Disposition-target approvals), the NDA row itself still inserts fine, but `NDA_Signed_Rollup`'s
 * parent update hits `ENTITY_IS_LOCKED` and its fault sink swallows it — so the counters stay 0
 * and the row is NOT actually repaired. Those rows are flagged LOCKED in the log; recall or resolve
 * the approval and re-run, or save any NDA on that disposition afterwards to re-fire the rollup.
 * (Measured on usman-dpeg 2026-08-19: none of the five had a pending approval.)
 *
 * ROLLBACK: delete the created `NDA__c` rows. ⚠ Deleting them does NOT restore the counters —
 * `NDA_Signed_Rollup` is `recordTriggerType = CreateAndUpdate` and never fires on delete (a live
 * gap documented in that flow). After a rollback the counts read 1/1 against zero children until
 * the next NDA save on that disposition. That staleness fails OPEN (the gate would pass), so a
 * rollback must be followed by resetting both counters by hand.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * ARCHITECTURE.md §2 mandates `WITH USER_MODE` for SELECTOR CLASSES in force-app. This is
 * anonymous apex run by an administrator against live data, is not part of the deployed codebase,
 * and is not a selector; the surrounding scripts/ files follow the same convention. Adding
 * USER_MODE here would only add a way for the repair to throw on a field the running admin happens
 * to lack FLS on — which, for Metadata-API-deployed fields, is the default state.
 */

// ── PREVIEW_ONLY: true = resolve, query, apply every skip rule, print the full plan, then RETURN
//    before any DML. Flip to false only after reading the PREVIEW output. See the header.
final Boolean PREVIEW_ONLY = true;

// ── The stages the release gate blocks. This is a VERBATIM copy of
//    `All_NDAs_Signed_Before_Progression`'s OR list — nothing more.
//    🔴 `NDA` IS DELIBERATELY ABSENT. The rule gates the stages FROM NDA ONWARD, not NDA itself; a
//    row sitting at NDA with a zero count is a deal still collecting real signatures, not a
//    pre-redesign casualty. Adding it here would fabricate a signature. See the header.
//    Any stage added AFTER NDA must be added here AND to the validation rule; neither list is
//    maintained automatically.
final Set<String> GATED_STAGES = new Set<String>{
    'Release Materials',
    'Active Listing',
    'Offer Selection',
    'LOI',
    'PSA',
    'Closing',
    'Sale Closes'
};

final String BASELINE_NAME = 'Baseline - buyer NDA signed before Salesforce tracking';
final String BASELINE_NOTES =
    'Created by scripts/repair-onmarket-nda-baseline.apex. This disposition was opened while the '
    + 'NDA stage existed on the Off Market path only, so it carried no NDA record. The '
    + 'All_NDAs_Signed_Before_Progression validation rule was rescoped to BOTH record types on '
    + '2026-08-19 and treats a zero NDA count as a block, which would have stranded this deal. '
    + 'This row records the buyer NDA that was executed outside Salesforce. Date Signed is '
    + 'backdated to the listing date where one exists, otherwise to the disposition creation date.';

// ── STEP 1. Resolve the sell-side record type. Abort rather than create Master-type NDAs: the
//    acquisition/Master value sets do not expose Party_Role__c and a wrong type is harder to
//    unpick than a refused run.
Schema.RecordTypeInfo ndaTypeInfo = Schema.SObjectType.NDA__c
    .getRecordTypeInfosByDeveloperName()
    .get('Disposition_NDA');
if (ndaTypeInfo == null || !ndaTypeInfo.isAvailable()) {
    System.debug(LoggingLevel.ERROR,
        'ABORT: the Disposition_NDA record type is missing or not available to '
        + UserInfo.getName() + '. Record-type assignment is a per-profile setup action and is not '
        + 'deployable; grant it, then re-run. Nothing was created.');
    System.debug(LoggingLevel.ERROR, 'REPAIR VERDICT: ABORTED (no Disposition_NDA record type)');
    return;
}
final Id NDA_RECORD_TYPE_ID = ndaTypeInfo.getRecordTypeId();

// ── STEP 2. Candidates: THE FIVE NAMED PRE-REDESIGN ROWS, further narrowed to those still at a
//    gated stage with a zero/blank NDA count.
//    🔴 THE NAME ALLOW-LIST IS NOT A CONVENIENCE — IT IS THE ONLY THING THAT EXPRESSES
//    "PRE-REDESIGN". Stage and count are both reachable by rows created AFTER this deploy (the
//    Advance_to_* quick actions and the D-1 auto-advance are live), and for such a row a zero count
//    means "nobody has signed yet", not "the signature predates Salesforce". Backfilling one would
//    fabricate a signature and open the release gate. Do not widen this list without re-measuring.
final Set<String> TARGET_NAMES = new Set<String>{
    'DISP-0003', 'DISP-0007', 'DISP-0008', 'DISP-0009', 'DISP-0010'
};

//    ⚠ NULL IS NOT 0 IN SOQL. `defaultValue 0` applies only at INSERT, so rows created before the
//    counters existed hold NULL — the same reason the validation rule wraps both terms in
//    BLANKVALUE. Querying `NDA_Count__c = 0` alone would silently miss exactly the oldest rows.
List<Disposition__c> candidates = [
    SELECT Id, Name, Disposition_Stage__c, RecordTypeId, Listing_Date__c, CreatedDate,
           NDA_Count__c, Signed_NDA_Count__c
    FROM Disposition__c
    WHERE Name IN :TARGET_NAMES
      AND Disposition_Stage__c IN :GATED_STAGES
      AND (NDA_Count__c = NULL OR NDA_Count__c = 0)
    ORDER BY Name
];
if (candidates.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to repair: none of the five named rows '
        + TARGET_NAMES + ' is currently at a gated stage with a zero/blank NDA count. If this is '
        + 'unexpected, confirm the names still exist and have not already been repaired - do NOT '
        + 'widen the name list to make the script find something.');
    System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: NOTHING TO DO');
    return;
}

Map<Id, Disposition__c> byId = new Map<Id, Disposition__c>(candidates);

// ── STEP 3. The real idempotency key — does a child NDA already exist? Never trust the counter
//    (see the header: the rollup's fault sink leaves it stale by design).
Set<Id> alreadyHasNda = new Set<Id>();
for (NDA__c existing : [
    SELECT Id, Disposition__c FROM NDA__c WHERE Disposition__c IN :byId.keySet()
]) {
    alreadyHasNda.add(existing.Disposition__c);
}

// ── STEP 4. Which parents are locked by a pending approval? The insert will succeed on those, but
//    the rollup's parent write will not, so the row is reported rather than silently "repaired".
Set<Id> lockedByApproval = new Set<Id>();
for (ProcessInstance pi : [
    SELECT TargetObjectId FROM ProcessInstance
    WHERE TargetObjectId IN :byId.keySet() AND Status = 'Pending'
]) {
    lockedByApproval.add(pi.TargetObjectId);
}

// ── STEP 5. Build. Off-market rows are OUT OF SCOPE and are reported, not repaired: the gate has
//    always applied to them, so a zero count there is a genuine missing NDA for a human to chase,
//    not fallout from the rescope.
//    ⚠ Record-type resolution goes through DispositionDomain so a Master/unset row is treated as
//    On_Market by the SAME rule the approval and advance services use.
List<NDA__c> toCreate = new List<NDA__c>();
List<Id> targetOrder = new List<Id>();
Integer skippedExisting = 0;
Integer skippedOffMarket = 0;

for (Disposition__c d : candidates) {
    String typeName = DispositionDomain.recordTypeNameOf(d);
    if (DispositionDomain.RT_OFF_MARKET.equals(typeName)) {
        skippedOffMarket++;
        System.debug(LoggingLevel.WARN, 'SKIP (off-market, out of scope) ' + d.Name + ' at '
            + d.Disposition_Stage__c + ' has no NDA. This is a real gap on a path that always '
            + 'required one - chase the missing NDA, do not backfill it here.');
        continue;
    }
    if (alreadyHasNda.contains(d.Id)) {
        skippedExisting++;
        System.debug(LoggingLevel.INFO, 'SKIP (already has an NDA child) ' + d.Name + ' at '
            + d.Disposition_Stage__c + '. Count reads ' + d.NDA_Count__c + ' - if that is still 0 '
            + 'after this run, the rollup was blocked by a lock; save the NDA again to re-fire it.');
        continue;
    }

    Date signedOn = (d.Listing_Date__c != null) ? d.Listing_Date__c : d.CreatedDate.date();
    toCreate.add(new NDA__c(
        RecordTypeId = NDA_RECORD_TYPE_ID,
        Disposition__c = d.Id,
        Party_Role__c = 'Buyer',
        Status__c = 'Signed',
        Date_Signed__c = signedOn,
        Counterparty_Name__c = BASELINE_NAME,
        Notes__c = BASELINE_NOTES
    ));
    targetOrder.add(d.Id);
    System.debug(LoggingLevel.INFO, 'PLAN ' + d.Name + ' (' + d.Disposition_Stage__c + ') -> '
        + 'buyer NDA, Signed, Date Signed ' + signedOn
        + (d.Listing_Date__c != null ? ' (from Listing Date)' : ' (from Created Date)')
        + (lockedByApproval.contains(d.Id) ? ' [WARNING: PARENT LOCKED BY A PENDING APPROVAL]' : ''));
}

if (toCreate.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to create. Skipped ' + skippedExisting
        + ' with an existing NDA and ' + skippedOffMarket + ' off-market rows.');
    System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: NOTHING TO DO');
    return;
}

// ── STEP 5b. THE PREVIEW GATE. Everything above this line is reads and in-memory building; the
//    first DML in this script is the insert below. Returning here is therefore a genuine dry run,
//    not a partial one.
if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO RECORDS WERE CREATED. Would create '
        + toCreate.size() + ' baseline NDA(s); skipped ' + skippedExisting
        + ' with an existing NDA and ' + skippedOffMarket + ' off-market rows. Read every PLAN '
        + 'line above and confirm each named row is the row you mean, then set PREVIEW_ONLY = '
        + 'false and re-run.');
    System.debug(LoggingLevel.WARN, 'REPAIR VERDICT: PREVIEW (no DML performed)');
    return;
}

// ── STEP 6. Insert. allOrNone = false so ONE refused row cannot cost the other four their repair;
//    every outcome is logged against its disposition by index.
List<Database.SaveResult> results = Database.insert(toCreate, false);
Integer created = 0;
Integer failed = 0;
for (Integer i = 0; i < results.size(); i++) {
    Disposition__c parent = byId.get(targetOrder.get(i));
    if (results[i].isSuccess()) {
        created++;
        System.debug(LoggingLevel.INFO, 'CREATED ' + results[i].getId() + ' for ' + parent.Name);
    } else {
        failed++;
        String detail = '';
        for (Database.Error err : results[i].getErrors()) {
            detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
        }
        System.debug(LoggingLevel.ERROR, 'FAILED for ' + parent.Name + ' -> ' + detail);
    }
}

// ── STEP 7. Verify from the DATABASE, not from what we intended. The rollup is an after-save flow
//    on NDA__c, so it has already run in this same transaction and the counters below are final.
Integer repaired = 0;
Integer stillBlocked = 0;
for (Disposition__c after : [
    SELECT Id, Name, Disposition_Stage__c, NDA_Count__c, Signed_NDA_Count__c
    FROM Disposition__c
    WHERE Id IN :targetOrder
    ORDER BY Name
]) {
    // Written as statements rather than ternaries on purpose: a `? 0 :` against a Decimal field is
    // an Integer/Decimal ternary, which Apex is entitled to reject at compile time.
    Decimal total = after.NDA_Count__c;
    if (total == null) {
        total = 0;
    }
    Decimal signed = after.Signed_NDA_Count__c;
    if (signed == null) {
        signed = 0;
    }
    Boolean passes = (total > 0 && signed >= total);
    if (passes) {
        repaired++;
        System.debug(LoggingLevel.INFO, 'VERIFY PASS ' + after.Name + ' (' + after.Disposition_Stage__c
            + ') counts ' + signed + '/' + total + ' - the release gate now passes.');
    } else {
        stillBlocked++;
        System.debug(LoggingLevel.ERROR, 'VERIFY FAIL ' + after.Name + ' ('
            + after.Disposition_Stage__c + ') counts ' + signed + '/' + total
            + (lockedByApproval.contains(after.Id)
                ? ' - the parent is LOCKED by a pending approval, so NDA_Signed_Rollup swallowed '
                  + 'ENTITY_IS_LOCKED. Resolve or recall the approval, then save the NDA again.'
                : ' - unexpected. Check that NDA_Signed_Rollup is ACTIVE.'));
    }
}

System.debug(LoggingLevel.INFO, 'REPAIR SUMMARY: created ' + created + ', failed ' + failed
    + ', skipped-existing ' + skippedExisting + ', skipped-off-market ' + skippedOffMarket
    + ', verified-passing ' + repaired + ', still-blocked ' + stillBlocked);
System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: '
    + ((failed == 0 && stillBlocked == 0) ? 'COMPLETE' : 'INCOMPLETE - read the FAILED/VERIFY FAIL lines above'));
