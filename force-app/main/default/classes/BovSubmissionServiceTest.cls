/**
 * @description Tests BovSubmissionService — the BOV broker REPLACEMENT (design DEV-6), the first
 * `Bov*Service` in the repo. Added 2026-08-19 with the disposition flow redesign, backing
 * `BovController.replaceSelectedBroker` / `c/bovReplaceBrokerModal`.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * NO 251-RECORD BULK TEST — .claude/rules/bulk-test-rule.md PER-TRANSACTION-SINGLETON
 * EXEMPTION APPLIES. RECORDED HERE PER THE CLASS HEADER'S OWN INSTRUCTION.
 * ─────────────────────────────────────────────────────────────────────────────────────
 * `replaceSelectedBroker` is a per-transaction-singleton @AuraEnabled operation invoked once per
 * modal click: one disposition, no loop over records, no trigger behind it. There is no second
 * batch chunk for 251 records to force. The submission WRITE is still proven as a single bulk DML
 * over however many submissions the disposition has — tested at 3, which is enough to exercise
 * the exclusivity swap (one incumbent demoted, one challenger promoted, one bystander untouched).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 2026-08-20 — THE HISTORY ROW (Tranche 2 Workstream B, design D4.3)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * `replaceSelectedBroker` now takes `reason` and `notes` and writes a fourth record: one
 * `BOV_Broker_Change__c`. Three of the tests below exist ONLY for that write, and the most
 * important of them is not any of the happy-path ones — it is
 * `lockedDisposition_refusesTheWholeReplacementAndRollsBack`, which now also asserts that NO
 * history row survives a refused replacement. A history row that outlives its own rolled-back
 * transaction is a durable, reportable claim that a broker changed when none did; that assertion is
 * the falsifier for "the insert is inside the savepoint", and it fails if anyone moves the insert
 * out of the try block or commits it separately.
 *
 * ⚠ The order of the writes is asserted INDIRECTLY, by that rollback test, and cannot be asserted
 * directly from Apex — there is no observable "which DML ran first" after a successful transaction.
 * If the insert is ever moved BEFORE the parent stamp, the rollback test still passes; what breaks
 * is the guarantee that history is only written once the swap has actually succeeded. The service's
 * own header carries that instruction; this note records that no test enforces it.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 2026-08-21 — THE "SELECT BROKER" ENTRY POINT (first appointment)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * `c/bovComparisonMatrix` gained a second broker button that reaches THIS SAME METHOD. No new
 * public method, no new signature, and deliberately so — a second server path would duplicate the
 * exclusivity swap, the approval revocation, the savepoint and the history writer, four invariants
 * that could each drift. What IS new is behavioural and is covered by four tests below:
 *   - the returned String branches on `outgoing == null` ("Broker appointed…" vs "Broker
 *     replaced…"), asserted in BOTH directions on BOTH paths;
 *   - `Initial Appointment` reaches `Reason__c` and is proven to exist in the restricted picklist;
 *   - `Initial Appointment` is REFUSED, before any write, when an incumbent actually exists;
 *   - the converse is deliberately NOT refused, and that trade is pinned by its own test.
 *

 * @see force-app/main/default/classes/BovSubmissionService.cls
 * @author Unit Testing Agent
 */
