/**
 * LIVE UAT BLOCKER REPAIR — give the test buyer Contact "Jordan Ellis (Test Buyer)" a parent
 * Account so it becomes visible to non-owner users, and restore the buyer link this fix exists
 * to unblock.
 *
 * Run:  sf apex run --file scripts/fix-test-buyer-account.apex --target-org usman-dpeg
 * Then read the log and the final "FIX VERDICT" line.
 *
 * =====================================================================================
 * 🔴 THE BUG, MEASURED (2026-08-21) — NOT RE-DERIVED HERE, READ scripts/seed-nda-buyer.apex FIRST
 * =====================================================================================
 * Junior Dhanani hit: "insufficient access rights on cross-reference id: 003iw000000uJPl" while
 * working NDA-0114. 003iw000000uJPlAAM is Jordan Ellis (Test Buyer), a Contact created earlier
 * today by scripts/seed-nda-buyer.apex, owned by Usman Khan, with AccountId = NULL.
 *
 * A Contact with no AccountId is a "private contact" — visible only to its owner and their role
 * hierarchy, REGARDLESS of Contact OWD. `EntityDefinition.InternalSharingModel` reports
 * 'ReadWrite' for Contact, which does not govern account-less Contacts at all. Measured baseline
 * (UserRecordAccess for Junior Dhanani, 005iw000000AJhJAAW):
 *
 *     Jordan Ellis  (003iw000000uJPlAAM, AccountId NULL) -> HasReadAccess = false, HasEditAccess = false
 *     Derek Simmons (003iw000000o39BAAQ, AccountId set)  -> HasReadAccess = true,  HasEditAccess = true
 *     (Derek Simmons queried only as a same-org CONTROL to prove the AccountId theory, not because
 *     this script touches Derek Simmons.)
 *
 * The fix: give Jordan Ellis a parent Account. `Account`'s OWD is Public Read/Write
 * (EntityDefinition.InternalSharingModel = 'ReadWrite' for Account, confirmed by live query, and
 * unlike Contact this setting DOES govern Account since Account has no "account-less" carve-out) —
 * so once Jordan Ellis sits under ANY Account, sharing is inherited from that Account
 * (Contact.sharingModel = ControlledByParent) and every internal user, including Junior, gains
 * read/edit access regardless of who owns the Account. This script verifies that with a live
 * UserRecordAccess re-query after the DML — see STEP 5. Do not trust a successful save in this
 * (System Administrator) context as proof; the whole bug is that access differs by user.
 *
 * =====================================================================================
 * 🔴 WHICH ACCOUNT, AND WHY NOT AN EXISTING ONE
 * =====================================================================================
 * There is no buyer-side Account in this org today — the 19 broker Contacts hang off broker firm
 * Accounts (Colliers Houston, Cushman & Wakefield Dallas, Transwestern, Newmark Knight Frank,
 * Stream Realty Partners, Matthews Real Estate Investment Services, plus junk firms Acme / Global
 * Media / salesforce.com / "Unknown - Via Email" — see scripts/backfill-broker-firm.apex). Parking
 * a BUYER Contact under a BROKER FIRM Account would make Jordan Ellis look like a broker to anyone
 * reading the Account's contact roster, and would corrupt the buyer timeline this Contact exists to
 * test — explicitly the thing the operator said not to do. This script creates a new, standalone
 * Account instead: 'Test Buyer Entity (Jordan Ellis)' — the name is deliberately test-flavoured so
 * nobody mistakes it for a real buying entity later, matching the naming spirit of the Contact
 * itself ("Jordan Ellis (Test Buyer)").
 *
 * =====================================================================================
 * 🔴 RECORD TYPE — NEITHER Broker_Firm NOR Investor_Entity
 * =====================================================================================
 * Account has exactly two record types in this org: Broker_Firm and Investor_Entity (measured via
 * RecordType query). Neither fits a one-off deal counterparty/buyer. This script leaves
 * RecordTypeId unset on the new Account (defaults to Account's implicit Master type — 18 of the
 * org's 23 existing Accounts already carry RecordTypeId = null, so this is a proven, unremarkable
 * shape, not a novel one).
 *
 * `objects/Contact/validationRules/Record_Type_Matches_Account.validationRule-meta.xml` only fires
 * when `RecordType.DeveloperName` on the CONTACT is 'Broker' or 'Investor' AND the parent Account's
 * record type doesn't match. Jordan Ellis's Contact.RecordTypeId is NULL today (implicit Master) —
 * confirmed by live query — so the rule's AND() condition is false regardless of what record type
 * the Account carries. This script does not change Jordan Ellis's Contact record type. Leaving the
 * Account on Master as well means the combination is doubly safe: neither side matches a
 * Broker/Investor pairing, so there is nothing for the rule to misfire on even if the Contact's
 * record type were changed later by someone else.
 *
 * =====================================================================================
 * 🔴 THE NDA-0114 DISCREPANCY — READ BEFORE RUNNING
 * =====================================================================================
 * The live org does NOT currently match the state implied by the task ("Jordan Ellis ... set as
 * NDA__c.Buyer__c on NDA-0114"). Measured facts, in order:
 *   - Jordan Ellis Contact: CreatedDate/LastModifiedDate = 2026-08-21T10:33:35Z, CreatedBy = Usman
 *     Khan (System Administrator) — consistent with scripts/seed-nda-buyer.apex having been run
 *     with PREVIEW_ONLY = false and having set NDA-0114.Buyer__c = Jordan Ellis at that moment.
 *   - NDA-0114: LastModifiedDate = 2026-08-21T10:44:34Z, LastModifiedBy = Junior Dhanani — eleven
 *     minutes LATER, by a DIFFERENT user, and the save SUCCEEDED (LastModifiedDate moved).
 *   - NDA-0114.Buyer__c currently reads 003iw000000o39BAAQ (Derek Simmons, a BROKER Contact), and
 *     Counterparty_Name__c currently reads "Derek Simmons", not "Jordan Ellis (Test Buyer)".
 *   - NDA__History has exactly one row for this record ("created") — Buyer__c is not a
 *     field-history-tracked field here, so history cannot confirm the intermediate value, but the
 *     LastModifiedBy/Date change on NDA-0114 attributed to Junior Dhanani is independent evidence a
 *     save by Junior succeeded after the Contact was created.
 * The most consistent read: Junior hit the cross-reference error trying to work NDA-0114 while it
 * pointed at the then-inaccessible Jordan Ellis, and re-picked Derek Simmons (a broker, already
 * readable) as a workaround so SOMETHING would save. `scripts/seed-nda-buyer.apex`'s own header
 * calls using a broker Contact as a buyer "nonsense" that "would corrupt the buyer timeline" — so
 * this script treats the Derek Simmons value as an unintended workaround, not a deliberate decision
 * to change test data, and restores Buyer__c to Jordan Ellis in STEP 6, now that the access
 * fault this script exists to fix is closed. This is called out here, loudly, specifically so a
 * human reviewing this script's PREVIEW output can override that judgment before any DML runs.
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * Defaults to **true**, matching every other script in this directory. In PREVIEW mode every step
 * is resolved and logged, INCLUDING the post-fix UserRecordAccess re-query for Jordan Ellis (which
 * in preview reflects the PRE-fix, still-broken state, and is logged as such) — the script stops
 * before any DML. Flip to false only after reading the full PREVIEW output.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * Anonymous Apex run by an administrator against live production data — not a selector, not part
 * of the deployed codebase. Same convention as every other script in this directory.
 *
 * ROLLBACK: delete the new Account (which will also null out Contact.AccountId per standard
 * Account-Contact relationship behavior — re-verify Jordan Ellis's access breaks again if you do
 * this), and set NDA-0114.Buyer__c back to Derek Simmons (003iw000000o39BAAQ) if STEP 6 ran.
 */

