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
            SELECT Id, Submission_Status__c, Approval_Status__c, Broker_Firm__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
        ]);
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
        String msg = BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id);
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
        Assert.areEqual('Backup', after.get(bystander.Id).Submission_Status__c,
            'A third, untouched submission must be left exactly as it was');
        Assert.areEqual('JLL - New Challenger',
            [SELECT Selected_Broker__c FROM Disposition__c WHERE Id = :d.Id].Selected_Broker__c,
            'The Disposition must be stamped with the new broker\'s firm');
        Assert.isTrue(msg.contains('must be approved'),
            'The confirmation must warn that a fresh approval is required: ' + msg);
    }

    /** "Replace" degrades cleanly to "appoint" when there is no incumbent to demote. */
    @isTest
    static void noIncumbent_degradesToAnAppointment() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Submission_Status__c = 'Backup';
        insert challenger;

        Test.startTest();
        BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id);
        Test.stopTest();

        Assert.areEqual('Selected',
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :challenger.Id].Submission_Status__c,
            'With nothing to demote, the challenger is simply promoted');
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
            BovSubmissionService.replaceSelectedBroker(d.Id, already.Id);
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
            BovSubmissionService.replaceSelectedBroker(d.Id, foreign.Id);
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
            BovSubmissionService.replaceSelectedBroker(null, sub.Id);
        } catch (BovSubmissionService.BovSubmissionException e) {
            refusedNullDisposition = true;
        }
        Boolean refusedNullSubmission = false;
        try {
            BovSubmissionService.replaceSelectedBroker(d.Id, null);
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
                BovSubmissionService.replaceSelectedBroker(d.Id, challenger.Id);
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
