/**
 * Tests for `DispositionOfferFormService` — the Log Offer dialog's read (2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 SIX BUYER TESTS WERE DELETED FROM THIS CLASS ON 2026-08-21, WITH THE PICKER THEY COVERED
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * DPEG communicates only with the appointed listing broker; buyers sit behind them and are not
 * tracked. `buyers_areReturnedAsContactIdKeyedOptionsWithNames`,
 * `buyers_areDeDuplicatedWhenOnePartyHasTwoNdas`,
 * `buyers_excludeTheIntroducingBrokerAndUnsignedParties`,
 * `buyers_emptyIsAFirstClassAnswer_notAnError` and `buyers_areScopedToThisDisposition` were
 * DELETED, not softened — the DTO members they asserted on no longer compile, so keeping them as
 * `isNull` checks was not even an option. The de-duplication they guarded went with them.
 * ⚠ If a buyer-shaped read ever returns, recover them from git history: the de-duplication test in
 * particular encoded a non-obvious fact (SOQL has no `SELECT DISTINCT`, and a duplicate `value` in
 * a `lightning-combobox` renders a dead, unselectable menu item).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THIS CLASS IS ACTUALLY DEFENDING NOW
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 1. THE BROKER SOURCE IS PER RECORD TYPE, AND THE TWO SOURCES ARE DIFFERENT OBJECTS. On-market
 *    it is the SELECTED `BOV_Submission__c`'s `Broker__c`; off-market it is
 *    `Disposition__c.Broker__c`. Getting this backwards does not throw — it silently attributes
 *    every off-market offer to a BOV broker who was never appointed, or leaves every on-market
 *    offer brokerless. Both directions are asserted, and the CROSS-CONTAMINATION is asserted as
 *    absence (an off-market sale that ALSO has a Selected BOV row must still read the parent).
 *    ⚠ THE STAKES ROSE ON 2026-08-21: a brokerless context now REFUSES the save rather than
 *    rendering an empty read-only field, so a record-type branch that falls through takes the
 *    dialog out entirely instead of degrading it.
 * 2. `Selected_Broker__c` IS NEVER PARSED. It is a display string that reads "Firm" on one path
 *    and "Person - Firm" on the other, and its own field metadata says NO CONSUMER MAY PARSE IT.
 *    A test below gives it a value that would produce a WRONG answer if anyone ever did.
 * 3. 🔴 A DENIED READ **THROWS** AND DOES NOT DEGRADE TO "no broker appointed". This is the
 *    2026-08-21 reversal and it is the highest-value test in the file — see
 *    `deniedPersona_throwsRatherThanReportingNoBrokerAppointed`.
 * 4. THE QUERY BUDGET IS A CEILING, NOT A DESCRIPTION. 2 SOQL on-market, 1 off-market, 0 for a
 *    null parent. A third query added later is invisible on a single-record screen.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT APPLY HERE, AND THE REASON
 *   IS RECORDED SO REVIEW DOES NOT DEMAND IT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `getFormContext` takes a SINGLE `Id`. It is invoked exactly once per modal open by a `@wire`;
 * there is no trigger, no batch, no queueable and no collection parameter. That is the rule's own
 * "structurally single-record-per-transaction" exemption, and it is STRUCTURAL rather than
 * convenient: there is no loop over records that a 251st row would force a second pass through,
 * so a 251-record test would exercise no additional code path while risking unrelated governor
 * limits — the exact anti-pattern the exemption exists to prevent.
 * 🔴 IT IS NOT A RELAXATION OF "no SOQL/DML in loops", WHICH IS HONOURED IN FULL AND IS TESTED:
 * `budget_*` below pin the exact query count. ⚠ IF A CALLER EVER PASSES A COLLECTION, THIS
 * EXEMPTION LAPSES.
 *
 * ⚠ `@TestSetup` builds Property -> Property_Asset only. Every test creates its OWN Disposition,
 * because the record type is the variable under test in half of them and a shared on-market
 * scaffold row would quietly make the off-market cases untestable.
 */
