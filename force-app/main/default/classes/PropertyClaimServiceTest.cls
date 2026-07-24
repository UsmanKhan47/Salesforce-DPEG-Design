/**
 * Test class for PropertyClaimService: the first-broker-wins claim writer.
 *
 * NOTE on bulk-test scope (.claude/rules/bulk-test-rule.md): claim()/markDuplicate()
 * are deliberately single-record-per-invocation (one inbound email = one call, per
 * the class header). A 251-iteration same-transaction loop would misrepresent the
 * production invocation model (each email runs in its own async transaction) and
 * would risk the 150-DML-statement governor limit for no real coverage benefit.
 * See the Unit Testing report for this as an explicit open item for code review.
 *
 * W4 (concurrency control) ADDITIONS — claim() now derives a coarse cluster key
 * (PropertyMatchingService.deriveClusterKey) and get-or-creates + FOR UPDATE-locks a
 * Property_Claim_Lock__c row for it BEFORE running findMatchingRegistry, so the
 * winner decision happens while holding the lock. Tests below cover: the lock row is
 * created alongside the registry/submission on a first claim; a fuzzy-but-similar
 * address in the SAME cluster still correctly resolves to markDuplicate (the in-lock
 * recheck, exercised sequentially since Apex tests are single-threaded); a repeat
 * claim for the same cluster reuses (never duplicates) the lock row; and a blank
 * normalized address fails safe with zero DML. Two DEFENSIVE branches are
 * deliberately left uncovered (see the Unit Testing report): (1) acquireClusterLock's
 * QueryException-triggered retry (the FOR UPDATE lock-wait timeout) — not
 * deterministically reproducible without a second concurrent transaction; and
 * (2) registerWinner's catch-block re-check for a LIVE winner (as opposed to an
 * orphan) — under serialization a live winner is always caught by claim()'s own
 * pre-insert findMatchingRegistry call first, so DUPLICATE_VALUE can only ever
 * surface for the orphan case in single-threaded execution (the orphan branch itself
 * IS covered, via claim_orphanedKey_adoptsOrphanAndBecomesNewWinner).
 *
 * @author Unit Testing Agent
 */
@isTest
private class PropertyClaimServiceTest {

    private static Map<String, String> extractedFields() {
        return new Map<String, String>{
            'broker_name' => 'Jane Broker',
            'broker_email' => 'jane@brokerfirm.example.invalid',
            'property_address' => '100 Main St, Houston, TX',
            'sent_datetime' => '2026-07-01 10:00:00'
        };
    }

    // ── claim(): first winner ────────────────────────────────────────────────

    @isTest
    static void claim_firstWinner_registersPropertyAndWinningSubmission() {
        Lead sourceLead = TestDataFactory.createLead(true);
        Datetime submittedOn = Datetime.newInstanceGmt(2026, 7, 1, 10, 0, 0);

        Test.startTest();
        PropertyClaimService.claim(
            sourceLead.Id, '100 main st', extractedFields(), submittedOn, 'forwarder@example.invalid', 'FW: 100 Main St'
        );
        Test.stopTest();

        List<Property_Registry__c> registries = [
            SELECT Id, Property_Key__c, Normalized_Address__c, Winning_Lead__c, Registered_DateTime__c
            FROM Property_Registry__c
            WHERE Property_Key__c = '100 main st'
        ];
        Assert.areEqual(1, registries.size(), 'A winner registry row should be created');
        Property_Registry__c registry = registries[0];
        Assert.areEqual(sourceLead.Id, registry.Winning_Lead__c, 'Winning_Lead__c should be the claiming lead');
        Assert.isNotNull(registry.Registered_DateTime__c, 'Registered_DateTime__c should be stamped');
        Assert.isTrue(
            Math.abs(registry.Registered_DateTime__c.getTime() - Datetime.now().getTime()) < 60000,
            'Registered_DateTime__c should be the claim time (now), not the email\'s submitted time'
        );

        List<Competing_Broker_Submission__c> submissions = [
            SELECT Winning_Lead__c, Source_Lead__c, Broker_Name__c, Broker_Email__c, Property_Address_Raw__c,
                   Submitted_DateTime__c, Forwarded_By_Email__c, Email_Subject__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :sourceLead.Id
        ];
        Assert.areEqual(1, submissions.size(), 'A winning submission row should be created');
        Competing_Broker_Submission__c sub = submissions[0];
        Assert.areEqual(sourceLead.Id, sub.Source_Lead__c, 'Source_Lead__c should be the claiming lead');
        Assert.isTrue(sub.Is_Winning_Submission__c, 'The first submission should be flagged as the winner');
        Assert.areEqual('Jane Broker', sub.Broker_Name__c, 'Broker_Name__c should be stamped from the extracted fields');
        Assert.areEqual('jane@brokerfirm.example.invalid', sub.Broker_Email__c, 'Broker_Email__c should be stamped');
        Assert.areEqual('100 Main St, Houston, TX', sub.Property_Address_Raw__c, 'Property_Address_Raw__c should be stamped');
        Assert.areEqual('forwarder@example.invalid', sub.Forwarded_By_Email__c, 'Forwarded_By_Email__c should be stamped');
        Assert.areEqual('FW: 100 Main St', sub.Email_Subject__c, 'Email_Subject__c should be stamped');
        Assert.areEqual(submittedOn, sub.Submitted_DateTime__c, 'Submitted_DateTime__c should be the email\'s original send time');
    }

