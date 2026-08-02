/**
 * Test class for ExtractAddressQueueable — the async routing tree (staging model,
 * Phase 3 rewrite). Every scenario inserts an Inbound_Email_Staging__c row directly
 * (bypassing EmailToLeadHandler, which has its own test class), mocks the LLM
 * callout boundary via the shared LLMExtractionCalloutMock (set before
 * Test.startTest()), enqueues the job, and lets it run synchronously at
 * Test.stopTest() so its effects can be asserted.
 *
 * COVERS the routing tree end to end: Reply Thread, Repeat (via the LLM's
 * broker_email, via the envelope-From backfill, via the envelope-From SECOND
 * lookup when the LLM names the wrong broker, and for a COMPETING broker who has
 * no Lead of their own), No-Property, Competing Submission, Winner, Idempotent
 * Redelivery, Auto-forward Detection, Race Recovery (orphan adoption), and a null
 * Message-ID. Plus the regex-fallback backfill, the forceClaimRace test seam, the
 * missing-staging-row guard, the unparseable-sent_datetime fallback, and the
 * DEGRADED-EXTRACTION path (W1) — a CalloutException from the LLM boundary must
 * land on branch (c) with a distinct outcome label rather than aborting the email
 * onto an Error row.
 *
 * 2026-07-31 — COMPETING BROKERS NO LONGER GET A LEAD. Three tests in this class
 * encode that contract, and they are the ones to read first if the routing tree is
 * ever changed back: a competing broker's email creates NO Lead and only a
 * source-less submission under the winner; their FOLLOW-UP is a Repeat that lands
 * on the winning Lead (while still appending an audit row — see ARCHITECTURE.md §1);
 * and a LOST RACE deletes the Lead that had already been created. Assertions on the
 * retired Lead.Is_Duplicate_Property__c / Duplicate_Of_Lead__c fields were removed
 * rather than inverted where they had become vacuous — nothing writes those fields,
 * so asserting they are false proves nothing.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in
 * this exact module (PropertyClaimServiceTest, PropertyMatchingServiceTest).
 *
 * ⚠ 2026-07-31 — THE PER-TRANSACTION-SINGLETON EXEMPTION NO LONGER COVERS THIS CLASS.
 * D1 multi-property extraction made execute() LOOP, so `.claude/rules/bulk-test-rule.md`
 * was narrowed (design C-18) to `LLMExtractionCalloutService` alone. The replacement
 * volume tests live at the BOTTOM of this class: 10-property routing WITH governor-headroom
 * assertions, 15-property truncation, mixed outcomes, cluster-key ordering (both the pure
 * function and end to end), the tiered gate, and the two no-callout branches. The reasoning
 * below still explains why a literal 251 is impossible here, and is retained for exactly
 * that reason.
 *
 * NOTE ON THE 251-RECORD BULK MANDATE (.claude/rules/bulk-test-rule.md): this class
 * is architecturally ONE INSTANCE PER INBOUND EMAIL (see its own class header —
 * "One instance is enqueued per inbound broker email"). A literal loop of 251 sequential
 * System.enqueueJob calls does not exist in
 * production (each real email gets its own async transaction) and is not achievable
 * in a SINGLE test transaction at all: Apex caps System.enqueueJob at 50 calls per
 * transaction, so a 251-call loop fails with
 * "System.LimitException: Too many enqueued jobs" before ever reaching the routing
 * logic under test — exactly the "test encodes a state production cannot produce"
 * anti-pattern the bulk-test-rule exemption exists to avoid (see also
 * PropertyClaimServiceTest's own header for the identical reasoning). Two tests near
 * the bottom of this class cover this module's genuine volume risk instead:
 *   (1) execute_manyConcurrentEmails_noCrossContaminationBetweenJobs — 25 independent
 *       winner claims (safely under the 50-job cap) in one transaction, proving no
 *       shared/static state leaks between jobs.
 *   (2) execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread — the
 *       genuinely bulk-shaped, zero-governor-risk case: 251 Task rows inserted via
 *       ONE bulk DML, then ONE queueable execution proving the reply-threading read
 *       still resolves the correct thread at volume (the established "251 records
 *       via one bulk DML + one read call" pattern used elsewhere in this repo for
 *       single-record controllers/services).
 * This deviation from a literal 251-enqueueJob loop is flagged explicitly for
 * code-review, per the Unit Testing Agent's standing practice for this module.
 *
 * @author Unit Testing Agent
 */
@isTest
private class ExtractAddressQueueableTest {

