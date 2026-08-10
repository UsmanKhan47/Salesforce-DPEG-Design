/**
 * Backs the psaVersionLog LWC on the Opportunity Contract tab and the Contract Review
 * record page. Reads the PSA draft/counter history (PSA_Version__c children of the
 * Contract Review) and appends a new version, which also derives and stamps the parent's
 * Ball_In_Court__c and Latest_Version__c.
 *
 * ⚠ TWO CORRECTIONS TO THIS PARAGRAPH, BOTH MADE IN PLACE RATHER THAN LEFT TO MISLEAD.
 * (1) It used to claim the save also derives `Negotiation_Status__c`. That STOPPED on 2026-08-05
 * (user decision) — the two counter values were removed from the restricted picklist and the
 * status is now moved only by the deal driver through Advance Stage; PsaVersionService's header
 * carries the full note. (2) Since 2026-08-10 `direction` is a ROLE, not a label: the service
 * DERIVES the stored token from the parent's side of the deal ('Seller' on a purchase, 'Buyer' on
 * a sale), so this controller must keep passing the picker's token through UNCHANGED. Do not
 * "normalise" it here — that would put the decision back on the client, which is the defect the
 * 3C fix pass closed.
 *
 * All SOQL is delegated to PsaVersionSelector and ContractReviewSelector per ARCHITECTURE.md §2 —
 * this controller holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The append + Contract-Review-stamp DML and the
 * version business rules live in PsaVersionService per .claude/rules/apex-layering-rule.md;
 * saveVersion() only marshals input, delegates, and maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). Every @AuraEnabled method
 * (read and write) maps failures the same way: platform detail goes to the debug log
 * (admin-only) and the user gets a message. A user-actionable rule violation
 * (PsaVersionException) is surfaced verbatim; an unexpected platform failure gets a fixed,
 * generic message with no exception detail concatenated into it.
 */
public with sharing class PsaVersionController {

    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This PSA version could not be saved. Refresh the page and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<PSA_Version__c> getVersions(Id contractReviewId) {
        try {
            // SOQL and the null guard live in PsaVersionSelector per ARCHITECTURE.md §2;
            // the selector preserves the empty-list-on-null contract.
            return PsaVersionSelector.selectByContractReviewId(contractReviewId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PsaVersionController.getVersions on ' + contractReviewId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static void saveVersion(Id contractReviewId, String direction, Date versionDate,
                                   String summary, String documentUrl) {
        try {
            PsaVersionService.saveVersion(contractReviewId, direction, versionDate, summary, documentUrl);
        } catch (PsaVersionService.PsaVersionException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PsaVersionController.saveVersion on Contract Review '
                + contractReviewId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
