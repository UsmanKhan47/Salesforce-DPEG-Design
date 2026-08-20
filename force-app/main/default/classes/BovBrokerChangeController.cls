/**
 * Backs `c/bovBrokerChangeHistory` — the read-only card on the Disposition record page listing
 * every broker replacement recorded against that sale. Added 2026-08-20 with Tranche 2 Workstream B
 * (design D4.6).
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md): one `@AuraEnabled`
 * read, all SOQL delegated to `BovBrokerChangeSelector`, no business logic. The rows it returns are
 * written by `BovSubmissionService.replaceSelectedBroker` and by nothing else — this class exposes
 * no write, deliberately, because the object is an APPEND-ONLY LOG whose only legitimate author is
 * the replacement it records.
 *
 * ── 🔴 WHY THIS IS APEX AND NOT `getRelatedListRecords` ──────────────────────
 * ARCHITECTURE.md §5 puts LDS first and this diverges, so the divergence is argued rather than
 * assumed. The card needs `Logged_By__r.Name` — a SPANNING field one hop off a lookup — plus a
 * deterministic two-key sort (`Entry_DateTime__c DESC, Name DESC`) whose tie-break is load-bearing
 * for rows written in the same second. `getRelatedListRecords` returns what the related list
 * LAYOUT defines, sorts on one column, and does not express a spanning name without that field
 * being on the layout — so the LDS route would make the card's contents a function of a layout
 * somebody can edit in App Builder, and would silently lose the tie-break. The Apex route makes
 * both explicit and testable. (`getRecord`-style adapters do not apply at all: the anchor is a
 * PARENT Id and the payload is a child collection.)
 *
 * ── ONE FIXED, GENERIC FAILURE MESSAGE ──────────────────────────────────────
 * ⚠ AND THE CLIENT MUST NOT SHOW IT AS AN EMPTY STATE. An empty list and a failed read mean
 * completely different things on an audit log: "no broker was ever replaced" is a fact about the
 * sale, "we could not read the log" is a fact about the reader. `c/bovBrokerChangeHistory` renders
 * them as two distinct, non-alarming states for exactly that reason — see that component's header.
 */
public with sharing class BovBrokerChangeController {

    /**
     * One recorded broker replacement, flattened for the client.
     *
     * ⚠ MEMBER NAMES ARE THE CLIENT'S CONTRACT AND ARE THE SILENT HALF OF THIS DTO. A renamed
     * member does not fail a deploy, does not fail Apex tests, and does not throw in the browser —
     * the card simply renders blanks. Rename one only together with the LWC and its Jest suite.
     */
    public class ChangeRow {
        /** BOV_Broker_Change__c Id — the `key` for the client's iteration, and nothing else. */
        @AuraEnabled public String id;
        /** The `BBC-0000` AutoNumber. Displayed, and also the selector's sort tie-break. */
        @AuraEnabled public String changeNumber;
        /**
         * Stamped snapshot of the firm that was replaced. NULL when there was no incumbent —
         * "replace" degrading to "appoint" is a normal state (see `BovSubmissionService`), and the
         * client renders that case as an appointment rather than as missing data.
         */
        @AuraEnabled public String outgoingBrokerFirm;
        /** Stamped snapshot of the firm appointed. Always populated on a well-formed row. */
        @AuraEnabled public String incomingBrokerFirm;
        /** `Reason__c` — a restricted picklist value, required by the service that writes it. */
        @AuraEnabled public String reason;
        /** Free text; frequently null, and null is not an error. */
        @AuraEnabled public String notes;
        /** `Entry_DateTime__c` — the write time, which IS the event time for this object. */
        @AuraEnabled public Datetime entryDateTime;
        /** `Logged_By__r.Name`. Null only if the User lookup was somehow left blank. */
        @AuraEnabled public String loggedBy;
    }

    // Fixed, generic user-safe message (ARCHITECTURE.md §5). Never interpolate platform text or
    // exception detail into it — the detail goes to the debug log (admin-only) and the user gets
    // this. A `WITH USER_MODE` FLS denial on this 2026-08-20 object surfaces here rather than as a
    // raw QueryException naming a column.
    private static final String READ_FAILURE_MESSAGE =
        'The broker change history could not be loaded. Refresh the page or contact your '
        + 'administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * Every recorded broker change for one disposition, newest first.
     *
     * 🔴 AN EMPTY LIST IS A SUCCESSFUL ANSWER AND MUST NEVER BECOME AN EXCEPTION. Most dispositions
     * never replace a broker, so empty is the COMMON case here — commoner than any populated one.
     * Turning it into a throw (or letting the client treat it as one) would put a permanent error
     * on the majority of disposition record pages.
     *
     * @param dispositionId the Disposition__c whose history to read; null returns an empty list
     * @return ordered ChangeRow list, newest first; empty when there are no recorded changes
     * @throws AuraHandledException — with a fixed generic message — when the read itself fails
     * @example
     * List&lt;ChangeRow&gt; rows = BovBrokerChangeController.getHistory(dispositionId);
     */
    @AuraEnabled(cacheable=true)
    public static List<ChangeRow> getHistory(Id dispositionId) {
        try {
            List<ChangeRow> rows = new List<ChangeRow>();
            for (BOV_Broker_Change__c change
                    : BovBrokerChangeSelector.selectByDispositionId(dispositionId)) {
                ChangeRow row = new ChangeRow();
                row.id = change.Id;
                row.changeNumber = change.Name;
                row.outgoingBrokerFirm = change.Outgoing_Broker_Firm__c;
                row.incomingBrokerFirm = change.Incoming_Broker_Firm__c;
                row.reason = change.Reason__c;
                row.notes = change.Notes__c;
                row.entryDateTime = change.Entry_DateTime__c;
                row.loggedBy = change.Logged_By__r == null ? null : change.Logged_By__r.Name;
                rows.add(row);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovBrokerChangeController.getHistory on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