    private static void setMock(Map<String, String> fields) {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(200, LLMExtractionCalloutMock.extractionBody(fields, false)));
    }

    private static Inbound_Email_Staging__c insertStaging(String fromAddress, String forwardedBy,
            String subject, String rawBody, String messageId, String inReplyTo, String references) {
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = fromAddress,
            Subject__c = subject,
            Raw_Body__c = rawBody,
            Forwarded_By__c = forwardedBy,
            Message_Id__c = messageId,
            In_Reply_To__c = inReplyTo,
            References__c = references
        );
        insert staging;
        return staging;
    }

    // ── (e) WINNER ───────────────────────────────────────────────────────────

    @isTest
    static void execute_newUnclaimedProperty_createsWinnerLeadAndRegistersClaim() {
        Inbound_Email_Staging__c staging = insertStaging(
            'broker@example.invalid', 'forwarder@example.invalid',
            'FW: 100 Winner St', 'some forwarded email body',
            'msg-winner-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Winner St', 'sent_datetime' => '2026-07-01 10:00:00'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c, 'A successful winner claim should mark the staging row Processed');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c, 'The outcome should be the winner label');
        Assert.isNotNull(updatedStaging.Result_Record_Id__c, 'Result_Record_Id__c should carry the new Lead Id');

        Lead created = [
            SELECT FirstName, LastName, Email, Property_Address__c, Forwarded_By_Email__c
            FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c
        ];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be applied from the LLM extraction');
        Assert.areEqual('Broker', created.LastName, 'LastName should be applied from the LLM extraction');
        Assert.areEqual('jane@brokerfirm.example.invalid', created.Email, 'Email should be applied from the LLM extraction');
        Assert.areEqual('100 Winner St', created.Property_Address__c, 'Property_Address__c should be applied');
        Assert.areEqual('forwarder@example.invalid', created.Forwarded_By_Email__c, 'Forwarded_By_Email__c should flow from the staging row');

        List<Property_Registry__c> registries = [
            SELECT Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c = '100 winner st'
        ];
        Assert.areEqual(1, registries.size(), 'A winner registry row should be created for the normalized address');
        Assert.areEqual(created.Id, registries[0].Winning_Lead__c, 'The new lead should win the claim');

        Competing_Broker_Submission__c sub = [
            SELECT Is_Winning_Submission__c, Submitted_DateTime__c
            FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :created.Id
        ];
        Assert.isTrue(sub.Is_Winning_Submission__c, 'The submission should be flagged as the winner');
        Assert.areEqual(Datetime.valueOfGmt('2026-07-01 10:00:00'), sub.Submitted_DateTime__c,
            'Submitted_DateTime__c should be parsed from the LLM\'s sent_datetime');

        Task logged = [SELECT WhoId, Inbound_Message_Id__c, Thread_Key__c FROM Task WHERE WhoId = :created.Id];
        Assert.areEqual('msg-winner-1@example.invalid', logged.Inbound_Message_Id__c, 'The Task should carry the RFC Message-ID');
        Assert.areEqual('msg-winner-1@example.invalid', logged.Thread_Key__c,
            'With no In-Reply-To/References, the thread key should be this message\'s own id');
    }

    // ── (d) COMPETING SUBMISSION — no Lead for the losing broker ─────────────

    @isTest
    static void execute_propertyAlreadyClaimedByAnotherBroker_createsNoLeadAndLogsSubmissionOnWinner() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('200 duplicate st', winnerLead.Id, true);

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'competing@example.invalid', 'forwarder2@example.invalid',
            'FW: 200 Duplicate St', 'some forwarded email body',
            'msg-dup-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Competing Broker', 'broker_email' => 'competing@example.invalid',
            'property_address' => '200 Duplicate St', 'sent_datetime' => '2026-07-02 09:00:00'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A competing broker must receive NO Lead — the submission row is the only record of their claim');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE, updatedStaging.Outcome__c,
            'The outcome should be the competing-submission label');
        Assert.areEqual(winnerLead.Id, updatedStaging.Result_Record_Id__c,
            'Result_Record_Id__c should point at the WINNER\'s live record, not at a newly minted Lead');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '200 duplicate st'],
            'No second registry row should be created for an already-claimed property');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Source_Lead__c, Is_Winning_Submission__c, Broker_Email__c
            FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :winnerLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'Exactly one competing submission should be logged under the winner');
        Assert.isNull(subs[0].Source_Lead__c,
            'A competing broker has no Lead of their own, so their submission must carry a null Source_Lead__c');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The competing submission must not be flagged as the winner');
        Assert.areEqual('competing@example.invalid', subs[0].Broker_Email__c,
            'With no Lead to hold it, the submission is now the ONLY record of the competing broker\'s address');

        Task logged = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-dup-1@example.invalid'];
        Assert.areEqual(winnerLead.Id, logged.WhoId,
            'The competing broker\'s email must be logged on the WINNING Lead so the property\'s whole story lives in one place');
    }

    // ── (b) REPEAT — a COMPETING broker re-emails (they own no Lead) ─────────

    @isTest
    static void execute_competingBrokerRepeats_appendsAuditRowAndFilesOnWinningLead() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('250 competing repeat st', winnerLead.Id, true);

        // The competing broker's FIRST submission, in the exact shape branch (d) now writes:
        // rolled up under the winner, NOT winning, and with no Source_Lead__c of its own.
        Competing_Broker_Submission__c firstSub =
            TestDataFactory.createCompetingBrokerSubmission(winnerLead.Id, false);
        firstSub.Source_Lead__c = null;
        firstSub.Is_Winning_Submission__c = false;
        firstSub.Broker_Email__c = 'competing.repeat@example.invalid';
        firstSub.Property_Address_Raw__c = '250 Competing Repeat St';
        firstSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert firstSub;

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'competing.repeat@example.invalid', 'forwarder17@example.invalid',
            'FW: 250 Competing Repeat St - following up', 'any update on this one?',
            'msg-competing-repeat-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Competing Broker', 'broker_email' => 'competing.repeat@example.invalid',
            'property_address' => '250 Competing Repeat St', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A competing broker chasing their own earlier submission must still never receive a Lead');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPEAT, updatedStaging.Outcome__c,
            'A competing broker\'s follow-up is a Repeat — branch (b) precedes branch (d), so it is never re-logged as a fresh competing claim');
        Assert.areEqual(winnerLead.Id, updatedStaging.Result_Record_Id__c,
            'With no Lead of their own, the competing broker\'s repeat must route to the WINNING Lead');

        Assert.areEqual(2, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :winnerLead.Id],
            'The repeat appends a SECOND audit row: Competing_Broker_Submission__c is the append-only trail of EVERY inbound email that matched a property (ARCHITECTURE.md §1), so the evidence that this broker chased the property twice must survive');
        Assert.areEqual(2, [
            SELECT COUNT() FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :winnerLead.Id AND Source_Lead__c = null
        ], 'Both of the competing broker\'s rows stay source-less — a repeat must not invent a Lead reference');

        Task logged = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-competing-repeat-1@example.invalid'];
        Assert.areEqual(winnerLead.Id, logged.WhoId,
            'The follow-up email lands on the winning Lead, alongside the broker\'s submission entries');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '250 competing repeat st'],
            'A repeat must never touch the registry');
    }

    // ── (b) REPEAT — via LLM-extracted broker_email ─────────────────────────

    @isTest
    static void execute_sameBrokerSameProperty_viaLlmEmail_filesOnExistingLeadAsRepeat() {
        Lead originalLead = TestDataFactory.createLead(true);
        Competing_Broker_Submission__c priorSub = TestDataFactory.createCompetingBrokerSubmission(originalLead.Id, false);
        priorSub.Broker_Email__c = 'repeat.broker@example.invalid';
        priorSub.Property_Address_Raw__c = '400 Repeat Blvd';
        priorSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert priorSub;

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'repeat.broker@example.invalid', 'forwarder3@example.invalid',
            'FW: 400 Repeat Blvd again', 'checking back in',
            'msg-repeat-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Repeat Broker', 'broker_email' => 'repeat.broker@example.invalid',
            'property_address' => '400 Repeat Blvd', 'sent_datetime' => '2026-07-03 09:00:00'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead], 'A repeat submission from the same broker for the same property must not create a second Lead');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPEAT, updatedStaging.Outcome__c, 'The outcome should be the repeat label');
        Assert.areEqual(originalLead.Id, updatedStaging.Result_Record_Id__c, 'The repeat should route back onto the broker\'s existing Lead');

        Task logged = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-repeat-1@example.invalid'];
        Assert.areEqual(originalLead.Id, logged.WhoId, 'The repeat email should be logged as a Task on the existing Lead');

        Assert.areEqual(2, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :originalLead.Id],
            'A repeat should append a second audit row (the original + this follow-up) without a registry write');
    }

    // ── (b) REPEAT — via envelope-From fallback (LLM blank) ─────────────────

    @isTest
    static void execute_sameBrokerSameProperty_viaEnvelopeFromFallback_filesOnExistingLeadAsRepeat() {
        Lead originalLead = TestDataFactory.createLead(true);
        Competing_Broker_Submission__c priorSub = TestDataFactory.createCompetingBrokerSubmission(originalLead.Id, false);
        priorSub.Broker_Email__c = 'fallback.broker@example.invalid';
        priorSub.Property_Address_Raw__c = '450 Fallback Way';
        priorSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert priorSub;

        Inbound_Email_Staging__c staging = insertStaging(
            'fallback.broker@example.invalid', 'forwarder4@example.invalid',
            'FW: 450 Fallback Way', 'auto-forwarded body with no From: line to backfill from',
            'msg-repeat-fallback-1@example.invalid', null, null);
        // The LLM misses the broker_email this time (blank) — the queueable must fall back to
        // the envelope From address, which IS the broker on an auto-forward.
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => '',
            'property_address' => '450 Fallback Way', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPEAT, updatedStaging.Outcome__c,
            'A blank LLM broker_email should still resolve to a repeat via the envelope From fallback');
        Assert.areEqual(originalLead.Id, updatedStaging.Result_Record_Id__c, 'The repeat should route back onto the broker\'s existing Lead');
    }

    // ── (b) REPEAT — winner Lead deleted: must fall through to orphan adoption ───
    //
    // C1 regression (2026-07-31). Both Lead lookups on Competing_Broker_Submission__c are
    // deleteConstraint=SetNull, so deleting the winner's Lead leaves submission rows with BOTH
    // lookups null. Removing the selector's `Source_Lead__c != null` filter briefly admitted
    // those rows into repeat detection, where branch (b) would call
    // logRepeatSubmission(null, null, ...) -> an insert with a null Winning_Lead__c -> the
    // Winning_Lead_Required validation rule -> DmlException -> the email dies as Status
    // 'Error' with no Lead and no Task. It ALSO defeated orphan adoption, which is the
    // module's designed answer to a deleted winner. The replacement filter
    // (`Winning_Lead__c != null`) restores that path; this test is what proves it.

    @isTest
    static void execute_priorSubmissionWinnerLeadDeleted_adoptsOrphanInsteadOfErroring() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('700 deleted winner st', winnerLead.Id, true);

        // A competing broker's submission, in the post-2026-07-31 source-less shape.
        Competing_Broker_Submission__c priorSub =
            TestDataFactory.createCompetingBrokerSubmission(winnerLead.Id, false);
        priorSub.Source_Lead__c = null;
        priorSub.Is_Winning_Submission__c = false;
        priorSub.Broker_Email__c = 'deleted.winner.broker@example.invalid';
        priorSub.Property_Address_Raw__c = '700 Deleted Winner St';
        priorSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert priorSub;

        // The winner's Lead is deleted (merged away, cleaned up, whatever). SetNull now leaves
        // the registry row orphaned AND the submission row with both lookups null.
        delete winnerLead;
        Assert.areEqual(0, [
            SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Winning_Lead__c != null
        ], 'Precondition: deleting the winner Lead must have nulled the submission\'s Winning_Lead__c via SetNull');

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'deleted.winner.broker@example.invalid', 'forwarder19@example.invalid',
            'FW: 700 Deleted Winner St', 'still interested?',
            'msg-deleted-winner-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Persistent Broker', 'broker_email' => 'deleted.winner.broker@example.invalid',
            'property_address' => '700 Deleted Winner St', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c,
            'A prior submission whose winner Lead was deleted must not be able to kill the email — it must be skipped by repeat detection, not crash it');
        Assert.isNull(updatedStaging.Error__c,
            'Specifically: no Winning_Lead_Required DmlException may reach the staging row');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c,
            'With the orphaned key adopted, this broker legitimately becomes the new winner — that is the module\'s designed recovery for a deleted winner');

        Assert.areEqual(leadsBefore + 1, [SELECT COUNT() FROM Lead],
            'The email must produce a real Lead rather than dying on a validation rule');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '700 deleted winner st'],
            'The orphaned registry row must be ADOPTED, not duplicated — the property key stays claimable');
        Property_Registry__c adopted = [
            SELECT Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c = '700 deleted winner st'
        ];
        Assert.areEqual(updatedStaging.Result_Record_Id__c, String.valueOf(adopted.Winning_Lead__c),
            'The newly created Lead should now own the previously orphaned registry row');

        Task logged = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-deleted-winner-1@example.invalid'];
        Assert.areEqual(updatedStaging.Result_Record_Id__c, String.valueOf(logged.WhoId),
            'The email must still be logged — losing the Task is the most damaging symptom of the bug this guards');
    }

    // ── W2: manual forward must NOT stamp the internal forwarder as the broker ──

    @isTest
    static void execute_manualForwardWithNoBrokerEmail_leavesSubmissionBrokerEmailBlank() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('800 manual forward st', winnerLead.Id, true);

        // MANUAL forward: EmailToLeadHandler could find no forwarding header, so it fell back
        // to the envelope From for Forwarded_By__c — making the two equal. That equality is
        // the module's own tell that the From address is the INTERNAL employee, not the broker.
        Inbound_Email_Staging__c staging = insertStaging(
            'employee@dpeg.example.invalid', 'employee@dpeg.example.invalid',
            'FW: 800 Manual Forward St', 'no quoted From: block in this body at all',
            'msg-manual-fwd-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => '',
            'property_address' => '800 Manual Forward St', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE, updatedStaging.Outcome__c,
            'Precondition: this must land on the competing branch, where the submission is the only record of the broker');

        Competing_Broker_Submission__c sub = [
            SELECT Broker_Email__c FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :winnerLead.Id
        ];
        Assert.isNull(sub.Broker_Email__c,
            'On a MANUAL forward the envelope From is the internal DPEG employee, so it must NOT be backfilled as the competing broker\'s address. This row is an adjudication record: blank is visibly incomplete and sends someone to the raw email, whereas a wrong address is silently authoritative and would attribute a broker\'s claim to an employee. (The auto-forward case, where From IS the broker, still backfills — see execute_sameBrokerSameProperty_viaEnvelopeFromFallback_...)');
    }

    // ── (b) REPEAT — the LLM names the WRONG broker (second lookup) ──────────
    //
    // The blank-broker_email case above is now satisfied by the envelope backfill in
    // execute(), so it resolves on the FIRST findBrokerSubmission call. This test drives the
    // SECOND call — the one guarded by !fromAddress.equalsIgnoreCase(brokerEmail) — which is
    // the genuinely distinct scenario: the LLM returns a plausible but wrong address (it read
    // an assistant's signature block rather than the broker's), so only the envelope From
    // finds the prior submission.

    @isTest
    static void execute_llmNamesTheWrongBroker_stillDetectsTheRepeatViaTheEnvelopeFrom() {
        Lead originalLead = TestDataFactory.createLead(true);
        Competing_Broker_Submission__c priorSub = TestDataFactory.createCompetingBrokerSubmission(originalLead.Id, false);
        priorSub.Broker_Email__c = 'true.broker@example.invalid';
        priorSub.Property_Address_Raw__c = '460 Wrong Email Way';
        priorSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert priorSub;

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'true.broker@example.invalid', 'forwarder18@example.invalid',
            'FW: 460 Wrong Email Way', 'auto-forwarded body with no quoted From: block',
            'msg-wrong-llm-email-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Assistant', 'broker_email' => 'assistant@example.invalid',
            'property_address' => '460 Wrong Email Way', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A repeat found via the envelope From must not create a second Lead just because the LLM named the wrong person');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPEAT, updatedStaging.Outcome__c,
            'A non-blank but WRONG LLM broker_email must still resolve to a repeat via the second, envelope-From lookup');
        Assert.areEqual(originalLead.Id, updatedStaging.Result_Record_Id__c,
            'The repeat should route back onto the broker\'s existing Lead');
    }

    // ── (a) REPLY ────────────────────────────────────────────────────────────

    @isTest
    static void execute_replyToExistingThread_filesOnThatRecordWithoutCreatingNewLead() {
        Lead existingLead = TestDataFactory.createLead(true);
        insert new Task(
            Subject = 'Original inquiry', Status = 'Completed', TaskSubtype = 'Email',
            WhoId = existingLead.Id,
            Inbound_Message_Id__c = 'root-123@example.invalid',
            Thread_Key__c = 'root-123@example.invalid'
        );

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'anyone@example.invalid', 'forwarder5@example.invalid',
            'RE: Original inquiry', 'Thanks, following up',
            'msg-reply-1@example.invalid', '<root-123@example.invalid>', null);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'jane@example.invalid',
            'property_address' => '999 Should Not Matter Ave', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead], 'A reply inside a logged thread must never create a new Lead');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPLY, updatedStaging.Outcome__c, 'The outcome should be the reply-thread label');
        Assert.areEqual(existingLead.Id, updatedStaging.Result_Record_Id__c, 'The reply should resolve to the original thread\'s record');

        Task reply = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-reply-1@example.invalid'];
        Assert.areEqual(existingLead.Id, reply.WhoId, 'The reply Task should attach to the same record as the original thread (WhoId resolved for a Lead)');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :existingLead.Id],
            'No claim should ever be attempted for a reply, regardless of the extracted property address');
    }

    // ── (c) NO-PROPERTY ──────────────────────────────────────────────────────

    @isTest
    static void execute_noExtractableAddress_createsPlainLeadWithoutClaimingAnything() {
        Inbound_Email_Staging__c staging = insertStaging(
            'broker6@example.invalid', 'forwarder6@example.invalid',
            'FW: no address here', 'no address in this body',
            'msg-noprop-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'broker6@example.invalid',
            'property_address' => '', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_NO_PROPERTY, updatedStaging.Outcome__c, 'The outcome should be the no-property label');
        Assert.isNotNull(updatedStaging.Result_Record_Id__c, 'A Lead should still be created so the email is never lost');

        Lead created = [SELECT Property_Address__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.isNull(created.Property_Address__c, 'A blank extracted address should never be stamped');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :created.Id],
            'No registry row should be created when there is no usable address');
        Assert.areEqual(0, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :created.Id],
            'No submission should be logged when there is no usable address');
    }

    // ── DEGRADED EXTRACTION: the LLM is down (W1) ────────────────────────────
    //
    // A CalloutException from the LLM boundary must DEGRADE into branch (c), not abort.
    // Before W1 these emails ended as Status 'Error' with no Lead, no Task and no claim —
    // indistinguishable from lost, caused by a transient third-party 429.

    /** Drives LLMExtractionCalloutService's non-200 path, which throws CalloutException. */
    private static void setOutageMock() {
        Test.setMock(HttpCalloutMock.class,
            new LLMExtractionCalloutMock(429, '{"error":{"message":"Rate limit reached"}}'));
    }

    @isTest
    static void execute_llmCalloutFails_stillCreatesLeadFromRegexFallbackAndNeverErrors() {
        // The body carries BOTH a parseable From: line and a very obvious address, so this
        // also proves the degraded path never guesses at a claim: the regex fallback
        // recovers only the broker, never the property.
        String textContent = 'From: Jane Broker <jane@brokerfirm.example.invalid>\n' +
            'Sent: Monday, January 5, 2026 10:00 AM\n' +
            'Subject: FW: 800 Outage Blvd\n\n' +
            'Pitching 800 Outage Blvd, see attached.';
        Inbound_Email_Staging__c staging = insertStaging(
            'forwarder15@dpeg.example.invalid', 'forwarder15@dpeg.example.invalid',
            'FW: 800 Outage Blvd', textContent,
            'msg-outage-1@example.invalid', null, null);
        setOutageMock();

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c,
            'An LLM outage is a missing optional input, not a pipeline failure — the row must reach Processed, never Error');
        Assert.isNull(updatedStaging.Error__c, 'A degraded run is a success, so no error text should be recorded');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_NO_PROPERTY_LLM_DOWN, updatedStaging.Outcome__c,
            'The outage must be labelled distinctly from a genuinely addressless email so these Leads can be re-extracted later');
        Assert.isNotNull(updatedStaging.Result_Record_Id__c, 'A Lead must still be created so the broker submission is never lost');

        Lead created = [
            SELECT FirstName, LastName, Email, Property_Address__c, Forwarded_By_Email__c
            FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c
        ];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should come from the regex fallback when the LLM is unreachable');
        Assert.areEqual('Broker', created.LastName, 'LastName should come from the regex fallback when the LLM is unreachable');
        Assert.areEqual('jane@brokerfirm.example.invalid', created.Email, 'Email should come from the regex fallback when the LLM is unreachable');
        Assert.isNull(created.Property_Address__c,
            'The regex fallback must never invent a property address — an unread address must not reach the Lead');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :created.Id],
            'No claim may be registered from an address nobody actually extracted');
        Assert.areEqual(0, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :created.Id],
            'No competing-submission row may be written on the degraded path');

        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-outage-1@example.invalid'],
            'The email must still be logged as a Task so the thread is recognisable when the NEXT message arrives');
    }

    @isTest
    static void execute_llmCalloutFails_onAReplyThread_stillFilesOnThatRecordWithoutANewLead() {
        Lead existingLead = TestDataFactory.createLead(true);
        insert new Task(
            Subject = 'Original inquiry', Status = 'Completed', TaskSubtype = 'Email',
            WhoId = existingLead.Id,
            Inbound_Message_Id__c = 'outage-root@example.invalid',
            Thread_Key__c = 'outage-root@example.invalid'
        );
        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'anyone@example.invalid', 'forwarder16@example.invalid',
            'RE: Original inquiry', 'Thanks, following up',
            'msg-outage-reply-1@example.invalid', '<outage-root@example.invalid>', null);
        setOutageMock();

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'Degrading on an LLM outage must not bypass the reply guard — a reply still creates no Lead');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPLY, updatedStaging.Outcome__c,
            'The reply label must win over the LLM-unavailable label: the outage flag changes the OUTCOME LABEL only on branch (c), never which branch is taken');
        Assert.areEqual(existingLead.Id, updatedStaging.Result_Record_Id__c, 'The reply should still resolve to the original thread\'s record');
    }

    // ── idempotency: duplicate Message-ID redelivery ─────────────────────────

    @isTest
    static void execute_duplicateMessageIdRedelivery_isSkippedNotReprocessed() {
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'idempotent@example.invalid',
            'property_address' => '555 Idempotent Ln', 'sent_datetime' => ''
        });

        Inbound_Email_Staging__c staging1 = insertStaging(
            'idempotent@example.invalid', 'forwarder7@example.invalid',
            'FW: 555 Idempotent Ln', 'first delivery',
            'dup-id-123@example.invalid', null, null);
        Inbound_Email_Staging__c staging2 = insertStaging(
            'idempotent@example.invalid', 'forwarder7@example.invalid',
            'FW: 555 Idempotent Ln', 'redelivered copy',
            'dup-id-123@example.invalid', null, null);

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging1.Id, null, null));
        System.enqueueJob(new ExtractAddressQueueable(staging2.Id, null, null));
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Email = 'idempotent@example.invalid'], 'Only the first delivery should create a Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'dup-id-123@example.invalid'], 'Only one Task should ever carry this Message-ID');

        Inbound_Email_Staging__c updatedStaging2 = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging2.Id
        ];
        Assert.areEqual('Processed', updatedStaging2.Status__c, 'The skipped redelivery still reaches a terminal Processed state');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE_DELIVERY, updatedStaging2.Outcome__c,
            'The redelivery should be labeled a duplicate delivery, not reprocessed');
        Assert.isNull(updatedStaging2.Result_Record_Id__c, 'A skipped redelivery records no routed record');
    }

    // ── auto-forward detection flows through to the Lead ─────────────────────

    @isTest
    static void execute_forwardedByFromStaging_flowsThroughToLeadForwardedByEmail() {
        Inbound_Email_Staging__c staging = insertStaging(
            'broker8@example.invalid', 'monitoring@example.com',
            'FW: monitored inbox test', 'body',
            'msg-monitored-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'broker8@example.invalid',
            'property_address' => '', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [SELECT Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id];
        Lead created = [SELECT Forwarded_By_Email__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.areEqual('monitoring@example.com', created.Forwarded_By_Email__c,
            'Whatever monitored inbox EmailToLeadHandler resolved onto staging.Forwarded_By__c must flow through to the Lead');
    }

    // ── race recovery: orphan adoption ────────────────────────────────────────

    @isTest
    static void execute_orphanedRegistryKey_isAdoptedByNewWinnerNotDuplicated() {
        Lead deletedWinner = TestDataFactory.createLead(true);
        Property_Registry__c orphan = TestDataFactory.createPropertyRegistry('900 orphan way', deletedWinner.Id, true);
        orphan.Winning_Lead__c = null;
        update orphan; // simulates the winning Lead having been deleted (SetNull)

        Inbound_Email_Staging__c staging = insertStaging(
            'orphan.claimant@example.invalid', 'forwarder9@example.invalid',
            'FW: 900 Orphan Way', 'body',
            'msg-orphan-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'New Broker', 'broker_email' => 'orphan.claimant@example.invalid',
            'property_address' => '900 Orphan Way', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '900 orphan way'],
            'The orphan row must be ADOPTED, not duplicated — still exactly one row for this key');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c, 'Adopting an orphan is still a winning claim');

        Property_Registry__c adopted = [SELECT Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c = '900 orphan way'];
        Assert.areEqual(updatedStaging.Result_Record_Id__c, adopted.Winning_Lead__c, 'The new Lead should now own the previously orphaned registry row');

        // The assertion that stood here checked Is_Duplicate_Property__c was false. Nothing
        // writes that legacy field any more, so it could only ever BE false — a vacuous
        // assertion that would keep passing even if orphan adoption broke entirely. Assert the
        // properties that actually distinguish a winner instead: the Lead survives (only a lost
        // race deletes one) and it owns the WINNING submission row.
        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c],
            'The orphan-adopting Lead must survive — only a lost race deletes a Lead');

        Competing_Broker_Submission__c sub = [
            SELECT Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :updatedStaging.Result_Record_Id__c
        ];
        Assert.isTrue(sub.Is_Winning_Submission__c,
            'A Lead that adopts an orphaned registry key is a WINNER, so its submission must be flagged as the winning row');
        Assert.areEqual(updatedStaging.Result_Record_Id__c, String.valueOf(sub.Source_Lead__c),
            'A winner keeps its own Source_Lead__c — only a losing broker\'s submission is source-less');
    }

    // ── graceful handling of a blank Message-ID ───────────────────────────────

    @isTest
    static void execute_nullMessageId_processesNormallyWithoutIdempotencyCheck() {
        Inbound_Email_Staging__c staging = insertStaging(
            'broker10@example.invalid', 'forwarder10@example.invalid',
            'FW: 1000 No Message Id Rd', 'body',
            null, null, null); // Message_Id__c left null on purpose
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'broker10@example.invalid',
            'property_address' => '1000 No Message Id Rd', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [SELECT Status__c, Outcome__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id];
        Assert.areEqual('Processed', updatedStaging.Status__c, 'A blank Message-ID should not block processing');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c,
            'A blank Message-ID should route normally (here: a winning claim), never the duplicate-delivery skip label');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '1000 no message id rd'],
            'The claim should still be registered even though there was no Message-ID to key idempotency on');
    }

    // ── missing staging row (hard-deleted between insert and async run) ──────

    @isTest
    static void execute_stagingHardDeletedBeforeAsyncRun_returnsGracefullyWithoutError() {
        Inbound_Email_Staging__c staging = insertStaging(
            'ghost@example.invalid', 'forwarder12@example.invalid',
            'FW: will be deleted', 'body',
            'msg-ghost-1@example.invalid', null, null);
        Id stagingId = staging.Id;
        delete staging;

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(stagingId, null, null));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = 'ghost@example.invalid'],
            'A staging row missing at async run time should produce no Lead and no exception');
    }

    // ── forceClaimRace test seam: the LOST RACE deletes the racer's Lead ──────

    @isTest
    static void execute_forceClaimRaceSeam_deletesTheRacersLeadAndLogsSubmissionOnWinner() {
        Lead existingWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('600 race ave', existingWinner.Id, true);

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'racer@example.invalid', 'forwarder11@example.invalid',
            'FW: 600 Race Ave', 'body',
            'msg-race-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Racer Broker', 'broker_email' => 'racer@example.invalid',
            'property_address' => '600 Race Ave', 'sent_datetime' => ''
        });

        ExtractAddressQueueable.forceClaimRace = true;
        try {
            Test.startTest();
            System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
            Test.stopTest();
        } finally {
            ExtractAddressQueueable.forceClaimRace = false;
        }

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '600 race ave'],
            'Forcing the queueable\'s upfront shortcut off must not create a second registry row for the same key');

        // The distinguishing behaviour of this branch: unlike branch (d), a Lead really WAS
        // created here (the pre-read shortcut was skipped, so the queueable believed the
        // property was free) and must be removed once claim() reports the race was lost.
        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'The racer\'s Lead must be DELETED once claim() reports DUPLICATE_RACE — a broker who loses the race gets no Lead');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = 'racer@example.invalid'],
            'Specifically, the Lead created for the racing broker must be gone');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        // W4: forceClaimRace skips ONLY the queueable's own cheap upfront findMatchingRegistry
        // shortcut. PropertyClaimService.claim() runs its OWN findMatchingRegistry check under
        // the cluster lock regardless, so the race is still detected — just one layer deeper.
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE_RACE, updatedStaging.Outcome__c,
            'A race lost inside claim() gets its own label, distinct from a settled competing submission, because it is the only shape where a Lead briefly existed');
        Assert.areEqual(existingWinner.Id, updatedStaging.Result_Record_Id__c,
            'Result_Record_Id__c should point at the real winner, not at the deleted Lead');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :existingWinner.Id
        ];
        Assert.areEqual(1, subs.size(), 'The race loser should still be logged as a competing submission under the winner');
        Assert.isNull(subs[0].Source_Lead__c,
            'Deleting the racer\'s Lead clears Source_Lead__c through the lookup\'s SetNull delete constraint, leaving the same source-less shape branch (d) writes directly');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The race loser\'s submission must not be flagged as the winner');

        Task logged = [SELECT WhoId FROM Task WHERE Inbound_Message_Id__c = 'msg-race-1@example.invalid'];
        Assert.areEqual(existingWinner.Id, logged.WhoId,
            'The racer\'s email must be logged on the WINNING Lead — the Lead it would otherwise have gone to no longer exists');
    }

    // ── regex fallback (applyRegexFallback) ──────────────────────────────────

    @isTest
    static void execute_blankBrokerFields_backfillsFromRawFromLineViaRegex() {
        String textContent = 'From: Jane Broker <jane@x.com>\n' +
            'Sent: Monday, January 5, 2026 10:00 AM\n' +
            'To: forwarder@dpeg.example.invalid\n' +
            'Subject: FW: Property listing\n\n' +
            'Please see attached.';
        Inbound_Email_Staging__c staging = insertStaging(
            'forwarder@dpeg.example.invalid', 'forwarder@dpeg.example.invalid',
            'FW: Property listing', textContent,
            'msg-regex-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '500 Fallback Ave', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [SELECT Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id];
        Lead created = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.areEqual('Jane', created.FirstName, 'FirstName should be backfilled from the raw From: line via regex');
        Assert.areEqual('Broker', created.LastName, 'LastName should be backfilled from the raw From: line via regex');
        Assert.areEqual('jane@x.com', created.Email, 'Email should be backfilled from the raw From: line via regex');
    }

    @isTest
    static void execute_onlyBrokerNameBlank_regexFallbackDoesNotOverwriteLlmEmail() {
        String textContent = 'From: Jane Broker <jane@x.com>\nSent: Monday\nTo: forwarder@dpeg.example.invalid\n\nBody.';
        Inbound_Email_Staging__c staging = insertStaging(
            'forwarder@dpeg.example.invalid', 'forwarder@dpeg.example.invalid',
            'FW: partial', textContent,
            'msg-regex-2@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => 'llm.broker@example.invalid', 'property_address' => '', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [SELECT Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id];
        Lead created = [SELECT FirstName, LastName, Email FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.areEqual('Jane', created.FirstName, 'The blank broker_name should still be backfilled by regex');
        Assert.areEqual('Broker', created.LastName, 'The blank broker_name should still be backfilled by regex');
        Assert.areEqual('llm.broker@example.invalid', created.Email, 'A non-blank LLM broker_email must not be overwritten by the regex fallback');
    }

    // ── parseSentDatetime fallback ────────────────────────────────────────────

    @isTest
    static void execute_unparseableSentDatetime_fallsBackToNow() {
        Inbound_Email_Staging__c staging = insertStaging(
            'baddate@example.invalid', 'forwarder13@example.invalid',
            'FW: bad date', 'body',
            'msg-baddate-1@example.invalid', null, null);
        setMock(new Map<String, String>{
            'broker_name' => 'Jane Broker', 'broker_email' => 'baddate@example.invalid',
            'property_address' => '700 Fallback Time Ave', 'sent_datetime' => 'not-a-real-date'
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [SELECT Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id];
        Competing_Broker_Submission__c sub = [
            SELECT Submitted_DateTime__c FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :updatedStaging.Result_Record_Id__c
        ];
        Assert.isNotNull(sub.Submitted_DateTime__c, 'An unparseable sent_datetime must still stamp a value (now())');
        Assert.isTrue(Math.abs(sub.Submitted_DateTime__c.getTime() - Datetime.now().getTime()) < 60000,
            'The fallback value should be approximately now(), not the unparseable raw string');
    }

    // ── volume / concurrency (governor-limit-aware — see class header) ───────

    /** Custom mock that echoes a distinct broker/property per job, derived from an
     *  "IDX:n" marker embedded in that job's own staging Raw_Body__c, so 25 jobs run
     *  in one transaction can each be proven to win their own distinct property. */
    private class VolumeMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            String body = req.getBody();
            Matcher idxMatcher = Pattern.compile('IDX:(\\d+)').matcher(body);
            String idx = idxMatcher.find() ? idxMatcher.group(1) : '0';
            Map<String, String> fields = new Map<String, String>{
                'broker_name' => 'Broker ' + idx,
                'broker_email' => 'broker' + idx + '@example.invalid',
                'property_address' => idx + ' Volume St',
                'sent_datetime' => ''
            };
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(LLMExtractionCalloutMock.successBody(JSON.serialize(fields)));
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    @isTest
    static void execute_manyConcurrentEmails_noCrossContaminationBetweenJobs() {
        Integer jobCount = 25;
        List<Inbound_Email_Staging__c> stagings = new List<Inbound_Email_Staging__c>();
        for (Integer i = 0; i < jobCount; i++) {
            stagings.add(new Inbound_Email_Staging__c(
                From_Name__c = 'Broker ' + i,
                From_Address__c = 'envelope' + i + '@example.invalid',
                Subject__c = 'FW: Volume St ' + i,
                Raw_Body__c = 'forwarded body IDX:' + i,
                Forwarded_By__c = 'forwarder@example.invalid',
                Message_Id__c = 'msg-volume-' + i + '@example.invalid'
            ));
        }
        insert stagings;
        Test.setMock(HttpCalloutMock.class, new VolumeMock());

        Test.startTest();
        for (Inbound_Email_Staging__c staging : stagings) {
            System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        }
        Test.stopTest();

        List<Property_Registry__c> registries = [
            SELECT Property_Key__c, Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c LIKE '%volume st'
        ];
        Assert.areEqual(jobCount, registries.size(),
            'Each of the ' + jobCount + ' concurrent emails should independently win its own distinct property — no shared/static state should leak between queueable executions');

        Set<Id> distinctWinners = new Set<Id>();
        for (Property_Registry__c r : registries) {
            distinctWinners.add(r.Winning_Lead__c);
        }
        Assert.areEqual(jobCount, distinctWinners.size(), 'Every job should produce its own distinct winning Lead, never reusing another job\'s Lead');
    }

    @isTest
    static void execute_replyThreadedAmong251PriorTasks_stillFindsTheCorrectThread() {
        Lead threadLead = TestDataFactory.createLead(true);

        List<Task> noise = new List<Task>();
        for (Integer i = 0; i < 250; i++) {
            noise.add(new Task(
                Subject = 'Noise ' + i, Status = 'Completed', TaskSubtype = 'Email',
                WhoId = threadLead.Id,
                Inbound_Message_Id__c = 'noise-' + i + '@example.invalid',
                Thread_Key__c = 'noise-thread-' + i + '@example.invalid'
            ));
        }
        insert noise;
        insert new Task(
            Subject = 'The real thread root', Status = 'Completed', TaskSubtype = 'Email',
            WhoId = threadLead.Id,
            Inbound_Message_Id__c = 'the-real-root@example.invalid',
            Thread_Key__c = 'the-real-root@example.invalid'
        );
        Assert.areEqual(251, [SELECT COUNT() FROM Task WHERE WhoId = :threadLead.Id], 'Precondition: 251 prior Tasks should exist under this Lead');

        Inbound_Email_Staging__c staging = insertStaging(
            'anyone@example.invalid', 'forwarder14@example.invalid',
            'RE: The real thread root', 'reply body',
            'msg-reply-among-many-1@example.invalid', '<the-real-root@example.invalid>', null);
        setMock(new Map<String, String>{
            'broker_name' => '', 'broker_email' => '', 'property_address' => '999 Ignored Ave', 'sent_datetime' => ''
        });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPLY, updatedStaging.Outcome__c, 'The reply should still be recognized among 251 prior Tasks');
        Assert.areEqual(threadLead.Id, updatedStaging.Result_Record_Id__c,
            'The reply should resolve to the SAME thread\'s Lead, not any of the 250 noise Tasks\' unrelated threads');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // D1 MULTI-PROPERTY — the §7 replacements for the retired 251-record mandate.
    //
    // WHY 251 IS NOT USED HERE, and why that is not a gap: the exemption in
    // .claude/rules/bulk-test-rule.md was NARROWED on 2026-07-31 (design C-18) and no longer
    // covers this class, because execute() now loops. A literal 251 is nevertheless both
    // IMPOSSIBLE and MEANINGLESS for it — System.enqueueJob caps at 50 calls per transaction,
    // and 251 properties in ONE email would exhaust the SOQL limit at roughly 14-24 properties,
    // which is precisely why MAX_PROPERTIES is 10. Testing a volume production cannot reach is
    // the anti-pattern the exemption existed to prevent. The tests below are the specified
    // replacement: cap-volume, truncation, mixed outcomes, ordering determinism, and governor
    // headroom.
    // ═════════════════════════════════════════════════════════════════════════

    /** Builds N distinct, cluster-key-orderable addresses. */
    private static List<String> addresses(Integer count) {
        List<String> result = new List<String>();
        for (Integer i = 1; i <= count; i++) {
            // Zero-padded so the lexical cluster-key order is predictable in assertions.
            result.add(String.valueOf(1000 + i) + ' Multi St');
        }
        return result;
    }

    private static void setPropertiesMock(String brokerEmail, List<String> propertyAddresses) {
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(
            200, LLMExtractionCalloutMock.propertiesBody(brokerEmail, propertyAddresses)));
    }

    @isTest
    static void execute_tenPropertyEmail_routesEveryPropertyAndStaysInsideTheGovernorBudget() {
        // §7 items 1 + 3 — the MAX_PROPERTIES volume case AND the headroom guard, asserted
        // together because they describe the same execution.
        //
        // NAMED BUDGETS, not the raw platform caps: the point is to fail HERE when a future
        // change adds a query per property, long before it fails in production at N = 8.
        final Integer QUERY_BUDGET = 120;   // async cap is 200
        final Integer DML_BUDGET = 60;      // async cap is 150

        Inbound_Email_Staging__c staging = insertStaging(
            'blast.broker@example.invalid', 'forwarder20@example.invalid',
            'FW: 10-property portfolio', 'portfolio body',
            'msg-multi-10@example.invalid', null, null);
        setPropertiesMock('blast.broker@example.invalid', addresses(10));

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Routed_Record_Ids__c, Property_Count__c, Error__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c, 'A 10-property email must route cleanly');
        Assert.isNull(updatedStaging.Error__c, 'No property should have failed');
        Assert.areEqual(10, updatedStaging.Property_Count__c, 'Property_Count__c records what the extraction found');
        Assert.isTrue(updatedStaging.Outcome__c.startsWith(ExtractAddressQueueable.OUTCOME_MULTI_PREFIX + ' (10)'),
            'A multi-property email must summarise with the stable, filterable prefix. Actual: ' + updatedStaging.Outcome__c);
        Assert.areEqual(10, updatedStaging.Routed_Record_Ids__c.split('\n').size(),
            'Routed_Record_Ids__c is the ONLY place the full property-to-record mapping exists — one line per property');

        Assert.areEqual(10, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c LIKE '%multi st'],
            'Each of the 10 properties must take its own claim — that is the whole point of D1');
        Assert.areEqual(10, [SELECT COUNT() FROM Lead WHERE Property_Address__c LIKE '%Multi St'],
            'One Lead per property, per the restated invariant');

        Assert.isTrue(ExtractAddressQueueable.lastRunQueryCount <= QUERY_BUDGET,
            'GOVERNOR HEADROOM: 10 properties consumed ' + ExtractAddressQueueable.lastRunQueryCount
            + ' SOQL queries against a budget of ' + QUERY_BUDGET + '. If this fails, a change has added '
            + 'per-property queries — fix that rather than raising the budget, because the async cap is 200 '
            + 'and production hits it before this test does.');
        Assert.isTrue(ExtractAddressQueueable.lastRunDmlCount <= DML_BUDGET,
            'GOVERNOR HEADROOM: 10 properties consumed ' + ExtractAddressQueueable.lastRunDmlCount
            + ' DML statements against a budget of ' + DML_BUDGET + ' (async cap 150)');
        Assert.isTrue(ExtractAddressQueueable.lastRunQueryCount > 0,
            'Sanity: the telemetry must actually have been captured, or the two assertions above are vacuous');
    }

    @isTest
    static void execute_fifteenProperties_truncatesVisiblyAtTheCap() {
        // §7 item 2. Truncation must be VISIBLE in three independent places, because the whole
        // design principle is that dropping a broker's property silently is unacceptable.
        Inbound_Email_Staging__c staging = insertStaging(
            'overflow.broker@example.invalid', 'forwarder21@example.invalid',
            'FW: 15-property blast', 'blast body',
            'msg-multi-15@example.invalid', null, null);
        setPropertiesMock('overflow.broker@example.invalid', addresses(15));

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Routed_Record_Ids__c, Property_Count__c, Result_Record_Id__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(15, updatedStaging.Property_Count__c,
            'Property_Count__c records what the extraction FOUND (M), pre-truncation');
        Assert.areEqual(ExtractAddressQueueable.MAX_PROPERTIES, updatedStaging.Routed_Record_Ids__c.split('\n').size(),
            'Only MAX_PROPERTIES may be routed — the gap between this and Property_Count__c IS the signal');
        Assert.isTrue(updatedStaging.Outcome__c.contains('[truncated: 10 of 15]'),
            'The outcome must state the truncation explicitly. Actual: ' + updatedStaging.Outcome__c);
        Assert.areEqual(ExtractAddressQueueable.MAX_PROPERTIES,
            [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c LIKE '%multi st'],
            'Exactly MAX_PROPERTIES claims should be registered');

        Lead firstLead = [
            SELECT Deal_Notes__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c
        ];
        Assert.isTrue(firstLead.Deal_Notes__c.contains('Additional properties in this email'),
            'The un-routed remainder must be written onto the FIRST Lead so a human can act on it (C-1)');
    }

    @isTest
    static void execute_scrambledInput_isProcessedInDeterministicClusterKeyOrder() {
        // §7 item 5, the END-TO-END half. True concurrency is not reproducible in Apex, so this
        // asserts the observable proxy: whatever order the MODEL returned, the routed audit comes
        // back in cluster-key order. That ordering is what makes an AB-BA deadlock impossible.
        List<String> scrambled = new List<String>{
            '3003 Multi St', '1001 Multi St', '2002 Multi St'
        };
        Inbound_Email_Staging__c staging = insertStaging(
            'order.broker@example.invalid', 'forwarder22@example.invalid',
            'FW: scrambled order', 'body',
            'msg-multi-order@example.invalid', null, null);
        setPropertiesMock('order.broker@example.invalid', scrambled);

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        String audit = [
            SELECT Routed_Record_Ids__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ].Routed_Record_Ids__c;
        List<String> lines = audit.split('\n');
        Assert.areEqual(3, lines.size(), 'All three properties should be routed');
        Assert.isTrue(lines[0].startsWith('1001 multi st'),
            'Processing order must be ascending CLUSTER KEY, never the model\'s array order. Actual: ' + audit);
        Assert.isTrue(lines[1].startsWith('2002 multi st'), 'Second by cluster key. Actual: ' + audit);
        Assert.isTrue(lines[2].startsWith('3003 multi st'), 'Third by cluster key. Actual: ' + audit);
    }

    @isTest
    static void buildWorkList_sortsByClusterKeyAndDeduplicatesOnNormalizedAddress() {
        // §7 item 5, the PURE-FUNCTION half — the only part of the deadlock guarantee that can be
        // asserted directly, with no platform dependency at all.
        List<PropertyExtraction> input = new List<PropertyExtraction>();
        for (String raw : new List<String>{
                '900 Zulu Ave', '100 Alpha St', '100 Alpha St.', '  ', '500 Mike Rd' }) {
            PropertyExtraction property = new PropertyExtraction();
            property.propertyAddress = raw;
            input.add(property);
        }
        input.add(null);

        Test.startTest();
        List<PropertyExtraction> workList = ExtractAddressQueueable.buildWorkList(input);
        Test.stopTest();

        Assert.areEqual(3, workList.size(),
            'Blank and null entries drop out, and "100 Alpha St" / "100 Alpha St." normalize to ONE key — '
            + 'de-duplication is on the NORMALIZED ADDRESS, never on the coarse cluster key');
        Assert.areEqual('100 alpha st', workList[0].normalizedAddress, 'Ascending cluster key puts 100 Alpha first');
        Assert.areEqual('500 mike rd', workList[1].normalizedAddress, 'Then 500 Mike');
        Assert.areEqual('900 zulu ave', workList[2].normalizedAddress, 'Then 900 Zulu');
        Assert.areEqual('100 alpha', workList[0].clusterKey,
            'The cluster key must be derived from the ADDRESS, since the model\'s array order is not stable across transactions');
    }

    @isTest
    static void buildWorkList_emptyAndNullInput_returnEmptyListsNotNull() {
        Test.startTest();
        List<PropertyExtraction> fromNull = ExtractAddressQueueable.buildWorkList(null);
        List<PropertyExtraction> fromEmpty = ExtractAddressQueueable.buildWorkList(new List<PropertyExtraction>());
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null property array must yield an empty work-list, never an NPE');
        Assert.areEqual(0, fromEmpty.size(), 'An empty property array must yield an empty work-list');
    }

    @isTest
    static void execute_mixedOutcomeEmail_routesWinnerCompetingAndRepeatIndependently() {
        // §7 item 4 — the normal case for a broker blast, not an edge case: one email whose
        // properties land on three DIFFERENT branches. The critical property is INDEPENDENCE:
        // the competing and repeat properties must not stop the winner from claiming.
        Lead otherWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('2002 multi st', otherWinner.Id, true);

        Lead priorLead = TestDataFactory.createLead(true);
        Competing_Broker_Submission__c priorSub =
            TestDataFactory.createCompetingBrokerSubmission(priorLead.Id, false);
        priorSub.Broker_Email__c = 'mixed.broker@example.invalid';
        priorSub.Property_Address_Raw__c = '3003 Multi St';
        priorSub.Submitted_DateTime__c = Datetime.now().addDays(-1);
        insert priorSub;

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Inbound_Email_Staging__c staging = insertStaging(
            'mixed.broker@example.invalid', 'forwarder23@example.invalid',
            'FW: mixed outcomes', 'body',
            'msg-multi-mixed@example.invalid', null, null);
        setPropertiesMock('mixed.broker@example.invalid',
            new List<String>{ '1001 Multi St', '2002 Multi St', '3003 Multi St' });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore + 1, [SELECT COUNT() FROM Lead],
            'Exactly ONE Lead: the winner property. The competing property gets none (2026-07-31) and the repeat reuses the prior record');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c, Routed_Record_Ids__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.isTrue(updatedStaging.Outcome__c.contains(ExtractAddressQueueable.OUTCOME_WINNER),
            'The summary must name the winner. Actual: ' + updatedStaging.Outcome__c);
        Assert.isTrue(updatedStaging.Outcome__c.contains(ExtractAddressQueueable.OUTCOME_DUPLICATE),
            'The summary must name the competing submission. Actual: ' + updatedStaging.Outcome__c);
        Assert.isTrue(updatedStaging.Outcome__c.contains(ExtractAddressQueueable.OUTCOME_REPEAT),
            'The summary must name the repeat. Actual: ' + updatedStaging.Outcome__c);

        Lead winnerLead = [
            SELECT Id FROM Lead WHERE Property_Address__c = '1001 Multi St' LIMIT 1
        ];
        Assert.areEqual(winnerLead.Id, updatedStaging.Result_Record_Id__c,
            'Result_Record_Id__c is Text(18) and must carry the PRIMARY record — the winner Lead outranks the others');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '1001 multi st'],
            'The winner property must still claim, independently of the other two properties\' outcomes');
        Assert.areEqual(1, [
            SELECT COUNT() FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :otherWinner.Id AND Source_Lead__c = null
        ], 'The competing property logs a source-less submission under the OTHER broker\'s winner');

        // One Task per DISTINCT routed record (C-2): winner Lead, the other broker's winner, and
        // the repeat's prior Lead — three records, three Tasks, one Message-ID, one bulk DML.
        Assert.areEqual(3, [
            SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-multi-mixed@example.invalid'
        ], 'One Task per DISTINCT routed record: a competing submission with no email behind it is a claim nobody can audit');
    }

    @isTest
    static void execute_multiPropertyEmail_logsTheHighestPriorityTaskLast() {
        // C-3. The N Tasks share a CreatedDate to the millisecond, so TaskSelector's `, Id DESC`
        // tie-break is what decides where a later REPLY lands — and it only lands correctly
        // because the winner is inserted LAST. Without both halves the reply is undefined.
        Lead otherWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('2002 multi st', otherWinner.Id, true);

        Inbound_Email_Staging__c staging = insertStaging(
            'priority.broker@example.invalid', 'forwarder24@example.invalid',
            'FW: priority order', 'body',
            'msg-multi-priority@example.invalid', null, null);
        setPropertiesMock('priority.broker@example.invalid',
            new List<String>{ '1001 Multi St', '2002 Multi St' });

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        List<Task> logged = [
            SELECT WhoId FROM Task
            WHERE Inbound_Message_Id__c = 'msg-multi-priority@example.invalid'
            ORDER BY CreatedDate DESC, Id DESC
        ];
        Assert.areEqual(2, logged.size(), 'Two distinct routed records means two Tasks');

        Id winnerLeadId = [SELECT Id FROM Lead WHERE Property_Address__c = '1001 Multi St' LIMIT 1].Id;
        Assert.areEqual(winnerLeadId, logged[0].WhoId,
            'The WINNER\'s Task must sort first under `CreatedDate DESC, Id DESC` — that is what lands a later '
            + 'reply on the deal DPEG actually owns instead of on an arbitrary row');
    }

    @isTest
    static void execute_replyIntoAMultiPropertyThread_resolvesToTheRecordWeOwn() {
        // §7 item 6 — the payoff of C-3, end to end. A multi-property email anchors the SAME
        // thread key on several records; a later reply must land deterministically on the deal
        // DPEG owns, not on whichever row the database happened to return first.
        Lead otherWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('2002 multi st', otherWinner.Id, true);

        Inbound_Email_Staging__c original = insertStaging(
            'thread.broker@example.invalid', 'forwarder29@example.invalid',
            'FW: two properties', 'body',
            'multi-thread-root@example.invalid', null, null);
        setPropertiesMock('thread.broker@example.invalid',
            new List<String>{ '1001 Multi St', '2002 Multi St' });

        Inbound_Email_Staging__c reply = insertStaging(
            'thread.broker@example.invalid', 'forwarder29@example.invalid',
            'RE: two properties', 'Any interest?',
            'multi-thread-reply@example.invalid', '<multi-thread-root@example.invalid>', null);

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(original.Id, null, null));
        System.enqueueJob(new ExtractAddressQueueable(reply.Id, null, null));
        Test.stopTest();

        Id winnerLeadId = [SELECT Id FROM Lead WHERE Property_Address__c = '1001 Multi St' LIMIT 1].Id;
        Inbound_Email_Staging__c updatedReply = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :reply.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPLY, updatedReply.Outcome__c,
            'The second email is a reply into the thread the first one anchored');
        Assert.areEqual(winnerLeadId, updatedReply.Result_Record_Id__c,
            'The reply must resolve to the WINNER\'s Lead. This works only because the Tasks were inserted '
            + 'in ascending priority AND TaskSelector orders by `CreatedDate DESC, Id DESC` — remove either '
            + 'half and this becomes undefined, since N Tasks from one bulk DML share a CreatedDate');
    }

    // ── D2 RELEVANCE GATE + the deterministic pre-filter ─────────────────────

    @isTest
    static void execute_confidentlyNotAcquisition_createsNoLeadButStillLogsTheEmail() {
        Integer leadsBefore = [SELECT COUNT() FROM Lead];
        Inbound_Email_Staging__c staging = insertStaging(
            'newsletter@example.invalid', 'forwarder25@example.invalid',
            'Weekly market roundup', 'newsletter body',
            'msg-gated-1@example.invalid', null, null);
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200,
            LLMExtractionCalloutMock.enrichedBody(new Map<String, Object>{
                'email_category' => 'newsletter',
                'is_acquisition_related' => false,
                'confidence' => 0.97,
                'broker_email' => 'newsletter@example.invalid'
            }, new List<Map<String, Object>>())));

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A confident not-acquisition classification must produce NO Lead — the Gmail forwarding-confirmation case');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c, Extracted_JSON__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_NOT_ACQUISITION, updatedStaging.Outcome__c,
            'The gate must be recorded distinctly from a pre-filter hit — the follow-up differs');
        Assert.isNull(updatedStaging.Result_Record_Id__c, 'A gated email routes to no record');
        Assert.isTrue(String.isNotBlank(updatedStaging.Extracted_JSON__c),
            'D3: the extraction is stored BEFORE routing, so it survives even the branch that creates nothing');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-gated-1@example.invalid'],
            'The Task MUST still be logged, or a redelivery of this message re-runs the whole pipeline forever');
    }

    @isTest
    static void execute_notAcquisitionButUnsure_stillCreatesTheLeadAndStillClaims() {
        // The SOFT tier. Deliberately asymmetric: claiming a junk address costs one deletable
        // registry row, while failing to claim a real one costs a broker their commission.
        Inbound_Email_Staging__c staging = insertStaging(
            'unsure.broker@example.invalid', 'forwarder26@example.invalid',
            'FW: possibly a deal', 'ambiguous body',
            'msg-soft-1@example.invalid', null, null);
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200,
            LLMExtractionCalloutMock.enrichedBody(new Map<String, Object>{
                'is_acquisition_related' => false,
                'confidence' => 0.42,
                'broker_email' => 'unsure.broker@example.invalid'
            }, new List<Map<String, Object>>{
                new Map<String, Object>{ 'property_address' => '4004 Soft Gate Rd' }
            })));

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c,
            'A LOW-confidence not-acquisition verdict must NOT gate: the soft tier creates the Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '4004 soft gate rd'],
            'THE SOFT TIER STILL CLAIMS — generosity is the correct bias for a first-come-first-served ledger');
        Assert.areEqual('LOW', [
            SELECT Parse_Confidence__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c
        ].Parse_Confidence__c, 'The Lead is flagged LOW so it surfaces in the existing Review_Queue list view');
    }

    @isTest
    static void execute_forwardingNoreplySender_isPreFilteredWithoutACallout() {
        // The canonical case: Gmail's forwarding confirmations arrive from
        // forwarding-noreply@google.com, whose local part is neither an exact nor a prefix match
        // on 'noreply' — which is why matching is on the COMPACTED local part.
        Integer leadsBefore = [SELECT COUNT() FROM Lead];
        Inbound_Email_Staging__c staging = insertStaging(
            'forwarding-noreply@google.example.invalid', 'forwarder27@example.invalid',
            'Gmail Forwarding Confirmation', 'confirm this forwarding request',
            'msg-prefilter-1@example.invalid', null, null);
        // NO mock is set on purpose: if the pre-filter fails to short-circuit, the callout throws
        // and this test fails loudly rather than silently passing.

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'A forwarding-confirmation email must produce no Lead — this is the exact defect the pre-filter was added for');

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Extracted_JSON__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c, 'A pre-filtered email reaches a clean terminal state');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_PRE_FILTERED, updatedStaging.Outcome__c,
            '"A regex rejected it before we ever asked" needs a different label from "the classifier rejected it"');
        Assert.isTrue(updatedStaging.Extracted_JSON__c.contains('pre-filter'),
            'Extracted_JSON__c must never be ambiguously empty — the skip marker says why there is no extraction');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Inbound_Message_Id__c = 'msg-prefilter-1@example.invalid'],
            'The Message-ID must still be recorded, or a redelivery re-runs the pipeline');
    }

    @isTest
    static void execute_autoSubmittedHeader_isPreFilteredWithoutACallout() {
        Integer leadsBefore = [SELECT COUNT() FROM Lead];
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Jane Broker',
            From_Address__c = 'jane@brokerfirm.example.invalid',
            Subject__c = 'Out of office',
            Raw_Body__c = 'I am away until Monday.',
            Raw_Headers__c = 'Subject: Out of office\nAuto-Submitted: auto-replied\n',
            Message_Id__c = 'msg-prefilter-2@example.invalid'
        );
        insert staging;

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'An RFC 3834 auto-reply must not become a Lead even when the sender looks like a real broker');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_PRE_FILTERED, [
            SELECT Outcome__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ].Outcome__c, 'The header match must be recorded as a pre-filter gate');
    }

    // ── `Precedence: bulk` from a normal sender must NOT be hard-gated (code-review ruling) ──
    //
    // PINS THE REVIEWER'S RULING. The design (§2.2 / C-7) originally listed 'bulk' alongside
    // 'auto_reply' in the pre-filter; code review overruled that (user-approved) and
    // PRECEDENCE_PATTERN now matches 'auto_reply' ONLY — see the class header's
    // "🔴 `Precedence: bulk` IS DELIBERATELY EXCLUDED. DO NOT ADD IT" note. The reasoning:
    // `Precedence: bulk` means MASS-SENT, not MACHINE-GENERATED — it is exactly what a
    // legitimate broker BLAST platform (RCM, Crexi, Buildout) sets on a real listing
    // announcement, the highest-value email this pipeline exists to capture. Gating on it
    // BEFORE the callout would deny genuine bulk mail the tiered gate D2 says must judge it,
    // and a false positive here is an unobservable, irreversible LOST CLAIM. This test is what
    // goes red if anyone re-adds 'bulk' to the pre-filter.
    @isTest
    static void execute_precedenceBulkFromNormalSender_isNotPreFilteredAndReachesTheTieredGate() {
        Integer leadsBefore = [SELECT COUNT() FROM Lead];
        Inbound_Email_Staging__c staging = new Inbound_Email_Staging__c(
            From_Name__c = 'Blast Broker',
            From_Address__c = 'blast.broker@brokerfirm.example.invalid',
            Subject__c = 'New Listing: 1500 Bulk Ave',
            Raw_Body__c = 'Pleased to present 1500 Bulk Ave.',
            // A real broker-blast-platform header — 'bulk' means mass-sent, not
            // machine-generated, and must not short-circuit the pipeline before the callout.
            Raw_Headers__c = 'Subject: New Listing: 1500 Bulk Ave\nPrecedence: bulk\n',
            Message_Id__c = 'msg-precedence-bulk-1@example.invalid'
        );
        insert staging;
        // A normal, confident acquisition verdict — the email must be JUDGED by the tiered
        // gate like any other email, not skipped before ever reaching it.
        Test.setMock(HttpCalloutMock.class, new LLMExtractionCalloutMock(200,
            LLMExtractionCalloutMock.enrichedBody(new Map<String, Object>{
                'is_acquisition_related' => true,
                'confidence' => 0.95,
                'broker_name' => 'Blast Broker',
                'broker_email' => 'blast.broker@brokerfirm.example.invalid'
            }, new List<Map<String, Object>>{
                new Map<String, Object>{ 'property_address' => '1500 Bulk Ave' }
            })));

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c, Extracted_JSON__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areNotEqual(ExtractAddressQueueable.OUTCOME_PRE_FILTERED, updatedStaging.Outcome__c,
            '`Precedence: bulk` from a normal sender must NOT be hard pre-filtered. Actual: ' + updatedStaging.Outcome__c);
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_WINNER, updatedStaging.Outcome__c,
            'The email must reach the LLM callout and be judged by the ordinary tiered gate — landing on a '
            + 'winning claim exactly as it would with no Precedence header at all');
        Assert.isNotNull(updatedStaging.Result_Record_Id__c, 'A Lead must be created — the callout was not skipped');
        Assert.isFalse(updatedStaging.Extracted_JSON__c.contains('"skipped"'),
            'Extracted_JSON__c must hold the real callout response, not a pre-filter skip marker — proving the callout actually ran');
        Assert.areEqual(leadsBefore + 1, [SELECT COUNT() FROM Lead], 'Exactly one Lead should be created');
        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '1500 bulk ave'],
            'The claim must be taken — a hard pre-filter would have produced no claim at all');
    }

    @isTest
    static void execute_replyThread_skipsTheCalloutEntirely() {
        // C-6: branch (a) provably never reads the extraction, so it must not pay for one. No
        // mock is registered — a callout here would throw and fail the test.
        Lead existingLead = TestDataFactory.createLead(true);
        insert new Task(
            Subject = 'Original inquiry', Status = 'Completed', TaskSubtype = 'Email',
            WhoId = existingLead.Id,
            Inbound_Message_Id__c = 'no-callout-root@example.invalid',
            Thread_Key__c = 'no-callout-root@example.invalid'
        );

        Inbound_Email_Staging__c staging = insertStaging(
            'anyone@example.invalid', 'forwarder28@example.invalid',
            'RE: Original inquiry', 'Thanks!',
            'msg-reply-nocallout@example.invalid', '<no-callout-root@example.invalid>', null);

        Test.startTest();
        System.enqueueJob(new ExtractAddressQueueable(staging.Id, null, null));
        Test.stopTest();

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Status__c, Outcome__c, Result_Record_Id__c, Extracted_JSON__c
            FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual('Processed', updatedStaging.Status__c,
            'A reply must route with NO callout at all — the highest-volume branch should cost nothing');
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_REPLY, updatedStaging.Outcome__c, 'It is still a Reply');
        Assert.areEqual(existingLead.Id, updatedStaging.Result_Record_Id__c, 'It still lands on the thread\'s record');
        Assert.areEqual('{"skipped":"reply"}', updatedStaging.Extracted_JSON__c,
            'The skip marker keeps Extracted_JSON__c unambiguous: blank would read as "we tried and stored nothing"');
    }
}
