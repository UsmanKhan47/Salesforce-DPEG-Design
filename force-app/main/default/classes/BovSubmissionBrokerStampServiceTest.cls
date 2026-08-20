/**
 * @description Tests `BovSubmissionBrokerStampService.stampBrokerFields` — the BOV broker-contact
 * dropdown (`agent-output/bov-broker-contact-lookup-requirements.md` §3, D-5, added 2026-08-20).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION. Recorded here per the service's own
 * class header instruction so review does not have to re-derive it. This is a trigger path
 * (`BovSubmissionTriggerHandler.beforeInsert` / `beforeUpdate`) that loops over a collection. The
 * per-transaction-singleton exemption in `.claude/rules/bulk-test-rule.md` does NOT apply, and
 * neither does the `.claude/rules/content-publication-rule.md` carve-out (no content object).
 * See `bulkInsert251WithBroker_allStampedThroughTheRealTrigger`,
 * `bulk251BrokerChanges_costsExactlyOneQueryForTheWholeChunk` and
 * `bulk251NoRecordChangesBroker_costsNothing` below.
 * ─────────────────────────────────────────────────────────────────────────────────────
 *
 * ── 🔴 WHY THE "EXACTLY 1 QUERY" CLAIM IS MEASURED BY DIRECT INVOCATION, NOT THROUGH THE TRIGGER ──
 * The budget claim is "AT MOST 1 SOQL **PER CHUNK**". A real 251-row DML spans TWO trigger chunks
 * (chunks are 200), so the service is legitimately invoked TWICE and legitimately issues TWO
 * queries — asserting `1` around a real 251-row `insert` would be asserting a falsehood, and
 * asserting `2` would be pinning the chunk size rather than the service. The per-chunk constant is
 * therefore measured by invoking the service ONCE with 251 records in hand.
 *
 * That does not leave the real trigger unproven. `bulkInsert251WithBroker_allStampedThroughTheRealTrigger`
 * runs the genuine DML, and COMPLETING IT AT ALL is part of the falsifier: a per-record query would
 * need 251 SOQL and would blow the 100-query limit long before finishing. Same split, same reason,
 * as `DispositionBrokerStampServiceTest` and `DispositionStageEntryServiceTest`.
 *
 * ── EXPECTED-NAME ARITHMETIC (do not re-query Contact.Name — compose it locally) ──
 * `Name` is a compound field and is NOT reliably populated on an in-memory sObject immediately
 * after insert. `FirstName` / `LastName` are the literal fields the fixture set, and English-locale
 * `Name` is exactly `FirstName + ' ' + LastName` — the same assumption the service's own 121-char
 * `Name` ceiling rests on.
 *
 * ── ⚠ FIXTURE COLLISION HAZARD, STATED SO IT IS NOT REINTRODUCED ──
 * `TestDataFactory.createBrokerContacts` sets `Broker_Firm__c = 'Test Brokerage ' + i` and
 * `TestDataFactory.createBovSubmissions` sets the SAME string on the submission. At index 0 the
 * two are BYTE-IDENTICAL, so a test that just inserted a factory submission with a factory broker
 * and asserted "the firm equals the broker's firm" would PASS WITHOUT THE SERVICE EXISTING. Every
 * stamping test below therefore over-writes the submission's Text fields with distinct
 * `'TYPED ...'` literals first, so the assertion can only pass if the stamp actually ran.
 *
 * ── ⚠ BROKER CONTACTS MUST COME FROM `createBrokerContact(s)` ──
 * `BOV_Submission__c.Broker__c` carries an ACTIVE, NON-OPTIONAL lookup filter on the
 * `Contact.Broker` RECORD TYPE.
 *
 * ⚠ CORRECTED 2026-08-20 — THE OLD REASON IS NOW EXACTLY BACKWARDS. This read: "...lookup filter on
 * `Contact.Is_Broker__c`. A plain `createContacts()` Contact is refused at save time." A plain
 * `createContacts()` Contact is now ACCEPTED, because TestDataFactory stamps the Broker record type
 * on every Contact it builds. Keep using `createBrokerContact(s)` here — they populate the Broker_*
 * fields this stamp service reads — but do NOT use `createContacts()` as a NEGATIVE fixture. For a
 * Contact that genuinely is not a broker, use `TestDataFactory.createNonBrokerContact(s)`.
 *
 * @see force-app/main/default/classes/BovSubmissionBrokerStampService.cls
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/ContactSelector.cls (selectBrokerLabelsByIds)
 * @see force-app/main/default/classes/DispositionBrokerStampServiceTest.cls (the sibling suite)
 */
