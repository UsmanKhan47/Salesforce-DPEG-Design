/**
 * Backs the BOV broker-outreach card on the Disposition record page (`c/bovOutreach`,
 * `c/bovComparisonMatrix`) and, since 2026-08-19, the broker-replacement modal
 * (`c/bovReplaceBrokerModal`).
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). All SOQL is
 * delegated to `BovSubmissionSelector` / `DispositionSelector` / `NdaSelector`, and the only WRITE
 * this class exposes delegates wholly to `BovSubmissionService` — the exclusivity swap, the
 * approval-status revocation, the savepoint and the parent stamp all live there.
 *
 * ⚠ TWO READ METHODS AND ONE WRITE METHOD, AND THEY DO NOT SHARE A FAILURE MESSAGE. A failed read
 * degrades a card; a failed write leaves the user unsure whether a broker changed. Their generic
 * messages are deliberately different strings for that reason.
 */
public with sharing class BovController {

    public class BovRow {
        @AuraEnabled public String id;
        /**
         * `BOV_Submission__c.Name` — the record's own auto-number, added 2026-08-21.
         *
         * ⚠ IT IS NOT SHOWN IN THE MATRIX AND THAT IS NOT AN OVERSIGHT. It exists for the
         * Select/Replace Broker picker, where each option is one line of text and this org holds
         * SIX broker Contacts that exist twice with an identical name AND an identical firm — so
         * firm + contact cannot tell two of those options apart and the auto-number can. Adding a
         * column for it would spend matrix width on a value nobody reads on that surface.
         */
        @AuraEnabled public String name;
        @AuraEnabled public String brokerFirm;
        @AuraEnabled public String contactName;
        @AuraEnabled public Decimal bovAmount;
        @AuraEnabled public Decimal commissionRate;
        @AuraEnabled public Integer daysToMarket;
        @AuraEnabled public Decimal histSuccessRate;
        @AuraEnabled public Decimal capRate;
        /**
         * `BOV_Submission__c.BOV_Score__c` — a Number(5,2) FORMULA field (recreated
         * 2026-08-22, manifest/bov-score-formula-conversion/), so it carries up to 2
         * decimal places (e.g. 68.81). 🔴 THIS FIELD WAS `Integer` UNTIL THIS SAME
         * CHANGE — a plain `Integer` here would have silently truncated every score
         * (82.95 rendering as 82 in the matrix), which is a real display defect, not a
         * rounding nicety: the whole point of carrying 2 decimal places in the formula's
         * `precision`/`scale` is to distinguish two brokers a whole point apart from two
         * a hundredth of a point apart. Widened to `Decimal` so `getSubmissions` can pass
         * the formula's value straight through without truncating it. `c/bovComparisonMatrix`
         * was updated in the same change to stop assuming an integer.
         */
        @AuraEnabled public Decimal bovScore;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isSelected;
    }

    public class OutreachSummary {
        @AuraEnabled public String assetName;
        @AuraEnabled public Date packageSent;
        @AuraEnabled public Date submissionDeadline;
        @AuraEnabled public Integer responsesReceived;
        @AuraEnabled public Integer brokersContacted;
        @AuraEnabled public String selectedBroker;
        @AuraEnabled public Boolean matrixGenerated;
        /**
         * Status__c of the disposition's most recent NDA__c, or NULL when there is no NDA
         * yet — which is the normal state for most dispositions and is NOT an error.
         * lwc/bovOutreach renders null as "No NDA".
         *
         * ⚠ Null is ALSO what a failed NDA read degrades to (see getOutreachSummary). The
         * two are deliberately indistinguishable to the client: both mean "we cannot show
         * you a signed NDA", and neither is worth a second field or a second pill state.
         */
        @AuraEnabled public String ndaStatus;
    }

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the
    // debug log (admin-only) and the user gets this. A deleted / invalid Disposition Id
    // surfaces here as this message rather than a raw QueryException.
    private static final String READ_FAILURE_MESSAGE =
        'The BOV information could not be loaded. Refresh the page or contact your administrator.';

    // Fixed, generic user-safe message for an UNEXPECTED replacement failure. Deliberately distinct
    // from READ_FAILURE_MESSAGE: the user needs to know a WRITE did not happen, not that a card did
    // not load. Every foreseeable refusal (not this disposition's submission, already selected,
    // record locked, validation rule) arrives as a BovSubmissionException and is surfaced verbatim
    // instead — this message is only for the residue.
    private static final String REPLACE_FAILURE_MESSAGE =
        'The broker could not be replaced. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<BovRow> getSubmissions(Id dispositionId) {
        try {
            List<BOV_Submission__c> subs = BovSubmissionSelector.selectByDispositionId(dispositionId);
            List<BovRow> rows = new List<BovRow>();
            for (BOV_Submission__c s : subs) {
                BovRow r = new BovRow();
                r.id = s.Id;
                r.name = s.Name;
                r.brokerFirm = s.Broker_Firm__c;
                r.contactName = s.Contact_Name__c;
                r.bovAmount = s.BOV_Amount__c;
                r.commissionRate = s.Commission_Rate__c;
                r.daysToMarket = s.Days_To_Market__c != null ? s.Days_To_Market__c.intValue() : null;
                r.histSuccessRate = s.Hist_Success_Rate__c;
                r.capRate = s.Cap_Rate__c;
                // BOV_Score__c is a Number(5,2) formula (see BovRow.bovScore's own comment) —
                // passed straight through, not truncated with .intValue() as the old Integer-typed
                // field required.
                r.bovScore = s.BOV_Score__c;
                r.status = s.Submission_Status__c;
                r.isSelected = 'Selected'.equals(s.Submission_Status__c);
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController.getSubmissions on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static OutreachSummary getOutreachSummary(Id dispositionId) {
        try {
            Disposition__c d = DispositionSelector.selectOutreachById(dispositionId);
            OutreachSummary s = new OutreachSummary();
            s.assetName = d.Property_Asset__r != null ? d.Property_Asset__r.Name : '';
            s.packageSent = d.Package_Sent__c;
            s.submissionDeadline = d.Submission_Deadline__c;
            s.responsesReceived = d.Responses_Received__c != null ? d.Responses_Received__c.intValue() : 0;
            s.brokersContacted = d.Brokers_Contacted__c != null ? d.Brokers_Contacted__c.intValue() : 0;
            s.selectedBroker = d.Selected_Broker__c;
            s.matrixGenerated = s.responsesReceived >= 3;
            s.ndaStatus = readNdaStatusFailSoft(dispositionId);
            return s;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController.getOutreachSummary on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Replaces the disposition's appointed broker with another BOV submission — the server half of
     * `c/bovReplaceBrokerModal` (DEV-6).
     *
     * ⚠ THE THREE CATCHES AND THEIR ORDER MIRROR `DispositionApprovalController`, for the same
     * reasons: a permission denial must not be masked as a system failure (so it is caught FIRST
     * and surfaced verbatim); every user-actionable refusal — including a platform block's own
     * "this record is locked" text, which is the only thing naming the pending approval — arrives
     * as `BovSubmissionException` and is surfaced verbatim; anything else is masked.
     *
     * 🔴 THE RETURNED MESSAGE WARNS THAT A FRESH APPROVAL IS REQUIRED, and the client must show it.
     * Replacing the broker CLEARS both submissions' `Approval_Status__c`, so the sale is
     * deliberately left without an approved broker until someone re-submits. A toast that says only
     * "saved" would hide the single most important consequence of the action.
     *
     * ⚠ `reason` AND `notes` (2026-08-20, Tranche 2 Workstream B / design D4.4) ARE PASSED STRAIGHT
     * THROUGH AND NOT VALIDATED HERE. A blank reason is refused by the SERVICE, which owns that
     * rule and owns the sentence describing it; validating it a second time in this class would put
     * a copy of a business rule in the layer that is supposed to have none. The three catches, their
     * order and both fixed generic messages are unchanged by that addition — a missing reason
     * arrives as a `BovSubmissionException` and is therefore surfaced verbatim through the SECOND
     * catch, exactly like every other user-actionable refusal.
     *
     * @param dispositionId   the Disposition__c whose broker is being replaced
     * @param newSubmissionId the BOV_Submission__c to appoint
     * @param reason          a BOV_Broker_Change__c.Reason__c picklist value (required by the
     *                        service; the client sources the value set from getPicklistValues)
     * @param notes           optional free text recorded on the history row
     * @return an authored confirmation including the fresh-approval warning
     * @throws AuraHandledException on denial (verbatim), on a user-actionable refusal (verbatim),
     *         or — with a fixed generic message — on an unexpected failure
     */
    @AuraEnabled
    public static String replaceSelectedBroker(Id dispositionId, Id newSubmissionId,
                                               String reason, String notes) {
        try {
            return BovSubmissionService.replaceSelectedBroker(
                dispositionId, newSubmissionId, reason, notes);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (BovSubmissionService.BovSubmissionException e) {
            System.debug(LoggingLevel.INFO, 'BovController.replaceSelectedBroker refused on '
                + dispositionId + '/' + newSubmissionId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController.replaceSelectedBroker on '
                + dispositionId + '/' + newSubmissionId + ': ' + e.getMessage() + ' | '
                + e.getStackTraceString());
            throw ahe(REPLACE_FAILURE_MESSAGE);
        }
    }

    /**
     * The disposition's latest NDA status, or null when there is none — or when the read
     * itself fails.
     *
     * ⚠ THIS BLOCK WAS ORPHANED (code review W1, 2026-08-20): it had drifted up to sit
     * above replaceSelectedBroker, which has its own ApexDoc, leaving THIS method
     * undocumented and the reader of that one facing two headers. Moved back verbatim —
     * NOT rewritten, and neither method's behaviour, catch structure or message strings
     * were touched.
     *
     * 🔴 THE NARROW TRY/CATCH IS THE ENTIRE POINT OF THIS METHOD AND MUST NOT BE FOLDED
     * BACK INTO getOutreachSummary's OUTER CATCH. NDA__c is granted to the disposition
     * personas by DPEG_Disposition_View / DPEG_Disposition_Edit (Gate 1 Q7), but a
     * permission set deploy REPLACES its whole grant list, so that grant is one unrelated
     * redeploy away from vanishing — and a `WITH USER_MODE` read of an object the running
     * user cannot see THROWS rather than returning empty. Inside the outer catch that
     * QueryException becomes READ_FAILURE_MESSAGE and the ENTIRE BOV Outreach tile
     * disappears for every disposition-only user. Degrading one pill is strictly better
     * than blanking the whole card, and both worse than the hard-coded "Signed" this
     * replaced.
     *
     * ⚠ The grant and this catch are BOTH required — Gate 1 Q7 says "both, not either".
     * This is defence in depth, not a substitute for provisioning NDA__c.
     *
     * catch (Exception), not catch (QueryException): the failure mode being defended
     * against is an FLS/CRUD denial, which the platform reports as a QueryException today,
     * but nothing about this method's contract depends on the exception's type and a
     * narrower catch would only re-open the tile-blanking path for a neighbouring failure.
     *
     * @param dispositionId the disposition whose NDA to read
     * @return the latest NDA's Status__c; null when there is no NDA or the read failed
     */
    private static String readNdaStatusFailSoft(Id dispositionId) {
        try {
            NDA__c nda = NdaSelector.selectLatestByDispositionId(dispositionId);
            return (nda == null) ? null : nda.Status__c;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController NDA status read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            return null;
        }
    }
}