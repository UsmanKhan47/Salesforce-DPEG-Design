/**
 * Apex controller behind the public Experience Cloud (LWR) guest Broker Portal. A guest
 * submits the portal form; a Lead (LeadSource = 'Broker Portal') is created.
 *
 * ⚠ SHARING — `without sharing`, DELIBERATE and SECURITY-CRITICAL. Do NOT change it. The
 * guest anti-abuse duplicate check must see Leads the site guest user cannot; that
 * all-records read lives in LeadSelector.GuestReads / ContactSelector.GuestReads
 * (`without sharing`, SYSTEM_MODE) and in BrokerPortalService (also `without sharing`).
 * Converting to `with sharing` would silently scope the dedup to the guest's (empty)
 * sharing and defeat the anti-abuse Duplicate_Flag__c signal.
 *
 * Thin controller (P6 controller thinning): marshals the guest DTO, delegates the
 * Lead-creation + dedup workflow to BrokerPortalService, and maps every failure to a
 * user-safe AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). User-
 * actionable messages (validation, routing) are surfaced verbatim via the service's
 * typed SubmissionException; unexpected platform detail goes to the debug log
 * (admin-only) and the guest gets a fixed, generic message with no exception detail
 * concatenated in. All SOQL lives in selectors and the business logic lives in the
 * service — this controller holds neither.
 */
public without sharing class BrokerPortalController {

    // Fixed, generic user-safe message for an unexpected submit failure (e.g. the Lead
    // insert). Matches the original inline insert-catch message, so guest-visible
    // behaviour on a failed save is unchanged.
    private static final String SUBMIT_FAILURE_MESSAGE =
        'We could not save your submission. Please try again.';
    // Fixed, generic user-safe message for a failed form-metadata read.
    private static final String METADATA_FAILURE_MESSAGE =
        'The submission form could not be loaded. Refresh the page or contact your administrator.';

    // ---- DTOs (the @AuraEnabled contract consumed by the brokerDealIntakeForm LWC) ----
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
        /**
         * The Cloudflare Turnstile token produced by the widget in the guest's browser
         * (`cf-turnstile-response`). Verified server-side by BrokerPortalService via
         * TurnstileVerificationService before any DML — see ARCHITECTURE.md §3.5.
         *
         * ⚠ SINGLE-USE. A token that has already been verified comes back from Cloudflare as
         * `timeout-or-duplicate` and is refused, which is why brokerDealIntakeForm resets the
         * widget after every failed submit rather than resubmitting the same value.
         *
         * ⚠ It is UNTRUSTED CLIENT INPUT like every other field on this DTO. Its only use is as an
         * opaque parameter to Cloudflare; nothing derives a decision from its contents locally.
         */
        @AuraEnabled public String turnstileToken { get; set; }
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
        try {
            FormMetadata meta = new FormMetadata();
            meta.assetTypes = optionsFor(Lead.Asset_Type__c.getDescribe());
            meta.dealTypes = optionsFor(Lead.Deal_Type__c.getDescribe());
            return meta;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerPortalController.getFormMetadata: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(METADATA_FAILURE_MESSAGE);
        }
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
        try {
            return BrokerPortalService.submitDeal(input);
        } catch (BrokerPortalService.SubmissionException e) {
            // User-actionable validation / routing message — safe to surface verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            // Unexpected (e.g. the Lead insert) — log platform detail, show a fixed,
            // generic message with no raw exception text to the unauthenticated guest.
            System.debug(LoggingLevel.ERROR, 'BrokerPortalController.submitDeal: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SUBMIT_FAILURE_MESSAGE);
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
