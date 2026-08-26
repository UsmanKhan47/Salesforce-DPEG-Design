// ═══════════════════════════════════════════════════════════════════════════════════════════════
// BACKFILL — Disposition__c.Primary_LOI__c / Primary_PSA__c   (2026-08-26)
// ═══════════════════════════════════════════════════════════════════════════════════════════════
//
// WHY IT EXISTS. Both lookups are stamped forward by DispositionStageEntryService via
// DispositionPrimaryChildStampQueueable when it AUTO-CREATES the child on stage entry. Nothing
// stamps a row whose child already existed, and there are three populations of those:
//   1. dispositions that reached LOI / PSA before the lookups were first created (2026-08-25);
//   2. dispositions that reached LOI / PSA during the window when the lookups did not exist —
//      they were deleted on 2026-08-25 and restored on 2026-08-26 (user decision, option A);
//   3. dispositions whose child was created BY HAND rather than by the stage-entry automation.
//
// 🔴 A MISSING STAMP IS SILENT. The NDA / LOI / PSA Details sections on Disposition_Record_Page
// are SPANNING field items (Record.Primary_LOI__r.Stage__c and friends) gated on the lookup being
// non-blank, so an unstamped row simply shows no section. It does not error, and no user reports
// it. That is the entire reason this script exists rather than "someone will notice".
//
// ⚠ IT DOES NOT TOUCH Primary_NDA__c. That lookup pre-dates this work by several tranches, has
// never been deleted, and has its own writer. Widening this script to it would be a separate
// decision on a much older population — see objects/Disposition__c/fields/Primary_NDA__c.
//
// ── IDEMPOTENT ────────────────────────────────────────────────────────────────────────────────
// The candidate query is `Primary_LOI__c = null OR Primary_PSA__c = null`. A second run finds
// only what the first could not stamp. Re-running is safe and is the intended way to work through
// a large org (see the cap below). It NEVER overwrites an existing stamp — a hand-set link wins.
//
// ── 🔴 SYSTEM_MODE WAS ASKED FOR AND IS NOT AVAILABLE HERE. READ THIS BEFORE "FIXING" IT ──────
// The brief for this script said SYSTEM_MODE. Anonymous Apex CANNOT express it: both
// `WITH SYSTEM_MODE` and `AccessLevel.SYSTEM_MODE` are rejected outright with
//     "Cannot use SYSTEM_MODE access level in anonymous execution of Apex"
// (measured on this org 2026-08-24 while probing BOV_Submission__c.Approval_Pending__c). So the
// DML below is plain, and that has TWO consequences which are preconditions, not caveats:
//
//   (a) FLS APPLIES. A Metadata-API-deployed field arrives with NO field permissions for ANY
//       profile, System Administrator included. Primary_LOI__c / Primary_PSA__c are granted
//       editable ONLY by DPEG_Disposition_Edit. ⇒ RUN THIS AS A USER WHO HOLDS
//       DPEG_Disposition_Edit. Without it the update is refused on every row — and that grant's
//       editable = true exists partly for exactly this.
//   (b) SHARING APPLIES. Disposition__c is OWD Private. DPEG_Disposition_Edit carries
//       viewAllRecords = true but modifyAllRecords = false, so READ reaches every row while WRITE
//       reaches only rows the runner owns or is shared. ⇒ RUN AS A SYSTEM ADMINISTRATOR (Modify
//       All Data) WHO ALSO HOLDS THAT SET. Anything less silently stamps a subset, and the
//       per-row log below is what makes that visible instead of invisible.
//
// If this ever needs to run unattended or as a non-admin, it must become a deployed class (where
// SYSTEM_MODE is legal) rather than gaining a `without sharing` wrapper here — there is no such
// thing in anonymous Apex.
//
// ── allOrNone = FALSE, DELIBERATELY ───────────────────────────────────────────────────────────
// One locked or validation-refused disposition must not take the whole backfill down. Every
// failure is printed with its row Id and message; the rest commit.
//
// ── RUN IT ────────────────────────────────────────────────────────────────────────────────────
//   sf apex run --file scripts/backfill-disposition-primary-children.apex --target-org usman-dpeg
// Read the log. Re-run until it reports `candidates scanned: 0`.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

// A cap, not a limit of the data. Anonymous Apex allows 10,000 DML rows and 50,000 query rows per
// transaction; 2,000 dispositions keeps BOTH comfortably clear even when every row needs both
// lookups and the update re-enters DispositionTrigger. The script is idempotent, so a larger org
// is worked through by running it repeatedly.
final Integer MAX_DISPOSITIONS_PER_RUN = 2000;

List<Disposition__c> candidates = [
    SELECT Id, Name, Primary_LOI__c, Primary_PSA__c
    FROM Disposition__c
    WHERE Primary_LOI__c = null OR Primary_PSA__c = null
    ORDER BY CreatedDate
    LIMIT :MAX_DISPOSITIONS_PER_RUN
];
System.debug('candidates scanned: ' + candidates.size());

