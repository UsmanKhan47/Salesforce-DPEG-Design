public without sharing class BrokerPortalController {

    private static final String LEAD_SOURCE = 'Broker Portal';
    private static final String QUEUE_DEV_NAME = 'Broker_Portal_Leads';
    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Converted', 'Disqualified' };
    private static final String CONFIRMATION_MSG =
        'Thank you! We have received your deal. Our acquisitions team will review it shortly.';

    // ---- DTOs ----
    public class DealSubmission {
        @AuraEnabled public String firstName { get; set; }
        @AuraEnabled public String lastName { get; set; }
        @AuraEnabled public String brokerageFirm { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public String propertyAddress { get; set; }
        @AuraEnabled public String assetType { get; set; }
        @AuraEnabled public String dealType { get; set; }
        @AuraEnabled public String website { get; set; } // honeypot - must be blank
    }

    public class SubmitResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        public SubmitResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class FormMetadata {
        @AuraEnabled public List<PicklistOption> assetTypes { get; set; }
        @AuraEnabled public List<PicklistOption> dealTypes { get; set; }
    }

    // ---- getFormMetadata ----
    @AuraEnabled(cacheable=true)
    public static FormMetadata getFormMetadata() {
        FormMetadata meta = new FormMetadata();
        meta.assetTypes = optionsFor(Lead.Asset_Type__c.getDescribe());
        meta.dealTypes = optionsFor(Lead.Deal_Type__c.getDescribe());
        return meta;
    }

    private static List<PicklistOption> optionsFor(Schema.DescribeFieldResult dfr) {
        List<PicklistOption> opts = new List<PicklistOption>();
        for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
            if (e.isActive()) {
                opts.add(new PicklistOption(e.getLabel(), e.getValue()));
            }
        }
        return opts;
    }

    // ---- submitDeal ----
    @AuraEnabled
    public static SubmitResult submitDeal(DealSubmission input) {
        // Honeypot - silently drop bot submissions with a normal-looking response.
        if (input != null && String.isNotBlank(input.website)) {
            return new SubmitResult(true, CONFIRMATION_MSG);
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
            throw new AuraHandledException('We could not route your submission right now. Please try again later.');
        }
        l.OwnerId = queueId;
        l.Duplicate_Flag__c = isDuplicate(l.Property_Address__c);
        try {
            insert l;
        } catch (DmlException e) {
            throw new AuraHandledException('We could not save your submission. Please try again.');
        }
        return new SubmitResult(true, CONFIRMATION_MSG);
    }

    // ---- Helpers: queue ----
    private static Id cachedQueueId;
    private static Boolean queueResolved = false;
    private static Id brokerQueueId() {
        if (!queueResolved) {
            queueResolved = true;
            List<Group> qs = [
                SELECT Id FROM Group
                WHERE Type = 'Queue' AND DeveloperName = :QUEUE_DEV_NAME
                LIMIT 1
            ];
            cachedQueueId = qs.isEmpty() ? null : qs[0].Id;
        }
        return cachedQueueId;
    }

    private static String trimToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // ---- Helpers: validation ----
    private static void validate(DealSubmission sub) {
        if (sub == null) {
            throw new AuraHandledException('No submission was received.');
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
            throw new AuraHandledException(String.join(errors, ' '));
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
        List<Lead> existing = [
            SELECT Id FROM Lead
            WHERE Property_Address__c = :address.trim()
              AND Status NOT IN :CLOSED_STATUSES
            LIMIT 1
        ];
        return !existing.isEmpty();
    }
}