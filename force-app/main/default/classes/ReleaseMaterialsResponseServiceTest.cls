/**
 * Covers the whole Release Materials response logger vertical: the selector's query and ordering,
 * the service's broker resolution / validation / `USER_MODE` write, and the controller's two-clause
 * error boundary. Added 2026-08-24.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR TESTS THIS FILE EXISTS FOR — everything else is supporting fire
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 1. `nonOwnerEditPersona_theWriteActuallyLands` — a `Minimum Access - Salesforce` user holding the
 *    REAL deployed `DPEG_Disposition_Edit` who owns NONE of the fixture records. Every DPEG
 *    permission set grants `viewAllRecords` and NONE grants `modifyAllRecords`, and that gap cost
 *    this project two UAT cycles on 2026-08-21 — a non-owner's write was refused by sharing and
 *    then swallowed by `allOrNone = false`. This test is what proves the same shape does not exist
 *    here. It also asserts the PRECONDITION (`UserRecordAccess`: readable, NOT editable) so it
 *    cannot pass by accidentally being run as an owner.
 * 2. `readOnlyPersona_isRefused` — the same persona built from `DPEG_Disposition_View` instead.
 *    🔴 THIS IS THE ONE THAT REDS IF `AccessLevel.USER_MODE` IS EVER CHANGED TO `SYSTEM_MODE` on
 *    the insert. Without it, that mutation is invisible: every other test here runs as an admin who
 *    can create the record either way.
 * 3. `noBrokerAppointed_stillLogsWithABlankBroker` — the explicit 2026-08-24 instruction. A missing
 *    broker must NOT block the log, which is the OPPOSITE of what the Log Offer dialog does with
 *    the same resolution; `ReleaseMaterialsResponseService`'s header argues why they differ.
 * 4. `budget_*` — the query/DML ceilings, ASSERTED. A card that silently grows a query per row is
 *    invisible on a single-record screen until a page with ten cards on it times out.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE IS APPLIED TO THE **READ** AND
 * DELIBERATELY NOT TO THE WRITE. `logResponse` takes SCALARS, is invoked once per Save click, has
 * no trigger, no batch, no collection parameter and no loop a 251st record would force a second
 * pass through — the rule's own "structurally single-record-per-transaction" exemption, recorded in
 * `ReleaseMaterialsResponseService`'s header. The READ is volume-tested at 251 rows, where the
 * falsifier is real: the query count must stay CONSTANT.
 * ⚠ `Release_Materials_Response__c` IS NOT A CONTENT OBJECT, so
 * `.claude/rules/content-publication-rule.md`'s 20-row ceiling does not apply here. That rule is
 * specific to `ContentVersion` / `ContentNote` / `ContentDocument` and their non-refundable org-wide
 * quota; nothing in this file touches them.
 *
 * @see force-app/main/default/classes/ReleaseMaterialsResponseService.cls
 * @see force-app/main/default/classes/DispositionOfferFormServiceTest.cls (the persona patterns)
 */
@isTest
private class ReleaseMaterialsResponseServiceTest {

    private static final String METHOD_QUESTIONS = 'More questions';
    private static final String METHOD_DECISION = 'Decision';
    private static final String METHOD_OFFER = 'Offer';

