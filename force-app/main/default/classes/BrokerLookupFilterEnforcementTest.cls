/**
 * PROOF THAT THE BROKER LOOKUP FILTER ACTUALLY FILTERS — AND THAT IT FILTERS ON THE RECORD TYPE.
 *
 * Written 2026-08-20 for the change that moves the broker definition from `Contact.Is_Broker__c`
 * to the `Contact.Broker` record type. This class exists to close blocking gate G1.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * WHY A TEST CLASS EXISTS FOR A PIECE OF DECLARATIVE METADATA
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The record-type `<lookupFilter>` XML shape could NOT be resolved from schema or from precedent.
 * There is no record-type lookup filter anywhere else in this repo to copy, and the three candidate
 * `<field>` spellings (`Contact.RecordTypeId`, `Contact.RecordType.DeveloperName`,
 * `Contact.RecordType.Name`) are ALL schema-legal in a check-only deploy. A check-only pass
 * therefore proves the metadata parses. It does not prove the filter FILTERS.
 *
 * 🔴 THE FAILURE MODE THIS GUARDS IS THE QUIET ONE. A malformed-but-legal lookup filter can deploy
 * green and match everything, leaving all six broker lookups wide open while every reviewer, every
 * deploy log and every checklist reports them validated. This repo has a measured history of green
 * deploys that changed nothing. The only evidence that settles it is an actual save being REFUSED,
 * which is what this class performs.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE FIXTURES ARE ADVERSARIAL ON PURPOSE — READ THIS BEFORE "SIMPLIFYING" ANY OF THEM
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The obvious test — "a broker Contact is accepted, a plain Contact is refused" — WOULD PASS
 * IDENTICALLY UNDER BOTH THE OLD AND THE NEW FILTER, because a `TestDataFactory` broker carries
 * BOTH the checkbox and the record type, and a plain factory Contact carries neither predicate's
 * "true" value in the way you would expect. Such a test proves the filter is *a* filter and says
 * nothing about WHICH definition is live — which is the entire question.
 *
 * So the two load-bearing fixtures deliberately DISAGREE with themselves. Each satisfies exactly
 * one of the two definitions:
 *
 *   Record type | Is_Broker__c | OLD filter | NEW filter | this class asserts
 *   ------------|--------------|------------|------------|--------------------------------------
 *   Broker      | true         | accept     | accept     | ACCEPTED   (harness control)
 *   Broker      | FALSE        | refuse     | accept     | ACCEPTED   🔴 proves RT is the rule
 *   Investor    | TRUE         | accept     | refuse     | REFUSED    🔴 proves the checkbox is not
 *   Investor    | false        | refuse     | refuse     | REFUSED    (harness control)
 *
 * The two middle rows are the discriminator. If the filter is still on `Is_Broker__c`, they fail —
 * and they fail with a message that SAYS the filter is still on `Is_Broker__c`, which is the
 * diagnostic that tells the next agent which candidate `<field>` spelling to try. That is the
 * point: this class is designed to be read from its failure output, not only from its source.
 *
 * The two OUTER rows are not padding. Without them, a "refused" result on the Investor+checkbox row
 * could equally be caused by an unrelated validation rule, a required field, a duplicate rule or a
 * trigger refusing every insert on this object. They pin the harness itself.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * WHY THE ROW COUNTS ARE 1, NOT 251 (`.claude/rules/bulk-test-rule.md`)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * That rule's 251-record mandate exists to force a SECOND trigger-batch firing, exposing bugs that
 * only appear when logic runs more than once per transaction. It does not apply here, and the
 * reason is recorded so review does not demand it:
 *
 *   - There is no code under test. The subject is the PLATFORM's save-time lookup-filter
 *     enforcement, which is evaluated per ROW with no batch-chunk semantics and no shared state
 *     between rows. Row 251 exercises the identical code path as row 1 and can falsify nothing
 *     row 1 did not.
 *   - Each row here exists to prove ONE cell of the truth table above. Adding rows for volume
 *     would add cost without adding a proposition — the same reasoning
 *     `.claude/rules/content-publication-rule.md` applies to selector reads.
 *   - Every insert is a `BOV_Submission__c` under a `Disposition__c` scaffold and fires the real
 *     before-save broker stamp; 251 of them would spend the transaction's DML and CPU budget to
 *     re-prove a platform behaviour, and a governor failure here would be indistinguishable from
 *     the refusal this class is trying to measure. That ambiguity is itself a reason to stay small.
 *
 * Bulkification of the broker selectors themselves IS still proven at 251, in
 * `ContactSelectorTest.selectBrokersRankedByClosedVolume_251Brokers_returnsAll`. This class does
 * not duplicate that and is not a substitute for it.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * SCOPE — ONE FIELD, DELIBERATELY, AND HOW TO EXTEND IT
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Only `BOV_Submission__c.Broker__c` is exercised. It is the field the user actually hit, and it is
 * the field the change's own resolution protocol names as the one to prove FIRST, before the shape
 * is replicated to the other five. All six carry a byte-identical `<lookupFilter>` block by
 * construction, so proving the shape once proves the shape.
 *
 * ⚠ That is an argument about the SHAPE, not a guarantee about the other five FIELDS. If one of
 * them is ever edited independently, extend `assertLookupBehaviour` to it rather than assuming this
 * class still covers it. The remaining five are `Disposition__c.Broker__c`,
 * `Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c`, and the two others enumerated in
 * `scripts/seed-broker-contacts.apex`'s BROKER_LOOKUPS map. `Opportunity.Broker__c` is NOT among
 * them and carries NO lookup filter at all — see `objects/Opportunity/fields/Broker__c`.
 *
 * ⚠ THIS CLASS WILL FAIL UNTIL THE SIX `<lookupFilter>` BLOCKS ARE REPOINTED. That is correct and
 * intended: it is the gate, so it must be red before the gate is passed and green after. A run of
 * this class against an org still carrying the `Is_Broker__c` filter should show exactly the two
 * middle rows failing and the two outer rows passing — any OTHER pattern means something else is
 * wrong and the failure text will say what.
 *
 * @see .claude/rules/bulk-test-rule.md          (why 251 does not apply here)
 * @see .claude/rules/content-publication-rule.md (the precedent for a documented row-count carve-out)
 * @see force-app/main/default/classes/ContactSelector.cls (the four SOQL predicates that moved with this)
 */
