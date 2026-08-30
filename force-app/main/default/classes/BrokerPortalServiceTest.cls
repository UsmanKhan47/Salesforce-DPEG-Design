/**
 * Tests for BrokerPortalService — the guest Broker-Portal deal-intake business logic.
 *
 * Covers the happy path, honeypot, every validation branch, the routing-not-configured
 * branch (forced via the @TestVisible queue cache), duplicate flagging, broker-priority
 * copy, and Lead-insert failure propagation (DmlException). Runs the service directly to
 * assert its UI-agnostic contract: user-actionable failures throw the typed
 * SubmissionException; the Lead insert failure propagates as DmlException. The service
 * never throws AuraHandledException — that boundary is the controller's job.
 */
@IsTest
private class BrokerPortalServiceTest {

    private static BrokerPortalController.DealSubmission validInput() {
        BrokerPortalController.DealSubmission d = new BrokerPortalController.DealSubmission();
        d.firstName = 'Jane';
        d.lastName = 'Broker';
        d.brokerageFirm = 'Acme Realty';
        d.email = 'jane@acme.com';
        d.phone = '555-1234';
        d.propertyAddress = '123 Main St, Dallas TX';
        d.assetType = 'Retail';
        d.dealType = 'Retail';
        d.turnstileToken = SOLVED_TOKEN;
        return d;
    }

    private static final String SOLVED_TOKEN = 'a-plausible-looking-turnstile-token';

    /**
     * Canned Cloudflare siteverify response.
     *
     * 🔴 A mock CANNOT prove the credential works. It intercepts the request before the platform
     * would substitute `{!$Credential.Turnstile_Credential.Secret_Key}` into the body, so it
     * answers identically whether or not the merge field resolves. That was proven separately by a
     * live two-probe read-back on 2026-08-30 — see TurnstileVerificationService's class header.
     * What these tests DO prove is this service's policy: what it does with each answer.
     */
    private class TurnstileMock implements HttpCalloutMock {
        private final Integer status;
        private final String body;

