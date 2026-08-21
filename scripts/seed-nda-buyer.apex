/**
 * ONE-TIME DATA REPAIR — set `NDA__c.Buyer__c` on the org's one Disposition NDA so the offer
 * modal's buyer picker has an option to test with.
 *
 * Run:  sf apex run --file scripts/seed-nda-buyer.apex --target-org usman-dpeg
 * Then read the log and the final "SEED VERDICT" line.
 *
 * =====================================================================================
 * 🔴 WHY THIS EXISTS
 * =====================================================================================
 * `NDA__c.Buyer__c` (Lookup to Contact) was added 2026-08-20 for the buyer activity timeline
 * (see `NdaBuyerStampService.cls` header). Every NDA that existed before that date — including
 * NDA-0114, the org's one Disposition NDA — carries `Buyer__c = NULL`. The Log Offer modal's
 * buyer picker is gated by `NdaSelector.selectSignedBuyerNdasByDispositionId`, whose WHERE clause
 * requires `Party_Role__c = 'Buyer' AND Status__c = 'Signed' AND Buyer__c != NULL`. NDA-0114 is
 * Signed and Party_Role__c = Buyer already — only `Buyer__c` being blank is what empties the
 * picker. This is expected transition state, not a defect; this script closes it for the one
 * record the operator needs to test with.
 *
 * =====================================================================================
 * 🔴 WHICH CONTACT, AND WHY NOT ANY OF THE 25 THAT ALREADY EXIST
 * =====================================================================================
 * Every Contact in this org today (measured 2026-08-21, 25 total) is one of:
 *   - 19 on the `Contact.Broker` record type — the sell side of every deal. Setting a broker as
 *     the BUYER on the same disposition would be nonsense, and would corrupt the buyer timeline
 *     this field exists to drive. Excluded categorically, per the operator's explicit instruction.
 *   - 6 more with NO record type set (Derek Simmons/Colliers Houston, Katie Osborne/Newmark
 *     Knight Frank, Marcus Whitfield/Matthews REIS, Priya Nair/Cushman & Wakefield Dallas, Ryan
 *     O'Connell/Stream Realty Partners, Sofia Delgado/Transwestern) — these are the SAME person
 *     and firm as an existing Broker-record-type Contact (the "6 duplicate broker Contacts" data-
 *     quality issue the operator has not yet resolved). Picking one of these would be exactly as
 *     wrong as picking a broker outright — it IS a broker, just missing its record type.
 *   - The 7 known junk rows already flagged elsewhere in this repo (Acme x3, Global Media x2,
 *     salesforce.com, "Unknown - Via Email") are a SUBSET of the 19 Broker-record-type Contacts
 *     above — excluded for the same reason, doubly so for being junk.
 *
 * There is NO Contact in this org that plausibly represents a buying party. Per the operator's
 * instruction, this script CREATES one — a standalone Contact, clearly test-flavoured in its
 * name so nobody mistakes it for a real counterparty later, but professional enough to sit in a
 * picker and a report without looking broken:
 *
 *     FirstName = 'Jordan'
 *     LastName  = 'Ellis (Test Buyer)'
 *     Title     = 'Prospective Buyer'
 *     Email     = 'jordan.ellis.testbuyer@dpeg-test.example'   (reserved .example TLD — RFC 2606)
 *     Description = 'Created 2026-08-21 by scripts/seed-nda-buyer.apex to give the Log Offer
 *                    buyer picker an option on NDA-0114 / DISP-0011. Not a real counterparty.'
 *
 * No RecordTypeId is set (defaults to Contact's implicit Master), and no AccountId is set.
 * `Record_Type_Matches_Account` (objects/Contact/validationRules) only fires when RecordType is
 * Broker or Investor — a Master-type Contact is exempt regardless of AccountId — and the rule's
 * own header notes a Contact with no Account is permitted and "fails safe" (owner-visible only
 * under ControlledByParent). Inventing a parent Account for a one-off test buyer would be a new,
 * unrequested decision; leaving it blank is the narrower one.
 *
 * The `Investor` record type was considered and rejected: it models a FUND investor for the IR
 * portal (ARCHITECTURE.md §4), a different relationship entirely from the counterparty on a
 * property sale. Using it here would misclassify the Contact for anyone who later builds IR
 * reporting off that record type.
 *
 * =====================================================================================
 * 🔴 SCOPE — BLANK-ONLY, NEVER OVERWRITE, AND NAMED-RECORD ONLY
 * =====================================================================================
 * This script targets exactly ONE NDA by Name ('NDA-0114'), not a query over "every NDA missing
 * a buyer" — the operator asked for this one record, and a broader sweep is a separate, larger
 * decision (which Contact to pick per NDA does not generalize the way `Broker_Firm__c` did).
 * `Buyer__c` is read and checked for blank in Apex before any write is planned, exactly like
 * `scripts/backfill-broker-firm.apex`'s blank-only pattern — if a concurrent process has already
 * set it, this script skips and reports rather than overwriting.
 *
 * =====================================================================================
 * 🔴 VERIFY THE STAMP FIRED — DO NOT WRITE Counterparty_Name__c YOURSELF
 * =====================================================================================
 * `NdaBuyerStampService.stampBuyerName` is change-keyed on `Buyer__c` and runs in NdaTrigger's
 * before-insert/before-update context (see that class's header). Setting `Buyer__c` on an update
 * SHOULD cause `Counterparty_Name__c` to be stamped with the new Contact's Name in the SAME save
 * — this script does not set `Counterparty_Name__c` itself. STEP 4 re-queries both fields from
 * the database after the DML and reports whether the stamp actually fired. If it did not, that is
 * a real defect to report, not something to paper over by writing the text field directly here.
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * Defaults to **true**, matching `scripts/backfill-broker-firm.apex`. In PREVIEW mode the target
 * NDA is resolved, the new Contact's field values are printed, and the script STOPS before any
 * DML. Flip to false only after reading the full PREVIEW output.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * Anonymous Apex run by an administrator against live production data — not a selector, not part
 * of the deployed codebase. Same convention as every other script in this directory.
 *
 * ROLLBACK: setting `NDA__c.Buyer__c` back to null (and, if the stamp fired,
 * `Counterparty_Name__c` back to null) on the specific NDA Id logged below, and deleting the new
 * Contact if it is no longer wanted.
 */

