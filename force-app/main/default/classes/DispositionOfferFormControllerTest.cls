/**
 * Tests for `DispositionOfferFormController` — the Log Offer dialog's `@AuraEnabled` boundary
 * (2026-08-21).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE ONE THING THIS CLASS EXISTS TO PROVE, AND THE REASON IT NEEDS ITS OWN FILE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * THE AUTHORED MESSAGE SURVIVES THE `AuraHandledException`. An `AuraHandledException` built from
 * its constructor alone arrives at the LWC as `error.body.message === 'Script-thrown exception'`,
 * and every carefully-worded string in the controller is silently lost — the dialog then tells a
 * user with a provisioning gap to "refresh the page", advice that can never work. `setMessage`
 * is what carries it, and only a test that reads `getMessage()` back proves it is still there.
 * `DispositionApprovalController` records the same trap.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE DENIAL PATH IS EXERCISED FOR REAL, WITH A `System.runAs` PERSONA, BECAUSE NOTHING ELSE
 *    REACHES IT.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The controller's catch is the ONLY place `ACCESS_MESSAGE` is produced, and it is unreachable by
 * any ordinary input: a null Id short-circuits, a DELETED Id degrades to an empty context (proved
 * in `DispositionOfferFormServiceTest`), and a MALFORMED String never reaches the method at all —
 * measured 2026-08-21, `getOfferFormContext('not-an-id')` throws `System.StringException: Invalid
 * id` during PARAMETER COERCION at the call site, outside the method body, so a test written that
 * way covers nothing while looking like it covers the catch. The first version of this file did
 * exactly that and validated the class at 38.5%, which returned a `codeCoverageWarnings` entry.
 *
 * 🔴 THE BASE PROFILE IS `Minimum Access - Salesforce` AND THAT IS LOAD-BEARING. The persona holds
 * NO permission set at all, so it has no `NDA__c` object read, and `NdaSelector`'s `WITH USER_MODE`
 * query throws. `Standard User` would be the wrong base for a STANDARD-object denial (it grants
 * `Contact` read and masks it) — the trap `DispositionBuyerTimelineTest`'s header records — and
 * although `NDA__c` is custom, using the same base keeps the two fixtures answering the same way.
 *
 * ⚠ `User` DML is SETUP-object DML while this test also inserts `Disposition__c` / `NDA__c`
 * (non-setup) in the same transaction, so the persona insert runs inside
 * `System.runAs(new User(Id = UserInfo.getUserId()))` — the MIXED_DML_OPERATION workaround used by
 * `DispositionBuyerTimelineTest` and `DispositionDealSummaryServiceTest`.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not apply — see
 * `DispositionOfferFormServiceTest`'s header for the structural argument. This controller takes a
 * single `Id`, holds no loop, and performs no DML.
 */