        private TurnstileMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(this.status);
            response.setStatus(this.status == 200 ? 'OK' : 'Bad Request');
            response.setBody(this.body);
            return response;
        }
    }

    /** Cloudflare cannot be reached at all — transport failure or timeout. */
    private class UnreachableMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    /** Cloudflare confirms the token. Install this in ANY test that reaches past validate(). */
    private static void mockTurnstileVerified() {
        Test.setMock(HttpCalloutMock.class, new TurnstileMock(200, '{"success":true,"error-codes":[]}'));
    }

    /** Cloudflare refuses the token — the ordinary "unsolved or replayed" case. */
    private static void mockTurnstileRefused() {
        Test.setMock(
            HttpCalloutMock.class,
            new TurnstileMock(200, '{"success":false,"error-codes":["invalid-input-response"]}')
        );
    }

    /** Asserts the submission is rejected with a SubmissionException and inserts no Lead. */
    private static void assertRejected(BrokerPortalController.DealSubmission d, String scenario) {
        Boolean threw = false;
        try {
            BrokerPortalService.submitDeal(d);
        } catch (BrokerPortalService.SubmissionException e) {
            threw = true;
        }
        System.Assert.isTrue(threw, 'Expected SubmissionException for: ' + scenario);
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'No lead should be inserted for: ' + scenario);
    }

    // ---- Happy path ----

    @IsTest
    static void submitDeal_happyPath_insertsStampedLead() {
        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalService.submitDeal(validInput());
        Test.stopTest();

        System.Assert.isTrue(res.success, 'Should succeed');
        System.Assert.isNotNull(res.message, 'Confirmation message returned');

        List<Lead> leads = [
            SELECT FirstName, LastName, Company, Broker_First__c, Email, Phone,
                   Property_Address__c, Asset_Type__c, Deal_Type__c,
                   LeadSource, Status, First_Seen_Date__c, OwnerId,
                   Duplicate_Flag__c, Broker_Priority__c
            FROM Lead
        ];
        System.Assert.areEqual(1, leads.size(), 'Exactly one lead inserted');
        Lead l = leads[0];
        System.Assert.areEqual('Jane', l.FirstName, 'First name mapped');
        System.Assert.areEqual('Broker', l.LastName, 'Last name mapped');
        System.Assert.areEqual('Acme Realty', l.Company, 'Company = firm');
        System.Assert.areEqual('Acme Realty', l.Broker_First__c, 'Broker_First mirrors firm');
        System.Assert.areEqual('Retail', l.Asset_Type__c, 'Asset type mapped');
        System.Assert.areEqual('Broker Portal', l.LeadSource, 'LeadSource stamped server-side');
        System.Assert.areEqual('New', l.Status, 'Status stamped server-side');
        System.Assert.areNotEqual(null, l.First_Seen_Date__c, 'First Seen Date stamped server-side');
        System.Assert.isFalse(l.Duplicate_Flag__c, 'No duplicate expected');
        System.Assert.areEqual('Standard', l.Broker_Priority__c, 'Unknown broker defaults to Standard');

        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Broker_Portal_Leads' LIMIT 1];
        System.Assert.areEqual(q.Id, l.OwnerId, 'Lead owned by the Broker Portal queue, not the guest user');
    }

    // ---- Honeypot ----

    /**
     * 🔴 NOTE THE ABSENCE OF A MOCK. THAT IS THE POINT OF THIS TEST, NOT AN OMISSION.
     *
     * The honeypot must short-circuit BEFORE Turnstile, for two independent reasons, and this test
     * pins both. If verification ever moved ahead of the honeypot, this test would fail with
     * "Methods defined as TestMethod do not support Web service callouts" — the absence of a mock
     * is what makes the ordering assertion enforceable at all.
     *   1. A caught bot must still receive the SAME benign success it always did, so it learns
     *      nothing about which field betrayed it. A verification error would tell it plenty.
     *   2. A caught bot must burn NO CALLOUT. This is an unauthenticated public endpoint; if a
     *      scripted flood could make each request spend one of the org's 100 synchronous callouts,
     *      the honeypot would become the attack rather than the defence.
     */
    @IsTest
    static void submitDeal_honeypotFilled_skipsInsertAndSpendsNoCallout() {
        BrokerPortalController.DealSubmission d = validInput();
        d.website = 'http://spam.example';
        Test.startTest();
        BrokerPortalController.SubmitResult res = BrokerPortalService.submitDeal(d);
        Integer callouts = Limits.getCallouts();
        Test.stopTest();
        System.Assert.isTrue(res.success, 'Honeypot returns benign success so bots learn nothing');
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'Honeypot blocks the insert');
        System.Assert.areEqual(0, callouts,
            'The honeypot must short-circuit BEFORE Turnstile — a bot must not be able to make the '
            + 'public form spend a callout per request');
    }

    // ---- Turnstile (WS4) ----

    /**
     * The ordinary refusal: Cloudflare answered and said no (unsolved, expired, replayed, forged).
     * The broker gets an actionable message and NO Lead is created.
     */
    @IsTest
    static void submitDeal_turnstileRefused_rejectsAndInsertsNothing() {
        mockTurnstileRefused();
        Test.startTest();
        assertRejected(validInput(), 'Cloudflare refused the token');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_turnstileRefused_tellsTheBrokerToRetryTheWidget() {
        mockTurnstileRefused();
        String message;
        Test.startTest();
        try {
            BrokerPortalService.submitDeal(validInput());
        } catch (BrokerPortalService.SubmissionException e) {
            message = e.getMessage();
        }
        Test.stopTest();
        System.Assert.isNotNull(message, 'A refused token must raise a user-safe SubmissionException');
        System.Assert.isTrue(message.contains('complete the verification'),
            'A REFUSED token is recoverable by the human — the message must say how. Got: ' + message);
    }

    /**
     * 🔴 FAIL CLOSED. A Cloudflare outage takes the public form down, and that is the accepted
     * trade: a CAPTCHA that waves everything through whenever the verifier is unreachable hands an
     * attacker a one-step bypass. If this test is ever "fixed" to assert a successful submission,
     * the control has been removed, not repaired.
     */
    @IsTest
    static void submitDeal_turnstileUnreachable_failsClosed() {
        Test.setMock(HttpCalloutMock.class, new UnreachableMock());
        Test.startTest();
        assertRejected(validInput(), 'Cloudflare unreachable');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_turnstileUnreachable_doesNotBlameTheBroker() {
        Test.setMock(HttpCalloutMock.class, new UnreachableMock());
        String message;
        Test.startTest();
        try {
            BrokerPortalService.submitDeal(validInput());
        } catch (BrokerPortalService.SubmissionException e) {
            message = e.getMessage();
        }
        Test.stopTest();
        System.Assert.isTrue(message.contains('try again in a few minutes'),
            'When the VERIFIER is down, telling the broker to "complete the verification" would '
            + 'send them into a loop doing the one thing that cannot help. Got: ' + message);
    }

    /**
     * Our own credential is broken — the case that arrives as an ordinary HTTP response and that
     * no exception handler would ever see. It must still fail closed, and with the
     * "unavailable" message rather than the "solve it again" one, because the broker cannot fix it.
     */
    @IsTest
    static void submitDeal_turnstileCredentialBroken_failsClosedAsUnavailable() {
        Test.setMock(
            HttpCalloutMock.class,
            new TurnstileMock(400, '{"success":false,"error-codes":["invalid-input-secret"]}')
        );
        String message;
        Test.startTest();
        try {
            BrokerPortalService.submitDeal(validInput());
        } catch (BrokerPortalService.SubmissionException e) {
            message = e.getMessage();
        }
        Test.stopTest();
        System.Assert.isTrue(message.contains('try again in a few minutes'),
            'A broken secret is not the broker\'s fault and they cannot clear it. Got: ' + message);
        System.Assert.areEqual(0, [SELECT COUNT() FROM Lead],
            'A misconfigured credential must not let submissions through');
    }

    /**
     * A client that omits the token entirely (a scripted POST straight at the @AuraEnabled method,
     * bypassing the widget) is refused WITHOUT a callout. The LWC's disabled button is a courtesy;
     * this is the actual gate.
     */
    @IsTest
    static void submitDeal_missingToken_rejectedWithoutCallout() {
        BrokerPortalController.DealSubmission d = validInput();
        d.turnstileToken = null;
        mockTurnstileVerified(); // installed but must never be reached
        Test.startTest();
        assertRejected(d, 'no Turnstile token supplied');
        Integer callouts = Limits.getCallouts();
        Test.stopTest();
        System.Assert.areEqual(0, callouts,
            'A blank token is refused locally — no point relaying nothing to Cloudflare');
    }

    /**
     * Ordering proof from the other side: a submission that fails VALIDATION must never reach the
     * callout either. No mock is installed, so if validate() stopped running first this would fail
     * with the unsupported-callout error rather than a SubmissionException.
     */
    @IsTest
    static void submitDeal_invalidForm_neverReachesTurnstile() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = 'not-an-email';
        Test.startTest();
        assertRejected(d, 'invalid form must be refused before any callout');
        Integer callouts = Limits.getCallouts();
        Test.stopTest();
        System.Assert.areEqual(0, callouts, 'validate() runs before the callout');
    }

    // ---- Validation branches ----

    @IsTest
    static void submitDeal_nullInput_rejected() {
        Test.startTest();
        assertRejected(null, 'null submission');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirstName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.firstName = '  ';
        Test.startTest();
        assertRejected(d, 'blank first name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = '';
        Test.startTest();
        assertRejected(d, 'blank last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = null;
        Test.startTest();
        assertRejected(d, 'blank firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingAddress_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.propertyAddress = '';
        Test.startTest();
        assertRejected(d, 'blank property address');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_missingEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = '';
        Test.startTest();
        assertRejected(d, 'blank email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.email = 'not-an-email';
        Test.startTest();
        assertRejected(d, 'invalid email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_blankAssetType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.assetType = '';
        Test.startTest();
        assertRejected(d, 'blank asset type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidAssetType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.assetType = 'Spaceship';
        Test.startTest();
        assertRejected(d, 'invalid asset type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_invalidDealType_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.dealType = 'Banana';
        Test.startTest();
        assertRejected(d, 'invalid deal type');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthFirstName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.firstName = 'x'.repeat(41);
        Test.startTest();
        assertRejected(d, 'over-length first name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthLastName_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.lastName = 'x'.repeat(81);
        Test.startTest();
        assertRejected(d, 'over-length last name');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthFirm_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.brokerageFirm = 'x'.repeat(256);
        Test.startTest();
        assertRejected(d, 'over-length firm');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthEmail_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        // Valid-format email that exceeds the 80-char cap (long local part).
        d.email = 'a'.repeat(75) + '@ex.com';
        Test.startTest();
        assertRejected(d, 'over-length email');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthPhone_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.phone = '5'.repeat(41);
        Test.startTest();
        assertRejected(d, 'over-length phone');
        Test.stopTest();
    }

    @IsTest
    static void submitDeal_overLengthAddress_rejected() {
        BrokerPortalController.DealSubmission d = validInput();
        d.propertyAddress = 'x'.repeat(256);
        Test.startTest();
        assertRejected(d, 'over-length property address');
        Test.stopTest();
    }

    // ---- Routing (queue not configured) ----

    @IsTest
    static void submitDeal_queueNotConfigured_rejected() {
        // Force the queue lookup to resolve to null (queue "not configured") without
        // deleting the org's routing queue.
        BrokerPortalService.queueResolved = true;
        BrokerPortalService.cachedQueueId = null;

        mockTurnstileVerified();
        Test.startTest();
        assertRejected(validInput(), 'routing queue not configured');
        Test.stopTest();
    }

    // ---- Duplicate flagging ----

    @IsTest
    static void submitDeal_openDuplicate_setsFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Existing';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '123 Main St, Dallas TX';
        existing.Status = 'New';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalService.submitDeal(validInput()); // same address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isTrue(created.Duplicate_Flag__c, 'Open same-address lead should flag a duplicate');
    }

    @IsTest
    static void submitDeal_closedDuplicate_doesNotSetFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Old';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '123 Main St, Dallas TX';
        existing.Status = 'Disqualified';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalService.submitDeal(validInput()); // same address, but existing is closed
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Closed same-address lead should not flag a duplicate');
    }

    @IsTest
    static void submitDeal_differentAddress_doesNotSetFlag() {
        Lead existing = TestDataFactory.createLead(false);
        existing.LastName = 'Existing';
        existing.Company = 'Other Firm';
        existing.Property_Address__c = '999 Elsewhere Ave';
        existing.Status = 'New';
        existing.LeadSource = 'Manual Entry';
        insert existing;

        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalService.submitDeal(validInput()); // different address
        Test.stopTest();
        Lead created = [SELECT Duplicate_Flag__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.isFalse(created.Duplicate_Flag__c, 'Different address should not flag a duplicate');
    }

    // ---- Broker-priority copy ----

    @IsTest
    static void submitDeal_knownHighPriorityBroker_copiesPriority() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.FirstName = 'Jane';
        broker.LastName = 'Broker';
        broker.Email = 'jane@acme.com';
        broker.Broker_Priority__c = 'High';
        insert broker;

        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalService.submitDeal(validInput()); // same email as the broker contact
        Test.stopTest();
        Lead created = [SELECT Broker_Priority__c FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.areEqual('High', created.Broker_Priority__c, 'Priority copied from the broker contact');
    }

    // ---- Record-type stamp (IR/Acquisitions segregation, Task 4) ----

    @IsTest
    static void submitDeal_createdLeadCarriesTheAcquisitionRecordType() {
        mockTurnstileVerified();
        Test.startTest();
        BrokerPortalService.submitDeal(validInput());
        Test.stopTest();

        Lead readBack = [SELECT RecordType.DeveloperName FROM Lead WHERE LeadSource = 'Broker Portal' LIMIT 1];
        System.Assert.areEqual('Acquisition_Broker', readBack.RecordType.DeveloperName,
            'A guest Broker-Portal Lead without this record type matches no sharing rule once Lead OWD '
            + 'is Private, so the acquisitions team never sees it.');
    }

    // ---- Lead-insert failure propagates as DmlException (not swallowed by the service) ----

    @IsTest
    static void submitDeal_insertFails_propagatesDmlException() {
        // WHAT THIS PINS: submitDeal's bare `insert l` must let a DmlException PROPAGATE —
        // the service must not swallow it, because the controller's generic catch is what
        // turns it into a user-safe message for an unauthenticated guest. The specific
        // reason the insert fails is irrelevant to that contract.
        //
        // ⚠ MECHANISM CHANGED 2026-08-03 — this test was previously seeded with a
        // same-identity "blocker" Lead and relied on "this org's active Lead duplicate rule
        // (Block)". That mechanism never worked and cannot work:
        //   1. Standard_Lead_Duplicate_Rule is isActive=FALSE in the repo (deactivated in
        //      commit e1f5a9f, 2026-07-25, because it was blocking the inbound email
        //      pipeline) and IsActive=false live on usman-dpeg.
        //   2. Even when active it is actionOnInsert=Allow / operationsOnInsert=Alert,Report
        //      — an ALERT rule, never a Block rule. The old comment's "(Block)" was wrong
        //      about the org's own configuration.
        // So the blocker Lead inserted fine, the portal Lead inserted fine, nothing threw,
        // and the assertion failed. Never couple a test to org-level duplicate rules: they
        // are configuration, changeable in Setup by anyone, and not enforced by this code.
        //
        // The failure is now forced through the @TestVisible queue seam that production
        // already exposes for exactly this kind of deterministic test control (see the same
        // seam used by submitDeal_queueNotConfigured_rejected). A Contact Id is a
        // syntactically valid Id that Lead.OwnerId cannot accept — only a User or a Queue —
        // so `insert l` fails with an un-mockable, org-independent DmlException at precisely
        // the line under test. It is non-null, so the earlier "queue not configured"
        // SubmissionException branch is deliberately NOT the thing being exercised.
        Contact notAValidOwner = TestDataFactory.createContact(null, true);
        BrokerPortalService.queueResolved = true;
        BrokerPortalService.cachedQueueId = notAValidOwner.Id;

        Boolean threwDml = false;
        mockTurnstileVerified();
        Test.startTest();
        try {
            BrokerPortalService.submitDeal(validInput());
        } catch (DmlException e) {
            threwDml = true;
        }
        Test.stopTest();
        System.Assert.isTrue(threwDml, 'A blocked Lead insert should surface as an un-swallowed DmlException');
    }
}