@isTest
private class BrokerLookupFilterEnforcementTest {

    private static final String BROKER_RT   = 'Broker';
    private static final String INVESTOR_RT = 'Investor';

    /** The status code the platform raises when a lookup filter refuses a save. */
    private static final String FILTER_REFUSAL = 'FIELD_FILTER_VALIDATION_EXCEPTION';

    // ═════════════════════════════════════════════════════════════════════════════════
    // THE TWO DISCRIMINATING CASES — these are the proof
    // ═════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PRIMARY PROOF. A Contact on the Broker record type with `Is_Broker__c = FALSE` must be
     * ACCEPTED. Under the retired checkbox filter this exact row was REFUSED, so a pass here is
     * positive evidence that the record type — and not the checkbox — is what the filter now reads.
     *
     * This is also the shape of every real broker in the org: measured on `usman-dpeg`, ZERO
     * Contacts carry `Is_Broker__c = true` while 19 sit on the Broker record type. If this test
     * fails, the live broker roster cannot be selected into any broker lookup at all.
     */
    @isTest
    static void brokerRecordTypeWithoutTheLegacyCheckbox_isAccepted() {
        assertLookupBehaviour(
            BROKER_RT,
            false,
            true,
            'A Contact on the Contact.Broker record type MUST be accepted into '
            + 'BOV_Submission__c.Broker__c even with Is_Broker__c = false. A refusal here means the '
            + 'lookup filter is STILL reading Is_Broker__c, so the record-type repoint did not take '
            + 'effect - re-check the <field> spelling in the six <lookupFilter> blocks. Every one of '
            + 'the org\'s ~19 real brokers has exactly this shape, so this failing means no real '
            + 'broker can be selected anywhere in the application.'
        );
    }

