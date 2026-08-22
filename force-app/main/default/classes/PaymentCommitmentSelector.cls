/**
 * Selector for `Payment_Commitment__c` - promises to pay and payment-plan instalments, a
 * master-detail child of `Case`.
 *
 * MODE - `WITH SYSTEM_MODE` on every method; all are automation-path reads inside the nightly batch.
 *
 * SHARING - ESCAPED via `SweepReads`. `Payment_Commitment__c` OWD is `ControlledByParent` (verified
 * 2026-08-22 via `EntityDefinition`), which means its visibility is EXACTLY its parent Case's - and
 * `Case` OWD is Private. So the sharing hazard is inherited wholesale from `CaseSelector`: the
 * nightly job runs as one principal while commitments hang off Cases owned by many property
 * managers, and a sharing-filtered sweep would see only the commitments under Cases the running
 * principal happens to own.
 *
 * The consequence is the FSD 5.9.7 row 4 alert (a promise-to-pay date passing unpaid) simply never
 * firing for most tenants, with no error anywhere. Unlike the duplicate-Case guard this fails
 * CLOSED - a missed alert, not a corrupted data set - but it is still invisible, so the escape is
 * applied for the same reason and confined the same way.
 *
 * @see PaymentCommitmentService.cls (the only caller)
 */
public with sharing class PaymentCommitmentSelector {

    /** `Status__c` values (restricted picklist). */
    @TestVisible
    private static final String STATUS_OPEN = 'Open';

    /**
     * Open commitments whose due date has passed - the breach sweep (FSD 5.9.7 rows 4 and 5).
     *
     * @param asOf    The date to measure against; passed in so one run evaluates against a single
     *                date rather than straddling midnight mid-chunk.
     * @param maxRows Hard row cap so an unbounded backlog cannot blow the heap.
     * @return Open, overdue commitments with their parent Case fields, oldest due date first. Never
     *         null.
     * @example
     * List&lt;Payment_Commitment__c&gt; due =
     *     PaymentCommitmentSelector.selectOpenDueOnOrBefore(Date.today(), 2000);
     */
    public static List<Payment_Commitment__c> selectOpenDueOnOrBefore(Date asOf, Integer maxRows) {
        if (asOf == null) {
            return new List<Payment_Commitment__c>();
        }
        return new SweepReads().openDueOnOrBefore(asOf, (maxRows == null) ? 2000 : maxRows);
    }

    /**
     * Commitments under a set of Cases, whatever their status.
     *
     * @param caseIds Parent Case Ids; null/empty safe.
     * @return Matching commitments; never null.
     */
    public static List<Payment_Commitment__c> selectByCaseIds(Set<Id> caseIds) {
        if (caseIds == null || caseIds.isEmpty()) {
            return new List<Payment_Commitment__c>();
        }
        return new SweepReads().byCaseIds(caseIds);
    }

    /**
     * The sharing escape. `ControlledByParent` inherits `Case`'s Private OWD, so this is the same
     * hazard `CaseSelector` documents, one level down.
     */
    private without sharing class SweepReads {

        private List<Payment_Commitment__c> openDueOnOrBefore(Date asOf, Integer maxRows) {
            String open = STATUS_OPEN;
            return [
                SELECT Id, Name, Case__c, Commitment_Type__c, Promised_Amount__c, Due_Date__c,
                       Instalment_Number__c, Status__c, Breached_Date__c, Breach_Notified__c,
                       Case__r.Id, Case__r.Status, Case__r.IsClosed, Case__r.OwnerId,
                       Case__r.Yardi_AR_Id__c, Case__r.Reopened_Count__c
                FROM Payment_Commitment__c
                WHERE Status__c = :open
                  AND Due_Date__c != NULL
                  AND Due_Date__c <= :asOf
                WITH SYSTEM_MODE
                ORDER BY Due_Date__c ASC, Id ASC
                LIMIT :maxRows
            ];
        }

        private List<Payment_Commitment__c> byCaseIds(Set<Id> caseIds) {
            return [
                SELECT Id, Case__c, Commitment_Type__c, Promised_Amount__c, Due_Date__c,
                       Instalment_Number__c, Status__c, Breached_Date__c, Breach_Notified__c
                FROM Payment_Commitment__c
                WHERE Case__c IN :caseIds
                WITH SYSTEM_MODE
                ORDER BY Due_Date__c ASC, Id ASC
            ];
        }
    }
}
