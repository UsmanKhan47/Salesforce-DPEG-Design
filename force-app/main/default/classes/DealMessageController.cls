/**
 * Backs the dealMessageLog LWC - the shared, append-only communication tracker
 * shown in the Messages tab on LOI, Underwriting, and Contract Review record
 * pages (same interaction pattern as the Lease Activity / Lease Renewal
 * timelines). The parent object is derived from the record Id, so one component
 * and one controller serve all three objects.
 *
 * Thin controller (P6 controller thinning). The message-insert DML and the
 * parent-resolution business rule live in DealMessageService per
 * .claude/rules/apex-layering-rule.md; all SOQL lives in DealMessageSelector per
 * ARCHITECTURE.md §2. Every @AuraEnabled method (read and write) maps failures the same
 * way (ARCHITECTURE.md §5): the platform detail goes to the debug log (admin-only) and
 * the user gets a message. A user-actionable rule violation (ValidationException /
 * UnsupportedParentException) is surfaced verbatim; an unexpected platform failure gets a
 * fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class DealMessageController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';
    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This message could not be saved. Refresh the page and try again, or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class Entry {
        @AuraEnabled public String id;
        @AuraEnabled public String method;
        @AuraEnabled public String direction;
        @AuraEnabled public String details;
        @AuraEnabled public String revision;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }

    @AuraEnabled(cacheable=true)
    public static List<Entry> getMessages(Id recordId) {
        try {
            if (recordId == null) {
                return new List<Entry>();
            }
            // Parent-field resolution is a business rule owned by the service.
            String parentField = DealMessageService.parentFieldFor(recordId);
            List<Entry> entries = new List<Entry>();
            // SOQL relocated to DealMessageSelector per ARCHITECTURE.md §2 (it re-validates
            // parentField against its own allow-list and re-binds :recordId via queryWithBinds).
            for (Deal_Message__c m : DealMessageSelector.selectByParent(parentField, recordId)) {
                Entry e = new Entry();
                e.id = m.Id;
                e.method = m.Method__c;
                e.direction = m.Direction__c;
                e.details = m.Details__c;
                e.revision = m.Revision__c;
                e.enteredBy = m.CreatedBy.Name;
                e.entryDate = m.Entry_DateTime__c != null ? m.Entry_DateTime__c : m.CreatedDate;
                entries.add(e);
            }
            return entries;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DealMessageController.getMessages on ' + recordId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Logs one message against the record's parent (LOI / Underwriting / Contract Review).
     * Delegates the validation + insert to DealMessageService; a user-actionable rule
     * violation is surfaced verbatim, any other failure gets the generic message.
     */
    @AuraEnabled
    public static void addMessage(Id recordId, String method, String direction, String details, String revision) {
        try {
            DealMessageService.addMessage(recordId, method, direction, details, revision);
        } catch (DealMessageService.ValidationException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (DealMessageService.UnsupportedParentException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DealMessageController.addMessage on ' + recordId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