@isTest
private class DispositionOfferFormServiceTest {

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
            assetId(),
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
    }

    private static Disposition__c offMarket(Id brokerContactId) {
        Disposition__c disposition = TestDataFactory.createDisposition(
            assetId(),
            TestDataFactory.DISPOSITION_RT_OFF_MARKET,
            false
        );
        disposition.Broker__c = brokerContactId;
        insert disposition;
        return disposition;
    }

    /** Promotes one of a disposition's BOV submissions to Selected and returns its broker Id. */
    private static Id appointBovBroker(Id dispositionId) {
        BOV_Submission__c submission =
            TestDataFactory.createBovSubmission(dispositionId, true);
        submission.Submission_Status__c = 'Selected';
        update submission;
        return submission.Broker__c;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BROKER — two record types, two sources, and no cross-contamination
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void onMarket_resolvesTheBrokerFromTheSelectedBovSubmission() {
        Disposition__c disposition = onMarket();
        Id expectedBroker = appointBovBroker(disposition.Id);
        Contact broker = [SELECT Id, Name FROM Contact WHERE Id = :expectedBroker LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(true, context.isOnMarket, 'The On_Market record type');
        Assert.areEqual(expectedBroker, context.brokerId,
            'On-market, the broker is the SELECTED BOV submission\'s Broker__c');
        Assert.areEqual(broker.Name, context.brokerName,
            'The name is displayed read-only on the form');
        Assert.areEqual(DispositionOfferFormService.SOURCE_ON_MARKET, context.brokerSource,
            'The source line tells the analyst WHY that name is there');
    }

    @isTest
    static void offMarket_resolvesTheBrokerFromTheDispositionLookup() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        Contact expected = [SELECT Id, Name FROM Contact WHERE Id = :broker.Id LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.areEqual(false, context.isOnMarket, 'The Off_Market record type');
        Assert.areEqual(broker.Id, context.brokerId,
            'Off-market, the broker is Disposition__c.Broker__c — read straight off the parent');
        Assert.areEqual(expected.Name, context.brokerName, 'With its display name');
        Assert.areEqual(DispositionOfferFormService.SOURCE_OFF_MARKET, context.brokerSource,
            'The off-market source wording, which points at a different screen');
    }

    @isTest
    static void offMarket_ignoresASelectedBovSubmissionEvenWhenOneExists() {
        Contact parentBroker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(parentBroker.Id);
        Id bovBroker = appointBovBroker(disposition.Id);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 CROSS-CONTAMINATION, ASSERTED AS ABSENCE. A record-type branch that fell through —
        // or read both sources and preferred the wrong one — would attribute this off-market
        // offer to a BOV broker who was never appointed to it. It fails silently: both values
        // are real Contact Ids and both render perfectly well in the dialog.
        Assert.areEqual(parentBroker.Id, context.brokerId,
            'Off-market must read the PARENT lookup, never the BOV row');
        Assert.areNotEqual(bovBroker, context.brokerId,
            'The Selected BOV submission is not the off-market source');
    }

    /**
     * 🔴 NO SELECTED SUBMISSION -> NULL BROKER, AND THE MODAL NOW REFUSES THE SAVE ON IT.
     *
     * ⚠ THE MEANING OF THIS TEST CHANGED ON 2026-08-21 EVEN THOUGH ITS ASSERTIONS DID NOT. It used
     * to end `Assert.areEqual(1, context.buyers.size(), 'The buyer picker still loads')` — i.e. "a
     * null broker degrades one field of a working dialog". With the buyer gone, `brokerId == null`
     * is the dialog's ONLY refusal condition: `c/dispositionLogOfferModal` renders an explained
     * panel with no form and no Save button. This is still NOT a throw, and that distinction is the
     * whole point — "no broker appointed" is a readable state the dialog must be able to explain,
     * whereas "the broker is unreadable" is a provisioning gap it must NOT report as the same thing
     * (see `deniedPersona_throwsRatherThanReportingNoBrokerAppointed`).
     */
    @isTest
    static void onMarket_noSelectedSubmission_leavesTheBrokerNullWithoutThrowing() {
        Disposition__c disposition = onMarket();
        // Every factory submission defaults to Backup — the state before the appointment is
        // approved, which is exactly when an early offer might be logged.
        TestDataFactory.createBovSubmissions(2, disposition.Id, true);

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        Assert.isNull(context.brokerId, 'No Selected submission means no broker yet');
        Assert.areEqual('', context.brokerName,
            'NEVER null across the @AuraEnabled boundary — an undefined renders as "undefined"');
        Assert.areEqual(DispositionOfferFormService.SOURCE_ON_MARKET, context.brokerSource,
            'and the source line still answers, so the modal can word its refusal per record type');
    }

    /**
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE "SELECTED ROW WITH A NULL BROKER" STATE CANNOT BE BUILT, AND THIS TEST ASSERTS THE
     *    PREMISE INSTEAD OF PRETENDING IT CAN.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * The service's `if (submission.Broker__c != null)` skip is a defensive branch, and the first
     * version of this file tried to exercise it by nulling `Broker__c` on a Selected submission.
     * MEASURED 2026-08-21 — that DML is refused outright:
     *
     *   FIELD_CUSTOM_VALIDATION_EXCEPTION, "Choose the Broker Contact who submitted this BOV.
     *   A submission with no broker cannot be compared or appointed." : [Broker__c]
     *
     * `Broker_Required_On_Submission` is ACTIVE and has no ISNEW/ISCHANGED guard, so it refuses
     * every save — the state is unreachable through any supported write path.
     *
     * ⚠ THAT DOES **NOT** MAKE THE SERVICE'S BRANCH DEAD CODE, and it must not be deleted on that
     * argument. Two live routes still produce it: a submission created BEFORE that rule was
     * activated (the rule cannot retroactively repair rows), and a Contact deleted after the fact
     * — `Broker__c` uses `SetNull`, so the platform nulls the lookup with no validation rule in
     * the way. Both leave a Selected row with no broker, and the skip is what stops the dialog
     * accepting it and masking a real row further down the list.
     *
     * ⚠ THE PREMISE IS ASSERTED RATHER THAN ASSUMED because if that rule is ever relaxed, the
     * unbuildable fixture becomes buildable and a proper positive test SHOULD be written here.
     * This test going red is the signal to write it.
     */
    @isTest
    static void aSelectedSubmissionCannotBeStrippedOfItsBroker_soTheSkipStaysDefensive() {
        Disposition__c disposition = onMarket();
        BOV_Submission__c submission =
            TestDataFactory.createBovSubmission(disposition.Id, true);
        submission.Submission_Status__c = 'Selected';
        submission.Broker__c = null;

        Test.startTest();
        Boolean refused = false;
        try {
            update submission;
        } catch (DmlException e) {
            refused = true;
            Assert.isTrue(
                e.getMessage().contains('Broker'),
                'The refusal must be the broker rule, not some unrelated failure: '
                    + e.getMessage()
            );
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'Broker_Required_On_Submission must still refuse a Selected row with no broker. If '
                + 'this now SAVES, the rule was relaxed — write the real positive test for the '
                + 'service\'s null-broker skip instead of deleting this one.');
    }

    @isTest
    static void selectedBrokerTextIsNeverParsed_evenWhenItWouldGiveTheWrongAnswer() {
        Contact parentBroker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(parentBroker.Id);
        // `Selected_Broker__c` is stamped by DispositionBrokerStampService from Broker__c, so it
        // already agrees. Overwrite it with a DIFFERENT name: if anything ever parsed it, the
        // assertion below would return this string instead of the real Contact's.
        disposition.Selected_Broker__c = 'Someone Else - Wrong Firm';
        update disposition;
        Contact expected = [SELECT Id, Name FROM Contact WHERE Id = :parentBroker.Id LIMIT 1];

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Test.stopTest();

        // 🔴 THE STANDING RULE: "NO CONSUMER MAY PARSE `Selected_Broker__c`." It reads "Firm" on
        // on-market rows and "Person - Firm" on off-market ones, so a parser works on whichever
        // path its author tested and fails silently on the other. It is the obvious shortcut here
        // (one field, both paths, one fewer query) and this test is what makes taking it fail.
        Assert.areEqual(expected.Name, context.brokerName,
            'The name comes from the Contact traversal, never from the display string');
        Assert.areNotEqual('Someone Else - Wrong Firm', context.brokerName,
            'Selected_Broker__c must not reach this DTO by any route');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE 2026-08-21 REVERSAL: A DENIED READ THROWS, IT DOES NOT DEGRADE
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * A persona on `Minimum Access - Salesforce` holding NO permission set — so no
     * `Disposition__c` object read at all.
     *
     * 🔴 THE BASE PROFILE IS LOAD-BEARING. `Standard User` grants read on standard objects and
     * would mask a denial; `Minimum Access - Salesforce` grants nothing, which is what makes the
     * `WITH USER_MODE` selector throw. Same fixture, same reasoning, as
     * `DispositionOfferFormControllerTest.deniedPersona`.
     *
     * ⚠ `User` DML is SETUP-object DML and the caller also inserts `Disposition__c` (non-setup) in
     * the same transaction, so this runs inside `System.runAs(new User(Id = UserInfo.getUserId()))`
     * — the MIXED_DML_OPERATION workaround used across this repo.
     */
    private static User deniedPersona() {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        String unique = 'doffs' + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User persona = new User(
            FirstName = 'Offer',
            LastName = 'FormServiceDenied',
            Alias = 'doffs',
            Email = 'doffs@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert persona;
        }
        return persona;
    }

    /**
     * 🔴 THE HIGHEST-VALUE TEST IN THIS FILE. IT PINS A DELIBERATE REVERSAL, AND THE BEHAVIOUR IT
     *    FORBIDS IS THE ONE THIS SERVICE USED TO HAVE.
     *
     * Until 2026-08-21 both broker reads sat inside `catch (System.QueryException)` blocks that
     * degraded to "no broker resolved", because the buyer picker was the dialog and an FLS gap on
     * the broker must not take it down. The buyer picker is gone. Keeping those catches would now
     * mean a persona who cannot READ the broker is told **"No broker is appointed on this sale
     * yet — go appoint one on the BOV comparison matrix"**, about a sale that already has one.
     * That is a confident wrong answer with a remedy that cannot work, and it is strictly worse
     * than an error naming a provisioning gap.
     *
     * ⚠ THE ASSERTION IS DELIBERATELY "IT THREW", NOT A MESSAGE MATCH. The user-facing wording is
     * the CONTROLLER's job and is asserted in `DispositionOfferFormControllerTest`; what this test
     * owns is that the exception ESCAPES this layer at all.
     * 🔴 SECOND-ORDER CONSEQUENCE THIS ALSO PROTECTS: if the catches come back, `getFormContext`
     * becomes incapable of throwing, the controller's single `catch` goes permanently unreachable,
     * and that class drops under the 75% per-class coverage threshold — which this repo has
     * measured rolling a whole deploy back with every error counter reading zero.
     */
    @isTest
    static void deniedPersona_throwsRatherThanReportingNoBrokerAppointed() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);
        User denied = deniedPersona();

        Exception failure;
        DispositionOfferFormService.OfferFormContext degraded;

        Test.startTest();
        System.runAs(denied) {
            try {
                degraded = DispositionOfferFormService.getFormContext(disposition.Id);
            } catch (Exception e) {
                failure = e;
            }
        }
        Test.stopTest();

        Assert.isNull(degraded,
            '🔴 A DENIED READ MUST NOT RETURN A CONTEXT AT ALL. If this is non-null, a '
                + 'degrade-catch has been re-added and the dialog is now telling users with a '
                + 'permission gap that their sale has no appointed broker. Returned brokerId: '
                + (degraded == null ? 'n/a' : String.valueOf(degraded.brokerId)));
        Assert.isNotNull(failure,
            'FIXTURE PRECONDITION: a Minimum Access persona with no permission set must not be '
                + 'able to read Disposition__c. If this stops throwing, the profile changed or the '
                + 'selector stopped using USER_MODE — investigate, do not delete this test.');
        Assert.isTrue(failure instanceof QueryException,
            'and the documented type is System.QueryException, which is what the controller\'s '
                + '`instanceof` test branches on to choose the ACCESS message over the generic '
                + 'one. Actual: ' + failure.getTypeName() + ': ' + failure.getMessage());
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // NOT-FOUND / NULL CONTRACTS
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void nullDispositionId_returnsAFullyPopulatedEmptyContext_withoutThrowing() {
        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(null);
        Test.stopTest();

        // 🔴 NEVER A THROW. The modal's `@wire` fires before `dispositionId` is set on a slow
        // first render, and an exception there would flash an error banner on a dialog that is
        // about to work perfectly.
        Assert.isNotNull(context, 'A null Id still returns a context');
        Assert.isNull(context.brokerId, 'No broker');
        Assert.areEqual('', context.brokerName, 'A STRING, never null — see the DTO');
        Assert.areEqual('', context.brokerSource, 'A STRING, never null');
        Assert.areEqual(true, context.isOnMarket, 'Defaults to the On_Market branch');
    }

    /**
     * A DELETED parent degrades to an empty context rather than throwing.
     *
     * ⚠ THIS IS NOT IN TENSION WITH `deniedPersona_throwsRatherThanReportingNoBrokerAppointed`,
     * AND THE DIFFERENCE IS THE WHOLE DESIGN. `selectBrokerContextById` returns NULL for a row
     * that does not exist (or is not visible under SHARING) and THROWS when the running user
     * cannot read the object or a field (FLS/CRUD). "It isn't there" is a data state the dialog
     * can honestly report; "you may not look" is a provisioning gap it must not disguise as one.
     */
    @isTest
    static void deletedDisposition_degradesInsteadOfThrowing() {
        Disposition__c ghost = onMarket();
        Id deletedId = ghost.Id;
        delete ghost;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(deletedId);
        Test.stopTest();

        // The record-type fallback is DispositionDomain.recordTypeNameOf's own (`On_Market` for a
        // null/Master row), reused rather than re-derived — so an absent parent answers the
        // same way a Master-record-type row does, in this class and in
        // DispositionApprovalService alike.
        Assert.isNotNull(context, 'A missing parent is a degrade, not an exception');
        Assert.isNull(context.brokerId, 'Nothing to resolve');
        Assert.areEqual(true, context.isOnMarket, 'The shared On_Market fallback');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BUDGET — a CEILING, asserted, not described
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THE CEILING DROPPED FROM 3 TO 2 ON 2026-08-21 when the buyer NDA read was deleted.
     * Asserting the EXACT number is what makes that deletion stick: a `<= 3` ceiling would let the
     * query quietly return.
     */
    @isTest
    static void budget_onMarketCostsExactlyTwoQueries() {
        Disposition__c disposition = onMarket();
        appointBovBroker(disposition.Id);

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormService.getFormContext(disposition.Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isNotNull(context.brokerId, 'The broker resolved');
        // 🔴 THE CEILING, NOT A DESCRIPTION. Parent + Selected BOV. A third query added later is
        // invisible on a single-record screen and would only surface as latency.
        Assert.areEqual(2, used, 'On-market costs exactly 2 SOQL');
    }

    @isTest
    static void budget_offMarketCostsOneQuery_theBovReadIsSkippedEntirely() {
        Contact broker = TestDataFactory.createBrokerContact(null, true);
        Disposition__c disposition = offMarket(broker.Id);

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.getFormContext(disposition.Id);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        // 🔴 THE BOV READ IS INSIDE THE RECORD-TYPE BRANCH, NOT BEFORE IT. Hoisting it out —
        // which is the shape a "read both, prefer one" refactor takes — would cost every
        // off-market dialog an extra query for a value it must not use, and would ALSO defeat
        // the cross-contamination test above by making the wrong value available.
        Assert.areEqual(1, used, 'Off-market skips the BOV read entirely');
    }

    @isTest
    static void budget_nullIdCostsZeroQueries() {
        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionOfferFormService.getFormContext(null);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, used,
            'The wire can fire before dispositionId is set; that must be free');
    }
}