if (candidates.isEmpty()) {
    System.debug('Nothing to do — every disposition already carries both stamps, or none is missing one.');
} else {
    Set<Id> candidateIds = new Map<Id, Disposition__c>(candidates).keySet();

    // NEWEST CHILD WINS, AND THE ORDERING IS WHAT MAKES THAT TRUE. Descending CreatedDate means
    // the FIRST row seen per disposition is the newest, so `containsKey` keeps it and every older
    // sibling is skipped. Id DESC is the tie-break: two children created in the same transaction
    // (a re-stage that opened a second row) share a CreatedDate to the second, and without it the
    // winner would differ between runs — which would make this script non-idempotent in the one
    // case it most needs to be.
    Map<Id, Id> newestLoiByDisposition = new Map<Id, Id>();
    for (LOI__c loi : [
        SELECT Id, Disposition__c
        FROM LOI__c
        WHERE Disposition__c IN :candidateIds
        ORDER BY CreatedDate DESC, Id DESC
    ]) {
        if (!newestLoiByDisposition.containsKey(loi.Disposition__c)) {
            newestLoiByDisposition.put(loi.Disposition__c, loi.Id);
        }
    }

    Map<Id, Id> newestPsaByDisposition = new Map<Id, Id>();
    for (Contract_Review__c cr : [
        SELECT Id, Disposition__c
        FROM Contract_Review__c
        WHERE Disposition__c IN :candidateIds
        ORDER BY CreatedDate DESC, Id DESC
    ]) {
        if (!newestPsaByDisposition.containsKey(cr.Disposition__c)) {
            newestPsaByDisposition.put(cr.Disposition__c, cr.Id);
        }
    }

    // ONE SHELL PER DISPOSITION CARRYING ONLY THE COLUMNS THAT ARE ACTUALLY NULL. A shell that
    // re-sent an already-populated lookup would be a no-op write on paper, but it would also
    // re-enter DispositionTrigger for a row that needed nothing — and it would make the counts
    // below lie about how much work was done.
    List<Disposition__c> stamps = new List<Disposition__c>();
    List<String> stampedNames = new List<String>();
    Integer loiStamps = 0;
    Integer psaStamps = 0;
    Integer noChildFound = 0;

    for (Disposition__c d : candidates) {
        Id loiId = d.Primary_LOI__c == null ? newestLoiByDisposition.get(d.Id) : null;
        Id psaId = d.Primary_PSA__c == null ? newestPsaByDisposition.get(d.Id) : null;

        if (loiId == null && psaId == null) {
            // NORMAL, NOT A FAILURE. A disposition that has not reached the LOI or PSA stage has
            // no child to point at. It is counted rather than logged per row, because on a healthy
            // org this is the overwhelming majority of the candidate set.
            noChildFound++;
            continue;
        }

        Disposition__c stamp = new Disposition__c(Id = d.Id);
        String what = '';
        if (loiId != null) {
            stamp.Primary_LOI__c = loiId;
            loiStamps++;
            what += ' Primary_LOI__c=' + loiId;
        }
        if (psaId != null) {
            stamp.Primary_PSA__c = psaId;
            psaStamps++;
            what += ' Primary_PSA__c=' + psaId;
        }
        stamps.add(stamp);
        stampedNames.add(d.Name + ' (' + d.Id + ')' + what);
    }

    System.debug('to stamp: ' + stamps.size() + ' dispositions — '
        + loiStamps + ' Primary_LOI__c, ' + psaStamps + ' Primary_PSA__c');
    System.debug('skipped (no LOI and no Contract Review exists yet — expected): ' + noChildFound);

    if (stamps.isEmpty()) {
        System.debug('Nothing to write.');
    } else {
        // allOrNone = false: see the header. SYSTEM_MODE is not expressible here.
        List<Database.SaveResult> results = Database.update(stamps, false);

        Integer ok = 0;
        Integer failed = 0;
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult r = results[i];
            if (r.isSuccess()) {
                ok++;
                System.debug('OK     ' + stampedNames[i]);
            } else {
                failed++;
                // EVERY error on the row, not just the first. A validation rule and an FLS refusal
                // can arrive together, and reporting one of them sends the reader after the wrong
                // precondition in the header above.
                List<String> messages = new List<String>();
                for (Database.Error e : r.getErrors()) {
                    messages.add(e.getStatusCode() + ': ' + e.getMessage()
                        + (e.getFields().isEmpty() ? '' : ' ' + e.getFields()));
                }
                System.debug('FAILED ' + stampedNames[i] + ' — ' + String.join(messages, ' | '));
            }
        }

        System.debug('═══ BACKFILL COMPLETE — stamped ' + ok + ', failed ' + failed
            + ', skipped ' + noChildFound + ', scanned ' + candidates.size() + ' ═══');
        if (candidates.size() == MAX_DISPOSITIONS_PER_RUN) {
            System.debug('⚠ THE CAP WAS HIT (' + MAX_DISPOSITIONS_PER_RUN + '). There are almost '
                + 'certainly more candidates. Re-run until "candidates scanned: 0".');
        }
        if (failed > 0) {
            System.debug('⚠ ' + failed + ' rows were refused. If the status code is '
                + 'INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY or the message names the field, '
                + 'read precondition (a) and (b) in this script\'s header BEFORE editing the code — '
                + 'the usual cause is the runner not holding DPEG_Disposition_Edit or not having '
                + 'Modify All Data on a Private-OWD object.');
        }
    }
}