@isTest
private class BovSubmissionBrokerStampServiceTest {

    private static final Integer BULK_N = 251;

    /** Distinct from anything the factory writes — see the FIXTURE COLLISION HAZARD note. */
    private static final String TYPED_FIRM = 'TYPED FIRM - MUST BE OVERWRITTEN BY THE STAMP';
    private static final String TYPED_NAME = 'TYPED NAME - MUST BE OVERWRITTEN BY THE STAMP';

    private static Id dispositionId() {
        return TestDataFactory.defaultDisposition().Id;
    }

    /** `Contact.Name` composed from the literal fixture fields, never re-queried. */
    private static String nameOf(Contact broker) {
        return broker.FirstName + ' ' + broker.LastName;
    }

    /**
     * A factory submission with both Text fields set to literals no stamp could coincidentally
     * produce.
     *
     * ⚠ `Broker__c` IS RESET TO NULL HERE, DELIBERATELY, AS OF 2026-08-20 (Tranche 2, requirements
     * §3 D1). `TestDataFactory.createBovSubmission` now always attaches a real broker Contact so
     * that `Broker_Required_On_Submission` (which deploys alongside this change) is satisfiable —
     * see that factory method's own header. That default broker is irrelevant to most tests in
     * this suite, which either explicitly set `Broker__c` themselves right after calling this
     * helper (surviving as the override), or need the true "insert naming no broker" shape this
     * reset restores.
     */
    private static BOV_Submission__c typedSubmission() {
        BOV_Submission__c submission = TestDataFactory.createBovSubmission(dispositionId(), false);
        submission.Broker__c = null;
        submission.Broker_Firm__c = TYPED_FIRM;
        submission.Contact_Name__c = TYPED_NAME;
        return submission;
    }

    /** Null/empty-safe per the method's own ApexDoc. */
    @isTest
    static void stampBrokerFields_nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        BovSubmissionBrokerStampService.stampBrokerFields(null, null);
        BovSubmissionBrokerStampService.stampBrokerFields(new List<BOV_Submission__c>(), null);
        completedWithoutThrowing = true; // reached only if neither call above threw
        Test.stopTest();

        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 1 — Broker__c SET, Contact resolves
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The primary behaviour: BOTH Text fields are copied STRAIGHT ACROSS from the chosen Contact,
     * with no composition and no separator (the sibling service's `Person - Firm` shape must NOT
     * appear here — that is design C-3's central warning).
     *
     * The `TYPED_*` literals also pin the "where they would collide, the stamp wins" clause of the
     * service header: this save both sets `Broker__c` and hand-types the two fields, and the stamp
     * overwrites, because a before trigger sees the final field values.
     */
    @isTest
    static void insertWithBroker_stampsBothTextFieldsFromTheContact() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expectedName = nameOf(broker);
        String expectedFirm = broker.Broker_Firm__c;
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = broker.Id;

        Test.startTest();
        insert submission;
        Test.stopTest();

        BOV_Submission__c saved = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(expectedName, saved.Contact_Name__c,
            'Contact_Name__c must be Contact.Name copied verbatim — no composition, no separator');
        Assert.areEqual(expectedFirm, saved.Broker_Firm__c,
            'Broker_Firm__c must be Contact.Broker_Firm__c copied verbatim, overwriting the typed literal');
        Assert.areNotEqual(TYPED_FIRM, saved.Broker_Firm__c,
            'The hand-typed firm must NOT survive a save that also set Broker__c — the stamp wins');
        Assert.isFalse(saved.Contact_Name__c.contains(' - '),
            'This service must NOT compose "Person - Firm" — that is the SIBLING service\'s format '
            + 'and copying its body here is the bug design C-3 exists to prevent');
    }

    /**
     * The blank-firm decision, pinned. A resolved Contact with no firm yields
     * `Broker_Firm__c = null` — the blank is COPIED, not skipped — while `Contact_Name__c` is still
     * stamped. The rejected alternative ("leave the firm alone when blank") would leave the PRIOR
     * broker's firm beside the NEW broker's name, and `Broker_Display__c` renders both.
     */
    @isTest
    static void insertWithBroker_blankFirm_stampsNameAndNullsFirm() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.Broker_Firm__c = null;
        insert broker;
        String expectedName = nameOf(broker);
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = broker.Id;