    @isTest
    static void claim_nullExtractedMap_stillCreatesSubmissionWithNullBrokerFields() {
        Lead sourceLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.claim(
            sourceLead.Id, '200 no extraction ave', null, Datetime.now(), 'forwarder@example.invalid', 'FW: no data'
        );
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '200 no extraction ave'],
            'A registry row should still be created even with a null extracted map');
        Competing_Broker_Submission__c sub = [
            SELECT Broker_Name__c, Broker_Email__c, Property_Address_Raw__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :sourceLead.Id
        ];
        Assert.isNull(sub.Broker_Name__c, 'A null extracted map should null-coalesce to an empty map, leaving fields null (not an NPE)');
        Assert.isNull(sub.Broker_Email__c, 'Broker_Email__c should be null when extracted is null');
    }

    // ── markDuplicate() ──────────────────────────────────────────────────────

    @isTest
    static void markDuplicate_flagsLeadAndLogsNonWinningSubmission() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Property_Registry__c registry = TestDataFactory.createPropertyRegistry('300 winner st', winnerLead.Id, true);
        Lead loserLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.markDuplicate(
            registry, loserLead.Id, extractedFields(), Datetime.now(), 'forwarder2@example.invalid', 'FW: also 300 Winner St'
        );
        Test.stopTest();

        Lead loserAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :loserLead.Id];
        Assert.isTrue(loserAfter.Is_Duplicate_Property__c, 'The losing lead should be flagged as a duplicate property');
        Assert.areEqual(winnerLead.Id, loserAfter.Duplicate_Of_Lead__c, 'Duplicate_Of_Lead__c should point at the winner');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Source_Lead__c = :loserLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the losing lead');
        Assert.areEqual(winnerLead.Id, subs[0].Winning_Lead__c, 'The submission should roll up under the winning lead');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'A duplicate submission must never be flagged as the winner');

        Lead winnerAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c, LastName FROM Lead WHERE Id = :winnerLead.Id];
        Assert.isFalse(winnerAfter.Is_Duplicate_Property__c, 'The winner\'s Lead data must be untouched by marking a competitor as duplicate');
        Assert.isNull(winnerAfter.Duplicate_Of_Lead__c, 'The winner should never itself be flagged as a duplicate');
        Assert.areEqual(winnerLead.LastName, winnerAfter.LastName, 'The winner\'s other fields should be unchanged');
    }

    // ── claim(): duplicate-value race recovery ──────────────────────────────

    @isTest
    static void claim_duplicateValueRace_recoversAsMarkDuplicate() {
        Lead leadA = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('400 race st', leadA.Id, true); // leadA already won this key
        Lead leadB = TestDataFactory.createLead(true);

        Test.startTest();
        // leadB claims the SAME exact key leadA already won. W4 note: under the current
        // lock-then-findMatchingRegistry flow this is now caught by claim()'s own pre-insert
        // exact-key check (findMatchingRegistry finds leadA's registry BEFORE any insert is
        // attempted), rather than by a DUPLICATE_VALUE DmlException on the insert itself — the
        // final reconciliation (leadB becomes a duplicate of leadA) is identical either way, so
        // this test's outcome-level assertions are unchanged post-W4.
        PropertyClaimService.claim(
            leadB.Id, '400 race st', extractedFields(), Datetime.now(), 'forwarder3@example.invalid', 'FW: race'
        );
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '400 race st'],
            'Exactly one registry row should exist for the key — the race loser must not create a second row');

        Lead leadBAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :leadB.Id];
        Assert.isTrue(leadBAfter.Is_Duplicate_Property__c, 'The race-losing lead should be flagged as a duplicate');
        Assert.areEqual(leadA.Id, leadBAfter.Duplicate_Of_Lead__c, 'It should be marked a duplicate of the race winner');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Is_Winning_Submission__c FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :leadB.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the race loser');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The race-recovered submission must not be flagged as the winner');
    }

    // ── claim(): orphan adoption ─────────────────────────────────────────────

    @isTest
    static void claim_orphanedKey_adoptsOrphanAndBecomesNewWinner() {
        Lead deletedWinnersLead = TestDataFactory.createLead(true);
        Property_Registry__c orphan =
            TestDataFactory.createPropertyRegistry('500 orphan claim st', deletedWinnersLead.Id, true);
        orphan.Winning_Lead__c = null; // simulate the original winning Lead having been deleted (SetNull)
        update orphan;

        Lead newClaimant = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.claim(
            newClaimant.Id, '500 orphan claim st', extractedFields(), Datetime.now(),
            'forwarder4@example.invalid', 'FW: orphan adoption'
        );
        Test.stopTest();

        List<Property_Registry__c> registries = [
            SELECT Id, Winning_Lead__c FROM Property_Registry__c WHERE Property_Key__c = '500 orphan claim st'
        ];
        Assert.areEqual(1, registries.size(), 'Adopting the orphan must not create a second row for the same key');
        Assert.areEqual(orphan.Id, registries[0].Id, 'The SAME orphan row should be adopted, not replaced');
        Assert.areEqual(newClaimant.Id, registries[0].Winning_Lead__c, 'The orphan should now be won by the new claimant');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Source_Lead__c = :newClaimant.Id
        ];
        Assert.areEqual(1, subs.size(), 'A winning submission should be logged for the new claimant');
        Assert.areEqual(newClaimant.Id, subs[0].Winning_Lead__c, 'Winning_Lead__c should now be the new claimant');
        Assert.isTrue(subs[0].Is_Winning_Submission__c, 'The orphan-adopting submission should be flagged as the winner');
    }

    // ── claim(): W4 cluster-lock row creation ────────────────────────────────

    @isTest
    static void claim_firstWinner_alsoCreatesClusterLockRow() {
        Lead sourceLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.claim(
            sourceLead.Id, '100 main st', extractedFields(), Datetime.now(), 'forwarder6@example.invalid', 'FW: 100 Main St'
        );
        Test.stopTest();

        // '100 main st' derives the coarse cluster key '100 main' (number + first street token).
        List<Property_Claim_Lock__c> locks = [
            SELECT Id, Cluster_Key__c FROM Property_Claim_Lock__c WHERE Cluster_Key__c = '100 main'
        ];
        Assert.areEqual(1, locks.size(),
            'W4: claim() must get-or-create a Property_Claim_Lock__c row for the address\'s coarse cluster key');
        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '100 main st'],
            'The registry winner should still be created alongside the lock row');
        Assert.areEqual(1, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :sourceLead.Id],
            'The winning submission should still be created alongside the lock row');
    }

    // ── claim(): W4 fuzzy-variant duplicate within the same cluster ─────────
    // Proves the in-lock recheck is authoritative: a fuzzy (non-identical) variant of an
    // already-committed winner's address, in the SAME coarse cluster and clearing the 0.6
    // similarity threshold, still resolves to markDuplicate — the exact race W4 closes
    // (two differently-worded-but-similar claims each "winning" the same property) — proven
    // here as its sequential equivalent, since Apex tests run single-threaded.

    @isTest
    static void claim_fuzzyVariantInSameCluster_stillRoutesToMarkDuplicateUnderLock() {
        Lead winnerLead = TestDataFactory.createLead(true);
        // Pre-inserted directly (bypassing claim()) to simulate an already-committed winner
        // registration in the same coarse cluster ('123 main').
        Property_Registry__c winnerRegistry = TestDataFactory.createPropertyRegistry('123 main street', winnerLead.Id, true);
        Lead secondLead = TestDataFactory.createLead(true);

        Test.startTest();
        // '123 main street suite 100' is a DIFFERENT exact Property_Key__c (no unique-index
        // collision) but shares the '123 main' coarse cluster AND scores exactly 0.6 similarity
        // against the winner (3 shared / 5 union tokens) — at the SIMILARITY_THRESHOLD.
        PropertyClaimService.claim(
            secondLead.Id, '123 main street suite 100', extractedFields(), Datetime.now(),
            'forwarder7@example.invalid', 'FW: 123 Main Street Suite 100'
        );
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '123 main street suite 100'],
            'A fuzzy variant that resolves to the existing winner must NOT create its own registry row');

        Lead secondLeadAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :secondLead.Id];
        Assert.isTrue(secondLeadAfter.Is_Duplicate_Property__c, 'The fuzzy-variant claimant should be flagged as a duplicate');
        Assert.areEqual(winnerLead.Id, secondLeadAfter.Duplicate_Of_Lead__c,
            'It should be marked a duplicate of the cluster\'s existing winner');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Is_Winning_Submission__c, Winning_Lead__c FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :secondLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the fuzzy-variant claimant');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The fuzzy-duplicate submission must not be flagged as the winner');
        Assert.areEqual(winnerLead.Id, subs[0].Winning_Lead__c, 'The submission should roll up under the existing winner');

        Lead winnerAfter = [SELECT Is_Duplicate_Property__c FROM Lead WHERE Id = :winnerLead.Id];
        Assert.isFalse(winnerAfter.Is_Duplicate_Property__c, 'The winner\'s Lead must be untouched by the fuzzy-duplicate recheck');

        Property_Registry__c registryAfter = [SELECT Winning_Lead__c FROM Property_Registry__c WHERE Id = :winnerRegistry.Id];
        Assert.areEqual(winnerLead.Id, registryAfter.Winning_Lead__c, 'The original winner registry must remain unchanged');
    }

    // ── claim(): W4 idempotent lock get-or-create ────────────────────────────

    @isTest
    static void claim_calledTwiceForSameCluster_createsOnlyOneLockRow() {
        Lead firstLead = TestDataFactory.createLead(true);
        Lead secondLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.claim(
            firstLead.Id, '900 idempotent ave', extractedFields(), Datetime.now(), 'forwarder8@example.invalid', 'FW: first'
        );
        PropertyClaimService.claim(
            secondLead.Id, '900 idempotent ave', extractedFields(), Datetime.now(), 'forwarder9@example.invalid', 'FW: second'
        );
        Test.stopTest();

        // Both calls derive the same cluster key ('900 idempotent'); the second call's
        // get-or-create (ensureLockRow) must find the first call's row rather than inserting
        // a second one for the same unique Cluster_Key__c.
        Assert.areEqual(1, [SELECT COUNT() FROM Property_Claim_Lock__c WHERE Cluster_Key__c = '900 idempotent'],
            'W4: a repeat claim for the same cluster must reuse the existing lock row, never insert a duplicate');

        Lead secondLeadAfter = [SELECT Is_Duplicate_Property__c FROM Lead WHERE Id = :secondLead.Id];
        Assert.isTrue(secondLeadAfter.Is_Duplicate_Property__c,
            'The second same-key claim should still be recognised as a duplicate of the first');
    }

    // ── claim(): W4 blank cluster key fails safe ─────────────────────────────

    @isTest
    static void claim_blankNormalizedAddress_failsSafeWithoutAnyDml() {
        Lead sourceLead = TestDataFactory.createLead(true);

        Test.startTest();
        // ExtractAddressQueueable normally guards against a blank normalized address before ever
        // calling claim(); calling claim() directly with '' here proves the defensive fail-safe
        // path inside claim() itself: deriveClusterKey('') -> '', acquireClusterLock('') returns
        // false immediately on the blank-key check, so claim() logs a warning and returns without
        // any DML — the same fail-safe outcome as a lock-wait timeout, reached via a
        // deterministic path instead of one requiring a second concurrent transaction.
        PropertyClaimService.claim(
            sourceLead.Id, '', extractedFields(), Datetime.now(), 'forwarder10@example.invalid', 'FW: blank address'
        );
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :sourceLead.Id],
            'A blank normalized address must never create a registry row');
        Assert.areEqual(0, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :sourceLead.Id],
            'A blank normalized address must never create a submission row');
        Assert.areEqual(0, [SELECT COUNT() FROM Property_Claim_Lock__c],
            'A blank normalized address must never create a lock row — the blank-key check short-circuits before any DML');

        Lead sourceLeadAfter = [SELECT Is_Duplicate_Property__c FROM Lead WHERE Id = :sourceLead.Id];
        Assert.isFalse(sourceLeadAfter.Is_Duplicate_Property__c, 'The Lead should be left as a normal, unclaimed record — not flagged a duplicate');
    }

    // ── claim(): non-duplicate DmlException propagates ──────────────────────

    @isTest
    static void claim_nonDuplicateDmlFailure_rethrowsAndRollsBack() {
        Boolean threw = false;

        Test.startTest();
        try {
            // A null sourceLeadId leaves Winning_Lead__c blank, tripping the Winning_Lead_Required
            // validation rule — a genuine (non-duplicate-value) DmlException that must propagate,
            // not be silently swallowed as a race-recovery case.
            PropertyClaimService.claim(
                null, '600 invalid claim st', extractedFields(), Datetime.now(), 'forwarder5@example.invalid', 'FW: bad claim'
            );
            Assert.fail('Expected a DmlException for a blank Winning_Lead__c to propagate out of claim()');
        } catch (DmlException de) {
            threw = true;
            Assert.isTrue(de.getMessage().contains('Winning Lead is required'),
                'The validation rule\'s own message should surface, proving this is the rethrow path, not a swallowed race');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A genuine (non-duplicate) DmlException must propagate out of claim()');
        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '600 invalid claim st'],
            'No registry row should exist after the rethrown failure');
    }
}