// ── PREVIEW_ONLY: true = resolve the target NDA, print the planned Contact and the planned NDA
//    write, then RETURN before any DML. Flip to false only after reading the PREVIEW output.
final Boolean PREVIEW_ONLY = true;

final String TARGET_NDA_NAME = 'NDA-0114';

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Resolve the target NDA. Named-record only — not a query over every blank-buyer NDA.
// ═════════════════════════════════════════════════════════════════════════════════════
List<NDA__c> targets = [
    SELECT Id, Name, Status__c, Party_Role__c, Buyer__c, Counterparty_Name__c, Disposition__c,
           Disposition__r.Name
    FROM NDA__c
    WHERE Name = :TARGET_NDA_NAME
    LIMIT 1
];

if (targets.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Nothing to do: no NDA__c named "' + TARGET_NDA_NAME + '" found.');
    System.debug(LoggingLevel.INFO, 'SEED VERDICT: NOTHING TO DO (target NDA not found)');
    return;
}

NDA__c nda = targets[0];
System.debug(LoggingLevel.INFO, 'TARGET: ' + nda.Name + ' (' + nda.Id + ') on Disposition '
    + nda.Disposition__r.Name + ' — Status__c=' + nda.Status__c + ', Party_Role__c='
    + nda.Party_Role__c + ', Buyer__c=' + nda.Buyer__c + ', Counterparty_Name__c="'
    + nda.Counterparty_Name__c + '"');

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. Blank-only guard. Never overwrite an existing buyer.
// ═════════════════════════════════════════════════════════════════════════════════════
if (nda.Buyer__c != null) {
    System.debug(LoggingLevel.WARN, 'SKIP: ' + nda.Name + ' already has Buyer__c = ' + nda.Buyer__c
        + '. Never overwritten by this script.');
    System.debug(LoggingLevel.INFO, 'SEED VERDICT: NOTHING TO DO (Buyer__c already set)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 3. Build the new buyer Contact. See the header for why no existing Contact qualifies and
// why this shape (no RecordTypeId, no AccountId) was chosen.
// ═════════════════════════════════════════════════════════════════════════════════════
Contact buyer = new Contact(
    FirstName = 'Jordan',
    LastName = 'Ellis (Test Buyer)',
    Title = 'Prospective Buyer',
    Email = 'jordan.ellis.testbuyer@dpeg-test.example',
    Description = 'Created ' + Date.today().format() + ' by scripts/seed-nda-buyer.apex to give '
        + 'the Log Offer buyer picker an option on ' + nda.Name + ' / ' + nda.Disposition__r.Name
        + '. Not a real counterparty.'
);

System.debug(LoggingLevel.INFO, 'PLAN: create Contact ' + buyer.FirstName + ' ' + buyer.LastName
    + ' (Title="' + buyer.Title + '", Email=' + buyer.Email + '), then set ' + nda.Name
    + '.Buyer__c to its Id.');

if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO RECORDS WERE CREATED OR UPDATED. '
        + 'Read the PLAN line above, then set PREVIEW_ONLY = false and re-run.');
    System.debug(LoggingLevel.WARN, 'SEED VERDICT: PREVIEW (no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. Insert the Contact, set the lookup, verify the stamp fired.
// ═════════════════════════════════════════════════════════════════════════════════════
insert buyer;
System.debug(LoggingLevel.INFO, 'CREATED Contact ' + buyer.Id + ' — ' + buyer.FirstName + ' '
    + buyer.LastName);

nda.Buyer__c = buyer.Id;
update nda;
System.debug(LoggingLevel.INFO, 'UPDATED ' + nda.Name + '.Buyer__c = ' + buyer.Id);

NDA__c after = [
    SELECT Id, Name, Status__c, Party_Role__c, Buyer__c, Buyer__r.Name, Counterparty_Name__c
    FROM NDA__c
    WHERE Id = :nda.Id
];

System.debug(LoggingLevel.INFO, 'VERIFY: ' + after.Name + ' — Status__c=' + after.Status__c
    + ', Party_Role__c=' + after.Party_Role__c + ', Buyer__c=' + after.Buyer__c
    + ', Buyer__r.Name=' + after.Buyer__r.Name + ', Counterparty_Name__c="'
    + after.Counterparty_Name__c + '"');

Boolean stampFired = (after.Counterparty_Name__c == after.Buyer__r.Name);
if (stampFired) {
    System.debug(LoggingLevel.INFO, 'STAMP CHECK: Counterparty_Name__c matches Buyer__r.Name — '
        + 'NdaBuyerStampService fired as documented.');
} else {
    System.debug(LoggingLevel.ERROR, '🔴 STAMP CHECK FAILED: Counterparty_Name__c ("'
        + after.Counterparty_Name__c + '") does NOT match Buyer__r.Name ("' + after.Buyer__r.Name
        + '"). NdaBuyerStampService did not stamp as documented in its class header — this is a '
        + 'real defect to report, not something to paper over by writing the text field directly.');
}

Boolean pickerGateMet = (after.Party_Role__c == 'Buyer' && after.Status__c == 'Signed'
    && after.Buyer__c != null);
System.debug(LoggingLevel.INFO, 'PICKER GATE (Party_Role__c=Buyer AND Status__c=Signed AND '
    + 'Buyer__c != NULL): ' + (pickerGateMet ? 'MET — this NDA will now appear in the Log Offer '
    + 'buyer picker.' : 'NOT MET.'));

System.debug(LoggingLevel.INFO, 'SEED VERDICT: ' + (stampFired && pickerGateMet ? 'COMPLETE'
    : 'INCOMPLETE - read the STAMP CHECK / PICKER GATE lines above'));
