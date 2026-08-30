/**
 * Guest Broker-Portal deal-intake business logic: validates the public form, creates
 * the intake Lead (LeadSource = 'Broker Portal'), flags open-address duplicates, and
 * copies the broker's priority. Extracted from BrokerPortalController (P6 controller
 * thinning) so the controller is a thin marshal -> delegate -> catch boundary.
 *
 * ⚠ SHARING — `without sharing`, DELIBERATE and SECURITY-CRITICAL. The controller's
 * ORIGINAL `without sharing` declaration is PRESERVED here verbatim; do NOT convert to
 * `with sharing`. The public LWR portal runs as the site guest user, whose sharing is
 * minimal/unconfigured (P3 guest-sharing spike incomplete). The anti-abuse duplicate
 * check and the broker-priority lookup must see records the guest cannot. Those
 * all-records reads live in LeadSelector.GuestReads / ContactSelector.GuestReads —
 * `without sharing` inner selector classes running WITH SYSTEM_MODE — and are UNCHANGED
 * by this extraction. This class only reproduces the controller's original guest-context
 * `without sharing` for the Lead insert. Converting to `with sharing` would silently
 * scope the dedup to the guest's (empty) sharing and defeat the Duplicate_Flag__c
 * anti-abuse signal.
 *
 * ⚠ PRE-PROMOTION: this preserves the INTENT (all-records anti-abuse dedup) but the
 * guest sharing/ownership model itself is still unverified — the P3 guest-sharing spike
 * must be completed before portal promotion. (Carried over from the GuestReads selectors.)
 *
 * All SOQL is delegated to selectors (LeadSelector / ContactSelector / QueueGroupSelector)
 * per ARCHITECTURE.md §2 — this service holds zero inline SOQL.
 *
 * UI-agnostic error contract: user-actionable failures (validation, routing) throw the
 * typed SubmissionException carrying a user-safe message; the controller maps that to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). Unexpected failures
 * (e.g. the Lead insert) propagate as their native type to the controller's generic
 * catch. This class never throws AuraHandledException.
 *
 * EXTENDED 2026-08-10 (IR/Acquisitions segregation, Task 4): submitDeal now stamps the
 * Acquisition_Broker record type on every guest-submitted Lead via
 * EmailToLeadService.acquisitionBrokerRecordTypeId() — reused rather than re-derived, so this
 * class's guest-context Lead and the inbound-email pipeline's Lead can never answer the
 * record-type question two different ways. That helper's guard
 * (`info != null && info.isAvailable()`) is a deliberate fail-soft backstop, not a defect: the
 * Site guest user is not provisioned with record-type visibility through the UI, so guarding on
 * `isAvailable()` here is what keeps a provisioning gap from THROWING on `insert l` and
 * destroying a guest submission outright (measured — see the helper's own doc comment on
 * EmailToLeadService). Guarded, the same gap costs an unstamped Lead: recoverable, and
 * detectable. Without the record-type stamp, once Lead OWD flips to Private (a later task in
 * this plan) a Broker-Portal Lead would match no sharing rule and become invisible to the
 * Acquisitions team.
 *
 * ═══ EXTENDED 2026-08-30 (WS4): CLOUDFLARE TURNSTILE CAPTCHA — AND IT FAILS CLOSED ═══
 * `submitDeal` now makes ONE outbound callout, to Cloudflare Turnstile, via
 * `TurnstileVerificationService` (ARCHITECTURE.md §3.5, the third standing direct-callout
 * exception). Three properties of that change are worth reading before touching this method:
 *
 * 1. 🔴 THE ORDER honeypot -> validate -> TURNSTILE -> ... -> `insert l` IS LOAD-BEARING, in both
 *    directions, and the reasons are written at each site. In short: the honeypot must stay first
 *    so a bot learns nothing and burns no callout, and the verification must precede the insert
 *    because Apex forbids a callout after uncommitted DML. There is exactly one legal slot.
 *
 * 2. 🔴 A CLOUDFLARE OUTAGE TAKES THE PUBLIC FORM DOWN. Verification failures of every kind —
 *    refused, unreachable, timed out, misconfigured — refuse the submission. This is deliberate
 *    (a CAPTCHA that fails open is not a CAPTCHA; see `verifyHuman`'s header for the full argument
 *    and for why `LeadConvertMatchService` correctly does the opposite) and it is a real,
 *    accepted availability cost, not an oversight. It belongs in the release note.
 *
 * 3. ⚠ THIS METHOD IS NOW CALLOUT-BEARING, WHICH CHANGES ITS TESTING CONTRACT PERMANENTLY. Every
 *    test that reaches past `validate` MUST install an `HttpCalloutMock` before calling it, or it
 *    fails with "Methods defined as TestMethod do not support Web service callouts" — a message
 *    that names the test, not the cause. `BrokerPortalServiceTest.mockTurnstile(...)` exists for
 *    this. The honeypot test deliberately installs NO mock, which is what proves property 1.
 */
