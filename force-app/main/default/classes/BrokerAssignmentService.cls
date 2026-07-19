/**
 * Service for the Broker Assignments (Property Management → Leasing) write workflows.
 *
 * Owns the business logic behind BrokerAssignmentController's four write methods
 * (P6 controller thinning): the check-in stamp, the listing close-out, the native
 * Note create, and the broker-replacement snapshot-and-swap. Per
 * .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2, this DML + transaction
 * management is Service work, not Controller work — the controller now only marshals
 * input, delegates here, and maps failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to BrokerAssignmentSelector — this service holds no inline
 * SOQL. It throws typed exceptions (BrokerAssignmentException for validation) and the
 * raw platform DmlException on a save failure; the multi-DML methods roll back through
 * a savepoint before propagating. The AuraHandledException boundary lives in the
 * controller, NOT here: a service must not know about the LWC transport, so it never
 * constructs an AuraHandledException.
 *
 * @see force-app/main/default/classes/BrokerAssignmentController.cls (thin caller)
 * @see force-app/main/default/classes/BrokerAssignmentSelector.cls (all SOQL)
 */
public with sharing class BrokerAssignmentService {

    /**
     * Typed validation failure. Carries a user-safe message that the controller
     * surfaces unchanged through its AuraHandledException boundary. This is NOT an
     * AuraHandledException: keeping the transport type at the controller lets the
     * service stay UI-agnostic (also callable from Flow / Apex / a future caller).
     */
    public class BrokerAssignmentException extends Exception {}

    /**
     * Stamps today's date onto the assignment's Last Check-In Date — resets the
     * broker-check-in staleness clock the dashboard's Alerts tiles read.
     *
     * @param assignmentId the Broker_Assignment__c being checked in against
     * @throws System.DmlException on a platform save failure
     */
    public static void logCheckIn(Id assignmentId) {
        update new Broker_Assignment__c(Id = assignmentId, Last_Check_In_Date__c = Date.today());
    }

    /**
     * Closes out a listing: sets its Status, its Listing End Date (defaulting to
     * today when none is supplied) and the reason it ended.
     *
     * @param assignmentId the Broker_Assignment__c being closed out
     * @param status       the terminal Status to set (e.g. Fully Leased / Disposed)
     * @param endDate      the Listing End Date; today when null
     * @param reason       the Reason Ended text
     * @throws System.DmlException on a platform save failure
     */
    public static void closeOut(Id assignmentId, String status, Date endDate, String reason) {
        update new Broker_Assignment__c(
            Id = assignmentId,
            Status__c = status,
            Listing_End_Date__c = endDate == null ? Date.today() : endDate,
            Reason_Ended__c = reason
        );
    }

    /**
     * Creates a native Salesforce Note (ContentNote) from free text and links it to
     * the record. Title is derived from the first 50 chars of the flattened body so the
     * note is identifiable in the standard Notes UI too. The ContentNote insert and its
     * ContentDocumentLink insert are one unit of work — a savepoint rolls back the note
     * if the link fails, so a note can never be left orphaned.
     *
     * @param recordId the record to link the note to
     * @param body     the free-text note body; blank is rejected (nothing is persisted)
     * @throws BrokerAssignmentException when the body is blank (raised before any DML)
     * @throws System.DmlException       on a platform save failure (already rolled back)
     */
    public static void addNote(Id recordId, String body) {
        String text = body == null ? '' : body.trim();
        if (String.isBlank(text)) {
            throw new BrokerAssignmentException('Note cannot be empty.');
        }
        String flat = text.replaceAll('\\s+', ' ');
        String title = flat.length() > 50 ? flat.substring(0, 50) : flat;
        String html = text.escapeHtml4().replace('\n', '<br>');

        Savepoint sp = Database.setSavepoint();
        try {
            ContentNote n = new ContentNote(Title = title, Content = Blob.valueOf(html));
            insert n;
            insert new ContentDocumentLink(
                ContentDocumentId = n.Id,
                LinkedEntityId = recordId,
                ShareType = 'V',
                Visibility = 'AllUsers'
            );
        } catch (DmlException e) {
            // Roll back the committed note before re-throwing the raw platform exception.
            // The controller owns the user-safe/user-visible split (ARCHITECTURE.md §5).
            Database.rollback(sp);
            throw e;
        }
    }

    /**
     * Replaces the broker on a listing while preserving the outgoing broker's history.
     *
     * Snapshots the current broker's stint as a new closed (Disposed) history record
     * carrying the replacement reason and notes, then swaps the current listing in place
     * to the incoming broker — it stays Active, its start date and check-in clock reset to
     * the effective date, and any prior end date / reason / notes are cleared. The snapshot
     * insert and the swap update are one unit of work: a savepoint rolls the snapshot back
     * if the swap fails, so the history can never be recorded without the swap taking effect.
     *
     * @param assignmentId  the Broker_Assignment__c being reassigned
     * @param newBrokerId   the incoming broker Contact
     * @param effectiveDate the reassignment date; today when null
     * @param reason        the reason the outgoing broker's stint ended (on the snapshot)
     * @param notes         replacement notes carried onto the snapshot
     * @return the same assignment Id, so the caller can refresh the record
     * @throws System.QueryException when assignmentId matches no row (from the selector)
     * @throws System.DmlException   on a platform save failure (already rolled back)
     */
    public static Id replaceBroker(Id assignmentId, Id newBrokerId, Date effectiveDate, String reason, String notes) {
        Date eff = effectiveDate == null ? Date.today() : effectiveDate;
        Broker_Assignment__c cur = BrokerAssignmentSelector.selectRequiredById(assignmentId);

        Savepoint sp = Database.setSavepoint();
        try {
            // Snapshot the outgoing broker's stint as a closed (Disposed) history record,
            // carrying the reason and notes for the replacement.
            if (cur.Broker__c != null) {
                insert new Broker_Assignment__c(
                    Property_Asset__c = cur.Property_Asset__c,
                    Broker__c = cur.Broker__c,
                    Status__c = 'Disposed',
                    Listing_Start_Date__c = cur.Listing_Start_Date__c,
                    Listing_End_Date__c = eff,
                    Last_Check_In_Date__c = cur.Last_Check_In_Date__c,
                    Reason_Ended__c = reason,
                    Replacement_Notes__c = notes
                );
            }
            // Swap the current listing in place to the incoming broker — it stays Active.
            // The incoming broker's tenure starts on the effective date; the check-in
            // clock resets and any prior end date / reason / notes are cleared.
            update new Broker_Assignment__c(
                Id = assignmentId,
                Broker__c = newBrokerId,
                Status__c = 'Active',
                Listing_Start_Date__c = eff,
                Last_Check_In_Date__c = eff,
                Listing_End_Date__c = null,
                Reason_Ended__c = null,
                Replacement_Notes__c = null
            );
        } catch (DmlException e) {
            Database.rollback(sp);
            throw e;
        }
        return assignmentId;
    }
}