@isTest
private class DispositionOfferFormControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Disposition__c onMarketDisposition() {
        return TestDataFactory.createDisposition(
            [SELECT Id FROM Property_Asset__c LIMIT 1].Id,
            TestDataFactory.DISPOSITION_RT_ON_MARKET,
            true
        );
    }

    @isTest
    static void getOfferFormContext_returnsTheServiceResultUnchanged() {
        Disposition__c disposition = onMarketDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = TestDataFactory.createDispositionNda(disposition.Id, false);
        nda.Status__c = 'Signed';
        nda.Buyer__c = buyer.Id;
        insert nda;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormController.getOfferFormContext(disposition.Id);
        Test.stopTest();

        // The controller is THIN: it marshals and delegates. Asserting the payload survives it
        // intact is what proves no filtering or reshaping crept into the boundary layer.
        Assert.isNotNull(context, 'The context is returned, not swallowed');
        Assert.areEqual(1, context.buyers.size(), 'The service\'s buyer list passes through');
        Assert.areEqual((String) buyer.Id, context.buyers[0].value, 'Unchanged, Contact-keyed');
        Assert.areEqual(true, context.isOnMarket, 'And the record-type flag');
    }

    @isTest
    static void getOfferFormContext_nullId_returnsAnEmptyContextRatherThanThrowing() {
        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormController.getOfferFormContext(null);
        Test.stopTest();

        // 🔴 The modal's `@wire` fires before `dispositionId` is set on a slow first render. An
        // AuraHandledException there would flash an error banner on a dialog about to work.
        Assert.isNotNull(context, 'A null Id is a normal call, not an error');
        Assert.areEqual(0, context.buyers.size(), 'With nothing in it');
    }

    @isTest
    static void getOfferFormContext_deletedDisposition_degradesRatherThanThrowing() {
        Disposition__c ghost = onMarketDisposition();
        Id deletedId = ghost.Id;
        delete ghost;

        Test.startTest();
        DispositionOfferFormService.OfferFormContext context =
            DispositionOfferFormController.getOfferFormContext(deletedId);
        Test.stopTest();

        Assert.isNotNull(context, 'An unreadable parent is a degrade, not an exception');
        Assert.isNull(context.brokerId, 'Nothing to resolve');
    }

    /**
     * A persona on `Minimum Access - Salesforce` holding NO permission set — so no `NDA__c` read.
     * See the class header for why the base profile and the runAs wrapper both matter.
     */
    private static User deniedPersona() {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        String unique = 'doffc' + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User persona = new User(
            FirstName = 'Offer',
            LastName = 'FormDenied',
            Alias = 'doffc',
            Email = 'doffc@example.invalid',
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

    @isTest
    static void aDeniedPersona_getsTheAuthoredAccessMessage_notAStackTrace() {
        Disposition__c disposition = onMarketDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = TestDataFactory.createDispositionNda(disposition.Id, false);
        nda.Status__c = 'Signed';
        nda.Buyer__c = buyer.Id;
        insert nda;
        User denied = deniedPersona();

        Test.startTest();
        Boolean refused = false;
        System.runAs(denied) {
            try {
                DispositionOfferFormController.getOfferFormContext(disposition.Id);
                Assert.fail(
                    'FIXTURE PRECONDITION FAILED: a Minimum Access persona with no permission set '
                        + 'must not be able to read NDA__c. If this stops throwing, either the '
                        + 'profile now grants NDA__c or the selector stopped using USER_MODE — '
                        + 'investigate, do not delete this test.'
                );
            } catch (AuraHandledException e) {
                refused = true;
                // 🔴 THE AUTHORED MESSAGE MUST HAVE SURVIVED `AuraHandledException`. Built from the
                // constructor alone it arrives as 'Script-thrown exception' and every carefully
                // worded string in the controller is silently lost — the dialog would then tell a
                // user with a provisioning gap to "refresh the page", advice that can never work.
                // Only `setMessage` carries it, and only reading it back proves that.
                Assert.areEqual(
                    DispositionOfferFormController.ACCESS_MESSAGE,
                    e.getMessage(),
                    'A USER_MODE denial must surface the AUTHORED access message'
                );
                // ⚠ AND IT MUST NOT CARRY PLATFORM DETAIL. `QueryException.getMessage()` names the
                // FIELD, which is information about the org's security model, and the raw text
                // ("No such column") sends the reader hunting for a field that exists.
                Assert.isFalse(
                    e.getMessage().contains('No such column'),
                    'Raw platform text must never reach the user'
                );
                Assert.isFalse(
                    e.getMessage().contains('NDA__c'),
                    'No object or field name may be leaked into the user-facing message'
                );
            }
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The denial must surface as an AuraHandledException');
    }

    @isTest
    static void aMalformedIdNeverReachesTheMethod_soItCannotTestTheCatch() {
        // ⚠ THIS TEST DOCUMENTS A PLATFORM BEHAVIOUR THAT MADE AN EARLIER TEST VACUOUS, AND THAT
        // IS ITS ONLY PURPOSE. Coercing a malformed String into an `Id` PARAMETER throws at the
        // CALL SITE, before the method body runs — so a "malformed Id exercises the generic catch"
        // test covers nothing at all while reading as though it does. Measured 2026-08-21: the
        // first version of this file did exactly that and validated the controller at 38.5%.
        Test.startTest();
        Boolean threwBeforeEntering = false;
        try {
            DispositionOfferFormController.getOfferFormContext('not-an-id');
            Assert.fail('A malformed Id cannot be coerced and must throw');
        } catch (AuraHandledException e) {
            Assert.fail(
                'If this branch is ever taken, the coercion behaviour has changed and a malformed '
                    + 'Id DOES reach the catch — revisit the class header before relying on it: '
                    + e.getMessage()
            );
        } catch (Exception e) {
            threwBeforeEntering = true;
            // NOT an AuraHandledException — the controller never ran.
            Assert.isTrue(
                e.getMessage().contains('Invalid id'),
                'The platform refuses the coercion itself: ' + e.getMessage()
            );
        }
        Test.stopTest();

        Assert.isTrue(threwBeforeEntering, 'The call site throws, not the controller');
    }

    @isTest
    static void theAuthoredAccessMessageNamesBothTheCauseAndTheFix() {
        // ⚠ A CONSTANT ASSERTION, AND IT IS DELIBERATE RATHER THAN LAZY. The QueryException
        // branch is not reachable without a denial persona (see this class's header), so this
        // pins the thing that would otherwise be silently reworded into uselessness: the text
        // the analyst reads when their permission sets are wrong.
        String message = DispositionOfferFormController.ACCESS_MESSAGE;

        Assert.isTrue(message.contains('access'),
            'It must name the CAUSE — the platform\'s own "No such column" does not');
        Assert.isTrue(message.contains('administrator'),
            'And the FIX, because the user cannot resolve an FLS gap themselves');
        // 🔴 It must NOT tell them to refresh the page. ARCHITECTURE.md §2: the fix for a
        // USER_MODE denial is a permission set, every time — never a retry, and never
        // SYSTEM_MODE.
        Assert.isFalse(message.contains('Refresh'),
            'Refreshing can never fix a missing grant; the generic message says that, this one '
                + 'must not');
        Assert.areNotEqual(DispositionOfferFormController.GENERIC_MESSAGE, message,
            'The two messages must stay distinct — one names a person, the other names an action');
    }
}
