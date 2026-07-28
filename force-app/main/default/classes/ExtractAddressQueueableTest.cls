/**
 * Test class for ExtractAddressQueueable — the async routing tree (staging model,
 * Phase 3 rewrite). Every scenario inserts an Inbound_Email_Staging__c row directly
 * (bypassing EmailToLeadHandler, which has its own test class), mocks the LLM
 * callout boundary via the shared LLMExtractionCalloutMock (set before
 * Test.startTest()), enqueues the job, and lets it run synchronously at
 * Test.stopTest() so its effects can be asserted.
 *
 * COVERS the routing tree's 10 branches end to end: Reply Thread, Repeat (via the
 * LLM's broker_email and via the envelope-From fallback), No-Property, Competing
 * Duplicate, Winner, Idempotent Redelivery, Auto-forward Detection, Race Recovery
 * (orphan adoption), and a null Message-ID. Plus the regex-fallback backfill, the
 * forceClaimRace test seam, the missing-staging-row guard, the
 * unparseable-sent_datetime fallback, and the DEGRADED-EXTRACTION path (W1) — a
 * CalloutException from the LLM boundary must land on branch (c) with a distinct
 * outcome label rather than aborting the email onto an Error row.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes in
 * this exact module (PropertyClaimServiceTest, PropertyMatchingServiceTest).
 *
 * NOTE ON THE 251-RECORD BULK MANDATE (.claude/rules/bulk-test-rule.md): this class
 * is architecturally ONE INSTANCE PER INBOUND EMAIL (see its own class header —
 * "One instance is enqueued per inbound broker email"), the same
 * per-transaction-singleton shape ARCHITECTURE.md §2 already exempts for
 * EmailToLeadService / PropertyClaimService / PropertyMatchingService in this same
 * module. A literal loop of 251 sequential System.enqueueJob calls does not exist in
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

    // ── (d) DUPLICATE ────────────────────────────────────────────────────────

    @isTest
    static void execute_propertyAlreadyClaimed_marksNewLeadAsDuplicateNotSecondWinner() {
        Lead winnerLead = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('200 duplicate st', winnerLead.Id, true);

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

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE, updatedStaging.Outcome__c, 'The outcome should be the duplicate label');

        Lead newLead = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.isTrue(newLead.Is_Duplicate_Property__c, 'The second submitter should be flagged a duplicate');
        Assert.areEqual(winnerLead.Id, newLead.Duplicate_Of_Lead__c, 'It should point at the existing winner');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '200 duplicate st'],
            'No second registry row should be created for an already-claimed property');

        Competing_Broker_Submission__c sub = [
            SELECT Winning_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :newLead.Id
        ];
        Assert.areEqual(winnerLead.Id, sub.Winning_Lead__c, 'The duplicate submission should roll up under the existing winner');
        Assert.isFalse(sub.Is_Winning_Submission__c, 'The duplicate submission must not be flagged as the winner');
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

    // ── (a) REPLY ────────────────────────────────────────────────────────────

    @isTest
    static void execute_replyToExistingThread_filesOnThatRecordWithoutCreatingNewLead() {
        Lead existingLead = TestDataFactory.createLead(true);
        insert new Task(
            Subject = 'Original inquiry', Status = 'Completed', TaskSubtype = 'Email', Type = 'Email',
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
            Subject = 'Original inquiry', Status = 'Completed', TaskSubtype = 'Email', Type = 'Email',
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

        Lead newLead = [SELECT Is_Duplicate_Property__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.isFalse(newLead.Is_Duplicate_Property__c, 'The lead that adopts an orphan is a winner, not a flagged duplicate');
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

    // ── forceClaimRace test seam ───────────────────────────────────────────────

    @isTest
    static void execute_forceClaimRaceSeam_stillReconcilesAsDuplicateViaClaimsOwnPreCheck() {
        Lead existingWinner = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('600 race ave', existingWinner.Id, true);

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

        Inbound_Email_Staging__c updatedStaging = [
            SELECT Outcome__c, Result_Record_Id__c FROM Inbound_Email_Staging__c WHERE Id = :staging.Id
        ];
        // W4: forceClaimRace skips ONLY the queueable's own cheap upfront findMatchingRegistry
        // shortcut. PropertyClaimService.claim() runs its OWN findMatchingRegistry check under
        // the cluster lock regardless, so the two callers converge on the same correct outcome.
        Assert.areEqual(ExtractAddressQueueable.OUTCOME_DUPLICATE, updatedStaging.Outcome__c,
            'With forceClaimRace=true, claim() must still correctly reconcile this lead as a duplicate via its own pre-lock check');

        Lead newLead = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :updatedStaging.Result_Record_Id__c];
        Assert.isTrue(newLead.Is_Duplicate_Property__c, 'The racer should be reconciled as a duplicate');
        Assert.areEqual(existingWinner.Id, newLead.Duplicate_Of_Lead__c, 'The race recovery should point at the real existing winner');
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
                Subject = 'Noise ' + i, Status = 'Completed', TaskSubtype = 'Email', Type = 'Email',
                WhoId = threadLead.Id,
                Inbound_Message_Id__c = 'noise-' + i + '@example.invalid',
                Thread_Key__c = 'noise-thread-' + i + '@example.invalid'
            ));
        }
        insert noise;
        insert new Task(
            Subject = 'The real thread root', Status = 'Completed', TaskSubtype = 'Email', Type = 'Email',
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
}
