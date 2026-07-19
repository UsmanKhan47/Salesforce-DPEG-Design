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
        if (input != null && String.isNotBlank(input.website)) {
            return new BrokerPortalController.SubmitResult(true, CONFIRMATION_MSG);
        }
        validate(input);

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