public without sharing class BrokerPortalService {

    private static final String LEAD_SOURCE = 'Broker Portal';
    private static final String QUEUE_DEV_NAME = 'Broker_Portal_Leads';
    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Converted', 'Disqualified' };
    private static final String CONFIRMATION_MSG =
        'Thank you! We have received your deal. Our acquisitions team will review it shortly.';
    private static final String ROUTING_UNAVAILABLE_MSG =
        'We could not route your submission right now. Please try again later.';

    /**
     * Shown when Cloudflare affirmatively REFUSED the token — unsolved, expired, replayed, or
     * tampered with. It tells the broker exactly what to do, because for a real human this is a
     * recoverable, self-service condition: solve the widget again and resubmit.
     */
    private static final String CAPTCHA_REFUSED_MSG =
        'We could not confirm that you are human. Please complete the verification below and submit again.';

    /**
     * Shown when verification could not be COMPLETED — Cloudflare unreachable, timed out, or our
     * own credential is broken. Deliberately different from the message above: telling a broker to
     * "complete the verification" when the verifier is down would send them into a loop doing the
     * one thing that cannot help. It promises nothing and asks them to come back.
     */
    private static final String CAPTCHA_UNAVAILABLE_MSG =
        'We could not verify your submission right now. Please try again in a few minutes.';

    /**
     * Typed, user-safe failure for user-actionable submit errors (validation and
     * routing). Its message is safe to surface to the guest verbatim; the controller
     * wraps it in an AuraHandledException. It is NOT thrown for unexpected/platform
     * errors — those propagate as their native type to the controller's generic catch.
     */
    public class SubmissionException extends Exception {}

    /**
     * Validate the guest form and create the server-stamped Broker-Portal Lead,
     * flagging open-address duplicates and copying broker priority. Honeypot
     * submissions return a benign success WITHOUT inserting (bots learn nothing).
     *
     * @param input The guest form DTO (BrokerPortalController.DealSubmission).
     * @return A success SubmitResult carrying the confirmation message.
     * @throws SubmissionException for validation / routing failures (user-safe message).
     * @throws DmlException if the Lead insert fails (the controller maps this to a
     *         fixed generic message).
     */
    public static BrokerPortalController.SubmitResult submitDeal(BrokerPortalController.DealSubmission input) {
        // Honeypot - silently drop bot submissions with a normal-looking response.
        // 🔴 THIS STAYS FIRST, AHEAD OF TURNSTILE, AND THE ORDER IS LOAD-BEARING IN BOTH
        // DIRECTIONS. A caught bot must still receive the benign success it always received, so it
        // learns nothing about having been detected — putting CAPTCHA first would answer a
        // honeypot hit with a verification error and tell the bot exactly which field betrayed it.
        // And a honeypot hit must burn NO CALLOUT: this is an unauthenticated public endpoint, so
        // the cheapest possible rejection has to come first or a scripted flood turns into a
        // callout-limit outage for legitimate brokers in the same org.
        if (input != null && String.isNotBlank(input.website)) {
            return new BrokerPortalController.SubmitResult(true, CONFIRMATION_MSG);
        }
        validate(input);
        // 🔴 TURNSTILE VERIFICATION SITS HERE, AND THIS IS THE ONLY LEGAL POSITION FOR IT.
        // After `validate` so an obviously-malformed form is refused without spending a callout;
        // before EVERY line below, because Apex forbids a callout once the transaction holds
        // uncommitted DML ("You have uncommitted work pending"). Everything between here and
        // `insert l` is SOQL only (brokerQueueId, isDuplicate, brokerPriorityFor) and SOQL does not
        // close the callout window — but the moment `insert l` runs, it does, permanently.
        // Moving this call one line past the insert does not fail at compile time or in review; it
        // fails at runtime, on the live public form, for every visitor.
        verifyHuman(input);

        Lead l = new Lead();
        l.FirstName = input.firstName.trim();
        l.LastName = input.lastName.trim();
        l.Company = input.brokerageFirm.trim();
        l.Broker_First__c = input.brokerageFirm.trim();
        l.Email = input.email.trim();
        l.Phone = trimToNull(input.phone);
        l.Property_Address__c = input.propertyAddress.trim();
        l.Asset_Type__c = input.assetType;
        l.Deal_Type__c = trimToNull(input.dealType);
        // Server-stamped - never accepted from the client.
        l.LeadSource = LEAD_SOURCE;
        l.Status = 'New';
        l.First_Seen_Date__c = Datetime.now();
        // IR/Acquisitions segregation (Task 4): reuse EmailToLeadService's guarded describe so
        // this Lead answers "which record type?" the same way the inbound-email pipeline does.
        Id acqRt = EmailToLeadService.acquisitionBrokerRecordTypeId();
        if (acqRt != null) {
            l.RecordTypeId = acqRt;
        }
        Id queueId = brokerQueueId();
        if (queueId == null) {
            throw new SubmissionException(ROUTING_UNAVAILABLE_MSG);
        }
        l.OwnerId = queueId;
        l.Duplicate_Flag__c = isDuplicate(l.Property_Address__c);
        l.Broker_Priority__c = brokerPriorityFor(l.Email);
        // Bare insert: an unexpected DmlException propagates to the controller's generic
        // catch, which surfaces a fixed, user-safe message (behaviour-preserving vs the
        // original inline try/catch).
        insert l;
        return new BrokerPortalController.SubmitResult(true, CONFIRMATION_MSG);
    }

    // ---- Helpers: CAPTCHA ----

    /**
     * Refuse the submission unless Cloudflare Turnstile affirmatively confirms the token.
     *
     * ═══ 🔴 FAIL CLOSED. A CAPTCHA THAT FAILS OPEN IS NOT A CAPTCHA. ═══
     * If Cloudflare is unreachable, times out, answers unparseably, or our own credential is
     * broken, this method REFUSES the submission. State the trade plainly, because it is real and
     * it is a deliberate choice: a Cloudflare outage takes the public broker form down. No deals
     * arrive by that route until it recovers. That is accepted, because the alternative — waving
     * everything through whenever the verifier is unavailable — hands an attacker a trivial
     * bypass: make verification fail (or simply wait for it to), and the control evaporates
     * exactly when it is needed. A control whose failure mode is "no control" was never one.
     *
     * ⚠ CONTRAST `LeadConvertMatchService`, WHICH FAILS *OPEN*, AND IS ALSO RIGHT.
     * Its header says why: matching "is an OPTIMISATION OVER PLATFORM DEFAULT BEHAVIOUR, not an
     * authorization control", so degrading it costs a duplicate, not a breach. Turnstile IS a
     * control, so the polarity inverts. The two classes are not inconsistent; they are answering
     * different questions, and anyone tempted to "harmonise" them should read both headers.
     *
     * ⚠ THE BROKER-VISIBLE COST OF FAIL-CLOSED IS A MESSAGE THAT MUST NOT MISLEAD, which is why
     * there are two of them: a REFUSED token tells the human to solve the widget again (they can
     * fix it); an UNAVAILABLE verifier tells them to come back later (they cannot).
     *
     * ⚠ OPERATIONAL: `isConfigurationFailure()` is logged at ERROR and nothing else is. A refused
     * token is the feature working and would drown the log; an invalid or missing secret is the
     * feature DOWN FOR EVERYONE while returning a perfectly ordinary HTTP response that no
     * exception handler will ever see. That single log line is the only automated trace that
     * distinguishes "we are blocking bots" from "we are blocking everybody".
     *
     * ⚠ There is no bypass switch, deliberately — none was requested, and a "disable CAPTCHA"
     * flag on a public endpoint is a control with an off button. If ops need one during an
     * outage, that is a design decision to take explicitly, not a helper to add quietly here.
     *
     * @param sub The validated guest form DTO.
     * @throws SubmissionException always, unless Cloudflare confirmed the token. The message is
     *         user-safe and is surfaced verbatim by the controller.
     */
    private static void verifyHuman(BrokerPortalController.DealSubmission sub) {
        // remoteIp is deliberately null — see TurnstileVerificationService.verify's @param note.
        // A Salesforce guest context can only offer a proxy address, and Cloudflare validates a
        // supplied remoteip against the one the token was issued to, so passing a wrong one
        // converts legitimate submissions into refusals.
        TurnstileVerificationService.VerificationResult result =
            new TurnstileVerificationService().verify(sub.turnstileToken, null);

        if (result.isVerified()) {
            return;
        }
        if (result.isConfigurationFailure()) {
            // Not a bot. Our credential is wrong, and every visitor is being turned away.
            System.debug(LoggingLevel.ERROR, 'BrokerPortalService.verifyHuman: Turnstile '
                + 'CREDENTIAL FAILURE - the public broker form is refusing all submissions. '
                + 'Check the Turnstile_Credential Secret_Key in Setup and the Named Credential '
                + 'allowMergeFieldsInBody flag. Codes: ' + String.join(result.errorCodes, ', '));
            throw new SubmissionException(CAPTCHA_UNAVAILABLE_MSG);
        }
        if (result.statusCode == 0) {
            // No HTTP exchange completed: transport failure, timeout, or a missing External
            // Credential Principal Access grant on the site guest user.
            System.debug(LoggingLevel.ERROR, 'BrokerPortalService.verifyHuman: Turnstile '
                + 'unreachable - ' + result.errorMessage);
            throw new SubmissionException(CAPTCHA_UNAVAILABLE_MSG);
        }
        // Cloudflare answered and said no. This is the feature working as designed.
        throw new SubmissionException(CAPTCHA_REFUSED_MSG);
    }

    // ---- Helpers: queue ----
    // @TestVisible so a test can force the "queue not configured" branch deterministically
    // without deleting the org's routing queue (a setup-object DML that risks MIXED_DML).
    @TestVisible private static Id cachedQueueId;
    @TestVisible private static Boolean queueResolved = false;
    private static Id brokerQueueId() {
        if (!queueResolved) {
            queueResolved = true;
            // SOQL relocated to QueueGroupSelector (ARCHITECTURE.md §2 layering).
            Group queue = QueueGroupSelector.selectQueueByDeveloperName(QUEUE_DEV_NAME);
            cachedQueueId = (queue == null) ? null : queue.Id;
        }
        return cachedQueueId;
    }

    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    /**
     * Broker priority lives on the broker's Contact (source of truth) and is copied
     * onto each lead they submit, so intake can be worked priority-first. Unknown
     * brokers default to Standard.
     */
    private static String brokerPriorityFor(String email) {
        if (String.isNotBlank(email)) {
            // SOQL relocated to ContactSelector's without-sharing GuestReads inner
            // class (ARCHITECTURE.md §2; preserves the original all-records guest read).
            Contact broker = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(email);
            if (broker != null && String.isNotBlank(broker.Broker_Priority__c)) {
                return broker.Broker_Priority__c;
            }
        }
        return 'Standard';
    }

    // ---- Helpers: validation ----
    private static void validate(BrokerPortalController.DealSubmission sub) {
        if (sub == null) {
            throw new SubmissionException('No submission was received.');
        }
        List<String> errors = new List<String>();
        if (String.isBlank(sub.firstName)) errors.add('First name is required.');
        if (String.isBlank(sub.lastName)) errors.add('Last name is required.');
        if (String.isBlank(sub.brokerageFirm)) errors.add('Brokerage firm is required.');
        if (String.isBlank(sub.propertyAddress)) errors.add('Property address is required.');
        if (String.isBlank(sub.email) || !isValidEmail(sub.email)) errors.add('A valid email is required.');
        if (String.isBlank(sub.assetType) || !isValidPicklist(Lead.Asset_Type__c.getDescribe(), sub.assetType)) {
            errors.add('Please choose a valid asset type.');
        }
        if (String.isNotBlank(sub.dealType) && !isValidPicklist(Lead.Deal_Type__c.getDescribe(), sub.dealType)) {
            errors.add('Please choose a valid deal type.');
        }
        if (String.isNotBlank(sub.firstName) && sub.firstName.length() > 40) errors.add('First name is too long.');
        if (String.isNotBlank(sub.lastName) && sub.lastName.length() > 80) errors.add('Last name is too long.');
        if (String.isNotBlank(sub.brokerageFirm) && sub.brokerageFirm.length() > 255) errors.add('Brokerage firm is too long.');
        if (String.isNotBlank(sub.email) && sub.email.length() > 80) errors.add('Email is too long.');
        if (String.isNotBlank(sub.phone) && sub.phone.length() > 40) errors.add('Phone is too long.');
        if (String.isNotBlank(sub.propertyAddress) && sub.propertyAddress.length() > 255) errors.add('Property address is too long.');
        if (!errors.isEmpty()) {
            throw new SubmissionException(String.join(errors, ' '));
        }
    }

    private static Boolean isValidEmail(String value) {
        return Pattern.matches('^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$', value.trim());
    }

    private static Boolean isValidPicklist(Schema.DescribeFieldResult dfr, String value) {
        for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
            if (e.isActive() && e.getValue() == value) {
                return true;
            }
        }
        return false;
    }

    // ---- Helpers: duplicate check ----
    private static Boolean isDuplicate(String address) {
        if (String.isBlank(address)) {
            return false;
        }
        // SOQL relocated to LeadSelector's without-sharing GuestReads inner class
        // (ARCHITECTURE.md §2; preserves the original all-records dedup).
        return !new LeadSelector.GuestReads()
            .selectOpenDuplicatesByAddressSystem(address, CLOSED_STATUSES)
            .isEmpty();
    }
}
