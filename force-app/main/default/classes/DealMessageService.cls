/**
 * Service behind DealMessageController (P6 controller thinning) for the shared, append-only
 * deal communication tracker used on the Messages tab of LOI, Underwriting, and Contract
 * Review record pages. The parent object is derived from the record Id, so one service serves
 * all three parents.
 *
 * Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 the message-insert DML and
 * the parent-resolution business rule are Service work, not Controller work. The controller
 * marshals input, delegates here, and maps failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5).
 *
 * This service holds no inline SOQL — the timeline read lives in DealMessageSelector. It
 * throws typed exceptions for the user-actionable rules (surfaced verbatim by the controller)
 * and the raw platform DmlException on a save failure. The AuraHandledException boundary lives
 * in the controller, NOT here, so the service stays UI-agnostic (also callable from Flow/Apex).
 *
 * TRANSACTIONALITY: addMessage issues a single Deal_Message__c insert — one single-record
 * statement mirroring the pre-thinning controller exactly. No Savepoint is needed.
 *
 * @see force-app/main/default/classes/DealMessageController.cls (thin caller)
 * @see force-app/main/default/classes/DealMessageSelector.cls (all SOQL)
 */
public with sharing class DealMessageService {

    /**
     * The Deal_Message__c parent lookup for each supported parent object API name.
     * Also the allow-list of objects the tracker is available on.
     */
    private static final Map<String, SObjectField> PARENT_FIELDS = new Map<String, SObjectField>{
        'LOI__c'             => Deal_Message__c.LOI__c,
        'Underwriting__c'    => Deal_Message__c.Underwriting__c,
        'Contract_Review__c' => Deal_Message__c.Contract_Review__c
    };

    /**
     * Raised when a message is logged with no record or no detail text. User-actionable and
     * user-safe: the controller surfaces the message verbatim.
     */
    public class ValidationException extends Exception {}

    /**
     * Raised when the record's object is not one of the three supported message-tracker
     * parents. User-actionable and user-safe: the controller surfaces the message verbatim.
     */
    public class UnsupportedParentException extends Exception {}

    /**
     * Resolves the Deal_Message__c parent lookup API name for a record Id — the object's own
     * API name, validated against the supported-parent allow-list.
     *
     * @param recordId the parent record Id (LOI / Underwriting / Contract Review)
     * @return the parent lookup field API name (equal to the object API name)
     * @throws UnsupportedParentException when the object is not a supported tracker parent
     */
    public static String parentFieldFor(Id recordId) {
        String objectName = recordId.getSObjectType().getDescribe().getName();
        if (!PARENT_FIELDS.containsKey(objectName)) {
            throw new UnsupportedParentException('The message tracker is not available on ' + objectName + '.');
        }
        return objectName;
    }

    /**
     * Appends one message to a parent's append-only communication log. Method, direction, and
     * revision default when blank (Note / Internal / none); details are required and trimmed.
     *
     * @param recordId  the parent record the message is logged against (required)
     * @param method    contact method; defaults to 'Note' when blank
     * @param direction message direction; defaults to 'Internal' when blank
     * @param details   what was communicated (required, trimmed before save)
     * @param revision  optional document revision label; trimmed, null when blank
     * @throws ValidationException        when recordId is null or details are blank
     * @throws UnsupportedParentException when the record's object is not a supported parent
     * @throws System.DmlException        on a platform save failure (e.g. a bad parent reference)
     */
    public static void addMessage(Id recordId, String method, String direction, String details, String revision) {
        if (recordId == null) {
            throw new ValidationException('No record to log the message against.');
        }
        if (String.isBlank(details)) {
            throw new ValidationException('Enter what was communicated before saving.');
        }
        String parentField = parentFieldFor(recordId);
        // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp for this log entry.
        Datetime entryStamp = Datetime.now();
        Deal_Message__c m = new Deal_Message__c(
            Method__c = String.isBlank(method) ? 'Note' : method,
            Direction__c = String.isBlank(direction) ? 'Internal' : direction,
            Details__c = details.trim(),
            Revision__c = String.isBlank(revision) ? null : revision.trim(),
            Entry_DateTime__c = entryStamp
        );
        m.put(PARENT_FIELDS.get(parentField), recordId);
        insert m;
    }
}
