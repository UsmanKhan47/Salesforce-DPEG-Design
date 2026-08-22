/**
 * FSD 5.9.7 ROWS 4 AND 5 - the promise-to-pay breach sweep, and the missed instalment that REOPENS a
 * resolved Case.
 *
 * LAYER - Service. Calls `PaymentCommitmentSelector` and `CaseSelector` for data; owns the
 * commitment and Case DML. No inline SOQL.
 *
 * === WHY THIS RUNS ONCE PER RUN, NOT ONCE PER CHUNK ===
 * A breached commitment is DATE-driven, not feed-driven: it becomes breached because a date passed,
 * whether or not that tenant appeared in tonight's feed. Running it inside the batch's `execute`
 * would both re-query the same overdue set for every chunk and MISS any tenant absent from the feed.
 * It is therefore invoked once from `finish()`. FSD 5.9.6 describes ONE nightly job, so this does not
 * get its own schedulable.
 *
 * === `Breach_Notified__c` IS A ONE-WAY MARKER AND IT IS THE WHOLE IDEMPOTENCY DESIGN ===
 * Without it, a commitment that breached in March alerts every single night until somebody closes the
 * Case - which is precisely how a team learns to ignore the alerts, the failure FSD 5.9.7 is written
 * to prevent. Stamped only after a successful send, per the send-first-stamp-second rule: a swallowed
 * send failure that still stamped would lose the alert forever and silently.
 *
 * === REOPENING IS ADDITIVE, NEVER DESTRUCTIVE ===
 * A missed instalment on a Case the sync already resolved reopens it by writing Status and
 * incrementing `Reopened_Count__c` on a FRESH sObject. Comments, prior commitments and field history
 * are untouched - the timeline of a tenant who broke a payment plan is the single most useful thing
 * on the record.
 *
 * @see PaymentCommitmentSelector.cls (the sharing-proof sweep read)
 * @see DelinquencyCaseService.cls    (the feed-driven half of the lifecycle)
 */
