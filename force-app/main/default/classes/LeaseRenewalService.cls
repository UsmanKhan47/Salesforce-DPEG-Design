/**
 * Service for the Lease Renewal Tracker write workflow — owns the DML behind
 * LeaseRenewalController.addUpdate (P6 controller thinning): appends one contact/system
 * entry to a renewal's append-only timeline and, for a human contact method, resets the
 * tenant-contact clock on the parent renewal.
 *
 * Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2 this DML and the
 * "valid method + non-blank outcome" business rule are Service work, not Controller work.
 * The controller now only marshals input, delegates here, and maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 *
 * This service holds no inline SOQL — the timeline reads live in RenewalActivitySelector /
 * LeaseRenewalSelector. It throws a typed RenewalUpdateException for the two user-actionable
 * validation rules (surfaced verbatim by the controller) and the raw platform DmlException
 * on a save failure. The AuraHandledException boundary lives in the controller, NOT here, so
 * the service stays UI-agnostic (also callable from Flow / Apex).
 *
 * TRANSACTIONALITY: addUpdate issues one child insert then, for non-System methods, one
 * parent update — the exact two single-record statements the pre-thinning controller ran, in
 * the same order. It is deliberately left Savepoint-free: this preserves the pre-thinning
 * (non-atomic) behaviour, and when the controller re-throws its AuraHandledException the
 * platform rolls back the whole @AuraEnabled transaction, so a failed parent update cannot
 * leave an orphan activity behind.
 *
 * @see force-app/main/default/classes/LeaseRenewalController.cls (thin caller)
 * @see force-app/main/default/classes/RenewalActivitySelector.cls (timeline SOQL)
 */
public with sharing class LeaseRenewalService {

    /** The contact methods a timeline entry may use. 'System' is a Yardi/automation note. */
    private static final Set<String> METHODS = new Set<String>{ 'Call', 'Email', 'Visit', 'Note', 'System' };

    /**
     * Raised when addUpdate is asked to log with no outcome text or an unknown contact
     * method. User-actionable and user-safe: the controller surfaces its message verbatim.
     * Distinct from an unexpected platform DmlException, which the controller maps to a
     * fixed generic message instead.
     */
    public class RenewalUpdateException extends Exception {}

    /**
     * Appends one entry to a renewal's timeline and, for a human contact method, stamps the
     * parent renewal's Last_Contact_Date__c to today. A 'System' entry is a Yardi/automation
     * note, not tenant contact, so it never resets the clock.
     *
     * @param renewalId the parent Lease_Renewal__c the entry belongs to (required)
     * @param method    contact method; must be one of Call/Email/Visit/Note/System
     * @param details   the outcome text (required, trimmed before save)
     * @throws RenewalUpdateException when details are blank or method is missing/invalid
     * @throws System.DmlException    on a platform save failure (e.g. a bad parent reference)
     */
    public static void addUpdate(Id renewalId, String method, String details) {
        if (String.isBlank(details)) {
            throw new RenewalUpdateException('Enter the outcome before saving.');
        }
        if (String.isBlank(method) || !METHODS.contains(method)) {
            throw new RenewalUpdateException('Choose a valid contact method.');
        }
        // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp for this log entry.
        Datetime entryStamp = Datetime.now();
        insert new Renewal_Activity__c(
            Lease_Renewal__c = renewalId,
            Method__c = method,
            Details__c = details.trim(),
            Entry_DateTime__c = entryStamp);
        // A Yardi/system note is not tenant contact — only human methods reset the clock.
        if (method != 'System') {
            update new Lease_Renewal__c(Id = renewalId, Last_Contact_Date__c = Date.today());
        }
    }
}
