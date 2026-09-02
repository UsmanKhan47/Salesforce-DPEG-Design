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
 * ⚠ RE-ARGUED FROM SCRATCH ON 2026-09-01, NOT INHERITED, BECAUSE THE METHOD'S SHAPE CHANGED.
 * Tranche 4 item 5 put a FOURTH object in this transaction (`Broker_Listing__c`, write 3a) and a
 * SECOND query in it. An exemption that is silently carried across a change to its own subject is
 * how one stops being true — `.claude/rules/bulk-test-rule.md`'s own narrowing note records a case
 * where exactly that happened, and three of four classes lost the exemption when a caller started
 * looping. THE EXEMPTION HOLDS HERE, and on the same ground rather than on precedent: the property
 * the 251 rule tests for is per-RECORD cost, and write 3a adds at most ONE row per click regardless
 * of how many submissions the disposition has. It multiplies the DML count by a constant, not by
 * the record count, and there is still no loop and no trigger driving this method. A 251-record
 * test would exercise no additional path and would burn DML statements proving nothing.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 2026-08-20 — THE HISTORY ROW (Tranche 2 Workstream B, design D4.3)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * `replaceSelectedBroker` now takes `reason` and `notes` and writes a fourth record: one
 * `BOV_Broker_Change__c`. Three of the tests below exist ONLY for that write, and the most
 * important of them is not any of the happy-path ones — it is
 * `lockedDisposition_refusesTheWholeReplacementAndRollsBack`, which now also asserts that NO
 * history row survives a refused replacement.
 * ⚠ AMENDED 2026-09-02 (code review W1) — THAT TEST HAS A BLIND SPOT AND IT IS NOT FIXABLE IN
 * PLACE. It locks a disposition at `Disposition Readiness`, where no `Broker_Listing__c` exists, so
 * `saleIsListed` is FALSE and write 3a never executes inside it. Everything the paragraph above
 * claims for the history row is still true; nothing it claims extends to the listing append.
 * `refusedReplacementRollsBackTheListingAppend` is the test that covers that, on a fixture that IS
 * listed, and it explains at length why it does not use the record-type refusal route. A history row that outlives its own rolled-back
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
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 2026-09-02 — WRITE 3a's ROLLBACK, AND THE LOOKUP STAMP (code review W1 + S1)
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Two additions, and the first one is the interesting one:
 *
 *   - `refusedReplacementRollsBackTheListingAppend` — a refused replacement on a LISTED sale must
 *     leave ZERO new `Broker_Listing__c` rows, with a presence control on the same fixture proving
 *     one WOULD have been appended. It refuses by passing a `Reason__c` value outside that field's
 *     restricted value set, and its javadoc carries the full argument for why the record-type
 *     route the service header documents would be VACUOUS here — since S1, write 3a carries a
 *     Contact lookup with the same filter, so a flipped Contact refuses BEFORE write 3a inserts.
 *
 *   - `replaceAtActiveListing_appendsTheIncomingBrokersOwnListing` gained three assertions for the
 *     new `Broker_Listing__c.Broker__c` stamp, including a NEGATIVE one pinning that the
 *     auto-created row's lookup is still blank. That negative is a residual being recorded, not a
 *     behaviour being endorsed — read it before "fixing" it.
 *
 * ⚠ NO NEW FIXTURE HELPERS AND NO NEW FACTORY METHODS. `onMarketAt` / `brokerPair` / `listingsOn`
 * are reused verbatim; `listingsOn` gained `Broker__c` in its SELECT, which is a plain test query
 * (not `WITH USER_MODE`), so widening it cannot take any other test down on FLS.
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
        // ⚠ AMENDED 2026-08-24 (two-slot model). This used to read "and the scored response it
        // DISPLACED stays a Backup" — a sentence about the retracted rule in which a preferred row
        // evicted the scored winner. It never did displace anything: the two rows hold different
        // slots and both are legitimately Selected. What is being asserted is unchanged in
        // substance — a REFUSED replace changes nothing — only the expected value is now the
        // truthful one.
        Assert.areEqual('Selected', after.get(scored.Id).Submission_Status__c,
            'and the scored response beside it keeps ITS slot: a refused replace writes nothing, '
            + 'and the two slots are independent even when the write succeeds');
        Assert.areEqual(0, historyFor(d.Id).size(), 'A refused replacement records nothing');
    }

    /**
     * 🔴 REPOINTED 2026-08-24 — AND THE REPOINT IS THE FINDING. This test was
     * `replacingOntoANonIncumbentPreferredRow_succeedsAndLocksAutoSelectionOut` and PINNED A
     * RESIDUAL: a superseded preferred row could be promoted through Replace Broker, which stamped
     * `Is_Manually_Appointed__c` and locked auto-selection out of the sale for good. Its own
     * comment said the trapdoor was "unreachable from the UI... and needs a deliberate API call".
     *
     * **THAT RESIDUAL IS NOW CLOSED, AND NOT BY A REFUSAL.** `BovPreferredBrokerService` DELETES
     * the outgoing preferred row when a new one is added, so a "superseded preferred row" no longer
     * exists to be replaced onto — the API call the old test made now fails the service's own
     * membership check (`NOT_ON_DISPOSITION_MESSAGE`), because the row is gone.
     *
     * ⚠ THE TEST IS REPOINTED RATHER THAN DELETED because the SCENARIO is still the one that
     * matters, and because "the row does not exist" and "the row exists and is refused" are very
     * different claims that would otherwise both look like a green suite. If the retirement service
     * is ever removed or made conditional, this test goes red and the old trapdoor is back.
     */
    @isTest
    static void aSupersededPreferredRow_noLongerExistsToBeReplacedOnto() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c older = TestDataFactory.createBovSubmission(d.Id, false);
        older.Is_Preferred_Broker__c = true;
        insert older;
        BOV_Submission__c newer = TestDataFactory.createBovSubmission(d.Id, false);
        newer.Is_Preferred_Broker__c = true;
        insert newer;

        Map<Id, BOV_Submission__c> afterAdd = submissionsById(d.Id);
        Assert.areEqual('Selected', afterAdd.get(newer.Id).Submission_Status__c,
            'PRECONDITION: the NEWEST preferred row holds the preferred slot');
        Assert.isNull(afterAdd.get(older.Id),
            '🔴 PRECONDITION AND POINT: the superseded preferred row is GONE, retired by '
            + 'BovPreferredBrokerService. Finding it here means the retirement did not run and the '
            + 'promote-a-superseded-preferred-row trapdoor is open again.');

        Test.startTest();
        try {
            BovSubmissionService.replaceSelectedBroker(
                d.Id, older.Id, REASON, 'Deliberate API call onto a superseded preferred row.');
            Assert.fail('A retired preferred row cannot be appointed — it does not exist');
        } catch (BovSubmissionService.BovSubmissionException e) {
            Assert.isTrue(e.getMessage().contains('does not belong to this disposition'),
                'The refusal is the ordinary membership check, with no preferred-specific rule '
                + 'anywhere: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual('Selected',
            submissionsById(d.Id).get(newer.Id).Submission_Status__c,
            'and the surviving preferred broker is untouched by the refused call');
    }

    /**
     * 🔴 REPLACE BROKER OPERATES ON THE APPOINTED SLOT ONLY. It must NOT knock the preferred broker
     * out of its own slot — the falsifier for the `&& Is_Preferred_Broker__c != true` clause added
     * to the demotion loop on 2026-08-24.
     *
     * Without that clause a single Replace Broker click on a sale that also has a preferred broker
     * demotes BOTH incumbents, and the history row records the WRONG one as outgoing (the single
     * `Outgoing` slot takes whichever the selector returns first). The user asked to change the
     * scored appointment and silently lost the preferred one, with no row naming it.
     */
    @isTest
    static void replaceBroker_leavesAPreferredBrokerAlone() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        BOV_Submission__c preferred = TestDataFactory.createBovSubmission(d.Id, false);
        preferred.Is_Preferred_Broker__c = true;
        insert preferred;

        Map<Id, BOV_Submission__c> before = submissionsById(d.Id);
        Assert.areEqual('Selected', before.get(preferred.Id).Submission_Status__c,
            'PRECONDITION: the preferred broker holds its slot');
        Assert.areEqual('Selected', before.get(incumbent.Id).Submission_Status__c,
            'PRECONDITION: and the scored incumbent holds the other one, beside it');

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, REASON, 'Swapping the appointed broker.');
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = submissionsById(d.Id);
        Assert.areEqual('Selected', after.get(challenger.Id).Submission_Status__c,
            'the challenger takes the APPOINTED slot');
        Assert.areEqual('Backup', after.get(incumbent.Id).Submission_Status__c,
            'and the row it replaced is demoted');
        Assert.areEqual('Selected', after.get(preferred.Id).Submission_Status__c,
            '🔴 AND THE PREFERRED BROKER IS UNTOUCHED. A Backup here means the demotion loop is '
            + 'still unconditional and Replace Broker is silently retiring preferred brokers.');
        List<BOV_Broker_Change__c> history = historyFor(d.Id);
        Assert.areEqual(1, history.size(), 'exactly one history row for one replacement');
        Assert.areEqual(incumbent.Id, history[0].Outgoing_BOV_Submission__c,
            '🔴 and it names the SCORED incumbent as outgoing, not the preferred broker. This is '
            + 'the assertion that catches the unconditional loop recording the wrong row: with two '
            + 'incumbents the single Outgoing slot takes whichever the selector returned first.');
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

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // TRANCHE 4 ITEM 5 (2026-09-01) — WRITE 3a: THE INCOMING BROKER'S OWN LISTING
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // The feature is an APPEND, never a reset. `Disposition__c.Listing_Date__c` — the MARKETING
    // clock, which feeds `Disposition__c.Days_On_Market__c`, the `Avg_Days_on_Market` report and
    // the `Broker Alert Due` KPI — is not written by this service at all, and
    // `parentsMarketingClockIsNeverRewrittenByAReplacement` is the pin for that.
    //
    // 🔴 THE FIRST TEST BELOW IS THE MOST IMPORTANT ONE IN THIS BLOCK AND IT IS A **NEGATIVE**.
    // A negative that silently stops holding is invisible for months, which is exactly the shape
    // of the defect it guards: Replace Broker is ALSO reachable at BOV Outreach
    // (`dispositionMain.html:42`, `c/bovBrokerPanel`), where no listing exists, and
    // `DispositionStageEntryService.openBrokerListings` idempotency test is SIMPLE PRESENCE —
    // "this disposition already has a broker listing", any listing. So a listing appended at BOV
    // Outreach makes the Active Listing auto-create a PERMANENT NO-OP for that sale.
    //
    // ⚠ EVERY FIXTURE HERE SETS `Listing_Date__c` TO A DATE THAT IS **NOT TODAY**, DELIBERATELY.
    // `TestDataFactory.createDispositions` seeds `Listing_Date__c = Date.today()` on every row, and
    // `openBrokerListings` COPIES the parent's date onto the child. With the factory default, an
    // auto-created listing and an appended one would both read `Date.today()` and every assertion
    // in this block would be unable to tell them apart — the tests would pass whether or not the
    // append happened in the right place. The 40-day-old date is what makes them discriminate.

    /** The marketing clock every fixture in this block starts on: old enough to differ from today. */
    private static final Date MARKETING_START = Date.today().addDays(-40);

    private static List<Broker_Listing__c> listingsOn(Id dispositionId) {
        return [
            SELECT Id, List_Date__c, Broker__c, Broker_Firm__c, Contact_Name__c, Listing_Status__c,
                   Days_On_Market_Live__c
            FROM Broker_Listing__c
            WHERE Disposition__c = :dispositionId
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    /**
     * An on-market disposition INSERTED straight at the given stage with a 40-day-old marketing
     * clock.
     *
     * ⚠ INSERT, NOT AN UPDATE INTO THE STAGE, AND THAT IS WHAT KEEPS THESE FIXTURES SHORT.
     * `All_NDAs_Signed_Before_Progression` blocks an on-market disposition from MOVING into Active
     * Listing without a signed buyer NDA, but the rule is `ISCHANGED`-only and deliberately exempts
     * an insert straight at a gated stage (`DispositionStageEntryServiceTest` states this in
     * terms). The one test below that genuinely needs the TRANSITION signs an NDA first.
     *
     * ⚠ `Listing_Date__c` IS PRE-SET, SO `stampListingDates` LEAVES IT ALONE — that stamp is
     * fill-if-blank, which `preexistingListingDateIsNotOverwritten` pins in the stage-entry
     * service's own test class. At `Active Listing` the after-insert `openBrokerListings` then
     * opens ONE listing carrying this same date.
     */
    private static Disposition__c onMarketAt(String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        d.Listing_Date__c = MARKETING_START;
        insert d;
        return d;
    }

    /**
     * Two broker Contacts with DISTINCT last names and distinct firms, inserted together.
     *
     * 🔴 `TestDataFactory.createBrokerContactWithFirm` CANNOT BE USED FOR A PAIR HERE. Its index
     * resets to 0 on every call, so two calls produce two Contacts BOTH named 'Test Contact 0' —
     * identical `Name`, and therefore identical `Contact_Name__c` on the submissions that point at
     * them, because `BovSubmissionBrokerStampService` stamps `Contact_Name__c` from `Broker__c.Name`
     * on every save and overwrites anything hand-typed. The assertions below need to tell the
     * outgoing broker's contact name from the incoming one's; with two identical names they would
     * pass no matter which row the listing was stamped from.
     *
     * ⚠ `insertAllowingDuplicates`, not a plain insert: the org's active
     * `Standard_Contact_Duplicate_Rule` is Alert/Allow, which Apex DML degrades into a hard
     * DUPLICATES_DETECTED on same-shaped test rows. See `TestDataFactory.createContacts`.
     */
    private static List<Contact> brokerPair(String firmA, String firmB) {
        List<Contact> pair = TestDataFactory.createBrokerContacts(2, null, false);
        pair[0].LastName = 'Outgoing Broker';
        pair[0].Broker_Firm__c = firmA;
        pair[1].LastName = 'Incoming Broker';
        pair[1].Broker_Firm__c = firmB;
        TestDataFactory.insertAllowingDuplicates(pair);
        return pair;
    }

    /**
     * 🔴 THE NEGATIVE, AND THE SINGLE MOST IMPORTANT TEST IN TRANCHE 4 (design decision D-10).
     *
     * A replacement performed at BOV OUTREACH must append NOTHING. The marketing period has not
     * started, so there is no broker clock to open — and far worse, a listing created here would
     * satisfy `openBrokerListings` presence-based idempotency guard forever, leaving the sale to
     * reach Active Listing with NO listing of its own: silent, months later, and unrecoverable
     * without hand repair.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THIS TEST DOES NOT STOP AT COUNTING ZERO ROWS, AND THE SECOND HALF IS THE POINT.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Assert.areEqual(0, listingsOn(...).size())` alone would ALSO pass if the service had refused
     * the whole replacement for an unrelated reason — a permission gate, a validation rule, a typo
     * in the challenger Id. Two controls close that:
     *   1. a PRESENCE CONTROL on the operation itself — the challenger really was promoted, so the
     *      zero above is "the append did not happen", not "nothing happened";
     *   2. the CONSEQUENCE, which is the thing the defect would actually destroy — the sale is then
     *      moved to Active Listing and the auto-create is proved to STILL FIRE.
     *
     * 🔴 AND THE DATE IS WHAT MAKES CONTROL 2 DISCRIMINATE. If write 3a HAD fired at BOV Outreach,
     * the count after the stage move would still be 1 (the auto-create would simply no-op), so a
     * bare count proves nothing. The poisoned row would carry `List_Date__c = Date.today()`; the
     * legitimate stage-entry row copies the PARENT's 40-day-old clock. Asserting the date is what
     * tells the two apart.
     */
    @isTest
    static void replaceAtBovOutreach_appendsNoListingAndLeavesTheAutoCreateIntact() {
        Disposition__c d = onMarketAt('BOV Outreach');
        List<Contact> brokers = brokerPair('CBRE - Old Incumbent', 'JLL - New Challenger');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = brokers[0].Id;
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = brokers[1].Id;
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        Assert.areEqual(0, listingsOn(d.Id).size(),
            'FIXTURE GUARD: a sale at BOV Outreach has no listing yet, or the assertion below is '
            + 'asserting the fixture rather than the code');

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, null);

        // ── THE NEGATIVE ──
        Assert.areEqual(0, listingsOn(d.Id).size(),
            '🔴 A REPLACEMENT AT BOV OUTREACH MUST APPEND NO LISTING. Replace Broker is rendered on '
            + 'this stage too (dispositionMain.html:42), and openBrokerListings idempotency test '
            + 'is SIMPLE PRESENCE — any listing satisfies it — so a row created here turns the '
            + 'Active Listing auto-create into a PERMANENT no-op for this sale.');

        // ── CONTROL 1: the replacement itself really happened, so the zero above is meaningful ──
        Assert.areEqual('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :challenger.Id]
                .Submission_Status__c,
            'PRESENCE CONTROL: the swap must have succeeded. Without this, the assertion above '
            + 'would pass on a service that refused the whole operation for an unrelated reason.');

        // ── CONTROL 2: the consequence the defect would destroy ──
        TestDataFactory.signBuyerNdaOn(d.Id);
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = 'Active Listing');
        Test.stopTest();

        List<Broker_Listing__c> afterListing = listingsOn(d.Id);
        Assert.areEqual(1, afterListing.size(),
            'Entering Active Listing must still open exactly one listing');
        Assert.areEqual(MARKETING_START, afterListing[0].List_Date__c,
            '🔴 THE DISCRIMINATOR. This row must carry the PARENT marketing clock, which is what '
            + 'openBrokerListings copies. A listing wrongly appended at BOV Outreach would carry '
            + 'Date.today() instead — and because the auto-create would then no-op, the COUNT '
            + 'above would still read 1. Only the date tells the two apart.');
        Assert.areEqual('JLL - New Challenger', afterListing[0].Broker_Firm__c,
            'and it is stamped from the parent Selected_Broker__c, i.e. the broker who actually '
            + 'holds the sale by the time it is listed');
    }

    /**
     * 🔴 THE POSITIVE: at Active Listing a replacement APPENDS a second listing opening the
     * incoming broker's own clock, and LEAVES THE SUPERSEDED ROW ALONE (decisions D-9, D-16).
     *
     * ⚠ THE SUPERSEDED ROW IS ASSERTED TO SURVIVE UNCHANGED, WHICH IS NOT AN OVERSIGHT BEING
     * PINNED — IT IS A RESIDUAL BEING PINNED. `Broker_Listing__c.Listing_Status__c` is RESTRICTED
     * to `On Track` / `At Risk` / `Hard Stop`, so there is no `Superseded` value to write, and
     * story 5's "exactly one active listing per on-market sale" is enforced by nothing. The old row
     * therefore stays in the related list looking live. That is the accepted state of the world as
     * of Tranche 4, and this assertion is what makes a future change to it deliberate: if someone
     * adds a `Superseded` value and starts closing the old row, THIS TEST is where they find out
     * they also owe the restricted-picklist sweep.
     *
     * ⚠ `c/brokerListing` NEEDS NO CHANGE TO FOLLOW THE NEW ROW.
     * `BrokerListingSelector.selectMostRecentByDispositionId` is already
     * `ORDER BY CreatedDate DESC LIMIT 1`, which is why this test orders its own read the same way.
     */
    @isTest
    static void replaceAtActiveListing_appendsTheIncomingBrokersOwnListing() {
        Disposition__c d = onMarketAt('Active Listing');
        List<Broker_Listing__c> opening = listingsOn(d.Id);
        Assert.areEqual(1, opening.size(),
            'FIXTURE GUARD: entering Active Listing must have auto-created exactly one listing');
        Id supersededId = opening[0].Id;

        List<Contact> brokers = brokerPair('CBRE - Old Incumbent', 'JLL - New Challenger');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = brokers[0].Id;
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = brokers[1].Id;
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        // Re-read the STAMPED values rather than asserting hand-typed literals:
        // BovSubmissionBrokerStampService overwrites Broker_Firm__c and Contact_Name__c from
        // Broker__c on every save, so a literal here would be asserting a value the platform has
        // already replaced. See TestDataFactory.createBrokerContactWithFirm's header.
        BOV_Submission__c challengerAfter = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :challenger.Id];
        BOV_Submission__c incumbentAfter = [
            SELECT Contact_Name__c FROM BOV_Submission__c WHERE Id = :incumbent.Id];

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, 'Swapped.');
        Test.stopTest();

        List<Broker_Listing__c> after = listingsOn(d.Id);
        Assert.areEqual(2, after.size(),
            '🔴 THE APPEND: a replacement on a LISTED sale opens a second Broker_Listing__c. It '
            + 'does not overwrite the first, and it does not reset the parent marketing clock.');

        Broker_Listing__c appended = after[0]; // newest first — the order the card itself uses
        Assert.areNotEqual(supersededId, appended.Id,
            'PREMISE: the newest row must be the new one, not the original');
        Assert.areEqual(Date.today(), appended.List_Date__c,
            '🔴 THE BROKER CLOCK STARTS TODAY. This is the ONE date in the feature that is '
            + 'Date.today() rather than a copy of the parent — it is what "restart the clock" '
            + 'honestly means, and it is why the marketing clock does not have to move.');
        Assert.areEqual(challengerAfter.Broker_Firm__c, appended.Broker_Firm__c,
            'The appended row names the INCOMING broker firm');
        Assert.areEqual(challengerAfter.Contact_Name__c, appended.Contact_Name__c,
            '🔴 AND ITS NAMED CONTACT — openBrokerListings leaves Contact_Name__c blank precisely '
            + 'because "a human fills it, or the future broker-change action supplies it". This is '
            + 'that action.');
        Assert.areNotEqual(incumbentAfter.Contact_Name__c, appended.Contact_Name__c,
            'FALSIFIER: stamped from the CHALLENGER, not from the row being demoted. Two brokers '
            + 'with the same contact name would make the assertion above pass either way, which is '
            + 'why brokerPair() gives them distinct last names.');
        Assert.areEqual('On Track', appended.Listing_Status__c,
            'A fresh broker starts On Track');
        Assert.areEqual(0, appended.Days_On_Market_Live__c,
            'and Days_On_Market_Live__c — the BROKER clock the card now shows beside the marketing '
            + 'one — reads 0 on its first day');
        Assert.areEqual(brokers[1].Id, appended.Broker__c,
            '🔴 THE LOOKUP, NOT JUST THE TEXT (code review S1, 2026-09-02). Write 3a is the FIRST '
            + 'place in the application that creates a Broker_Listing__c with a known broker '
            + 'Contact Id — DispositionStageEntryService.openBrokerListings has only the parent\'s '
            + 'Selected_Broker__c TEXT to work from and leaves this blank. Asserted against the '
            + 'CONTACT the challenger points at, not against challengerAfter.Broker__c, so the '
            + 'assertion cannot pass by comparing the service\'s input to itself.');
        Assert.areNotEqual(brokers[0].Id, appended.Broker__c,
            'FALSIFIER for the line above: the INCOMING broker, not the one being demoted. The two '
            + 'Contacts are distinct rows from brokerPair(), so this cannot tie.');

        Broker_Listing__c superseded = after[1];
        Assert.areEqual(supersededId, superseded.Id, 'PREMISE: the older row is the original');
        Assert.areEqual(null, superseded.Broker__c,
            '⚠ AND THE SUPERSEDED (AUTO-CREATED) ROW STILL HAS A BLANK LOOKUP, WHICH IS A RESIDUAL '
            + 'BEING PINNED, NOT AN ENDORSEMENT. S1 stamps the lookup only where a Contact Id is '
            + 'actually known — on a broker CHANGE. openBrokerListings still has no stamp, so the '
            + 'lookup/text duality survives on auto-created listings. If someone adds a stamp '
            + 'there, THIS assertion is where they find out, and they also owe '
            + 'scripts/seed-broker-contacts.apex a re-read (its STORED_DENORM_TEXT entry for this '
            + 'object is scoped by the fact that only appended rows carry the lookup).');
        Assert.areEqual(MARKETING_START, superseded.List_Date__c,
            'The superseded row is LEFT ALONE — its own dates are history and are not rewritten');
        Assert.areEqual('On Track', superseded.Listing_Status__c,
            '⚠ AND IT KEEPS A LIVE-LOOKING STATUS, WHICH IS A KNOWN RESIDUAL RATHER THAN AN '
            + 'ASSERTION THAT THIS IS DESIRABLE. Listing_Status__c is RESTRICTED to On Track / At '
            + 'Risk / Hard Stop, so there is no Superseded value to write, and nothing enforces '
            + '"exactly one active listing". Adding that value is a restricted-picklist change '
            + 'and triggers the standing repo-grep + org-query sweep.');
    }

    /**
     * A `Reason__c` value that is NOT in that field's RESTRICTED value set. Verified against the
     * describe inside the test rather than trusted, so that adding it to the picklist one day
     * fails HERE with an explanation instead of quietly disarming the whole test.
     */
    private static final String REASON_NOT_IN_VALUE_SET = 'ZZ Not A Real Reason ZZ';

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ROLLBACK OF WRITE 3a. Code review W1, 2026-09-02.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * A refused replacement on a LISTED sale must leave ZERO new `Broker_Listing__c` rows behind.
     *
     * 🔴 WHY THIS IS NOT AN ORDINARY COVERAGE GAP, AND WHY IT IS ARGUABLY WORSE THAN THE ARTEFACT
     * WRITE 4's PLACEMENT GUARDS AGAINST. `BrokerListingSelector.selectMostRecentByDispositionId`
     * is `ORDER BY CreatedDate DESC LIMIT 1`, so an orphaned listing surviving a rolled-back
     * replacement becomes THE row `c/brokerListing` renders: the Active Listing card would name,
     * and start a broker clock for, a broker who was never appointed — while the submissions and
     * `Disposition__c.Selected_Broker__c` all correctly still name the incumbent. Nothing on the
     * page disagrees with itself loudly enough for anyone to notice.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 `lockedDisposition_refusesTheWholeReplacementAndRollsBack` CANNOT REACH WRITE 3a AND IS
     *    NOT A SUBSTITUTE FOR THIS TEST. That is the finding W1 records.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * It locks a disposition at `Disposition Readiness`, where NO LISTING EXISTS — so `saleIsListed`
     * is false and write 3a never executes in it at all. Its "no history row survives" assertion is
     * real and stays; it simply says nothing about the listing append. Do not delete this test on
     * the grounds that "the savepoint is already covered": the savepoint is covered, the CONTENTS
     * of the savepoint on a listed sale were not.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 WHY THE INJECTION IS AN INVALID `Reason__c` AND **NOT** THE RECORD-TYPE ROUTE THE
     *    SERVICE HEADER DOCUMENTS. THIS IS THE LOAD-BEARING DESIGN DECISION IN THIS TEST.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The obvious fixture — and the one the service's own refusal note at the history insert
     * describes — is to move a broker Contact off the `Contact.Broker` record type so the
     * non-optional lookup filter refuses the write. IT WAS REJECTED HERE, for two independent
     * reasons, EITHER of which alone would make this test silently vacuous:
     *
     *   1. 🔴 SINCE CODE-REVIEW S1 (SAME CHANGE AS THIS TEST) WRITE 3a ITSELF CARRIES A CONTACT
     *      LOOKUP. `Broker_Listing__c.Broker__c` is stamped from the same `challenger.Broker__c`
     *      and carries a BYTE-IDENTICAL active non-optional filter on
     *      `Contact.RecordType.DeveloperName = 'Broker'`. A flipped Contact therefore refuses AT
     *      WRITE 3a — before it has inserted anything — so the "zero new listings" assertion below
     *      would be measuring a write that never ran. The exact defect this test exists to close.
     *   2. BOTH broker Contacts are also on the `BOV_Submission__c` rows that WRITE 1 updates, and
     *      `BOV_Submission__c.Broker__c` carries the same filter with the SAME `errorMessage`
     *      string. Whether the platform re-evaluates a lookup filter on an update that does not
     *      include the lookup field is not something this repo has measured, and the surfaced
     *      message is identical either way — so nothing in the test could tell a write-1 refusal
     *      from a write-4 one.
     *
     * `BOV_Broker_Change__c.Reason__c` has neither problem: it exists on EXACTLY ONE object in this
     * whole transaction (grep — `Reason__c` on any other object in this repo belongs to Lead,
     * Opportunity, Meter__c or Sync_Run__c, none of which this method touches). A restricted-picklist
     * refusal on it can therefore only come from write 4, which means writes 1, 2 AND 3a all
     * SUCCEEDED and were rolled back — which is precisely the proposition.
     *
     * ⚠ IT IS A REAL PATH, NOT A MOCK AND NOT A WEAKENING. `BovController.replaceSelectedBroker`
     * passes `reason` STRAIGHT THROUGH ("deliberately not validated here" — its own javadoc), and
     * this service validates only `String.isBlank(reason)`. Any Aura/LWC caller can send an
     * arbitrary string, and the platform's restricted-picklist enforcement is what refuses it.
     * Restricted picklists ARE DML-enforced on this project — `seed-lakeline-asset-repair.apex`
     * states it in terms after it was measured.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THE PRESENCE CONTROL IS THE SECOND HALF AND WITHOUT IT THE ZERO MEANS NOTHING.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Assert.areEqual(1, listingsOn(...).size())` after a refusal also passes on a service that
     * never appends on this fixture at all. So the SAME disposition, the SAME challenger and the
     * SAME listing state are then replayed with a VALID reason, and the append is proved to happen.
     * The re-run is free of side effects precisely because the first call rolled back: the
     * challenger is still `Backup`, so the `ALREADY_SELECTED` guard does not fire.
     */
    @isTest
    static void refusedReplacementRollsBackTheListingAppend() {
        // ── FIXTURE GUARD ON THE INJECTION ITSELF ──
        Boolean injectionIsInvalid = true;
        for (Schema.PicklistEntry entry
                : BOV_Broker_Change__c.Reason__c.getDescribe().getPicklistValues()) {
            if (REASON_NOT_IN_VALUE_SET.equalsIgnoreCase(entry.getValue())) {
                injectionIsInvalid = false;
            }
        }
        Assert.isTrue(injectionIsInvalid,
            'FIXTURE: "' + REASON_NOT_IN_VALUE_SET + '" must NOT be a value of the RESTRICTED picklist '
            + 'BOV_Broker_Change__c.Reason__c. If someone has added it, write 4 would succeed, the '
            + 'replacement would go through, and every rollback assertion below would be asserting '
            + 'nothing. Pick another absent value rather than deleting this guard.');

        Disposition__c d = onMarketAt('Active Listing');
        List<Broker_Listing__c> opening = listingsOn(d.Id);
        Assert.areEqual(1, opening.size(),
            'FIXTURE GUARD: entering Active Listing must have auto-created exactly one listing, or '
            + 'saleIsListed is false and write 3a never runs — the same blind spot that makes '
            + 'lockedDisposition_refusesTheWholeReplacementAndRollsBack unable to cover this.');
        Id supersededId = opening[0].Id;

        List<Contact> brokers = brokerPair('CBRE - Old Incumbent', 'JLL - New Challenger');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = brokers[0].Id;
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = brokers[1].Id;
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };
        BOV_Submission__c challengerAfter = [
            SELECT Broker_Firm__c FROM BOV_Submission__c WHERE Id = :challenger.Id];

        Test.startTest();

        // ══ THE REFUSAL ══════════════════════════════════════════════════════════════════════
        Boolean refused = false;
        String surfaced = 'no exception was thrown';
        try {
            BovSubmissionService.replaceSelectedBroker(
                d.Id, challenger.Id, REASON_NOT_IN_VALUE_SET, 'Rolled back.');
            Assert.fail('A Reason__c value outside the restricted value set must refuse the whole '
                + 'replacement at write 4. It did not, so nothing below is measuring a rollback.');
        } catch (BovSubmissionService.BovSubmissionException e) {
            refused = true;
            surfaced = e.getMessage();
        }
        Assert.isTrue(refused,
            'The refusal must arrive as the service\'s own BovSubmissionException, not as a raw '
            + 'DmlException escaping the catch.');

        // ── THE FAILURE MUST HAVE COME FROM WRITE 4, NOT FROM AN EARLIER WRITE ──
        Assert.isTrue(
            surfaced.contains(REASON_NOT_IN_VALUE_SET) || surfaced.containsIgnoreCase('reason'),
            '🔴 THE DISCRIMINATOR, AND IT IS WHAT MAKES THE NEXT ASSERTION MEAN ANYTHING. The '
            + 'refusal must name Reason__c — a field that exists on BOV_Broker_Change__c and on '
            + 'NOTHING ELSE in this transaction — proving writes 1, 2 and 3a all completed and '
            + 'were rolled back. A refusal from write 1 (a lookup filter: "Only Broker Contacts '
            + 'can be selected here.") or write 2 (a lock: "This record is locked") would leave '
            + 'write 3a un-executed and the zero below vacuous. OBSERVED: ' + surfaced);

        // ── 🔴 THE ASSERTION W1 EXISTS FOR ──
        List<Broker_Listing__c> afterRefusal = listingsOn(d.Id);
        Assert.areEqual(1, afterRefusal.size(),
            '🔴 ZERO NEW Broker_Listing__c ROWS MAY SURVIVE A REFUSED REPLACEMENT. Write 3a sits '
            + 'inside the savepoint between writes 3 and 4; move it outside the try, commit it '
            + 'separately, or take a second savepoint around it, and this reads 2. The surviving '
            + 'orphan would then be the row selectMostRecentByDispositionId returns (CreatedDate '
            + 'DESC LIMIT 1), so the Active Listing card would follow a broker who was never '
            + 'appointed — silently, and with every other field on the page still correct.');
        Assert.areEqual(supersededId, afterRefusal[0].Id,
            'and the one row present is the ORIGINAL auto-created listing, not a replacement for '
            + 'it — write 3a appends, it never overwrites.');

        // ── THE ROLLBACK ACROSS THE OTHER TWO WRITES, SO ALL THREE ARE PROVEN AT ONCE ──
        Map<Id, BOV_Submission__c> submissionsAfter = submissionsById(d.Id);
        Assert.areEqual('Selected', submissionsAfter.get(incumbent.Id).Submission_Status__c,
            '🔴 WRITE 1 ROLLED BACK — the incumbent must still be the appointed broker. A '
            + 'half-applied replacement that demoted the incumbent while refusing the history row '
            + 'would leave the sale with NO Selected broker at all.');
        Assert.areEqual('Backup', submissionsAfter.get(challenger.Id).Submission_Status__c,
            'and the challenger must not have been promoted.');
        Assert.areEqual(0, historyFor(d.Id).size(),
            'and no history row — the write that refused must not have partially landed.');

        // ══ THE PRESENCE CONTROL ═════════════════════════════════════════════════════════════
        // Same disposition, same challenger, same listing state — only the reason is now valid.
        // Free of side effects from the call above precisely because that call rolled back.
        BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, 'Went through.');
        Test.stopTest();

        List<Broker_Listing__c> afterSuccess = listingsOn(d.Id);
        Assert.areEqual(2, afterSuccess.size(),
            '🔴 THE PRESENCE CONTROL. This fixture DOES append a listing when the transaction is '
            + 'allowed to commit, so the 1 asserted above is "the append was rolled back", not '
            + '"this fixture never appends". Without this half, deleting write 3a entirely would '
            + 'leave every assertion above green.');
        // ⚠ THE APPENDED ROW IS FOUND BY ELIMINATION, NOT BY `[0]`. Both listings are created in
        // the SAME test transaction, so `ORDER BY CreatedDate DESC, Id DESC` can tie on its first
        // key and this test must not depend on the tie-break to identify which row is which. (The
        // positive test above deliberately DOES read `[0]`, because the order the card itself uses
        // is part of what IT asserts. Here the order is irrelevant and would only add a way to
        // fail for the wrong reason.)
        Broker_Listing__c appendedByControl;
        for (Broker_Listing__c listing : afterSuccess) {
            if (listing.Id != supersededId) {
                appendedByControl = listing;
            }
        }
        Assert.isNotNull(appendedByControl,
            'PREMISE: one of the two rows must be a NEW listing, not the original.');
        Assert.areEqual(challengerAfter.Broker_Firm__c, appendedByControl.Broker_Firm__c,
            'and it names the INCOMING broker firm, so the control is measuring write 3a rather '
            + 'than some unrelated listing that appeared.');
        Assert.areEqual(brokers[1].Id, appendedByControl.Broker__c,
            'stamped with the incoming broker Contact (code review S1) — the same value write 4 '
            + 'puts on Incoming_Broker__c in the same transaction.');
        Assert.areEqual('Selected',
            submissionsById(d.Id).get(challenger.Id).Submission_Status__c,
            'and the swap itself completed on the second call, so the control is a genuine '
            + 'success and not a second, quieter refusal.');
    }

    /**
     * 🔴 THE GATE 1 DECISION, PINNED (design D-9). `Disposition__c.Listing_Date__c` is NEVER
     * rewritten by a replacement.
     *
     * Two class headers refuse the reset in terms and both name this button as the hazard:
     *   DispositionTractionService:166-172 — "Using the child's date would silently reset the clock
     *   the moment a broker was replaced — i.e. exactly when the clock matters most."
     *   BrokerListingController:164-168 — "...which, now that this card carries a Replace Broker
     *   button, is one click away rather than hypothetical."
     *
     * ⚠ THE BLAST RADIUS IS WHY THIS IS A TEST AND NOT A COMMENT. `Listing_Date__c` feeds
     * `Disposition__c.Days_On_Market__c` (a formula), the `Dispositions/Avg_Days_on_Market` report
     * and the `Broker Alert Due` dashboard KPI. A reset would change all three WITH NO METADATA
     * DIFF AT ALL — nothing in a code review would show it. This assertion is the only thing that
     * would.
     *
     * ⚠ 40 DAYS OLD, NOT TODAY. Against the factory's `Listing_Date__c = Date.today()` default this
     * test would pass on a service that DID reset the clock, because the reset value and the
     * original would be the same date.
     */
    @isTest
    static void parentsMarketingClockIsNeverRewrittenByAReplacement() {
        Disposition__c d = onMarketAt('Active Listing');
        List<Contact> brokers = brokerPair('CBRE - Old Incumbent', 'JLL - New Challenger');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker__c = brokers[0].Id;
        incumbent.Submission_Status__c = 'Selected';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = brokers[1].Id;
        challenger.Submission_Status__c = 'Backup';
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id, REASON, null);
        Test.stopTest();

        Disposition__c after =
            [SELECT Listing_Date__c, Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(MARKETING_START, after.Listing_Date__c,
            '🔴 THE MARKETING CLOCK MUST NOT MOVE. It records when the PROPERTY went to market, '
            + 'which survives a broker change; the BROKER clock restarts on the appended '
            + 'Broker_Listing__c instead. Resetting this field would silently change '
            + 'Days_On_Market__c, the Avg_Days_on_Market report and the Broker Alert Due KPI with '
            + 'no metadata diff at all.');
        Assert.areEqual('JLL - New Challenger', after.Selected_Broker__c,
            'PRESENCE CONTROL: the replacement really happened. Without it, the date assertion '
            + 'above would pass on a service that did nothing.');
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