public with sharing class PaymentCommitmentService {

    @TestVisible private static final String GROUP_PM = 'DPEG_Property_Mgmt_Team';
    @TestVisible private static final String NOTIF_TYPE = 'Property_Mgmt_Update';
    @TestVisible private static final String STATUS_BREACHED = 'Breached';
    @TestVisible private static final String TYPE_INSTALMENT = 'Payment Plan Instalment';
    /** `Case.Status` used when a broken commitment reopens a resolved Case. */
    @TestVisible private static final String STATUS_PM_FOLLOW_UP = 'PM Follow-Up';
    /** Row cap on the sweep, so an unattended backlog cannot blow the heap. */
    @TestVisible private static final Integer MAX_SWEEP_ROWS = 2000;

    /** What the sweep did. */
    public class SweepResult {
        /** Commitments moved to Breached. */
        public Integer breached = 0;
        /** Resolved Cases reopened by a missed instalment. */
        public Integer reopened = 0;
    }

    /**
     * Sweep every open commitment whose due date has passed.
     *
     * @param asOf The date to measure against, captured ONCE by the caller. Passing it in rather
     *             than calling `Date.today()` per record is what stops two commitments in one run
     *             straddling midnight and disagreeing about whether they are overdue.
     * @return Counters; never null.
     * @example
     * PaymentCommitmentService.SweepResult r = PaymentCommitmentService.sweepBreaches(Date.today());
     */
    public static SweepResult sweepBreaches(Date asOf) {
        SweepResult result = new SweepResult();
        if (asOf == null) {
            return result;
        }
        List<Payment_Commitment__c> overdue =
            PaymentCommitmentSelector.selectOpenDueOnOrBefore(asOf, MAX_SWEEP_ROWS);
        if (overdue.isEmpty()) {
            return result;
        }

        List<Payment_Commitment__c> commitmentUpdates = new List<Payment_Commitment__c>();
        Map<Id, Case> caseUpdatesById = new Map<Id, Case>();
        List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
        List<Payment_Commitment__c> notifiedCommitments = new List<Payment_Commitment__c>();

        for (Payment_Commitment__c commitment : overdue) {
            Payment_Commitment__c commitmentUpdate = new Payment_Commitment__c(Id = commitment.Id);
            commitmentUpdate.Status__c = STATUS_BREACHED;
            commitmentUpdate.Breached_Date__c = asOf;
            commitmentUpdates.add(commitmentUpdate);
            result.breached++;

            Boolean isInstalment = commitment.Commitment_Type__c == TYPE_INSTALMENT;
            Boolean parentResolved = commitment.Case__r != null && commitment.Case__r.IsClosed == true;

            // FSD 5.9.7 row 5: a missed INSTALMENT reopens a Case the sync already resolved.
            if (isInstalment && parentResolved && commitment.Case__c != null
                    && !caseUpdatesById.containsKey(commitment.Case__c)) {
                Decimal priorCount = commitment.Case__r.Reopened_Count__c;
                Case reopen = new Case(Id = commitment.Case__c);
                reopen.Status = STATUS_PM_FOLLOW_UP;
                reopen.Auto_Closed_By_Sync__c = false;
                reopen.Reopened_Count__c = ((priorCount == null) ? 0 : priorCount.intValue()) + 1;
                caseUpdatesById.put(commitment.Case__c, reopen);
                result.reopened++;
            }

            // One-way marker: only alert on a breach nobody has been told about yet.
            if (commitment.Breach_Notified__c != true && commitment.Case__c != null) {
                notifiedCommitments.add(commitment);
                requests.add(buildRequest(
                    isInstalment ? 'Payment plan instalment missed' : 'Promise to pay breached',
                    breachBody(commitment, isInstalment),
                    commitment.Case__c));
            }
        }

        // SEND FIRST. Then stamp only the markers whose alert actually went out.
        List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);
        Map<Id, Payment_Commitment__c> updatesById = new Map<Id, Payment_Commitment__c>();
        for (Payment_Commitment__c commitmentUpdate : commitmentUpdates) {
            updatesById.put(commitmentUpdate.Id, commitmentUpdate);
        }
        for (Integer i = 0; i < notifiedCommitments.size(); i++) {
            if (i < outcomes.size() && outcomes[i] == true) {
                Payment_Commitment__c commitmentUpdate = updatesById.get(notifiedCommitments[i].Id);
                if (commitmentUpdate != null) {
                    commitmentUpdate.Breach_Notified__c = true;
                }
            }
        }

        CommitmentWrites writes = new CommitmentWrites();
        writes.updateCommitments(commitmentUpdates);
        if (!caseUpdatesById.isEmpty()) {
            writes.updateCases(caseUpdatesById.values());
        }
        return result;
    }

    /**
     * @param title    Notification title.
     * @param body     Notification body.
     * @param targetId Case the alert links to.
     * @return The request, under the PM notification type.
     */
    private static GroupNotifier.Request buildRequest(String title, String body, Id targetId) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = GROUP_PM;
        request.title = title;
        request.body = body;
        request.targetRecordId = targetId;
        request.notificationType = NOTIF_TYPE;
        return request;
    }

    /**
     * @param commitment   The breached commitment.
     * @param isInstalment Whether it is a payment-plan instalment.
     * @return Body text for the breach alert.
     */
    private static String breachBody(Payment_Commitment__c commitment, Boolean isInstalment) {
        String label = isInstalment
            ? ('Instalment ' + commitment.Instalment_Number__c)
            : 'Promise to pay';
        return label + ' of ' + commitment.Promised_Amount__c + ' was due '
            + commitment.Due_Date__c + ' and has not been met.';
    }

    /**
     * THE WRITES, ESCAPED. `Payment_Commitment__c` is `ControlledByParent` of `Case`, whose OWD is
     * Private, so both writes hit records the scheduling principal does not own.
     * `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing; without the escape the breach
     * stamp is refused, `allOrNone = false` swallows the refusal, and the same breach alerts every
     * night forever - which is the exact failure `Breach_Notified__c` exists to prevent.
     */
    private without sharing class CommitmentWrites {

        private void updateCommitments(List<Payment_Commitment__c> commitments) {
            if (commitments == null || commitments.isEmpty()) {
                return;
            }
            Database.update(commitments, false, AccessLevel.SYSTEM_MODE);
        }

        private void updateCases(List<Case> cases) {
            if (cases == null || cases.isEmpty()) {
                return;
            }
            Database.update(cases, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