@isTest
private class BovSubmissionServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    private static Map<Id, BOV_Submission__c> submissionsById(Id dispositionId) {
        return new Map<Id, BOV_Submission__c>([
            SELECT Id, Submission_Status__c, Approval_Status__c, Broker_Firm__c,
                   Is_Manually_Appointed__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
        ]);
    }

    /** A reason is REQUIRED by the service, so every positive-path call must supply one. */
    private static final String REASON = 'Performance Issue';

    /**
     * The history rows written against one disposition, newest first.
     *
     * ⚠ QUERIED DIRECTLY RATHER THAN THROUGH `BovBrokerChangeSelector`, DELIBERATELY. A test of the
     * WRITER must not be able to pass because the READER agrees with it — the selector is
     * `WITH USER_MODE` and this query is not, so a future FLS regression that blanks the card would
     * leave these assertions correctly green and the selector's own test correctly red.
     */
    private static List<BOV_Broker_Change__c> historyFor(Id dispositionId) {
        return [
            SELECT Id, Outgoing_BOV_Submission__c, Incoming_BOV_Submission__c,
                   Outgoing_Broker__c, Incoming_Broker__c,
                   Outgoing_Broker_Firm__c, Incoming_Broker_Firm__c,
                   Reason__c, Notes__c, Entry_DateTime__c, Logged_By__c
            FROM BOV_Broker_Change__c
            WHERE Disposition__c = :dispositionId
            ORDER BY Entry_DateTime__c DESC, Name DESC
        ];
    }

    @isTest
    static void replacesTheIncumbentAndStampsTheParent() {
        Disposition__c d = dispositionAt('BOV Outreach');
        // 🔴 Broker_Firm__c IS PINNED VIA Broker__c, NOT A HAND-TYPED LITERAL, AS OF 2026-08-20
        // (Tranche 2, requirements §3 D1) — see TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Old Incumbent', true).Id;
        incumbent.Submission_Status__c = 'Selected';
        incumbent.Approval_Status__c = 'Approved';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = TestDataFactory.createBrokerContactWithFirm('JLL - New Challenger', true).Id;
        challenger.Submission_Status__c = 'Backup';
        BOV_Submission__c bystander = TestDataFactory.createBovSubmission(d.Id, false);
        bystander.Broker__c = TestDataFactory.createBrokerContactWithFirm('Cushman - Bystander', true).Id;
        bystander.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger, bystander };

        Test.startTest();
        String msg = BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, REASON, 'Missed two marketing deadlines.');
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.areEqual('Backup', after.get(incumbent.Id).Submission_Status__c,
            'The old incumbent must be demoted to Backup');
        Assert.isNull(after.get(incumbent.Id).Approval_Status__c,
            '🔴 THE INCUMBENT\'S APPROVAL STATUS MUST BE REVOKED — an Approved status on a demoted '
            + 'broker reads as an appointment nobody made');
        Assert.areEqual('Selected', after.get(challenger.Id).Submission_Status__c,
            'The challenger must be promoted to Selected');
        Assert.isNull(after.get(challenger.Id).Approval_Status__c,
            'The challenger must arrive with a CLEAR approval status, requiring a fresh approval');
        // ── 🔴 ADDED 2026-08-24, AND IT IS THE PAIR OF THE ASSERTION IMMEDIATELY ABOVE ──
        // Clearing Approval_Status__c (correct — the replacement needs a fresh approval) also
        // zeroes two of the three legs of BovAutoSelectionService's LOCK. This flag is the third,
        // and without it automatic re-selection would UNLOCK and silently undo this user's
        // deliberate pick on the very next BOV save. The end-to-end proof is
        // BovAutoSelectionServiceTest.replaceBrokerAfterARejection_isNotUndoneByTheNextSave; this
        // assertion pins the WRITE itself, so a regression fails in the class that caused it.
        Assert.isTrue(after.get(challenger.Id).Is_Manually_Appointed__c,
            '🔴 The challenger must be stamped Is_Manually_Appointed__c — it is what locks '
            + 'automatic re-selection out of a broker a human deliberately chose');
        Assert.isFalse(after.get(incumbent.Id).Is_Manually_Appointed__c,
            'and the DEMOTED row must not be — the flag marks who was chosen, not who was replaced');
        Assert.areEqual('Backup', after.get(bystander.Id).Submission_Status__c,
            'A third, untouched submission must be left exactly as it was');
        Assert.areEqual('JLL - New Challenger',
            [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id].Selected_Broker__c,
            'The Disposition must be stamped with the new broker\'s firm');
        Assert.isTrue(msg.contains('must be approved'),
            'The confirmation must warn that a fresh approval is required: ' + msg);
        // The other half of the 2026-08-21 branch — see `noIncumbent_degradesToAnAppointment`.
        // Asserted here too, in both directions, so a change that collapses the two strings back
        // into one fails on BOTH paths rather than only the new one.
        Assert.isTrue(msg.contains('Broker replaced'),
            'A replacement must say so: ' + msg);
        Assert.isFalse(msg.contains('appointed'),
            'and must not read as a first appointment: ' + msg);
    }

    /** "Replace" degrades cleanly to "appoint" when there is no incumbent to demote. */
    @isTest
    static void noIncumbent_degradesToAnAppointment() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert challenger;

        Test.startTest();
        String msg = BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, null);
        Test.stopTest();

        Assert.areEqual('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :challenger.Id].Submission_Status__c,
            'With nothing to demote, the challenger is simply promoted');
        // 🔴 THE SENTENCE IS BRANCHED ON WHAT HAPPENED (2026-08-21). "Broker replaced" was wrong
        // here: nothing was replaced. Asserted in BOTH directions — the presence of "appointed" and
        // the ABSENCE of "replaced" — because a message containing both words would satisfy a
        // one-sided check while still telling the user a broker was demoted.
        Assert.isTrue(msg.contains('Broker appointed'),
            'A first appointment must say so: ' + msg);
        Assert.isFalse(msg.contains('replaced'),
            'and must NOT claim a replacement that did not happen: ' + msg);
        Assert.isTrue(msg.contains('must be approved'),
            'while still carrying the fresh-approval consequence, which is identical either way');

        // The history row is still written — an appointment IS a change worth recording — and its
        // outgoing columns are blank rather than absent.
        List<BOV_Broker_Change__c> history = historyFor(d.Id);
        Assert.areEqual(1, history.size(),
            'An appointment with no incumbent must still be recorded, not skipped');
        Assert.isNull(history[0].Outgoing_BOV_Submission__c,
            'There was no incumbent, so the outgoing submission must be blank — not the challenger');
        Assert.isNull(history[0].Outgoing_Broker_Firm__c,
            'And no outgoing firm may be invented');
        Assert.areEqual(challenger.Id, history[0].Incoming_BOV_Submission__c,
            'The appointed submission must still be recorded as incoming');
        Assert.isNull(history[0].Notes__c,
            'Notes are OPTIONAL — a null must round-trip as a null, not as an empty string or a '
            + 'DML failure');
    }

    /**
     * 🔴 THE HISTORY ROW IS THE POINT OF THE 2026-08-20 CHANGE, AND THE FIRM SNAPSHOTS ARE THE
     * POINT OF THE HISTORY ROW. Both Contact lookups are `deleteConstraint SetNull` and
     * `scripts/seed-broker-contacts.apex` mass-deletes every broker Contact, so a row that leaned
     * on the lookups for the firm name would read blank after any seed re-run. This test asserts
     * the TEXT columns carry the firms, and — the falsifier for the same claim — that they still
     * carry them after the Contacts are deleted out from under the row.
     */
    @isTest
    static void historyRow_stampsBothFirmsAndSurvivesTheBrokerContactsBeingDeleted() {
        Disposition__c d = dispositionAt('BOV Outreach');
        Contact outgoingBroker = TestDataFactory.createBrokerContactWithFirm('CBRE - Old Incumbent', true);
        Contact incomingBroker = TestDataFactory.createBrokerContactWithFirm('JLL - New Challenger', true);
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = outgoingBroker.Id;
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = incomingBroker.Id;
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, 'Better BOV Received', 'JLL came in 600k higher.');
        Test.stopTest();

        List<BOV_Broker_Change__c> history = historyFor(d.Id);
        Assert.areEqual(1, history.size(), 'Exactly ONE history row per replacement');
        BOV_Broker_Change__c row = history[0];
        Assert.areEqual(incumbent.Id, row.Outgoing_BOV_Submission__c, 'Outgoing submission');
        Assert.areEqual(challenger.Id, row.Incoming_BOV_Submission__c, 'Incoming submission');
        Assert.areEqual(outgoingBroker.Id, row.Outgoing_Broker__c, 'Outgoing broker Contact');
        Assert.areEqual(incomingBroker.Id, row.Incoming_Broker__c, 'Incoming broker Contact');
        Assert.areEqual('CBRE - Old Incumbent', row.Outgoing_Broker_Firm__c,
            '🔴 THE OUTGOING FIRM MUST BE STAMPED AS TEXT, not left to the Contact lookup');
        Assert.areEqual('JLL - New Challenger', row.Incoming_Broker_Firm__c,
            '🔴 And so must the incoming firm');
        Assert.areEqual('Better BOV Received', row.Reason__c, 'The reason must be recorded');
        Assert.areEqual('JLL came in 600k higher.', row.Notes__c, 'And the notes verbatim');
        Assert.areEqual(UserInfo.getUserId(), row.Logged_By__c, 'The actor must be recorded');
        Assert.isNotNull(row.Entry_DateTime__c,
            'The write time IS the event time — there is no effectiveDate parameter to supply one');

        // ── THE FALSIFIER ────────────────────────────────────────────────────
        // Reproduces scripts/seed-broker-contacts.apex's mass delete. Both lookups go null with no
        // error whatsoever; if the firms had been read through them, the row would now be anonymous.
        delete new List<Contact>{ outgoingBroker, incomingBroker };
        BOV_Broker_Change__c afterDelete = historyFor(d.Id)[0];
        Assert.isNull(afterDelete.Outgoing_Broker__c,
            'PRECONDITION: SetNull must have blanked the outgoing lookup, or this proves nothing');
        Assert.isNull(afterDelete.Incoming_Broker__c,
            'PRECONDITION: and the incoming lookup');
        Assert.areEqual('CBRE - Old Incumbent', afterDelete.Outgoing_Broker_Firm__c,
            '🔴 THE SNAPSHOT MUST SURVIVE THE CONTACT — this is the entire reason the Text column '
            + 'exists alongside the lookup');
        Assert.areEqual('JLL - New Challenger', afterDelete.Incoming_Broker_Firm__c,
            '🔴 Both of them');
    }

    /**
     * ⚠ REPOINTED 2026-08-24, SAME DAY IT WAS WRITTEN. This test was
     * `aPreferredBrokerIsRefusedAndNeitherSwapsNorRecords` and pinned a server-side refusal of ANY
     * preferred submission. Gate Q-5 was then answered NO and that refusal was removed — see the
     * retraction at the top of `BovSubmissionService`, where the deleted constant used to live.
     * The test is repointed rather than deleted because the SCENARIO is still the one that matters:
     * what happens when someone tries to Replace Broker onto the preferred row that already holds
     * the appointment.
     *
     * 🔴 THE ANSWER IS `ALREADY_SELECTED_MESSAGE`, AND IT ARRIVES WITHOUT ANY PREFERRED-SPECIFIC
     * CODE. That is the whole point of the reversal: promoting a broker to itself is not an
     * operation, the generic check already says so, and a preferred-specific rule would have
     * blocked the intended steady state instead.
     *
     * ⚠ IT ALSO PINS THE THING THE REMOVAL COULD HAVE BROKEN: that the refusal still lands BEFORE
     * any write, so a refused Replace Broker leaves the appointment and the history log untouched.
     */
    @isTest
    static void replacingOntoThePreferredIncumbent_isRefusedAsAlreadySelected() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c scored = TestDataFactory.createBovSubmission(d.Id, false);
        scored.Submission_Status__c = 'Selected';
        BOV_Submission__c preferred = TestDataFactory.createBovSubmission(d.Id, false);
        preferred.Submission_Status__c = 'Backup';
        preferred.Is_Preferred_Broker__c = true;
        insert new List<BOV_Submission__c>{ scored, preferred };

        Map<Id, BOV_Submission__c> before = submissionsById(d.Id);
        Assert.areEqual('Selected', before.get(preferred.Id).Submission_Status__c,
            'PRECONDITION — and it is the whole point of the 2026-08-24 decision: auto-selection '
            + 'promoted the preferred row on insert, so it is LEGITIMATELY the Selected broker. '
            + 'Backup here means BovAutoSelectionService is not treating the flag as a winner.');
        Assert.isFalse(before.get(preferred.Id).Is_Manually_Appointed__c,
            'PRECONDITION: it got there WITHOUT the manual-appointment lock, which is what keeps '
            + 'unflagging (or deleting) it able to hand the sale back to scoring');

        Test.startTest();
        try {
            BovSubmissionService.replaceSelectedBroker(
                d.Id, preferred.Id, REASON, 'Trying to appoint the broker that already holds it.');
            Assert.fail('Replacing a broker with ITSELF must be refused — the user asked for a '
                + 'CHANGE and there is none to make.');
        } catch (BovSubmissionService.BovSubmissionException e) {
            Assert.isTrue(e.getMessage().contains('already the selected broker'),
                'The generic already-Selected refusal is what covers this now; a preferred-specific '
                + 'message would mean the removed Q-5 rule has been restored: ' + e.getMessage());
        }
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.isFalse(after.get(preferred.Id).Is_Manually_Appointed__c,
            '🔴 A REFUSED replace must not have stamped the manual-appointment lock. If it did, '
            + 'unflagging this broker will silently do nothing forever.');
        Assert.areEqual('Selected', after.get(preferred.Id).Submission_Status__c,
            'The refusal changes nothing — the preferred broker keeps the appointment it holds by '
            + 'virtue of the flag');
        Assert.areEqual('Backup', after.get(scored.Id).Submission_Status__c,
            'and the scored response it displaced stays a Backup');
        Assert.areEqual(0, historyFor(d.Id).size(), 'A refused replacement records nothing');
    }

    /**
     * 🔴 THE OTHER HALF OF THE REVERSAL: a preferred row that is NOT the incumbent IS now promotable
     * through Replace Broker, and that is the DELIBERATE consequence of answering Q-5 "NO".
     *
     * ⚠ THIS TEST DOCUMENTS A RESIDUAL RATHER THAN A FEATURE, AND SAYS SO. The promotion also
     * stamps `Is_Manually_Appointed__c`, which permanently locks auto-selection out — so unflagging
     * this broker afterwards will NOT hand the sale back to scoring. That trapdoor is unreachable
     * from the UI (the matrix's picker filters preferred rows out) and needs a deliberate API call.
     * It is pinned here so the behaviour is VISIBLE and a future decision to close it has a test to
     * flip, rather than being discovered in UAT. See the retraction at the top of
     * `BovSubmissionService` for the narrow fix if it is ever wanted.
     */
    @isTest
    static void replacingOntoANonIncumbentPreferredRow_succeedsAndLocksAutoSelectionOut() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c older = TestDataFactory.createBovSubmission(d.Id, false);
        older.Is_Preferred_Broker__c = true;
        insert older;
        BOV_Submission__c newer = TestDataFactory.createBovSubmission(d.Id, false);
        newer.Is_Preferred_Broker__c = true;
        insert newer;
        Assert.areEqual('Selected',
            submissionsById(d.Id).get(newer.Id).Submission_Status__c,
            'PRECONDITION: the NEWEST preferred row holds the appointment, so `older` is a '
            + 'preferred row that is NOT the incumbent — the only shape this path can be reached '
            + 'with');

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(
            d.Id, older.Id, REASON, 'Deliberate API call onto a superseded preferred row.');
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.areEqual('Selected', after.get(older.Id).Submission_Status__c,
            'It is PERMITTED since gate Q-5 was answered NO — no preferred-specific refusal remains');
        Assert.isTrue(after.get(older.Id).Is_Manually_Appointed__c,
            '⚠ AND IT STAMPS THE PERMANENT LOCK. This is the named residual of the reversal, not an '
            + 'oversight: auto-selection is now locked out of this disposition for good, so '
            + 'unflagging this broker later will NOT resume scoring.');
        Assert.areEqual('Backup', after.get(newer.Id).Submission_Status__c,
            'and the preferred row it displaced is demoted like any other incumbent');
    }

    /**
     * The reason is required by the SERVER, not only by the modal's combobox — this class's
     * subject already refuses to depend on a client affordance for correctness (see the
     * cross-disposition test). A refusal must also write NOTHING.
     */
    @isTest
    static void blankReason_isRefusedAndNeitherSwapsNorRecords() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        Integer refusals = 0;
        for (String emptyReason : new List<String>{ null, '', '   ' }) {
            try {
                BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, emptyReason, 'notes');
                Assert.fail('A blank reason must be refused, not recorded as a blank');
            } catch (BovSubmissionService.BovSubmissionException e) {
                refusals++;
                Assert.isTrue(e.getMessage().contains('reason'),
                    'The refusal must name the missing reason: ' + e.getMessage());
            }
        }
        Test.stopTest();

        Assert.areEqual(3, refusals, 'null, empty and whitespace-only reasons must all be refused');
        Assert.areEqual(0, historyFor(d.Id).size(), 'A refused replacement records nothing');
        Assert.areEqual('Selected',
            submissionsById(d.Id).get(incumbent.Id).Submission_Status__c,
            'And the guard must run BEFORE any write — the incumbent is untouched');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FIRST APPOINTMENT — the "Select Broker" entry point (2026-08-21)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // 🔴 THERE IS NO `appointSelectedBroker` AND THESE TESTS ARE PART OF WHY. Both client buttons
    // reach THIS method; a second server path would be a second implementation of exclusivity, of
    // the approval revocation, of the savepoint and of the history writer.

    /**
     * The first appointment produces a history row attributed to `Initial Appointment`.
     *
     * ⚠ THE REASON VALUE IS THE POINT, NOT THE SWAP. Every OTHER `Reason__c` value presupposes a
     * predecessor (`Performance Issue`, `Better BOV Received`, `Broker Withdrew`,
     * `Company Decision`, `Other`), so before this value existed a first pick could only be logged
     * as "Other" — the un-attributed row the whole broker-change log exists to prevent.
     *
     * ⚠ IT ALSO PROVES THE VALUE IS DEPLOYED. `Reason__c` is a RESTRICTED picklist and restricted
     * picklists ARE enforced by Apex DML in this org, so if `Initial Appointment` were absent from
     * the field metadata this insert would fail with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`
     * rather than quietly storing a stray string. That makes this test the falsifier for the
     * literal held in `BovSubmissionService.REASON_INITIAL_APPOINTMENT` and its twin in
     * `c/bovReplaceBrokerModal` — neither can drift from the metadata without failing here.
     */
    @isTest
    static void firstAppointment_recordsInitialAppointmentOnTheHistoryRow() {
        Disposition__c d = dispositionAt('BOV Outreach');
        Contact broker = TestDataFactory.createBrokerContactWithFirm('JLL - First Pick', true);
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = broker.Id;
        challenger.Submission_Status__c = 'Backup';
        insert challenger;

        Test.startTest();
        String msg = BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, 'Initial Appointment', 'Chosen from four BOV responses.');
        Test.stopTest();

        List<BOV_Broker_Change__c> history = historyFor(d.Id);
        Assert.areEqual(1, history.size(), 'A first appointment is still one history row');
        Assert.areEqual('Initial Appointment', history[0].Reason__c,
            '🔴 A RESTRICTED PICKLIST VALUE THAT MUST EXIST IN THE ORG. If this reads back as '
            + 'anything else the value was never deployed and the DML would have thrown.');
        Assert.isNull(history[0].Outgoing_Broker__c,
            'and there is no predecessor to attribute anything to');
        Assert.areEqual(challenger.Id, history[0].Incoming_BOV_Submission__c, 'incoming submission');
        Assert.isTrue(msg.contains('Broker appointed'), 'and the appoint wording: ' + msg);
    }

    /**
     * 🔴 THE STALE-CLIENT RACE, REFUSED ON THE SERVER (2026-08-21).
     *
     * `c/bovComparisonMatrix` decides which of "Select Broker" / "Replace Broker" to render from a
     * CACHEABLE wire. So an analyst can open Select Broker on a disposition with no incumbent, a
     * colleague can appoint one in another tab, and the first analyst can then confirm. Without
     * this guard the swap would succeed as an ordinary replacement while its history row claimed
     * `Initial Appointment` — a durable, append-only, reportable assertion that this was a first
     * pick, sitting next to the broker it demoted. Same family of defect as a blank `Reason__c`.
     *
     * ⚠ WHAT THIS TEST DOES *NOT* CLAIM. Only ONE direction is enforced: `Initial Appointment` is
     * refused when there IS an incumbent. A predecessor-presupposing value on a FIRST appointment
     * is NOT refused, because doing so would require the service to hold a copy of the whole
     * `Reason__c` value set — the exact divergence-with-the-metadata that
     * `REASON_REQUIRED_MESSAGE`'s note refuses to create. That asymmetry is deliberate; do not
     * "complete" it by enumerating the other five values in Apex.
     */
    @isTest
    static void initialAppointmentWithAnIncumbent_isRefusedBeforeAnyWrite() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        incumbent.Approval_Status__c = 'Approved';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        Boolean refused = false;
        try {
            BovSubmissionService.replaceSelectedBroker(
                d.Id, challenger.Id, 'Initial Appointment', 'notes');
            Assert.fail('An "Initial Appointment" on a disposition WITH an incumbent must be '
                + 'refused — it would misattribute a replacement');
        } catch (BovSubmissionService.BovSubmissionException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('Replace Broker'),
                'The refusal must name the OTHER button, which is the user\'s actual fix: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The misattribution must be refused');
        // 🔴 THE GUARD RUNS BEFORE ANY WRITE. Without these three lines the test would pass on an
        // implementation that swapped the brokers and then threw — leaving the invariant changed by
        // a call the user was told had failed.
        Assert.areEqual(0, historyFor(d.Id).size(), 'A refused call records nothing');
        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.areEqual('Selected', after.get(incumbent.Id).Submission_Status__c,
            'The incumbent must be untouched');
        Assert.areEqual('Approved', after.get(incumbent.Id).Approval_Status__c,
            'and its approval must NOT have been revoked by a refused call');
    }

    /**
     * ⚠ THE CONVERSE IS NOT GUARDED, AND THAT IS PINNED HERE SO NOBODY "COMPLETES" IT BY ACCIDENT.
     * A predecessor-presupposing reason on a first appointment is ACCEPTED, because refusing it
     * would need a copy of the `Reason__c` value set in Apex. This test is the record of that
     * trade: if someone adds the reverse check, THIS test fails and they are forced to read the
     * argument in `FIRST_APPOINTMENT_ONLY_MESSAGE` before deciding.
     */
    @isTest
    static void firstAppointmentWithAReplacementReason_isAcceptedByDesign() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert challenger;

        Test.startTest();
        String msg = BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, 'Better BOV Received', null);
        Test.stopTest();

        Assert.areEqual('Better BOV Received', historyFor(d.Id)[0].Reason__c,
            'Accepted as sent — the server does not enumerate the value set, only the ONE value '
            + 'that has a server-checkable rule attached');
        Assert.isTrue(msg.contains('Broker appointed'),
            'and the MESSAGE still comes from what happened, not from the reason: ' + msg);
    }

    @isTest
    static void challengerAlreadySelected_isRefusedRatherThanTreatedAsANoOp() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c already = TestDataFactory.createBovSubmission(d.Id, false);
        already.Submission_Status__c = 'Selected';
        insert already;

        Test.startTest();
        Boolean refused = false;
        try {
            BovSubmissionService.replaceSelectedBroker(d.Id, already.Id, REASON, null);
            Assert.fail('Replacing a broker with itself must be refused, not silently no-op');
        } catch (BovSubmissionService.BovSubmissionException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('already the selected broker'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'An already-selected challenger must be refused');
    }

    @isTest
    static void challengerNotOnThisDisposition_isRefused() {
        Disposition__c d = dispositionAt('BOV Outreach');
        Disposition__c other = dispositionAt('BOV Outreach');
        BOV_Submission__c foreign = TestDataFactory.createBovSubmission(other.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            BovSubmissionService.replaceSelectedBroker(d.Id, foreign.Id, REASON, null);
            Assert.fail('A submission belonging to a DIFFERENT disposition must be refused');
        } catch (BovSubmissionService.BovSubmissionException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('does not belong to this disposition'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A cross-disposition submission Id must be refused');
    }

    @isTest
    static void nullIds_throwTheNoRecordMessage() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, true);

        Test.startTest();
        Boolean refusedNullDisposition = false;
        try {
            BovSubmissionService.replaceSelectedBroker(null, sub.Id, REASON, null);
        } catch (BovSubmissionService.BovSubmissionException e) {
            refusedNullDisposition = true;
        }
        Boolean refusedNullSubmission = false;
        try {
            BovSubmissionService.replaceSelectedBroker(d.Id, null, REASON, null);
        } catch (BovSubmissionService.BovSubmissionException e) {
            refusedNullSubmission = true;
        }
        Test.stopTest();

        Assert.isTrue(refusedNullDisposition, 'A null dispositionId must throw before any query');
        Assert.isTrue(refusedNullSubmission, 'A null newSubmissionId must throw before any query');
    }

    /**
     * 🔴 A LOCKED DISPOSITION REFUSES THE WHOLE REPLACEMENT — CORRECT, NOT UNFORTUNATE. While
     * `Sale_Decision_Approval` is pending, `recordEditability = AdminOnly` locks the Disposition,
     * and the parent stamp throws ENTITY_IS_LOCKED. The savepoint means the submission swap that
     * already succeeded must roll back too, rather than leaving `Selected_Broker__c` disagreeing
     * with which submission is actually Selected.
     *
     * 🔴 MUST RUN AS A NON-ADMIN. `AdminOnly` means exactly what it says — a user holding
     * "Modify All Data" (the deploying test-running admin, everywhere else in this class) can
     * still edit the record while the approval is pending, so this test would pass vacuously
     * under the admin: it would never reach ENTITY_IS_LOCKED at all. Only a genuine
     * non-admin disposition driver is refused by the lock.
     */
    @isTest
    static void lockedDisposition_refusesTheWholeReplacementAndRollsBack() {
        Disposition__c d = dispositionAt('Disposition Readiness');
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(d.Id);
        Approval.ProcessResult result = Approval.process(req);
        Assert.isTrue(result.isSuccess(), 'PRECONDITION: Sale_Decision_Approval must accept this '
            + 'disposition at Readiness, locking it, or this test proves nothing');

        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        // 🔴 THE USER IS BUILT INSIDE A SAME-USER System.runAs, NOT INLINE. Building a User (a
        // setup object) directly here would hit MIXED_DML_OPERATION against the Disposition__c /
        // BOV_Submission__c DML above — System.runAs opens a fresh DML-tracking context even when
        // it runs as the CURRENT user, which is the standard, documented way to mix setup and
        // non-setup DML in one test method without an @TestSetup detour.
        User dispositionDriver;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            dispositionDriver = buildDispositionDriverUser('bovlock1');
        }

        Test.startTest();
        Boolean refused = false;
        DispositionActionPermissionService.clearCache();
        System.runAs(dispositionDriver) {
            try {
                BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, 'notes');
                Assert.fail('A locked Disposition must refuse the whole replacement');
            } catch (BovSubmissionService.BovSubmissionException e) {
                refused = true;
            }
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'The lock must surface as a refusal, not an unhandled DmlException');
        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.areEqual('Selected', after.get(incumbent.Id).Submission_Status__c,
            '🔴 THE SUBMISSION SWAP MUST ROLL BACK — a savepoint-less implementation would leave the '
            + 'incumbent demoted while the parent stamp failed, disagreeing about who is Selected');
        Assert.areEqual('Backup', after.get(challenger.Id).Submission_Status__c,
            'And the challenger must still read Backup');
        Assert.areEqual(0, historyFor(d.Id).size(),
            '🔴 NO HISTORY ROW MAY SURVIVE A REFUSED REPLACEMENT. This is the falsifier for "the '
            + 'insert is the LAST DML inside the existing savepoint": an insert placed outside the '
            + 'try, or committed separately, leaves behind a durable, reportable, append-only claim '
            + 'that this disposition changed brokers — next to a disposition that did not. That is '
            + 'strictly worse than no history at all.');
    }

    /**
     * A Standard User holding `DPEG_Disposition_Edit` — NOT an admin.
     *
     * ⚠ THIS USED TO ASSIGN TWO SETS ("Disposition_Deal_Driver + DPEG_Disposition_Edit") AND NOW
     * ASSIGNS ONE, WITHOUT LOSING A SINGLE GRANT. The user retired `Disposition_Deal_Driver` on
     * 2026-08-19 and moved the `Disposition_Deal_Actions` custom permission onto
     * `DPEG_Disposition_Edit`, so that one set now carries BOTH halves this fixture needs: the
     * object CRUD/FLS on Disposition__c / BOV_Submission__c, and the authorization token
     * `BovSubmissionService.replaceSelectedBroker` asserts through
     * `DispositionActionPermissionService`. The persona this fixture models is unchanged.
     *
     * 🔴 THE QUERY BELOW IS A NAME LOOKUP, WHICH IS WHY THIS EDIT WAS MANDATORY RATHER THAN TIDY.
     * `WHERE Name IN (...)` against a DELETED set does not error — it silently returns one row
     * instead of two, the driver grant vanishes, and every test using this fixture fails on a
     * PERMISSION DENIAL that reads like a broken service. (A `WHERE Name =` / `LIMIT 1` lookup fails
     * even more confusingly, with `List has no rows for assignment to SObject`; `ContactSelectorTest`
     * still carries a live instance of that trap against the long-gone `DPEG_Acquisitions`.)
     */
    private static User buildDispositionDriverUser(String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = tag.left(8),
            Email = tag + '@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Test ' + tag,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = tag + '.' + DateTime.now().getTime()
                + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
        insert u;
        List<PermissionSet> sets = [
            SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Disposition_Edit'
        ];
        Assert.areEqual(1, sets.size(),
            'FIXTURE: DPEG_Disposition_Edit must exist and must carry the Disposition_Deal_Actions '
            + 'custom permission (moved there 2026-08-19 when Disposition_Deal_Driver was retired). '
            + 'Assigning nothing here would surface as a permission DENIAL in every test that uses '
            + 'this user — which reads like a broken service rather than a missing fixture.');
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        return u;
    }
}