    /**
     * 🔴 THE SECOND HALF OF THE PROOF, AND THE ONE THAT CANNOT BE SKIPPED. A Contact on the INVESTOR
     * record type carrying `Is_Broker__c = TRUE` must be REFUSED.
     *
     * A class asserting only acceptance would pass against a filter that filters NOTHING — which is
     * precisely the silent failure mode this whole class exists to rule out. This test is the one
     * that distinguishes "the filter permits brokers" from "the filter permits everything".
     *
     * It also pins the IR/Acquisitions boundary: an investor Contact must never be selectable as a
     * broker, no matter what a stray checkbox says.
     */
    @isTest
    static void investorRecordTypeWithTheLegacyCheckbox_isRefused() {
        assertLookupBehaviour(
            INVESTOR_RT,
            true,
            false,
            'A Contact on the Contact.Investor record type MUST be refused by '
            + 'BOV_Submission__c.Broker__c even with Is_Broker__c = true. If it was ACCEPTED, there '
            + 'are only two possibilities and both are serious: (a) the lookup filter is still '
            + 'reading Is_Broker__c, or (b) the filter deployed green and is not filtering at all - '
            + 'in which case all six broker lookups are currently wide open. Do not treat this as a '
            + 'test-data problem.'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════
    // THE TWO HARNESS CONTROLS — without these the two above are not interpretable
    // ═════════════════════════════════════════════════════════════════════════════════

    /**
     * CONTROL, POSITIVE SIDE. The ordinary broker (record type AND checkbox) is accepted. If this
     * fails, the refusals above prove nothing about the lookup filter — something unrelated is
     * refusing every save on this object (a validation rule, a required field, a duplicate rule or
     * a trigger) and THAT is the finding, not the filter.
     */
    @isTest
    static void ordinaryBrokerContact_isAccepted() {
        assertLookupBehaviour(
            BROKER_RT,
            true,
            true,
            'The ordinary broker fixture (Broker record type AND Is_Broker__c = true) must be '
            + 'accepted under EITHER definition. A failure here is NOT a lookup-filter finding - it '
            + 'means something else on BOV_Submission__c is refusing every insert, and it '
            + 'invalidates the two refusal assertions in this class until it is explained.'
        );
    }

    /**
     * CONTROL, NEGATIVE SIDE. A Contact that fails both definitions is refused. Establishes that a
     * refusal is reachable at all in this fixture, so the investor-plus-checkbox refusal above is
     * not the only refusal path being exercised.
     */
    @isTest
    static void contactFailingBothDefinitions_isRefused() {
        assertLookupBehaviour(
            INVESTOR_RT,
            false,
            false,
            'A Contact that is a broker under NEITHER definition must be refused. A failure here '
            + 'means the lookup filter is inactive or absent entirely, which would make every other '
            + 'assertion in this class vacuous.'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════
    // Harness
    // ═════════════════════════════════════════════════════════════════════════════════

    /**
     * Builds one Contact of the requested shape, points a BOV_Submission__c at it, saves, and
     * asserts the save was accepted or refused as expected.
     *
     * ⚠ A PLAIN `insert` IS USED DELIBERATELY, NOT `Database.insert(rec, false)`. `allOrNone = true`
     * raises `DmlException` whether the platform reports a lookup-filter refusal as a row-level
     * error or as a transaction-level one, so this harness does not depend on which of the two the
     * platform chooses. The observed status code is captured either way and printed on failure.
     *
     * @param recordTypeDevName  Contact record type to stamp ('Broker' or 'Investor').
     * @param isBrokerFlag       Value for the retired `Is_Broker__c` checkbox.
     * @param expectAccepted     True when the save must succeed, false when it must be refused.
     * @param diagnostic         The message a human reads when this cell of the truth table fails.
     */
    private static void assertLookupBehaviour(
        String recordTypeDevName,
        Boolean isBrokerFlag,
        Boolean expectAccepted,
        String diagnostic
    ) {
        Contact fixture = buildContact(recordTypeDevName, isBrokerFlag);

        BOV_Submission__c submission = TestDataFactory.createBovSubmissions(1, false)[0];
        submission.Broker__c = fixture.Id;

        Boolean accepted = false;
        String observed  = 'the insert SUCCEEDED - no exception was raised';

        Test.startTest();
        try {
            insert submission;
            accepted = true;
        } catch (DmlException e) {
            observed = e.getDmlStatusCode(0) + ' :: ' + e.getDmlMessage(0);
        }
        Test.stopTest();

        String shape = 'FIXTURE: RecordType=' + recordTypeDevName
            + ', Is_Broker__c=' + isBrokerFlag
            + ' | EXPECTED=' + (expectAccepted ? 'ACCEPTED' : 'REFUSED')
            + ' | OBSERVED=' + (accepted ? 'ACCEPTED' : 'REFUSED')
            + ' (' + observed + ')';

        Assert.areEqual(expectAccepted, accepted, diagnostic + ' || ' + shape);

        if (expectAccepted) {
            // Acceptance is only meaningful if the value actually persisted. A save that succeeds
            // while silently discarding the lookup would otherwise read as a pass.
            BOV_Submission__c saved = [
                SELECT Broker__c FROM BOV_Submission__c WHERE Id = :submission.Id LIMIT 1
            ];
            Assert.areEqual(fixture.Id, saved.Broker__c,
                'The broker Contact must actually PERSIST on the lookup, not merely survive the '
                + 'save. A null here means the write was accepted and discarded. || ' + shape);
        } else {
            // Refused for the RIGHT reason. A validation rule, a required field or a duplicate rule
            // would also refuse this insert, and would make the test pass while proving nothing
            // about the lookup filter.
            Assert.isTrue(observed.contains(FILTER_REFUSAL),
                'The save was refused, but NOT by the lookup filter. Expected status code '
                + FILTER_REFUSAL + '. Something else on BOV_Submission__c refused this insert, so '
                + 'this test would have passed for the wrong reason. || ' + shape);
        }
    }

    /**
     * A Contact of an exactly-specified shape. Built through `TestDataFactory` per ARCHITECTURE.md
     * §2, then overridden on both axes — the factory's own methods deliberately never produce the
     * self-contradictory combinations this class needs.
     *
     * 🔴 THE RECORD TYPE IS ASSERTED AFTER INSERT, NOT ASSUMED. `TestDataFactory.recordTypeId`
     * silently returns null when a record type is unavailable to the running user, which would land
     * the row on the default (Master) record type and INVERT this entire class into a set of
     * confident false passes. A describe-based resolve plus a post-insert read-back is the only
     * thing standing between that and a green suite that means nothing.
     */
    private static Contact buildContact(String recordTypeDevName, Boolean isBrokerFlag) {
        Schema.RecordTypeInfo info = Contact.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDevName);

        Assert.isNotNull(info,
            'This org has no Contact record type named "' + recordTypeDevName + '". This class '
            + 'cannot prove anything about a record-type lookup filter without it - deploy '
            + 'objects/Contact/recordTypes/ before reading any other result here.');
        Assert.isTrue(info.isAvailable(),
            'The Contact.' + recordTypeDevName + ' record type is not available to the running test '
            + 'user, so the fixture below would silently land on the DEFAULT record type and every '
            + 'assertion in this class would become meaningless. Grant it before trusting any '
            + 'result.');

        Contact c = TestDataFactory.createContact(null, false);
        c.RecordTypeId = info.getRecordTypeId();
        c.Is_Broker__c = isBrokerFlag;
        c.Broker_Firm__c = 'Lookup Filter Proof Brokerage';
        c.Broker_Status__c = 'Active';
        insert c;

        Contact readBack = [
            SELECT Id, RecordTypeId, RecordType.DeveloperName, Is_Broker__c
            FROM Contact WHERE Id = :c.Id LIMIT 1
        ];
        Assert.areEqual(recordTypeDevName, readBack.RecordType.DeveloperName,
            'The fixture did NOT land on the Contact.' + recordTypeDevName + ' record type. Every '
            + 'assertion in this class depends on this stamp, so a mismatch here invalidates the '
            + 'run rather than merely failing one case.');
        Assert.areEqual(isBrokerFlag, readBack.Is_Broker__c,
            'The fixture\'s Is_Broker__c did not persist as requested. The retired checkbox is half '
            + 'of what makes these fixtures discriminate between the old and new definitions, so '
            + 'this invalidates the run.');

        return readBack;
    }
}
