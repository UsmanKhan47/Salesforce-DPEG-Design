/**
 * Test class for PropertyClaimService: the first-broker-wins claim writer.
 *
 * NOTE on bulk-test scope (.claude/rules/bulk-test-rule.md): claim()/markDuplicate()
 * are deliberately single-record-per-invocation — each call claims exactly ONE property.
 *
 * ⚠ CORRECTED 2026-07-31: the old framing here was "one inbound email = one call". That is
 * NO LONGER TRUE. D1 multi-property extraction made ExtractAddressQueueable loop, so claim()
 * is now invoked N TIMES PER TRANSACTION (N <= ExtractAddressQueueable.MAX_PROPERTIES = 10)
 * — see PropertyClaimService's own header, which is authoritative. This class consequently
 * lost its share of the per-transaction-singleton bulk exemption, which was narrowed the same
 * day to LLMExtractionCalloutService alone.
 *
 * A 251-iteration same-transaction loop is STILL the wrong test, for a sharper reason than
 * before: production cannot reach it. The queueable caps at 10 properties precisely because
 * SOQL exhausts at roughly 14-24, so 251 claims in one transaction would trip the DML and SOQL
 * governors long before exercising anything, and would encode a state the system cannot
 * produce. The replacement volume coverage — 10-property routing, 15-property truncation,
 * mixed outcomes, cluster-key ordering, and the governor-headroom assertions that make an
 * added per-property query fail a test rather than production — lives in
 * ExtractAddressQueueableTest, which is where the loop actually is.
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
 * IS covered, via claim_orphanedKey_adoptsOrphanAndBecomesNewWinner); and
 * (3) NEW WAIVER (2026-07-31) — the SELF-MATCH branch of isLostRaceAgainst *as reached
 * from registerWinner's catch*. Reaching it requires the registry insert to succeed and
 * the SUBMISSION insert to then throw a duplicate-value DmlException, so that the
 * catch's findMatchingRegistry re-read finds our own uncommitted-but-unrolled-back
 * registry row (there is no Savepoint around that try). Competing_Broker_Submission__c
 * has no unique field, so that second failure cannot be forced single-threaded without
 * a mock DML layer this module does not have. The GUARD ITSELF is covered — see
 * claim_selfMatchOnFuzzyVariant_isNotALostRaceAndKeepsTheLead, which reaches the same
 * predicate through claim()'s in-lock check, the other of its two call sites.
 *
 * 2026-07-31 — TWO CONTRACT CHANGES ARE ENCODED HERE.
 *   1. markDuplicate NO LONGER WRITES TO THE LEAD. The assertions on
 *      Is_Duplicate_Property__c / Duplicate_Of_Lead__c were not deleted, they were
 *      INVERTED: they now assert the legacy fields stay UNWRITTEN. That is the direct
 *      regression guard for the removal — re-introducing the update would turn these
 *      red immediately, whereas deleting the assertions would let it slip back in
 *      silently. (Contrast the orphan-adoption assertion in
 *      ExtractAddressQueueableTest, which was removed rather than inverted because
 *      there it proved nothing about the behaviour under test.)
 *   2. claim() NOW RETURNS DUPLICATE_RACE, NOT DUPLICATE, on both lost-race paths.
 *      Reaching a duplicate THROUGH claim() means the caller's own pre-read was stale,
 *      which is a race by definition. The return value is asserted explicitly because
 *      it is the caller's ONLY cue to delete the Lead it already created — an outcome
 *      regression here would silently resurrect the duplicate-Lead behaviour one layer
 *      up, in ExtractAddressQueueable, with nothing in this class turning red.
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

    /**
     * Convert a Lead and hand back its Opportunity — the fixture behind every WINNER ANCHOR test.
     *
     * ⚠ THE OPPORTUNITY CASCADE IS DELIBERATELY NOT SUPPRESSED. `setDoNotCreateOpportunity(true)`
     * throws UNKNOWN_EXCEPTION on this org, and the plain conversion is the shape already proven
     * safe by LeadConvertServiceTest (single and 251-record bulk). Copying that pattern rather
     * than inventing a lighter one is the point — the Opportunity it produces is exactly what the
     * anchor is supposed to point at.
     *
     * @param leadToConvert The Lead to convert; must already be inserted.
     * @return The Id of the Opportunity conversion created.
     */
    private static Id convertAndGetOpportunity(Lead leadToConvert) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(leadToConvert.Id);
        lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
        Database.LeadConvertResult result = Database.convertLead(lc);
        Assert.isTrue(result.isSuccess(), 'The fixture Lead must convert for the winner-anchor tests to mean anything');
        return result.getOpportunityId();
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
    static void markDuplicate_logsNonWinningSubmissionAndWritesNoLeadAtAll() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Property_Registry__c registry = TestDataFactory.createPropertyRegistry('300 winner st', winnerLead.Id, true);
        Lead loserLead = TestDataFactory.createLead(true);

        Test.startTest();
        // winningRecordId == the winner's own Lead: that Lead is OPEN, so the row anchors on
        // Winning_Lead__c exactly as it always has (see PropertyClaimService's WINNER ANCHOR note).
        PropertyClaimService.markDuplicate(
            registry, loserLead.Id, winnerLead.Id, extractedFields(), Datetime.now(),
            'forwarder2@example.invalid', 'FW: also 300 Winner St'
        );
        Test.stopTest();

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Source_Lead__c = :loserLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the losing lead');
        Assert.areEqual(winnerLead.Id, subs[0].Winning_Lead__c, 'The submission should roll up under the winning lead');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'A competing submission must never be flagged as the winner');

        // REGRESSION GUARD (2026-07-31): markDuplicate must perform NO Lead DML. These two
        // assertions are inverted from what they used to check — re-adding the
        // `update new Lead(Is_Duplicate_Property__c = true, ...)` write turns them red.
        Lead loserAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :loserLead.Id];
        Assert.isFalse(loserAfter.Is_Duplicate_Property__c,
            'The legacy duplicate flag must no longer be written — a competing claim is tracked by the submission row alone');
        Assert.isNull(loserAfter.Duplicate_Of_Lead__c,
            'Duplicate_Of_Lead__c is legacy and must stay null; nothing may write it');

        Lead winnerAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c, LastName FROM Lead WHERE Id = :winnerLead.Id];
        Assert.isFalse(winnerAfter.Is_Duplicate_Property__c, 'The winner\'s Lead data must be untouched');
        Assert.isNull(winnerAfter.Duplicate_Of_Lead__c, 'The winner should never itself be flagged as a duplicate');
        Assert.areEqual(winnerLead.LastName, winnerAfter.LastName, 'The winner\'s other fields should be unchanged');
    }

    @isTest
    static void markDuplicate_nullSourceLead_logsSourcelessSubmissionAgainstWinner() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Property_Registry__c registry = TestDataFactory.createPropertyRegistry('320 sourceless st', winnerLead.Id, true);

        Integer leadsBefore = [SELECT COUNT() FROM Lead];

        Test.startTest();
        // The shape ExtractAddressQueueable's competing branch now calls: no Lead was ever
        // created for this broker, so there is no source Lead to point at.
        PropertyClaimService.markDuplicate(
            registry, null, winnerLead.Id, extractedFields(), Datetime.now(),
            'forwarder11@example.invalid', 'FW: also 320 Sourceless St'
        );
        Test.stopTest();

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Source_Lead__c, Is_Winning_Submission__c, Broker_Email__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :winnerLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'A null sourceLeadId must still produce exactly one submission row');
        Assert.isNull(subs[0].Source_Lead__c,
            'Source_Lead__c is optional and null is the normal competing-broker shape — it must not be defaulted to the winner');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'A competing submission must never be flagged as the winner');
        Assert.areEqual('jane@brokerfirm.example.invalid', subs[0].Broker_Email__c,
            'With no Lead to hold it, the submission must carry the broker\'s address itself');

        Assert.areEqual(leadsBefore, [SELECT COUNT() FROM Lead],
            'markDuplicate must never create a Lead, and with a null source it has none to touch either');
    }

    // ══ WINNER ANCHOR — converted winners (2026-08-03) ══════════════════════
    //
    // Closes W3, carried since 2026-07-31 (docs/2026-07-31-competing-broker-no-lead.md,
    // docs/2026-07-31-llm-field-extraction.md): every prior test used an UNCONVERTED Lead as the
    // winner, so no test ever wrote a Lead lookup at a converted Lead. Production did, on
    // 2026-08-03, and the platform rejected the insert — staging row a0aiw000000OCckAAG.
    //
    // ═══ 🔴 READ THIS BEFORE "FIXING" THE FIRST TEST BELOW ═══
    // It was written as a FALSIFIABILITY GUARD asserting that the platform REJECTS a lookup set to
    // a converted Lead. It ran on 2026-08-03 and the insert SUCCEEDED — so it has been REFRAMED to
    // pin what actually happens, rather than deleted or weakened into a tautology.
    //
    // WHAT WE KNOW, AND HOW WE KNOW IT:
    //   • AT RUNTIME THE WRITE FAILS. The evidence is the production incident, not a unit test:
    //     staging row a0aiw000000OCckAAG on `usman-dpeg` (2026-08-03T15:21:57Z), Outcome__c
    //     'Error (System.DmlException)', Property_Count__c 1, and NO Competing_Broker_Submission__c
    //     row written. Branch (b) is forced on that data (the prior submission matches on an exact
    //     normalized address inside the lookback window), and the ONLY DML it performs is this
    //     insert. The identical write had SUCCEEDED a day earlier, when the Lead was still open.
    //   • IN @isTest THE SAME WRITE IS ACCEPTED. Pinned below.
    //
    // ⚠ THIS IS A TEST-CONTEXT ASYMMETRY, AND THIS MODULE ALREADY HAS ONE: `EmailMessage.RelatedToId`
    // is updatable at runtime but REFUSED from test context. This is the same shape, inverted —
    // enforced at runtime, unenforced in tests.
    //
    // 🔴 THE CONSEQUENCE FOR REVIEW, STATED PLAINLY: the winner-anchor design CANNOT be falsified
    // by an Apex test in this org. A green suite is therefore not evidence that the restriction is
    // real, and a red one would not be evidence that it is not. Genuine falsification requires
    // running the insert as ANONYMOUS APEX in a scratch org, outside test context. Until someone
    // does that, the live incident is the evidence — and it is the reason this hotfix exists.
    //
    // ⚠ RESIDUAL, DELIBERATELY NOT HIDDEN: the production exception's exact StatusCode was never
    // captured, because `Error__c` was NULL on that row — that gap IS the defect-2 half of this
    // change. The root cause is therefore established by ELIMINATION (the only DML on the path;
    // every other field clipped or sanitized; the Winning_Lead_Required VR satisfied; and record
    // access ruled out, because the running user Junior Dhanani OWNS the converted Lead), not by a
    // captured message. Strong, but not proof. Defect 2 is what makes the NEXT occurrence
    // self-diagnosing: if the cause is something else, the staging row will now say so in one query.

    @isTest
    static void platform_lookupToAConvertedLead_isNotEnforcedInTestContext() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Id opportunityId = convertAndGetOpportunity(winnerLead);
        Assert.isNotNull(opportunityId, 'Conversion must produce an Opportunity for the anchor to have a target');
        // ⚠ THE PRECONDITION IS VERIFIED AGAINST THE DATABASE, not the stale in-memory Lead the
        // factory returned. Without this, a fixture that silently failed to convert would make the
        // assertion below pass for entirely the wrong reason — which is the first thing anyone
        // should suspect when a test claims a platform rule is not enforced.
        Assert.isTrue([SELECT IsConverted FROM Lead WHERE Id = :winnerLead.Id].IsConverted,
            'PRECONDITION: the Lead must genuinely be converted at the moment of the insert below, '
            + 'or this test pins nothing at all');

        Boolean threw = false;
        String actualMessage;
        Test.startTest();
        try {
            // THE EXACT PRODUCTION SHAPE: BOTH Lead lookups point at the converted Lead, because on
            // a winner's own row Source_Lead__c equals Winning_Lead__c. Setting both removes the
            // one remaining way to explain the runtime/test difference as a field-level quirk.
            insert new Competing_Broker_Submission__c(
                Winning_Lead__c = winnerLead.Id,
                Source_Lead__c = winnerLead.Id,
                Broker_Email__c = 'jane@brokerfirm.example.invalid',
                Property_Address_Raw__c = '100 Main St, Houston, TX',
                Submitted_DateTime__c = Datetime.now(),
                Is_Winning_Submission__c = false
            );
        } catch (DmlException de) {
            threw = true;
            actualMessage = de.getMessage();
        }
        Test.stopTest();

        // 🔴 THIS ASSERTION DOES NOT VALIDATE THE FIX, AND ITS FAILURE WOULD NOT INVALIDATE IT.
        // The previous version of this test asserted the opposite and claimed that failing here
        // "INVALIDATES THE FIX". That claim was WRONG and is corrected here: the design rests on
        // the runtime evidence recorded in the section header, not on this test. What this pins is
        // a CONTEXT QUIRK, documented where someone will actually meet it.
        //
        // If this ever goes RED — Salesforce enforcing the restriction inside @isTest too — that is
        // GOOD NEWS, not a regression: the premise would become directly testable, and this test
        // should be converted back into a genuine falsifiability guard asserting the rejection and
        // its StatusCode. Do not simply delete it.
        Assert.isFalse(threw,
            'PINNED QUIRK: in @isTest the platform ACCEPTS a lookup set to a converted Lead, even though '
            + 'it rejects the identical write at runtime (production incident, staging row '
            + 'a0aiw000000OCckAAG). If this is now throwing, Salesforce has closed the gap — turn this '
            + 'back into a falsifiability guard rather than deleting it. Message: ' + actualMessage);

        // Asserts the row was genuinely PERSISTED, not merely that nothing threw — otherwise this
        // test would also pass if the insert had been silently skipped.
        Assert.areEqual(1, [
            SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Winning_Lead__c = :winnerLead.Id
        ], 'and the row really is persisted against the converted Lead in test context');
    }

    @isTest
    static void markDuplicate_convertedWinner_anchorsOnTheOpportunityAndNullsBothLeadLookups() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Property_Registry__c registry =
            TestDataFactory.createPropertyRegistry('800 converted winner st', winnerLead.Id, true);
        Id opportunityId = convertAndGetOpportunity(winnerLead);

        Test.startTest();
        // Exactly what ExtractAddressQueueable branch (d) now passes: the registry still names the
        // (now converted) Lead, and the caller supplies what that Lead resolves to today.
        PropertyClaimService.markDuplicate(
            registry, null, opportunityId, extractedFields(), Datetime.now(),
            'forwarder30@example.invalid', 'FW: also 800 Converted Winner St'
        );
        Test.stopTest();

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c, Is_Winning_Submission__c,
                   Broker_Email__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Opportunity__c = :opportunityId
        ];
        Assert.areEqual(1, subs.size(),
            'A competing submission against a CONVERTED winner must still be written — losing the audit row is '
            + 'the failure this change exists to remove');
        Assert.areEqual(opportunityId, subs[0].Winning_Opportunity__c,
            'The anchor moves to the Opportunity, which is the record that actually holds the deal now');
        Assert.isNull(subs[0].Winning_Lead__c,
            'EXACTLY ONE ANCHOR: writing the converted Lead alongside it is what the platform rejects');
        Assert.isNull(subs[0].Source_Lead__c, 'A competing broker still receives no Lead of their own');
        Assert.areEqual('jane@brokerfirm.example.invalid', subs[0].Broker_Email__c,
            'The row remains the only record of who this broker was, so their address must survive the anchor swap');
    }

    @isTest
    static void markDuplicate_winnerResolvesToAContactOnly_skipsTheSubmissionRatherThanThrowing() {
        // THE DOCUMENTED RESIDUAL, DIRECTLY PINNED (buildSubmission's third branch). A winning
        // Lead converted to a Contact with NO Opportunity can be anchored to neither
        // Winning_Lead__c (converted, rejected by the platform) nor Winning_Opportunity__c (none
        // exists) — inserting anyway would fail Winning_Lead_Required and abort the WHOLE
        // property's routing branch, which is the exact failure this change exists to remove, so
        // buildSubmission returns null and insertSubmission is a deliberate no-op.
        //
        // Close to UNREACHABLE via a real conversion in this org — LeadConvertService always
        // produces an Opportunity here (setDoNotCreateOpportunity(true) throws) — so this drives
        // the branch directly with a real Contact standing in for whatever resolveLiveRecord would
        // have returned on an org where the shape is reachable, rather than skipping the branch
        // entirely for want of a fixture.
        Lead winnerLead = TestDataFactory.createLead(true);
        Property_Registry__c registry =
            TestDataFactory.createPropertyRegistry('700 contact only ave', winnerLead.Id, true);
        Contact standInContact = new Contact(LastName = 'Stand-In Contact');
        insert standInContact;

        Integer subsBefore = [SELECT COUNT() FROM Competing_Broker_Submission__c];

        Test.startTest();
        // No try/catch: a DmlException here would itself be the regression this test exists to
        // catch — the whole point of the residual is that the row is skipped, never thrown.
        PropertyClaimService.markDuplicate(
            registry, null, standInContact.Id, extractedFields(), Datetime.now(),
            'forwarder36@example.invalid', 'FW: also 700 Contact Only Ave'
        );
        Test.stopTest();

        Assert.areEqual(subsBefore, [SELECT COUNT() FROM Competing_Broker_Submission__c],
            'A winner that resolves to neither a Lead nor an Opportunity must be SKIPPED, not thrown. '
            + 'Losing one audit row is strictly better than losing the whole property\'s routing — and '
            + 'the caller (ExtractAddressQueueable) still logs the email\'s Task regardless');
    }

    @isTest
    static void logRepeatSubmission_convertedWinner_anchorsOnTheOpportunity() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Id opportunityId = convertAndGetOpportunity(winnerLead);

        Test.startTest();
        // Branch (b)'s shape once the winner has converted: the prior row still names the Lead,
        // and the queueable passes the resolved live record alongside it.
        PropertyClaimService.logRepeatSubmission(
            winnerLead.Id, winnerLead.Id, opportunityId, extractedFields(), Datetime.now(),
            'forwarder31@example.invalid', 'FW: following up again'
        );
        Test.stopTest();

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Opportunity__c = :opportunityId
        ];
        Assert.areEqual(1, subs.size(), 'A repeat on a converted winner must still append its audit row');
        Assert.isNull(subs[0].Winning_Lead__c, 'The converted Lead must not be written');
        Assert.isNull(subs[0].Source_Lead__c,
            'Source_Lead__c is the SAME converted Lead here, so it is equally unwritable and is nulled too');
    }

    @isTest
    static void logRepeatSubmission_priorRowAlreadyAnchoredOnAnOpportunity_keepsThatAnchor() {
        Lead winnerLead = TestDataFactory.createLead(true);
        Id opportunityId = convertAndGetOpportunity(winnerLead);

        Test.startTest();
        // The SECOND follow-up: by now the prior row itself has a null Winning_Lead__c and an
        // Opportunity anchor, so the caller passes winningLeadId = null. The old
        // `(winningLeadId == null) ? sourceLeadId : winningLeadId` fallback would have thrown a
        // perfectly good Opportunity anchor away here and written a Lead-shaped row.
        PropertyClaimService.logRepeatSubmission(
            null, null, opportunityId, extractedFields(), Datetime.now(),
            'forwarder32@example.invalid', 'FW: third email on this one'
        );
        Test.stopTest();

        Competing_Broker_Submission__c sub = [
            SELECT Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Opportunity__c = :opportunityId
        ];
        Assert.areEqual(opportunityId, sub.Winning_Opportunity__c,
            'A null winningLeadId no longer means "fall back to the source Lead" — it means the anchor is the Opportunity');
        Assert.isNull(sub.Winning_Lead__c, 'and no Lead lookup is written at all');
    }

    @isTest
    static void logRepeatSubmission_neitherAnchorSupplied_fallsBackToTheSourceLead() {
        // THE PREVIOUSLY-WORKING PATH, DIRECTLY PINNED FOR THE FIRST TIME. Before 2026-08-03 the
        // fallback fired whenever winningLeadId alone was null; it is now NARROWED to fire only
        // when winningRecordId is ALSO null, because an Opportunity-anchored prior row
        // legitimately has a null winningLeadId too (see the test immediately above). Neither the
        // pre-2026-08-03 nor the current logRepeatSubmission had a DIRECT unit test of this
        // fallback shape — ExtractAddressQueueable's own call site always resolves a live winner
        // before calling in, so the fallback is dead code from the pipeline's perspective and is
        // preserved purely for other direct callers. This closes that gap rather than merely
        // confirming the narrowing didn't regress something that was already covered.
        Lead sourceLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.logRepeatSubmission(
            null, sourceLead.Id, null, extractedFields(), Datetime.now(),
            'forwarder35@example.invalid', 'FW: direct caller supplying neither anchor'
        );
        Test.stopTest();

        Competing_Broker_Submission__c sub = [
            SELECT Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c
            FROM Competing_Broker_Submission__c
            WHERE Source_Lead__c = :sourceLead.Id
        ];
        Assert.areEqual(sourceLead.Id, sub.Winning_Lead__c,
            'With NEITHER anchor supplied, the method must still fall back to the source Lead — the '
            + 'pre-2026-08-03 behaviour, preserved for callers other than the queueable');
        Assert.isNull(sub.Winning_Opportunity__c, 'and the Opportunity anchor stays untouched');
    }

    @isTest
    static void claim_winnerLeadCannotBeConvertedYet_soTheWinningRowStillAnchorsOnTheLead() {
        Lead sourceLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.claim(
            sourceLead.Id, '850 fresh winner st', extractedFields(), Datetime.now(),
            'forwarder33@example.invalid', 'FW: 850 Fresh Winner St'
        );
        Test.stopTest();

        Competing_Broker_Submission__c sub = [
            SELECT Winning_Lead__c, Winning_Opportunity__c, Source_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :sourceLead.Id
        ];
        // REGRESSION GUARD. registerWinner passes the Lead as its own live record WITHOUT a
        // resolve query, on the reasoning that a Lead created seconds earlier cannot be converted
        // yet. This proves that shortcut still produces the Lead-anchored row, and it is also the
        // assertion that goes red if someone routes the winning row through the Opportunity branch.
        Assert.areEqual(sourceLead.Id, sub.Winning_Lead__c,
            'The WINNING row is written at claim time, when the Lead is by construction still open — it must anchor on the Lead');
        Assert.isNull(sub.Winning_Opportunity__c, 'EXACTLY ONE ANCHOR: an open winner has no Opportunity to point at');
        Assert.isTrue(sub.Is_Winning_Submission__c, 'and it is still the winning submission');
    }

    // ── claim(): duplicate-value race recovery ──────────────────────────────

    @isTest
    static void claim_duplicateValueRace_returnsDuplicateRaceAndLogsCompetingSubmission() {
        Lead leadA = TestDataFactory.createLead(true);
        TestDataFactory.createPropertyRegistry('400 race st', leadA.Id, true); // leadA already won this key
        Lead leadB = TestDataFactory.createLead(true);

        Test.startTest();
        // leadB claims the SAME exact key leadA already won. W4 note: under the current
        // lock-then-findMatchingRegistry flow this is now caught by claim()'s own pre-insert
        // exact-key check (findMatchingRegistry finds leadA's registry BEFORE any insert is
        // attempted), rather than by a DUPLICATE_VALUE DmlException on the insert itself — the
        // final reconciliation (leadB is recorded as competing under leadA) is identical either
        // way, so this test's outcome-level assertions are unchanged post-W4.
        PropertyClaimService.ClaimOutcome outcome = PropertyClaimService.claim(
            leadB.Id, '400 race st', extractedFields(), Datetime.now(), 'forwarder3@example.invalid', 'FW: race'
        );
        Test.stopTest();

        // The load-bearing assertion: DUPLICATE_RACE, not DUPLICATE. It is the caller's ONLY
        // signal that a Lead exists which should not, and therefore the only thing that makes
        // ExtractAddressQueueable delete it.
        Assert.areEqual(PropertyClaimService.ClaimOutcome.DUPLICATE_RACE, outcome,
            'A duplicate discovered inside claim() means the caller\'s pre-read was stale — that is a LOST RACE, and the caller must be told so it can delete the Lead it already created');

        Assert.areEqual(1, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '400 race st'],
            'Exactly one registry row should exist for the key — the race loser must not create a second row');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Winning_Lead__c, Is_Winning_Submission__c
            FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :leadB.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the race loser');
        Assert.areEqual(leadA.Id, subs[0].Winning_Lead__c, 'The submission should roll up under the race winner');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The race-recovered submission must not be flagged as the winner');
        // Source_Lead__c is still stamped here because the Lead genuinely exists at this
        // instant: deleting it is the CALLER's policy decision, not this claim engine's. The
        // lookup's SetNull delete constraint clears it the moment the caller acts — asserted
        // end-to-end in ExtractAddressQueueableTest's forceClaimRace test.

        Lead leadBAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :leadB.Id];
        Assert.isFalse(leadBAfter.Is_Duplicate_Property__c,
            'The legacy duplicate flag must no longer be written on the race loser');
        Assert.isNull(leadBAfter.Duplicate_Of_Lead__c, 'Duplicate_Of_Lead__c is legacy and must stay null');
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
        PropertyClaimService.ClaimOutcome outcome = PropertyClaimService.claim(
            secondLead.Id, '123 main street suite 100', extractedFields(), Datetime.now(),
            'forwarder7@example.invalid', 'FW: 123 Main Street Suite 100'
        );
        Test.stopTest();

        Assert.areEqual(PropertyClaimService.ClaimOutcome.DUPLICATE_RACE, outcome,
            'A fuzzy variant resolving to an existing winner is still a claim the caller believed was free — it must report the lost race');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Property_Key__c = '123 main street suite 100'],
            'A fuzzy variant that resolves to the existing winner must NOT create its own registry row');

        List<Competing_Broker_Submission__c> subs = [
            SELECT Is_Winning_Submission__c, Winning_Lead__c FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :secondLead.Id
        ];
        Assert.areEqual(1, subs.size(), 'A non-winning submission should be logged for the fuzzy-variant claimant');
        Assert.isFalse(subs[0].Is_Winning_Submission__c, 'The fuzzy-duplicate submission must not be flagged as the winner');
        Assert.areEqual(winnerLead.Id, subs[0].Winning_Lead__c, 'The submission should roll up under the existing winner');

        Lead secondLeadAfter = [SELECT Is_Duplicate_Property__c, Duplicate_Of_Lead__c FROM Lead WHERE Id = :secondLead.Id];
        Assert.isFalse(secondLeadAfter.Is_Duplicate_Property__c,
            'The legacy duplicate flag must no longer be written on the fuzzy-variant claimant');
        Assert.isNull(secondLeadAfter.Duplicate_Of_Lead__c, 'Duplicate_Of_Lead__c is legacy and must stay null');

        Lead winnerAfter = [SELECT Is_Duplicate_Property__c FROM Lead WHERE Id = :winnerLead.Id];
        Assert.isFalse(winnerAfter.Is_Duplicate_Property__c, 'The winner\'s Lead must be untouched by the fuzzy-duplicate recheck');

        Property_Registry__c registryAfter = [SELECT Winning_Lead__c FROM Property_Registry__c WHERE Id = :winnerRegistry.Id];
        Assert.areEqual(winnerLead.Id, registryAfter.Winning_Lead__c, 'The original winner registry must remain unchanged');
    }

    // ── claim(): SELF-MATCH is never a lost race (W1, 2026-07-31) ────────────
    //
    // The exact mirror of claim_fuzzyVariantInSameCluster_stillRoutesToMarkDuplicateUnderLock
    // above, with ONE variable changed: the claimant is the SAME Lead that already holds the
    // fuzzy-matched registration. That flips the correct answer completely. DUPLICATE_RACE is
    // the caller's sole cue to DELETE the Lead it created, so reporting it on a self-match
    // would delete the Lead that owns the registry row — orphaning the registration and
    // destroying a live broker record. isLostRaceAgainst exists to make that impossible.

    @isTest
    static void claim_selfMatchOnFuzzyVariant_isNotALostRaceAndKeepsTheLead() {
        Lead sameLead = TestDataFactory.createLead(true);
        // This Lead already won '123 main street'.
        TestDataFactory.createPropertyRegistry('123 main street', sameLead.Id, true);

        Test.startTest();
        // ...and now claims a fuzzy variant of it: a DIFFERENT exact Property_Key__c that
        // scores exactly 0.6 (3 shared / 5 union tokens) against the row it already owns.
        PropertyClaimService.ClaimOutcome outcome = PropertyClaimService.claim(
            sameLead.Id, '123 main street suite 100', extractedFields(), Datetime.now(),
            'forwarder12@example.invalid', 'FW: 123 Main Street Suite 100'
        );
        Test.stopTest();

        Assert.areNotEqual(PropertyClaimService.ClaimOutcome.DUPLICATE_RACE, outcome,
            'A claimant matching its OWN registration has lost no race — reporting DUPLICATE_RACE would make the caller delete the very Lead that holds the registry row');
        Assert.areEqual(PropertyClaimService.ClaimOutcome.WINNER, outcome,
            'With the race check correctly declined, the claim falls through to registerWinner and the new key is free, so this is a straightforward win');

        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :sameLead.Id],
            'The Lead must survive — this is the data-loss the guard prevents');

        List<Property_Registry__c> owned = [
            SELECT Property_Key__c FROM Property_Registry__c WHERE Winning_Lead__c = :sameLead.Id
        ];
        Assert.areEqual(2, owned.size(),
            'Falling through registers the new key alongside the original: the same broker legitimately holding two fuzzy-related keys is a harmless outcome, unlike deleting their Lead');

        Assert.areEqual(0, [
            SELECT COUNT() FROM Competing_Broker_Submission__c
            WHERE Winning_Lead__c = :sameLead.Id AND Is_Winning_Submission__c = false
        ], 'No COMPETING submission may be logged against yourself');
    }

    // ── claim(): W4 idempotent lock get-or-create ────────────────────────────

    @isTest
    static void claim_calledTwiceForSameCluster_createsOnlyOneLockRow() {
        Lead firstLead = TestDataFactory.createLead(true);
        Lead secondLead = TestDataFactory.createLead(true);

        Test.startTest();
        PropertyClaimService.ClaimOutcome firstOutcome = PropertyClaimService.claim(
            firstLead.Id, '900 idempotent ave', extractedFields(), Datetime.now(), 'forwarder8@example.invalid', 'FW: first'
        );
        PropertyClaimService.ClaimOutcome secondOutcome = PropertyClaimService.claim(
            secondLead.Id, '900 idempotent ave', extractedFields(), Datetime.now(), 'forwarder9@example.invalid', 'FW: second'
        );
        Test.stopTest();

        // Both calls derive the same cluster key ('900 idempotent'); the second call's
        // get-or-create (ensureLockRow) must find the first call's row rather than inserting
        // a second one for the same unique Cluster_Key__c.
        Assert.areEqual(1, [SELECT COUNT() FROM Property_Claim_Lock__c WHERE Cluster_Key__c = '900 idempotent'],
            'W4: a repeat claim for the same cluster must reuse the existing lock row, never insert a duplicate');

        Assert.areEqual(PropertyClaimService.ClaimOutcome.WINNER, firstOutcome, 'The first claim on a free key wins it');
        Assert.areEqual(PropertyClaimService.ClaimOutcome.DUPLICATE_RACE, secondOutcome,
            'The second same-key claim should still be recognised as competing with the first, reported as a lost race');
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
        PropertyClaimService.ClaimOutcome outcome = PropertyClaimService.claim(
            sourceLead.Id, '', extractedFields(), Datetime.now(), 'forwarder10@example.invalid', 'FW: blank address'
        );
        Test.stopTest();

        // UNCLAIMED, emphatically NOT DUPLICATE_RACE: the caller deletes the Lead on
        // DUPLICATE_RACE, so returning it here would destroy a legitimate broker submission
        // that merely failed to take a lock. This is the assertion that keeps the two apart.
        Assert.areEqual(PropertyClaimService.ClaimOutcome.UNCLAIMED, outcome,
            'A fail-safe claim must report UNCLAIMED — the Lead is legitimate and must never be deleted by the caller');

        Assert.areEqual(0, [SELECT COUNT() FROM Property_Registry__c WHERE Winning_Lead__c = :sourceLead.Id],
            'A blank normalized address must never create a registry row');
        Assert.areEqual(0, [SELECT COUNT() FROM Competing_Broker_Submission__c WHERE Source_Lead__c = :sourceLead.Id],
            'A blank normalized address must never create a submission row');
        Assert.areEqual(0, [SELECT COUNT() FROM Property_Claim_Lock__c],
            'A blank normalized address must never create a lock row — the blank-key check short-circuits before any DML');

        Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Id = :sourceLead.Id],
            'The Lead should be left intact as a normal, unclaimed record — the fail-safe path must never cost a broker their Lead');
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
