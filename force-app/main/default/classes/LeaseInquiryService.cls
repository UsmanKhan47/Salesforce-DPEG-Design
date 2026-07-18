/**
 * Service for the Lease Activity Tracker's append-an-update workflow.
 *
 * Owns the business logic behind LeaseInquiryController.addUpdate (P6 controller
 * thinning): the append of a Lease_Activity__c log entry, the parent
 * Lease_Inquiry__c Ball-in-Court / Stage-advance update, the optional reminder
 * Task, and the savepoint / rollback orchestration that keeps all three DMLs one
 * unit of work. Per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2,
 * this DML + transaction management is Service work, not Controller work.
 *
 * All SOQL is delegated to LeaseInquirySelector — this service holds no inline
 * SOQL. It throws typed exceptions (LeaseInquiryException for validation, and the
 * raw platform DmlException after rolling back). The AuraHandledException boundary
 * lives in the controller, NOT here (ARCHITECTURE.md §5): a service must not know
 * about the LWC transport, so it never constructs an AuraHandledException.
 *
 * @see force-app/main/default/classes/LeaseInquiryController.cls (thin caller)
 * @see force-app/main/default/classes/LeaseInquirySelector.cls (all SOQL)
 */
public with sharing class LeaseInquiryService {

    /**
     * The Lease Inquiry stage sequence, in advance order. Single source of truth:
     * the controller's read methods (getLog / getPipelineByStage) reference this,
     * and addUpdate advances one step along it. TestVisible so both the controller
     * and its tests can rely on the same ordering rather than a duplicated copy.
     */
    @TestVisible
    public static final List<String> STAGES = new List<String>{
        'Inquiry Received', 'LOI Received', 'LOI Negotiation', 'LOI Signed', 'Lease Drafting', 'Lease Ready', 'Lease Signed'
    };

    // Task.Subject is a 255-char combobox (verified against the org: 255 inserts, 256 fails
    // with 'Subject: data value too large'). The composer's max-length="255" is a
    // client-side control only and binds no other caller, so the guard lives server-side.
    @TestVisible
    private static final Integer REMINDER_NAME_MAX = 255;

    /**
     * Typed validation failure. Carries a user-safe message that the controller
     * surfaces unchanged through its AuraHandledException boundary. This is NOT an
     * AuraHandledException: keeping the transport type at the controller lets the
     * service stay UI-agnostic (also callable from Flow / Apex / a future caller).
     */
    public class LeaseInquiryException extends Exception {}

    /**
     * Appends a log entry, optionally sets the parent's Ball in Court / advances the Stage,
     * and optionally raises a standard Task as a reminder against the INQUIRY.
     *
     * The reminder Task targets the Lease Inquiry (WhatId) because Lease_Inquiry__c has
     * activities enabled and Lease_Activity__c does not — the log entry itself cannot carry
     * a Task. Only Subject / ActivityDate / OwnerId / WhatId are set: IsReminderSet and
     * ReminderDateTime are deliberately left unset (no bell popup was requested), and
     * Status / Priority / Description are left to their field defaults.
     *
     * The log entry, the parent update and the reminder Task are one unit of work. A
     * validation failure inside the transaction, or a platform DmlException, rolls the
     * whole set back via the savepoint before propagating — otherwise the controller's
     * conversion to AuraHandledException at the LWC boundary (ARCHITECTURE.md §5) would
     * suppress the platform's automatic rollback and leave the Lease_Activity__c committed
     * without its Task.
     *
     * @param inquiryId    the Lease Inquiry being logged against; required
     * @param details      what changed; required, trimmed onto Details__c
     * @param ball         who the ball is in court with next; sets the parent when non-blank
     * @param advance      true to move the parent to the next Stage (ignored when closed)
     * @param reminder     true to create the reminder Task; null/false creates nothing
     * @param reminderName reminder Task Subject; required when reminder is true
     * @param reminderDate reminder Task ActivityDate (Due Date, date-only); required when reminder is true
     * @return the inquiry Id, so the caller can refresh the record
     * @throws LeaseInquiryException on invalid input (validation failures are rolled back)
     * @throws System.DmlException   on a platform save failure (already rolled back here)
     */
    public static Id addUpdate(Id inquiryId, String details, String ball, Boolean advance,
                               Boolean reminder, String reminderName, Date reminderDate) {
        if (inquiryId == null) {
            throw new LeaseInquiryException('No inquiry specified.');
        }
        if (String.isBlank(details)) {
            throw new LeaseInquiryException('Enter what changed before saving.');
        }
        // Server-side length guard. Without it, a caller other than the composer (Flow, API,
        // a future component) that passes an over-length name fails on the Task insert with
        // STRING_TOO_LONG and gets the controller's generic DML message — a string that names
        // nothing the user can act on. Measured on the TRIMMED value, because reminderName.trim()
        // is what the Task insert below actually stores: a 250-char name padded to 260 with
        // whitespace fits, and must not be rejected here.
        if (reminder == true && reminderName != null
                && reminderName.trim().length() > REMINDER_NAME_MAX) {
            throw new LeaseInquiryException('The reminder name is too long. Shorten it to '
                + REMINDER_NAME_MAX + ' characters or fewer.');
        }
        Lease_Inquiry__c inq = LeaseInquirySelector.selectStageStatusById(inquiryId);
        Boolean closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';

        Savepoint sp = Database.setSavepoint();
        try {
            // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp for this log entry.
            Datetime entryStamp = System.now();
            insert new Lease_Activity__c(
                Lease_Inquiry__c = inquiryId,
                Details__c = details.trim(),
                Ball_In_Court__c = ball,
                Logged_By__c = UserInfo.getUserId(),
                Entry_DateTime__c = entryStamp
            );

            Lease_Inquiry__c upd = new Lease_Inquiry__c(Id = inquiryId);
            Boolean touched = false;
            if (String.isNotBlank(ball)) {
                upd.Ball_In_Court__c = ball;
                touched = true;
            }
            if (advance == true && !closed) {
                Integer idx = STAGES.indexOf(inq.Stage__c);
                if (idx >= 0 && idx < STAGES.size() - 1) {
                    upd.Stage__c = STAGES[idx + 1];
                    touched = true;
                }
            }
            if (touched) {
                update upd;
            }

            if (reminder == true) {
                // Backstops the composer's client-side validation; it does not replace it.
                if (String.isBlank(reminderName) || reminderDate == null) {
                    throw new LeaseInquiryException('Add a reminder name and due date, or clear the reminder.');
                }
                insert new Task(
                    Subject = reminderName.trim(),
                    ActivityDate = reminderDate,
                    OwnerId = UserInfo.getUserId(),
                    WhatId = inquiryId
                );
            }
        } catch (LeaseInquiryException e) {
            // Validation failure raised after some DML already committed — roll it back,
            // then surface the typed exception unchanged for the controller to map.
            Database.rollback(sp);
            throw e;
        } catch (DmlException e) {
            // Roll back the committed work, then re-throw the raw platform exception. The
            // controller owns the user-safe/user-visible split (ARCHITECTURE.md §5): it logs
            // the detail admin-only and surfaces a fixed generic message. The service does
            // not decide transport-layer messaging.
            Database.rollback(sp);
            throw e;
        }
        return inquiryId;
    }
}