        Test.startTest();
        insert submission;
        Test.stopTest();

        BOV_Submission__c saved = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(expectedName, saved.Contact_Name__c,
            'A blank firm must not stop the name being stamped');
        Assert.isNull(saved.Broker_Firm__c,
            'A blank Contact.Broker_Firm__c must be COPIED as null, not skipped — skipping would '
            + 'leave a previous broker\'s firm beside this broker\'s name, which Broker_Display__c '
            + 'would render as a person who does not work there');
    }

    /**
     * Both fields move together when the picker changes from one broker to another.
     *
     * ⚠ THE UPDATE IS A FRESH, NARROW sObject, AND THAT IS WHAT MAKES THE THIRD ASSERTION REAL
     * (fixed 2026-08-21, sweep prompted by the NDA/offer twins' clear-branch failure). This test
     * used to reuse the `submission` variable, which still carries the `TYPED_FIRM` / `TYPED_NAME`
     * literals `typedSubmission()` wrote — Apex never refreshes an sObject with values a before
     * trigger assigned, the same trap already documented at
     * `updateThatDoesNotTouchBroker_leavesBothTextFieldsUnchanged` below. The test PASSED (the stamp
     * fires on a broker change and overwrites), but `areNotEqual(brokerA.Broker_Firm__c, ...)` was
     * VACUOUS: A's firm was never in the payload, so no implementation could have left it behind.
     * With a narrow payload the DB really does hold A's stamped firm going into this save, so
     * "A's firm must be gone" is now a claim that can fail.
     */
    @isTest
    static void updateBrokerChangeFromAToB_restampsBothFields() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(2, null, true);
        Contact brokerA = brokers[0];
        Contact brokerB = brokers[1];
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = brokerA.Id;
        insert submission;

        Test.startTest();
        update new BOV_Submission__c(Id = submission.Id, Broker__c = brokerB.Id);
        Test.stopTest();

        BOV_Submission__c saved = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(nameOf(brokerB), saved.Contact_Name__c,
            'Changing Broker__c A -> B must re-stamp the name to B');
        Assert.areEqual(brokerB.Broker_Firm__c, saved.Broker_Firm__c,
            'Changing Broker__c A -> B must re-stamp the firm to B\'s — A\'s firm must not survive '
            + 'beside B\'s name');
        Assert.areNotEqual(brokerA.Broker_Firm__c, saved.Broker_Firm__c,
            'A\'s firm must be gone — a hybrid row is the failure mode this pairing prevents');
    }

    /**
     * Maximum-length case, made real rather than merely argued. The two lengths are INDEPENDENT
     * (there is no combined 244-char arithmetic here — that belongs to the sibling service):
     * `Name` = 40 + 1 + 80 = 121 into Text(255), and `Broker_Firm__c` = 120 into Text(255).
     */
    @isTest
    static void maxLengthValues_saveUntruncated() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.FirstName = 'F'.repeat(40);
        broker.LastName = 'L'.repeat(80);
        broker.Broker_Firm__c = 'B'.repeat(120);
        insert broker;
        String expectedName = nameOf(broker);
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = broker.Id;

        Test.startTest();
        insert submission;
        Test.stopTest();

        BOV_Submission__c saved = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(121, expectedName.length(),
            'Sanity check on the service header\'s arithmetic: 40 + 1 + 80 = 121');
        Assert.areEqual(expectedName, saved.Contact_Name__c,
            'The full 121-character name must save whole into Text(255) — no left(255) exists or is needed');
        Assert.areEqual(120, saved.Broker_Firm__c.length(),
            'The full 120-character firm must save whole into Text(255)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 2 — Broker__c CLEARED to null
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 RETARGETED TO DIRECT INVOCATION, 2026-08-20 (Tranche 2, requirements §3 D1).
     * `Broker_Required_On_Submission` (deployed alongside this change) makes `Broker__c` an
     * unguarded invariant on EVERY save, so a REAL `update` clearing it to null — this test's
     * original mechanism — is now refused before this service ever runs. Direct invocation is the
     * only way left to prove this outcome, exactly like the "Contact does not resolve" outcome
     * below, which was already unreachable via real DML for the same reason (the active lookup
     * filter there, the new validation rule here).
     */
    @isTest
    static void updateClearsBrokerToNull_nullsBothTextFieldsInTheSameSave() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = broker.Id;
        insert submission;
        BOV_Submission__c before = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.isNotNull(before.Contact_Name__c, 'Precondition: the insert must have stamped a name');

        BOV_Submission__c newRow = new BOV_Submission__c(Id = submission.Id, Broker__c = null);
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>{
            submission.Id => new BOV_Submission__c(Id = submission.Id, Broker__c = broker.Id)
        };

        Test.startTest();
        BovSubmissionBrokerStampService.stampBrokerFields(
            new List<BOV_Submission__c>{ newRow }, oldMap);
        Test.stopTest();

        Assert.isNull(newRow.Contact_Name__c,
            'Clearing Broker__c must null Contact_Name__c IN THE SAME SAVE');
        Assert.isNull(newRow.Broker_Firm__c,
            'Clearing Broker__c must null Broker_Firm__c too — Broker_Display__c is a formula over '
            + 'BOTH, so leaving either behind renders half a broker beside an empty picker');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 3 — Broker__c UNCHANGED. The regression guard for every other writer.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE MOST VALUABLE TEST IN THIS CLASS, AND ITS `Broker__c` IS NON-NULL DELIBERATELY.
     *
     * The null-broker version of this scenario is NOT sufficient and that is not a theoretical
     * concern — the null↔null shape fails to falsify the single most likely simplification: keying
     * the "should I stamp?" test on `submission.Broker__c != null` instead of on `Broker__c` having
     * CHANGED. With a null broker on both sides, a `!= null` variant skips the record too, the test
     * goes green, and the service's central budget claim ("a chunk in which no record changed
     * `Broker__c` costs ZERO queries") silently becomes false for every non-null-broker update in
     * the org — which, now that these before contexts fire on EVERY `BOV_Submission__c` write, is
     * most of them.
     *
     * Here `Broker__c` is NON-NULL and IDENTICAL on both sides, while BOTH Text fields are
     * independently hand-set to literals that do NOT match the broker's real values. Under an
     * `if (Broker__c != null)` variant this fails on ALL THREE assertions: the record enters
     * `changed`, the Contact query is issued (`queriesUsed` becomes 1, not 0), and PASS 2
     * overwrites both literals with the broker's real name and firm.
     *
     * Direct invocation (see the class header) so the query count is isolated to this service.
     */
    @isTest
    static void updateWithBrokerUnchangedNonNull_bothHandSetLiteralsSurviveAndCostZeroQueries() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        BOV_Submission__c holder = TestDataFactory.createBovSubmission(dispositionId(), true);

        // Simulated before-update context: same non-null broker on both sides (UNCHANGED), while
        // both Text fields are independently touched in the same save.
        BOV_Submission__c newRow = new BOV_Submission__c(
            Id = holder.Id,
            Broker__c = broker.Id,
            Broker_Firm__c = TYPED_FIRM,
            Contact_Name__c = TYPED_NAME
        );
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>{
            holder.Id => new BOV_Submission__c(Id = holder.Id, Broker__c = broker.Id)
        };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionBrokerStampService.stampBrokerFields(
            new List<BOV_Submission__c>{ newRow }, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(TYPED_FIRM, newRow.Broker_Firm__c,
            'An UNCHANGED non-null Broker__c must leave the record skipped — the hand-set firm must '
            + 'survive untouched, not be overwritten with the broker\'s real firm');
        Assert.areEqual(TYPED_NAME, newRow.Contact_Name__c,
            'The hand-set contact name must survive untouched for the same reason');
        Assert.areEqual(0, queriesUsed,
            'An unchanged non-null Broker__c must cost ZERO queries — a `!= null` change-key would '
            + 'query here, and this assertion is what catches that regression');
    }

    /**
     * The same guarantee through REAL DML: an analyst editing an unrelated field (the BOV amount)
     * must not disturb the broker text. This is the shape every other writer of this object takes —
     * the workflow field updates, `BovSubmissionService.replaceSelectedBroker`, and every ordinary
     * terms edit (design D-4's writer table).
     *
     * ⚠ RETARGETED, 2026-08-20 (Tranche 2, requirements §3 D1). `Broker_Required_On_Submission`
     * (deployed alongside this change) makes `Broker__c` mandatory on every save, so `typedSubmission()`
     * can no longer be inserted with a null `Broker__c`. The insert below therefore attaches a real
     * broker and is stamped for real ON THAT INSERT — "the TYPED literals below are dead the moment
     * Broker__c is set" is `insertWithBroker_stampsBothTextFieldsFromTheContact`'s own point. What
     * THIS test still proves, unweakened, is that the STAMPED values then survive an update that
     * never touches `Broker__c` — the regression this test exists to guard.
     */
    @isTest
    static void updateThatDoesNotTouchBroker_leavesBothTextFieldsUnchanged() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        BOV_Submission__c submission = typedSubmission();
        submission.Broker__c = broker.Id;
        insert submission;
        BOV_Submission__c afterInsert = [
            SELECT Broker_Firm__c, Contact_Name__c FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(broker.Broker_Firm__c, afterInsert.Broker_Firm__c,
            'PRECONDITION: the insert must have stamped the real broker\'s firm, not the typed literal');

        // A NARROW update object (Id + BOV_Amount__c only) — not the `submission` variable itself.
        // `submission` still carries the TYPED_FIRM/TYPED_NAME literals it was constructed with in
        // typedSubmission(); Apex never refreshes an sObject's in-memory fields after DML, so
        // reusing that variable for this update would resend those stale literals as part of the
        // payload. Since Broker__c is unchanged, the service correctly leaves whatever text values
        // the DML sends untouched — which would silently clobber the real stamped values with the
        // stale typed ones and falsely fail this exact assertion. A fresh, narrow sObject is the
        // only way to simulate "an analyst editing an unrelated field" without also resending fields
        // the analyst never touched.
        Test.startTest();
        update new BOV_Submission__c(Id = submission.Id, BOV_Amount__c = 9876543);
        Test.stopTest();

        BOV_Submission__c saved = [
            SELECT Broker__c, Broker_Firm__c, Contact_Name__c
            FROM BOV_Submission__c WHERE Id = :submission.Id
        ];
        Assert.areEqual(broker.Id, saved.Broker__c, 'Broker__c was never touched by this save');
        Assert.areEqual(afterInsert.Broker_Firm__c, saved.Broker_Firm__c,
            'A save that does not change Broker__c must leave Broker_Firm__c byte-for-byte intact');
        Assert.areEqual(afterInsert.Contact_Name__c, saved.Contact_Name__c,
            'A save that does not change Broker__c must leave Contact_Name__c byte-for-byte intact');
    }

    /**
     * Design R-3, the LEGACY-DATA guarantee. Rows that predate the picker carry Text values and a
     * NULL `Broker__c`; `null == null` is "unchanged", so they are skipped FOREVER and the
     * comparison matrix keeps rendering them. **No backfill is in scope and none is needed.**
     *
     * 🔴 RETARGETED TO DIRECT INVOCATION, 2026-08-20 (Tranche 2, requirements §3 D1).
     * `Broker_Required_On_Submission` (deployed alongside this change) makes a null `Broker__c`
     * UNSAVABLE by ANY means going forward — the "raw factory row" this test used to insert (the
     * shape every pre-existing BOV test in this repo used to rely on) can no longer exist as a REAL
     * row. It still describes a real category of PRODUCTION data (rows that predate both the picker
     * and this validation rule), and the service must still leave that shape alone — this can now
     * only be proven the same way the "Contact does not resolve" outcome already is: by direct
     * invocation with a synthetic before-context. The submission Id is borrowed from a real insert
     * purely to have a valid Id (identical technique to `updateWithBrokerUnchangedNonNull...`
     * above); its own real, factory-assigned broker is irrelevant — this test overwrites both
     * sides of the simulated save with the LEGACY shape (Broker__c null, Text values pre-set).
     */
    @isTest
    static void legacyRowWithTextAndNoBroker_survivesAnUnrelatedUpdate() {
        BOV_Submission__c holder = TestDataFactory.createBovSubmission(dispositionId(), true);
        String legacyFirm = 'LEGACY FIRM - PRE-DATES THE PICKER AND THE VALIDATION RULE';
        String legacyName = 'LEGACY CONTACT - PRE-DATES THE PICKER AND THE VALIDATION RULE';

        BOV_Submission__c newRow = new BOV_Submission__c(
            Id = holder.Id,
            Broker__c = null,
            Submission_Status__c = 'Selected',
            Broker_Firm__c = legacyFirm,
            Contact_Name__c = legacyName
        );
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>{
            holder.Id => new BOV_Submission__c(Id = holder.Id, Broker__c = null)
        };

        Test.startTest();
        BovSubmissionBrokerStampService.stampBrokerFields(
            new List<BOV_Submission__c>{ newRow }, oldMap);
        Test.stopTest();

        Assert.isNull(newRow.Broker__c, 'A legacy row has no broker lookup and must not gain one');
        Assert.areEqual(legacyFirm, newRow.Broker_Firm__c,
            'A legacy row\'s firm must survive — this is why every pre-existing BOV row stays green');
        Assert.areEqual(legacyName, newRow.Contact_Name__c,
            'A legacy row\'s contact name must survive for the same reason');
    }

    /** The common-case cost proof: an insert naming no broker touches nothing and queries nothing. */
    @isTest
    static void insertWithoutBroker_costsZeroQueriesAndLeavesFactoryTextIntact() {
        BOV_Submission__c submission = typedSubmission();
        // Broker__c left null; Id is also null (never inserted) — the true insert shape.
        List<BOV_Submission__c> newList = new List<BOV_Submission__c>{ submission };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionBrokerStampService.stampBrokerFields(newList, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'An insert naming no broker is the overwhelmingly common case and must cost ZERO queries');
        Assert.areEqual(TYPED_FIRM, submission.Broker_Firm__c,
            'No broker set means no stamp — a typed firm must be left exactly as it was');
        Assert.areEqual(TYPED_NAME, submission.Contact_Name__c,
            'No broker set means no stamp — a typed name must be left exactly as it was');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outcome 4 — Broker__c SET, Contact does NOT resolve
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Direct invocation, not real DML: the active, non-optional lookup filter on `Broker__c` would
     * refuse an actual save pointed at a deleted Contact, so this outcome can only be exercised
     * in-memory — as if the Contact vanished between the pick and a save already in flight (the
     * sharing-filtered and deleted cases the service treats identically).
     *
     * The assertion direction is the point: UNCHANGED, not blanked. Blanking is the more
     * destructive direction, and on THIS object the text is the analyst's response data, not a
     * derived display copy.
     */
    @isTest
    static void brokerSetButContactUnresolvable_leavesBothTextFieldsUnchanged() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Id deletedBrokerId = broker.Id;
        delete broker;
        BOV_Submission__c holder = TestDataFactory.createBovSubmission(dispositionId(), true);

        BOV_Submission__c newRow = new BOV_Submission__c(
            Id = holder.Id,
            Broker__c = deletedBrokerId,
            Broker_Firm__c = TYPED_FIRM,
            Contact_Name__c = TYPED_NAME
        );
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>{
            holder.Id => new BOV_Submission__c(Id = holder.Id, Broker__c = null)
        };

        Test.startTest();
        BovSubmissionBrokerStampService.stampBrokerFields(
            new List<BOV_Submission__c>{ newRow }, oldMap);
        Test.stopTest();

        Assert.areEqual(TYPED_FIRM, newRow.Broker_Firm__c,
            'An unresolvable Contact must leave Broker_Firm__c UNCHANGED, not blanked — on this '
            + 'object the text is the broker\'s response data, and a stale value beside a visible '
            + 'lookup is self-healing on the next successful save');
        Assert.areEqual(TYPED_NAME, newRow.Contact_Name__c,
            'An unresolvable Contact must leave Contact_Name__c UNCHANGED for the same reason');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BULK — 251 records. .claude/rules/bulk-test-rule.md applies IN FULL; no exemption.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 251 forces a SECOND trigger chunk (chunks are 200) through the REAL trigger — the newly added
     * `before insert` context, which did not exist before 2026-08-20.
     *
     * COMPLETING THIS TEST AT ALL IS PART OF THE FALSIFIER: a service that queried per record would
     * need 251 SOQL statements and would hit the 100-query governor limit long before finishing.
     * The exact per-chunk constant is asserted separately, by direct invocation — see the class
     * header for why it cannot be asserted here.
     */
    @isTest
    static void bulkInsert251WithBroker_allStampedThroughTheRealTrigger() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expectedName = nameOf(broker);
        String expectedFirm = broker.Broker_Firm__c;
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(BULK_N, dispositionId(), false);
        for (BOV_Submission__c submission : submissions) {
            submission.Broker__c = broker.Id;
            submission.Broker_Firm__c = TYPED_FIRM;
            submission.Contact_Name__c = TYPED_NAME;
        }

        Test.startTest();
        insert submissions;
        Test.stopTest();

        Assert.areEqual(BULK_N, [
            SELECT COUNT() FROM BOV_Submission__c
            WHERE Id IN :submissions
              AND Contact_Name__c = :expectedName
              AND Broker_Firm__c = :expectedFirm
        ], 'Every one of the 251 submissions inserted with Broker__c set must have BOTH Text fields '
           + 'stamped — 251 spans TWO trigger chunks, so a total below 251 means a chunk was dropped');
    }

    /**
     * 🔴 THE GOVERNOR ASSERTION. The property pinned is COST INDEPENDENT OF RECORD COUNT: exactly
     * one query for 251 records whose `Broker__c` all just changed. A future change that moved the
     * Contact read inside the per-record loop would report 251 here (or fail outright well before
     * 251), which is the entire reason this number is 251 and not something smaller.
     *
     * ⚠ The counters are read INSIDE `Test.startTest()` / `Test.stopTest()`. Reading them after
     * `stopTest()` restores the pre-test counters and makes the assertion silently vacuous.
     */
    @isTest
    static void bulk251BrokerChanges_costsExactlyOneQueryForTheWholeChunk() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        String expectedName = nameOf(broker);
        String expectedFirm = broker.Broker_Firm__c;
        List<BOV_Submission__c> baseline =
            TestDataFactory.createBovSubmissions(BULK_N, dispositionId(), true);

        // Synthetic trigger context: every record's Broker__c just changed from null to the SAME
        // Contact (one distinct Id — still exactly one query, not zero and not 251).
        List<BOV_Submission__c> newList = new List<BOV_Submission__c>();
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>();
        for (BOV_Submission__c submission : baseline) {
            newList.add(new BOV_Submission__c(
                Id = submission.Id,
                Broker__c = broker.Id,
                Broker_Firm__c = TYPED_FIRM,
                Contact_Name__c = TYPED_NAME
            ));
            oldMap.put(submission.Id,
                new BOV_Submission__c(Id = submission.Id, Broker__c = null));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionBrokerStampService.stampBrokerFields(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Integer stampedCount = 0;
        for (BOV_Submission__c submission : newList) {
            if (expectedName.equals(submission.Contact_Name__c)
                    && expectedFirm.equals(submission.Broker_Firm__c)) {
                stampedCount++;
            }
        }

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 changed records — the Contact read is issued once for the '
            + 'whole chunk. Anything above 1 means it moved into the per-record loop.');
        Assert.areEqual(BULK_N, stampedCount,
            'All 251 in-memory records must have BOTH Text fields stamped');
    }

    /**
     * The other half of the constant-cost claim: a chunk in which nothing changed costs NOTHING,
     * even at 251 records. This is now the overwhelmingly common path — these before contexts fire
     * on every `BOV_Submission__c` write in the org, where previously nothing fired on insert.
     */
    @isTest
    static void bulk251NoRecordChangesBroker_costsNothing() {
        List<BOV_Submission__c> baseline =
            TestDataFactory.createBovSubmissions(BULK_N, dispositionId(), true);

        List<BOV_Submission__c> newList = new List<BOV_Submission__c>();
        Map<Id, BOV_Submission__c> oldMap = new Map<Id, BOV_Submission__c>();
        for (BOV_Submission__c submission : baseline) {
            // Every record is "saved" with a field OTHER than Broker__c changing.
            newList.add(new BOV_Submission__c(
                Id = submission.Id, Broker__c = null, BOV_Amount__c = 5000000));
            oldMap.put(submission.Id,
                new BOV_Submission__c(Id = submission.Id, Broker__c = null));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionBrokerStampService.stampBrokerFields(newList, oldMap);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'A save where no record\'s Broker__c changed must cost ZERO queries even at 251 — these '
            + 'before contexts fire on every BOV_Submission__c write in the org');
    }
}