    /** The placeholder both cards render for a response with no broker. */
    private static final String NO_BROKER = 'No broker recorded';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c onMarket() {
        return TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true
        );
    }

    private static Disposition__c offMarket(Id brokerContactId) {
        Disposition__c disposition = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false
        );
        disposition.Broker__c = brokerContactId;
        insert disposition;
        return disposition;
    }

    /**
     * Promotes one of a disposition's BOV submissions to `Selected` and returns its broker Id — the
     * ON-MARKET source of the appointed broker. Copied verbatim from
     * `DispositionOfferFormServiceTest` so both suites exercise the resolution the same way.
     */
    private static Id appointBovBroker(Id dispositionId) {
        BOV_Submission__c submission = TestDataFactory.createBovSubmission(dispositionId, true);
        submission.Submission_Status__c = 'Selected';
        update submission;
        return submission.Broker__c;
    }

    /**
     * A broker Contact **PARENTED TO AN ACCOUNT**, and the Account is not decoration.
     *
     * 🔴 MEASURED IN `usman-dpeg` 2026-08-24, AND IT COST A TEST FAILURE TO FIND: an ACCOUNT-LESS
     * Contact is visible ONLY TO ITS OWNER, whatever the object's OWD says (`Contact`'s internal
     * OWD here is `ReadWrite`, and it made no difference). Because a Lookup insert requires READ
     * access to the referenced record, `nonOwnerEditPersona_theWriteActuallyLands` failed with
     * `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY, insufficient access rights on cross-reference
     * id: 003iw000000xEXb` — an error that reads like a defect in the SERVICE and is actually a
     * property of the FIXTURE.
     * ⚠ THE ACCOUNT-LESS SHAPE IS WHAT `TestDataFactory.createBrokerContact(null, true)` PRODUCES,
     * and every other test in this file uses it happily — because they run as the admin who owns
     * the Contact. Only the non-owner personas need the parent.
     * 🔴 AND THE PRODUCTION IMPLICATION IS REAL, NOT A TEST ARTEFACT: a broker Contact created
     * without a firm Account, by a user other than the one logging the response, cannot be stamped
     * onto a response by that other user. Broker Contacts in this org normally carry their firm's
     * Account, so it does not bite today — but "give the broker Contact an Account" is a data rule,
     * not a testing trick.
     */
    private static Contact accountedBroker() {
        Account firm = TestDataFactory.createAccount(true);
        return TestDataFactory.createBrokerContact(firm.Id, true);
    }

    /** The rows on a disposition, read as the admin test user so a persona's write is verifiable. */
    private static List<Release_Materials_Response__c> stored(Id dispositionId) {
        return [
            SELECT Id, OwnerId, Method__c, Notes__c, Broker__c, Entry_DateTime__c
            FROM Release_Materials_Response__c
            WHERE Disposition__c = :dispositionId
            ORDER BY Entry_DateTime__c DESC, Name DESC
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // PERSONAS — real profiles, real deployed permission sets, nothing from the base profile
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * A user on `Minimum Access - Salesforce` holding the named REAL, DEPLOYED permission sets and
     * owning nothing.
     *
     * 🔴 THE BASE PROFILE IS LOAD-BEARING AND IS NOT A DETAIL. `Standard User` carries broad
     * standard-object grants that MASK a denial and make a permission test pass for the wrong
     * reason — this repo has a written incident of exactly that (`denial-tests-need-minimum-access-
     * profile`). Everything these personas can do must come from an assigned set that a real DPEG
     * principal also holds.
     * 🔴 `DPEG_Contact_View` / `_Edit` IS NOT OPTIONAL EITHER. The broker resolution traverses
     * `Broker__r.Name`, and `USER_MODE` enforces OBJECT-level read on the related object — a grant
     * that lives in NEITHER disposition set. A persona assembled from the disposition set alone
     * throws `QueryException` before reaching the code under test, which reads like a defect in the
     * service. That cross-permission-set coupling is real and is documented at
     * `ReleaseMaterialsResponseSelector`.
     * ⚠ THE PERMISSION SETS ARE ASSIGNED INDIVIDUALLY RATHER THAN VIA THEIR PSG. A
     * `PermissionSetGroup` must be `Updated` before it can be assigned and recalculation is
     * asynchronous and org-state-dependent; a fixture that fails intermittently for an unrelated
     * reason is worse than one that is deliberately, documentedly explicit.
     * ⚠ NO ROLE, DELIBERATELY. A role would expose the persona to "Grant Access Using Hierarchies"
     * and could hand it record-level edit, turning the non-owner test green for a reason that has
     * nothing to do with the code. The `UserRecordAccess` precondition is what detects that.
     * ⚠ MIXED_DML: `User` / `PermissionSetAssignment` are SETUP objects and callers insert non-setup
     * fixtures in the same transaction, so both inserts run inside `System.runAs(currentUser)`.
     */
    private static User persona(String aliasSeed, List<String> permissionSetNames) {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        List<PermissionSet> sets = [
            SELECT Id, Name FROM PermissionSet WHERE Name IN :permissionSetNames
        ];
        Assert.areEqual(permissionSetNames.size(), sets.size(),
            'FIXTURE PRECONDITION FAILED: expected ' + permissionSetNames
                + ' to exist in this org; found ' + sets.size() + '. Without them this persona '
                + 'fails before reaching the code under test. Deploy the permission sets first.');
        String unique = aliasSeed + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User user = new User(
            FirstName = 'Rmr',
            LastName = 'Persona',
            Alias = aliasSeed,
            Email = 'dpeg.rmr@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : sets) {
                assignments.add(
                    new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = ps.Id)
                );
            }
            insert assignments;
        }
        return user;
    }

    /** Can read every Disposition, can create a response, OWNS NOTHING. */
    private static User editPersona() {
        return persona('rmre', new List<String>{
            'DPEG_Base_Access', 'DPEG_Disposition_Edit', 'DPEG_Contact_Edit'
        });
    }

    /** Can read every Disposition and every response, and may create NONE. */
    private static User readOnlyPersona() {
        return persona('rmrv', new List<String>{
            'DPEG_Base_Access', 'DPEG_Disposition_View', 'DPEG_Contact_View'
        });
    }

    /**
     * FIXTURE PRECONDITION for the non-owner tests: the persona can SEE the record and cannot EDIT
     * it, i.e. it holds `viewAllRecords` and not `modifyAllRecords` and is not the owner.
     *
     * 🔴 WITHOUT THIS, THE HEADLINE TEST CAN PASS FOR THE WRONG REASON. If a role, a sharing rule
     * or an ownership change ever hands the persona edit access, the write would land because the
     * persona is effectively an owner — and the test would report success about a property it no
     * longer exercises.
     */
    private static void assertReadableButNotEditable(User persona, Id recordId) {
        // ⚠ `RecordId` MUST BE IN THE SELECT LIST. `UserRecordAccess` refuses to compile without
        // it — "RecordId field must be selected" — even though it is also the filter.
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :persona.Id AND RecordId = :recordId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the persona must be able to SEE the disposition '
                + '(viewAllRecords). Without read on the parent, the child insert fails with '
                + 'INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY and proves nothing.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the persona must NOT be able to edit the disposition. If this '
                + 'is true, the persona has become an effective owner (a role, a sharing rule, an '
                + 'ownership change or a new modifyAllRecords grant) and the non-owner test below '
                + 'is no longer testing anything. Investigate; do not delete the assertion.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE HEADLINE: A NON-OWNER'S WRITE ACTUALLY LANDS
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE TEST THIS FEATURE WAS WRITTEN AROUND.
     *
     * The 2026-08-21 defect: a non-owner's write was refused by RECORD-LEVEL SHARING and then
     * swallowed by `allOrNone = false`, so every test stayed green while production silently lost
     * writes. Two properties make that unreachable here and BOTH are exercised below:
     *   · the write is an INSERT of a brand-new row the running user OWNS, so sharing has no
     *     existing row to consult — asserted via `OwnerId`;
     *   · `allOrNone` is TRUE, so a refusal would THROW rather than vanish — asserted by the fact
     *     that this test does not swallow anything and the row is then READ BACK.
     * ⚠ READING THE ROW BACK IS THE PROOF. Asserting that `logResponse` "did not throw" would pass
     * against a swallowed failure, which is precisely the shape that shipped in August.
     */
    @isTest
    static void nonOwnerEditPersona_theWriteActuallyLands() {
        Contact broker = accountedBroker();
        Disposition__c disposition = offMarket(broker.Id);
        User nonOwner = editPersona();
        assertReadableButNotEditable(nonOwner, disposition.Id);

        Test.startTest();
        System.runAs(nonOwner) {
            ReleaseMaterialsResponseService.logResponse(
                disposition.Id, METHOD_DECISION, 'Passing on this one.'
            );
        }
        Test.stopTest();

        List<Release_Materials_Response__c> rows = stored(disposition.Id);
        Assert.areEqual(1, rows.size(),
            '🔴 THE WRITE MUST ACTUALLY BE IN THE DATABASE. Zero rows here with no exception thrown '
                + 'is the exact 2026-08-21 failure shape: a refusal swallowed by allOrNone=false.');
        Assert.areEqual(nonOwner.Id, rows[0].OwnerId,
            'and the running user OWNS the new row — which is why record-level sharing could never '
                + 'have refused this insert, whatever it says about the parent');
        Assert.areEqual(METHOD_DECISION, rows[0].Method__c, 'with the method they picked');
        Assert.areEqual(broker.Id, rows[0].Broker__c,
            'and the broker RESOLVED from the parent, by a user who never chose one');
    }

    /**
     * 🔴 THE MUTATION DETECTOR FOR `AccessLevel.USER_MODE` ON THE INSERT.
     *
     * `DPEG_Disposition_View` grants `allowCreate = false` on `Release_Materials_Response__c`
     * (measured), so a read-only principal must be REFUSED. Change the insert to `SYSTEM_MODE` — or
     * drop the `AccessLevel` argument entirely, which defaults to system mode for `Database.insert`
     * — and this is the ONLY test in the suite that goes red: every other test runs as an admin who
     * can create the row either way.
     * ⚠ THE ASSERTION IS "IT THREW **AND** NOTHING WAS WRITTEN". "It threw" alone would pass if the
     * row were inserted and something else failed afterwards.
     */
    @isTest
    static void readOnlyPersona_isRefused() {
        Contact broker = accountedBroker();
        Disposition__c disposition = offMarket(broker.Id);
        User readOnly = readOnlyPersona();
        assertReadableButNotEditable(readOnly, disposition.Id);

        Exception failure;

        Test.startTest();
        System.runAs(readOnly) {
            try {
                ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_OFFER, 'No.');
            } catch (Exception e) {
                failure = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(failure,
            '🔴 A READ-ONLY PERSONA MUST BE REFUSED. If this is null, the insert is no longer '
                + 'running in USER_MODE and any user who can open the card can write to it.');
        Assert.areEqual(0, stored(disposition.Id).size(),
            'and nothing may reach the database — a throw AFTER a successful insert would be worse '
                + 'than no refusal at all');
    }

    /**
     * The same read-only persona can still READ the log — the refusal above is about CREATE, not
     * about visibility.
     *
     * ⚠ THIS IS THE CONTROL FOR THE DENIAL TEST. Without it, `readOnlyPersona_isRefused` would also
     * pass if the persona could not see the object at all, which would make it a test of the wrong
     * grant.
     */
    @isTest
    static void readOnlyPersona_canStillReadTheLog() {
        Disposition__c disposition = onMarket();
        TestDataFactory.createReleaseMaterialsResponses(2, disposition.Id, true);
        User readOnly = readOnlyPersona();

        ReleaseMaterialsResponseService.LogContext context;

        Test.startTest();
        System.runAs(readOnly) {
            context = ReleaseMaterialsResponseService.getLogContext(disposition.Id);
        }
        Test.stopTest();

        Assert.areEqual(2, context.responses.size(),
            'A view persona sees every logged response (viewAllRecords on a Private object)');
        Assert.isFalse(context.canLog,
            'but the card must not offer them a Save button they would be refused on');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BROKER RESOLUTION — two record types, two sources, and the blank-broker allowance
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void onMarket_stampsTheSelectedBovSubmissionsBroker() {
        Disposition__c disposition = onMarket();
        Id expected = appointBovBroker(disposition.Id);

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(
            disposition.Id, METHOD_QUESTIONS, 'What is the roof age?'
        );
        Test.stopTest();

        List<Release_Materials_Response__c> rows = stored(disposition.Id);
        Assert.areEqual(1, rows.size(), 'One response logged');
        Assert.areEqual(expected, rows[0].Broker__c,
            '🔴 ON-MARKET, THE BROKER IS THE **SELECTED** BOV SUBMISSION\'S. It is resolved server-'
                + 'side and never picked; Disposition__c.Selected_Broker__c is a Text FIRM NAME and '
                + 'is not read by any path this reaches.');
    }

    @isTest
    static void offMarket_stampsTheDispositionsOwnBrokerLookup() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_OFFER, 'Verbal 4.2m.');
        Test.stopTest();

        List<Release_Materials_Response__c> rows = stored(disposition.Id);
        Assert.areEqual(broker.Id, rows[0].Broker__c,
            'Off-market, the broker is the parent Disposition\'s own Broker__c lookup — a different '
                + 'source from the on-market path, and zero extra queries');
    }

    /**
     * 🔴 THE EXPLICIT 2026-08-24 INSTRUCTION: *"still allow the entry with a blank broker rather
     * than blocking the log"*.
     *
     * This is the OPPOSITE of what `DispositionOfferFormService` does with the identical resolution
     * — the Log Offer dialog REFUSES to save without a broker. The two differ on purpose and
     * `ReleaseMaterialsResponseService`'s header argues why: an offer naming nobody cannot be
     * attributed or chosen between, while "a decision came back on the 3rd" is a complete and useful
     * record on its own.
     */
    @isTest
    static void noBrokerAppointed_stillLogsWithABlankBroker() {
        // On-market with NO Selected submission at all — the ordinary state before appointment.
        Disposition__c disposition = onMarket();

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(
            disposition.Id, METHOD_QUESTIONS, 'Asked before anyone was appointed.'
        );
        Test.stopTest();

        List<Release_Materials_Response__c> rows = stored(disposition.Id);
        Assert.areEqual(1, rows.size(),
            '🔴 THE LOG MUST NOT BE BLOCKED BY A MISSING BROKER. If this is 0, the no-broker case '
                + 'has been turned into a refusal — read the class header before "fixing" it.');
        Assert.isNull(rows[0].Broker__c, 'and the lookup is genuinely blank, not a guess');
        Assert.areEqual(METHOD_QUESTIONS, rows[0].Method__c, 'while the entry itself is complete');
    }

    /** And the card must SAY the broker is missing rather than rendering a bare empty field. */
    @isTest
    static void noBrokerAppointed_theContextSaysSoRatherThanRenderingBlank() {
        Disposition__c disposition = onMarket();
        TestDataFactory.createReleaseMaterialsResponses(1, disposition.Id, true);

        Test.startTest();
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseService.getLogContext(disposition.Id);
        Test.stopTest();

        Assert.isNull(context.brokerId, 'No broker is appointed');
        Assert.areEqual('', context.brokerName,
            'and the NAME is an empty string rather than null — a null bound to an element '
                + 'attribute renders the literal text "undefined" (measured in this repo)');
        Assert.areEqual(DispositionOfferFormService.SOURCE_ON_MARKET, context.brokerSource,
            'and the source line still names WHERE a broker would come from, which is what makes '
                + 'the missing-broker message actionable');
        Assert.areEqual(NO_BROKER, context.responses[0].brokerName,
            'A logged row with no broker renders the fixed placeholder, never a blank cell — a '
                + 'blank reads as a rendering failure rather than as missing data');
    }

    /** A resolved broker's NAME reaches the row, not just its Id. */
    @isTest
    static void aLoggedResponseCarriesTheBrokersName() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        Contact named = [SELECT Id, Name FROM Contact WHERE Id = :broker.Id LIMIT 1];

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_DECISION, 'Proceeding.');
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseService.getLogContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(named.Name, context.responses[0].brokerName,
            'The Broker__r traversal supplies the display name — a broker Id with no name beside it '
                + 'is an unreadable field');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // INPUT VALIDATION — authored messages, never a raw platform refusal
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THE PLATFORM WOULD ALSO REFUSE THIS. `Method__c` is a `restricted` value set and Apex DML
     * enforces it — so this test is NOT about enforcement, it is about the MESSAGE. Delete the
     * allow-list and the save still fails, with
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, which the controller is obliged to replace with a
     * generic "could not be saved" because raw DML text leaks field API names. The user would then
     * see an unfixable error for a fixable mistake.
     */
    @isTest
    static void unknownMethod_isRefusedWithTheAuthoredMessage() {
        Disposition__c disposition = onMarket();
        Boolean threw = false;

        Test.startTest();
        try {
            ReleaseMaterialsResponseService.logResponse(disposition.Id, 'Carrier pigeon', 'x');
            Assert.fail('A value off the restricted picklist must not be accepted');
        } catch (ReleaseMaterialsResponseService.ReleaseMaterialsResponseException e) {
            threw = true;
            Assert.areEqual(
                ReleaseMaterialsResponseService.BAD_METHOD_MESSAGE, e.getMessage(),
                'and the message NAMES THE THREE CHOICES, so the user can fix it without an admin'
            );
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The typed exception must be what escapes — the controller branches on '
            + 'its type to decide whether to surface the text verbatim');
        Assert.areEqual(0, stored(disposition.Id).size(), 'and nothing is written');
    }

    @isTest
    static void blankMethod_isRefusedWithTheSameMessage() {
        Disposition__c disposition = onMarket();
        Boolean threw = false;

        Test.startTest();
        try {
            ReleaseMaterialsResponseService.logResponse(disposition.Id, '   ', 'x');
            Assert.fail('A blank method must not be accepted');
        } catch (ReleaseMaterialsResponseService.ReleaseMaterialsResponseException e) {
            threw = true;
            Assert.areEqual(ReleaseMaterialsResponseService.BAD_METHOD_MESSAGE, e.getMessage(),
                'Blank and wrong get the same guidance — both are "pick one of these three"');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The guard must fire');
    }

    /**
     * ⚠ VALIDATION HAPPENS BEFORE ANY READ, AND THIS IS THE TEST THAT PINS IT. A null parent with a
     * bad method must produce the DISPOSITION message, not the method one — the order of the two
     * guards is what decides which, and reversing them changes the user-facing text.
     */
    @isTest
    static void nullDisposition_isRefusedBeforeTheMethodIsEvenChecked() {
        Boolean threw = false;

        Test.startTest();
        try {
            ReleaseMaterialsResponseService.logResponse(null, 'Carrier pigeon', 'x');
            Assert.fail('A null disposition must not be accepted');
        } catch (ReleaseMaterialsResponseService.ReleaseMaterialsResponseException e) {
            threw = true;
            Assert.areEqual(ReleaseMaterialsResponseService.NO_DISPOSITION_MESSAGE, e.getMessage(),
                'The parent guard is FIRST — it is the one refusal that needs no row, and it must '
                    + 'not be pre-empted by the method check');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The guard must fire');
    }

    /** Notes are OPTIONAL, and blank is stored as NULL so the card has one em-dash condition. */
    @isTest
    static void blankNotes_areStoredAsNullNotAsEmptyString() {
        Disposition__c disposition = onMarket();

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_DECISION, '   ');
        Test.stopTest();

        List<Release_Materials_Response__c> rows = stored(disposition.Id);
        Assert.areEqual(1, rows.size(), 'A response with no notes is still a complete entry');
        Assert.isNull(rows[0].Notes__c,
            'and whitespace-only notes are NULL, not an empty string — the card renders an em-dash '
                + 'on exactly one condition');
    }

    @isTest
    static void notesAreTrimmed() {
        Disposition__c disposition = onMarket();

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_OFFER, '  4.2m offer  ');
        Test.stopTest();

        Assert.areEqual('4.2m offer', stored(disposition.Id)[0].Notes__c,
            'Leading/trailing whitespace from a textarea is not content');
    }

    /**
     * 🔴 `Entry_DateTime__c` IS STAMPED BY THE SERVICE, NOT LEFT TO THE FIELD DEFAULT.
     *
     * ⚠ THE ASSERTION IS A BOUNDED WINDOW, NOT AN EQUALITY. The test clock is frozen at
     * `Test.startTest()`, but nothing guarantees `System.now()` inside the service returns the same
     * millisecond as `System.now()` here; an equality assertion would be intermittently red for a
     * reason that has nothing to do with the code.
     */
    @isTest
    static void entryDateTimeIsStampedAtSaveTime() {
        Disposition__c disposition = onMarket();
        Datetime before = System.now();

        Test.startTest();
        ReleaseMaterialsResponseService.logResponse(disposition.Id, METHOD_DECISION, 'Now.');
        Test.stopTest();

        Datetime stamped = stored(disposition.Id)[0].Entry_DateTime__c;
        Assert.isNotNull(stamped, 'The timeline stamp must never be null on a logged row — it is '
            + 'what orders the merged Buyer Activity timeline');
        Assert.isTrue(stamped >= before.addSeconds(-5) && stamped <= System.now().addSeconds(5),
            'and it is NOW, within a tolerance the frozen test clock cannot break. Actual: '
                + stamped + ', window opened at ' + before);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE READ — ordering, scoping, and the not-found contract
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void responsesComeBackNewestFirst() {
        Disposition__c disposition = onMarket();
        // The factory descends Entry_DateTime__c by one minute per index, so index 0 is NEWEST.
        List<Release_Materials_Response__c> fixtures =
            TestDataFactory.createReleaseMaterialsResponses(3, disposition.Id, true);

        Test.startTest();
        List<ReleaseMaterialsResponseService.ResponseRow> rows =
            ReleaseMaterialsResponseService.getResponses(disposition.Id);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'All three rows');
        Assert.areEqual(fixtures[0].Id, rows[0].responseId,
            '🔴 NEWEST FIRST. Asserted on Ids rather than on the RMR AutoNumber, which increments '
                + 'org-wide and happens to agree with creation order — a name-based assertion here '
                + 'could pass for the wrong reason.');
        Assert.areEqual(fixtures[1].Id, rows[1].responseId, 'then the middle one');
        Assert.areEqual(fixtures[2].Id, rows[2].responseId, 'and the oldest last');
    }

    @isTest
    static void responsesOnAnotherDispositionAreNotReturned() {
        Disposition__c mine = onMarket();
        Disposition__c theirs = onMarket();
        TestDataFactory.createReleaseMaterialsResponses(2, mine.Id, true);
        TestDataFactory.createReleaseMaterialsResponses(3, theirs.Id, true);

        Test.startTest();
        List<ReleaseMaterialsResponseService.ResponseRow> rows =
            ReleaseMaterialsResponseService.getResponses(mine.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'The parent filter scopes the card to its own sale — 5 here would mean the WHERE clause '
                + 'lost its Disposition__c predicate');
    }

    @isTest
    static void aDispositionWithNoResponses_returnsAnEmptyListNotNull() {
        Disposition__c disposition = onMarket();

        Test.startTest();
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseService.getLogContext(disposition.Id);
        Test.stopTest();

        Assert.isNotNull(context.responses,
            'Never null — "nothing logged yet" is the normal early state and the card renders it as '
                + 'an empty state, not as an error');
        Assert.areEqual(0, context.responses.size(), 'and it is genuinely empty');
    }

    @isTest
    static void nullId_returnsAnEmptyContextWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseService.getLogContext(null);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.isNotNull(context, 'Never null: the card\'s wire fires before recordId is set');
        Assert.areEqual(0, context.responses.size(), 'with no rows');
        Assert.areEqual('', context.brokerName, 'and an empty (never null) broker name');
        Assert.areEqual(0, after - before,
            'and a null Id costs ZERO queries — the guard is a return, not a query that matches '
                + 'nothing');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BUDGET — the ceilings, asserted rather than described
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE CONSTANT-COST FALSIFIER, AND THE ONE VOLUME TEST THIS FEATURE NEEDS.
     *
     * 251 rows (`.claude/rules/bulk-test-rule.md`'s mandate, applied where it actually falsifies
     * something) read in ONE query. A per-row Contact read for the broker name — the obvious way to
     * "improve" `resolveBrokerName` — would show up here as 252.
     * ⚠ THE FIXTURE IS BUILT **BEFORE** `Test.startTest()` and the counter is read INSIDE the
     * window. A helper called inside a `getQueries()` window counts its own queries; this repo has
     * a measured incident of exactly that making a budget assertion meaningless.
     */
    @isTest
    static void budget_manyResponsesStillCostExactlyOneQuery() {
        Disposition__c disposition = onMarket();
        TestDataFactory.createReleaseMaterialsResponses(251, disposition.Id, true);

        Test.startTest();
        Integer before = Limits.getQueries();
        List<ReleaseMaterialsResponseService.ResponseRow> rows =
            ReleaseMaterialsResponseService.getResponses(disposition.Id);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(200, rows.size(),
            'The selector\'s LOG_LIMIT caps the card at 200 — and it truncates the OLDEST rows, '
                + 'because this read is ORDER BY Entry_DateTime__c DESC. (Contrast the NDA timeline '
                + 'read, which refuses a LIMIT precisely because it is ordered ASC.)');
        Assert.areEqual(1, after - before,
            '🔴 ONE QUERY, CONSTANT IN THE ROW COUNT. 252 here means a per-row Contact read has '
                + 'been introduced — SOQL in a loop on a page render.');
    }

    @isTest
    static void budget_getLogContextOnMarketCostsThreeQueriesAndNoDml() {
        Disposition__c disposition = onMarket();
        appointBovBroker(disposition.Id);
        TestDataFactory.createReleaseMaterialsResponses(3, disposition.Id, true);
        Id dispositionId = disposition.Id;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        ReleaseMaterialsResponseService.getLogContext(dispositionId);
        Integer queriesAfter = Limits.getQueries();
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(3, queriesAfter - queriesBefore,
            'One Disposition read + one Selected-BOV read + one response read. A fourth is a '
                + 'regression that is invisible on a single-record screen.');
        Assert.areEqual(0, dmlAfter - dmlBefore, 'A read path writes nothing');
    }

    @isTest
    static void budget_getLogContextOffMarketSkipsTheBovRead() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        Id dispositionId = disposition.Id;

        Test.startTest();
        Integer before = Limits.getQueries();
        ReleaseMaterialsResponseService.getLogContext(dispositionId);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(2, after - before,
            'Off-market resolves the broker from the parent row already in hand, so the BOV read is '
                + 'SKIPPED ENTIRELY — that skip is a cost property, not a micro-optimisation');
    }

    @isTest
    static void budget_logResponseCostsAtMostTwoQueriesAndOneDml() {
        Disposition__c disposition = onMarket();
        appointBovBroker(disposition.Id);
        Id dispositionId = disposition.Id;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        ReleaseMaterialsResponseService.logResponse(dispositionId, METHOD_OFFER, 'One click.');
        Integer queriesAfter = Limits.getQueries();
        Integer dmlAfter = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(2, queriesAfter - queriesBefore,
            'The two broker reads and nothing else — the write path does NOT re-read the log');
        Assert.areEqual(1, dmlAfter - dmlBefore, 'and exactly one DML statement per Save click');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // CONTROLLER — the thin boundary and its two-clause catch
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void controller_returnsTheContext() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        TestDataFactory.createReleaseMaterialsResponses(2, disposition.Id, true);

        Test.startTest();
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseController.getLogContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(2, context.responses.size(), 'The controller passes the rows through');
        Assert.areEqual(broker.Id, context.brokerId, 'and the resolved broker');
        Assert.isTrue(context.canLog, 'and the admin test user may create');
    }

    @isTest
    static void controller_withNullId_returnsAnEmptyContextRatherThanThrowing() {
        Test.startTest();
        ReleaseMaterialsResponseService.LogContext context =
            ReleaseMaterialsResponseController.getLogContext(null);
        Test.stopTest();

        Assert.isNotNull(context, 'A pre-wire render must not raise an error toast');
        Assert.areEqual(0, context.responses.size(), 'and claims nothing about the sale');
    }

    /**
     * 🔴 A WRONG SOBJECT TYPE IS REFUSED, LOUDLY. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it matches no rows — so without this guard a
     * card wired to the wrong `record-id` would render a confident, permanent empty log.
     */
    @isTest
    static void controller_withWrongSObjectType_throwsAuraHandledException() {
        Contact notADisposition = TestDataFactory.createContact(null, true);
        Boolean threw = false;

        Test.startTest();
        try {
            ReleaseMaterialsResponseController.getLogContext(notADisposition.Id);
            Assert.fail('A Contact Id must not be accepted as a Disposition Id');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Disposition'),
                'and the message names the expected object rather than being the generic '
                    + 'read-failure text — a wiring mistake and a permission gap need different '
                    + 'fixes. Actual: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The guard must fire');
    }

    @isTest
    static void controller_saveResponse_writesThroughToTheService() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);

        Test.startTest();
        ReleaseMaterialsResponseController.saveResponse(
            disposition.Id, METHOD_QUESTIONS, 'Through the boundary.'
        );
        Test.stopTest();

        Assert.areEqual(1, stored(disposition.Id).size(), 'The row lands');
    }

    /**
     * CLAUSE 1 of the controller's catch: a user-fixable input violation is surfaced VERBATIM.
     * ⚠ THE ASSERTION IS AN EXACT MATCH ON THE SERVICE'S OWN CONSTANT. `contains('Pick')` would
     * pass against the generic message if someone ever put that word in it.
     */
    @isTest
    static void controller_saveResponse_surfacesTheAuthoredMessageVerbatim() {
        Disposition__c disposition = onMarket();
        Boolean threw = false;

        Test.startTest();
        try {
            ReleaseMaterialsResponseController.saveResponse(disposition.Id, 'Smoke signal', 'x');
            Assert.fail('An unknown method must be refused');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.areEqual(ReleaseMaterialsResponseService.BAD_METHOD_MESSAGE, e.getMessage(),
                'The typed clause passes the authored sentence through unchanged — replacing it '
                    + 'with the generic text would tell a user with a fixable mistake to call an '
                    + 'administrator');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The boundary must throw');
    }

    /**
     * CLAUSE 2: an unexpected platform failure gets the FIXED generic message with no platform
     * detail concatenated into it. The read-only persona produces a real `DmlException` — this is
     * the same fixture as `readOnlyPersona_isRefused`, used here to prove the OTHER catch clause is
     * reachable.
     * 🔴 BOTH CLAUSES BEING REACHABLE IS NOT COSMETIC: an unreachable typed catch on a thin
     * controller has measurably dropped a class in this repo to 38% coverage and rolled a deploy
     * back with every error counter reading zero.
     */
    @isTest
    static void controller_saveResponse_mapsAPlatformFailureToTheGenericMessage() {
        Contact broker = accountedBroker();
        Disposition__c disposition = offMarket(broker.Id);
        User readOnly = readOnlyPersona();
        String message;

        Test.startTest();
        System.runAs(readOnly) {
            try {
                ReleaseMaterialsResponseController.saveResponse(
                    disposition.Id, METHOD_DECISION, 'Refused.'
                );
                Assert.fail('A read-only persona must be refused');
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isNotNull(message, 'The boundary must throw');
        Assert.areEqual(ReleaseMaterialsResponseService.BAD_METHOD_MESSAGE == message, false,
            'and it is NOT the input-validation message — the two clauses must not collapse');
        Assert.isFalse(message.contains('Release_Materials_Response__c'),
            '🔴 NO FIELD OR OBJECT API NAME MAY REACH THE USER. Raw DmlException text leaks schema '
                + 'and validation-rule internals. Actual: ' + message);
        Assert.isTrue(message.contains('administrator'),
            'and the generic message points at the only remedy that exists for a permission gap. '
                + 'Actual: ' + message);
    }
}