// ── PREVIEW_ONLY: true = resolve every step, print the full plan (including a live
//    UserRecordAccess check reflecting CURRENT, pre-fix state), then RETURN before any DML.
//    Flip to false only after reading the PREVIEW output.
final Boolean PREVIEW_ONLY = false;

final Id JORDAN_ELLIS_CONTACT_ID = '003iw000000uJPlAAM';
final Id JUNIOR_DHANANI_USER_ID = '005iw000000AJhJAAW';
final Id DEREK_SIMMONS_CONTACT_ID = '003iw000000o39BAAQ'; // control only, never written to
final String TARGET_NDA_NAME = 'NDA-0114';
final String NEW_ACCOUNT_NAME = 'Test Buyer Entity (Jordan Ellis)';

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Resolve the Contact, confirm its shape matches what this script assumes.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Contact> contacts = [
    SELECT Id, Name, AccountId, RecordTypeId, OwnerId
    FROM Contact
    WHERE Id = :JORDAN_ELLIS_CONTACT_ID
];

if (contacts.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Nothing to do: Contact ' + JORDAN_ELLIS_CONTACT_ID + ' not found.');
    System.debug(LoggingLevel.INFO, 'FIX VERDICT: NOTHING TO DO (Contact not found)');
    return;
}

Contact buyer = contacts[0];
System.debug(LoggingLevel.INFO, 'TARGET CONTACT: ' + buyer.Name + ' (' + buyer.Id + ') — AccountId='
    + buyer.AccountId + ', RecordTypeId=' + buyer.RecordTypeId + ', OwnerId=' + buyer.OwnerId);

if (buyer.RecordTypeId != null) {
    System.debug(LoggingLevel.ERROR, '🔴 UNEXPECTED: Contact now has a RecordTypeId set ('
        + buyer.RecordTypeId + '). This script\'s validation-rule-safety reasoning assumes Master '
        + '(null) record type. Stopping rather than guessing whether Broker/Investor matching '
        + 'would misfire.');
    System.debug(LoggingLevel.INFO, 'FIX VERDICT: STOPPED (unexpected RecordTypeId)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. Blank-only guard on AccountId. Never overwrite an existing parent Account.
// ═════════════════════════════════════════════════════════════════════════════════════
if (buyer.AccountId != null) {
    System.debug(LoggingLevel.WARN, 'SKIP ACCOUNT CREATE: Contact already has AccountId = '
        + buyer.AccountId + '. Not overwritten by this script. Re-run the UserRecordAccess check '
        + 'manually if you still see the access error.');
} else {
    // ═════════════════════════════════════════════════════════════════════════════════
    // STEP 3. Plan the new Account. Master record type (unset), plainly test-flavoured name.
    // ═════════════════════════════════════════════════════════════════════════════════
    Account newAccount = new Account(
        Name = NEW_ACCOUNT_NAME,
        Description = 'Created ' + Date.today().format() + ' by scripts/fix-test-buyer-account.apex '
            + 'so the test buyer Contact "Jordan Ellis (Test Buyer)" is visible to non-owner users '
            + 'via standard Account sharing. Not a real buying entity.'
    );
    System.debug(LoggingLevel.INFO, 'PLAN: create Account "' + NEW_ACCOUNT_NAME + '" (no RecordTypeId '
        + '= Master), then set Contact ' + buyer.Id + '.AccountId to its Id.');

    if (PREVIEW_ONLY) {
        System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO ACCOUNT CREATED, NO CONTACT UPDATED.');
    } else {
        insert newAccount;
        System.debug(LoggingLevel.INFO, 'CREATED Account ' + newAccount.Id + ' — "' + NEW_ACCOUNT_NAME + '"');

        buyer.AccountId = newAccount.Id;
        update buyer;
        System.debug(LoggingLevel.INFO, 'UPDATED Contact ' + buyer.Id + '.AccountId = ' + newAccount.Id);
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. Re-resolve the Contact's AccountId as it stands right now (post-DML if not preview,
// pre-fix if preview), for use in the STEP 5 access check and in the final report.
// ═════════════════════════════════════════════════════════════════════════════════════
Contact buyerNow = [SELECT Id, AccountId FROM Contact WHERE Id = :JORDAN_ELLIS_CONTACT_ID];
System.debug(LoggingLevel.INFO, 'CONTACT NOW: AccountId=' + buyerNow.AccountId
    + (PREVIEW_ONLY ? ' (PREVIEW — this is the PRE-fix value, not a result of this run)' : ''));

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 5. Verify from the platform, not from a successful admin-context DML. This is the ONLY
// proof that matters — a query run as this (System Administrator) context proves nothing about
// Junior Dhanani's access.
// ═════════════════════════════════════════════════════════════════════════════════════
List<UserRecordAccess> access = [
    SELECT RecordId, HasReadAccess, HasEditAccess
    FROM UserRecordAccess
    WHERE UserId = :JUNIOR_DHANANI_USER_ID
      AND RecordId IN (:JORDAN_ELLIS_CONTACT_ID, :DEREK_SIMMONS_CONTACT_ID)
];
Map<Id, UserRecordAccess> accessById = new Map<Id, UserRecordAccess>();
for (UserRecordAccess a : access) {
    accessById.put(a.RecordId, a);
}
UserRecordAccess jordanAccess = accessById.get(JORDAN_ELLIS_CONTACT_ID);
UserRecordAccess derekAccess = accessById.get(DEREK_SIMMONS_CONTACT_ID);

System.debug(LoggingLevel.INFO, 'ACCESS CHECK (Junior Dhanani, ' + JUNIOR_DHANANI_USER_ID + '):');
System.debug(LoggingLevel.INFO, '  Jordan Ellis (' + JORDAN_ELLIS_CONTACT_ID + '): HasReadAccess='
    + (jordanAccess != null ? String.valueOf(jordanAccess.HasReadAccess) : 'NO ROW')
    + ', HasEditAccess=' + (jordanAccess != null ? String.valueOf(jordanAccess.HasEditAccess) : 'NO ROW'));
System.debug(LoggingLevel.INFO, '  Derek Simmons (control, ' + DEREK_SIMMONS_CONTACT_ID
    + '): HasReadAccess=' + (derekAccess != null ? String.valueOf(derekAccess.HasReadAccess) : 'NO ROW')
    + ', HasEditAccess=' + (derekAccess != null ? String.valueOf(derekAccess.HasEditAccess) : 'NO ROW'));

if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - the access check above reflects the CURRENT, '
        + 'PRE-fix state. Read it, read every PLAN line above, then set PREVIEW_ONLY = false and '
        + 're-run to apply the fix and re-verify.');
    System.debug(LoggingLevel.WARN, 'FIX VERDICT: PREVIEW (no DML performed)');
    return;
}

if (jordanAccess == null || jordanAccess.HasReadAccess != true) {
    System.debug(LoggingLevel.ERROR, '🔴 FIX DID NOT RESOLVE ACCESS. Junior Dhanani still cannot '
        + 'read Jordan Ellis after the Account was attached. Do not proceed to STEP 6 — the buyer '
        + 'link would fail again with the same error. Investigate Account OWD / sharing rules '
        + 'before retrying.');
    System.debug(LoggingLevel.INFO, 'FIX VERDICT: INCOMPLETE (access still denied — see ERROR above)');
    return;
}

System.debug(LoggingLevel.INFO, '✅ ACCESS CONFIRMED: Junior Dhanani now has HasReadAccess = true on '
    + 'Jordan Ellis.');

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 6. Restore NDA-0114.Buyer__c to Jordan Ellis, undoing the Derek-Simmons workaround
// described in the header. Guarded: only proceeds if the current value is NOT already Jordan
// Ellis, and only after STEP 5 proved the access fault is closed.
// ═════════════════════════════════════════════════════════════════════════════════════
List<NDA__c> ndas = [
    SELECT Id, Name, Buyer__c, Counterparty_Name__c
    FROM NDA__c
    WHERE Name = :TARGET_NDA_NAME
    LIMIT 1
];

if (ndas.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Cannot restore buyer link: no NDA__c named "' + TARGET_NDA_NAME
        + '" found.');
    System.debug(LoggingLevel.INFO, 'FIX VERDICT: PARTIAL (access fixed, NDA-0114 not found to restore)');
    return;
}

NDA__c nda = ndas[0];
if (nda.Buyer__c == JORDAN_ELLIS_CONTACT_ID) {
    System.debug(LoggingLevel.INFO, 'SKIP RESTORE: ' + nda.Name + '.Buyer__c is already Jordan Ellis. '
        + 'Nothing to do.');
} else {
    System.debug(LoggingLevel.WARN, 'RESTORING: ' + nda.Name + '.Buyer__c currently = ' + nda.Buyer__c
        + ' (Counterparty_Name__c="' + nda.Counterparty_Name__c + '"). Setting back to Jordan Ellis ('
        + JORDAN_ELLIS_CONTACT_ID + ') per the header\'s discrepancy note.');
    nda.Buyer__c = JORDAN_ELLIS_CONTACT_ID;
    update nda;

    NDA__c after = [
        SELECT Id, Name, Buyer__c, Buyer__r.Name, Counterparty_Name__c
        FROM NDA__c
        WHERE Id = :nda.Id
    ];
    System.debug(LoggingLevel.INFO, 'VERIFY: ' + after.Name + ' — Buyer__c=' + after.Buyer__c
        + ', Buyer__r.Name=' + after.Buyer__r.Name + ', Counterparty_Name__c="'
        + after.Counterparty_Name__c + '"');

    Boolean stampFired = (after.Counterparty_Name__c == after.Buyer__r.Name);
    System.debug(LoggingLevel.INFO, 'STAMP CHECK: ' + (stampFired
        ? 'Counterparty_Name__c matches Buyer__r.Name — NdaBuyerStampService fired as documented.'
        : '🔴 Counterparty_Name__c ("' + after.Counterparty_Name__c + '") does NOT match Buyer__r.Name '
          + '("' + after.Buyer__r.Name + '") — real defect, report rather than paper over.'));
}

System.debug(LoggingLevel.INFO, 'FIX VERDICT: COMPLETE');
