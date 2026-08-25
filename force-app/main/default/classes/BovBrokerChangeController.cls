/**
 * Backs `c/bovBrokerChangeHistory` — the read-only "Broker Selection" card on the Disposition
 * record page. Added 2026-08-20 with Tranche 2 Workstream B (design D4.6).
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md): one `@AuraEnabled`
 * read, all SOQL delegated to selectors, no business logic. The change rows it returns are
 * written by `BovSubmissionService.replaceSelectedBroker` and by nothing else — this class exposes
 * no write, deliberately, because that object is an APPEND-ONLY LOG whose only legitimate author is
 * the replacement it records.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT RETURNS TWO LISTS, NOT ONE, SINCE 2026-08-25 — AND THAT IS THE WHOLE POINT OF THE CHANGE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `getHistory` used to return `List<ChangeRow>` — replacements only. The card is titled "Broker
 * Selection", and a user read that title literally and correctly: on a sale where a broker HAD been
 * selected but never REPLACED, the card said "(0) — No broker changes recorded", i.e. it denied the
 * existence of the very thing its title names. The selection itself was never in the payload.
 *
 * So the return type is now a `HistoryView` wrapper carrying BOTH halves:
 *   `selected` — the sale's CURRENT selection, up to two rows (one per slot: the preferred broker
 *                and the score-selected one). Read from `BovSubmissionSelector`.
 *   `changes`  — the replacement log, BYTE-FOR-BYTE the old payload. Read from
 *                `BovBrokerChangeSelector`, unchanged.
 *
 * ⚠ ONE METHOD AND ONE WIRE, NOT TWO. A second `@AuraEnabled(cacheable=true)` method would give the
 * card two independent wires that settle at different times, and its "(n)" title is a SUM over both
 * halves — so a two-wire card would render a transiently WRONG count, and its empty state (which is
 * the majority state and must only appear when BOTH halves are empty) would flash on every load.
 * One wrapper makes the card's three states a function of ONE payload.
 *
 * 🔴 TWO SELECTORS IN ONE CONTROLLER METHOD IS NOT A LAYERING BREACH. `.claude/rules/apex-layering-rule.md`
 * puts ALL SOQL in selectors and says a controller is "thin: call service, catch
 * AuraHandledException" — both hold here. Neither read has any logic to orchestrate (no cross-object
 * write, no transaction, no branching on the first result), so interposing a Service purely to make
 * two selector calls would add a layer that forwards and nothing else. If this method ever gains a
 * decision, that is when it earns a service.
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

    /**
     * ONE CURRENTLY-SELECTED BROKER — a `BOV_Submission__c` at `Submission_Status__c = 'Selected'`,
     * flattened for the client. Added 2026-08-25.
     *
     * ⚠ MEMBER NAMES ARE THE CLIENT'S CONTRACT, exactly as on `ChangeRow` above: a rename fails no
     * deploy, fails no Apex test and throws nothing in the browser — the card just renders blanks.
     * Rename one only together with the LWC and its Jest suite.
     *
     * 🔴 THIS IS NOT A `ChangeRow` AND MUST NOT BE MERGED INTO ONE. The two describe different
     * facts: a ChangeRow is a historical EVENT (somebody was replaced, on a date, for a reason, by a
     * named user), a SelectedRow is a CURRENT STATE (this broker holds a slot right now, on this
     * basis). A single union DTO would carry a null half on every row and would force the client to
     * guess which kind it was holding — which is precisely the guessing the `outgoingBrokerFirm`
     * null-check already does inside ChangeRow, and once per card is enough.
     */
    public class SelectedRow {
        /** BOV_Submission__c Id — the `key` for the client's iteration, and nothing else. */
        @AuraEnabled public String id;
        /**
         * `Contact_Name__c` — the broker CONTACT's name, stamped from `Broker__c` by
         * `BovSubmissionBrokerStampService`. Nullable: the stamp writes null when the resolved
         * Contact is cleared, and rows predating the stamp may carry nothing. The client falls back
         * to the firm and then to a word — never to a blank line.
         */
        @AuraEnabled public String brokerName;
        /** `Broker_Firm__c`, same stamp, same nullability. Rendered as the secondary line. */
        @AuraEnabled public String brokerFirm;
        /**
         * WHY this row holds its slot, already resolved to one display phrase — see `basisOf`.
         * NEVER NULL: the client renders it unconditionally, and a null would leave a dangling
         * separator promising a value that is not there.
         */
        @AuraEnabled public String basis;
        /**
         * `LastModifiedDate`. 🔴 THIS IS AN APPROXIMATION AND IT IS A DELIBERATE ONE. There is no
         * "date selected" field on `BOV_Submission__c`; the last write to a Selected row is in
         * practice the write that selected it (`Submission_Status__c` is what
         * `BovSubmissionService`, `BovAutoSelectionService` and `BovPreferredBrokerService` each
         * touch), so this is the best available answer and is good enough for a sidebar timeline.
         * ⚠ It DOES drift if anything later edits the row for another reason — a BOV amount
         * correction, say. If that ever matters, the fix is a real `Selected_DateTime__c` stamped by
         * the services above, NOT arithmetic here.
         */
        @AuraEnabled public Datetime selectedDateTime;
    }

    /**
     * The card's whole payload: the CURRENT SELECTION and then the CHANGE LOG, in one cacheable
     * answer. Added 2026-08-25 — see the class header for why it is one method rather than two.
     *
     * 🔴 BOTH LISTS ARE ALWAYS INSTANTIATED AND NEVER NULL. The client iterates each directly and
     * sums their sizes for the card's "(n)" title; a null half would render "undefined" in a title
     * or throw in a `for:each`, and "no broker is selected" / "no broker was ever replaced" are both
     * NORMAL states that must arrive as empty lists.
     */
    public class HistoryView {
        /** The sale's current selection, PREFERRED SLOT FIRST. Empty is the majority state. */
        @AuraEnabled public List<SelectedRow> selected = new List<SelectedRow>();
        /** The replacement log, newest first. Empty is the majority state. */
        @AuraEnabled public List<ChangeRow> changes = new List<ChangeRow>();
    }

    // Fixed, generic user-safe message (ARCHITECTURE.md §5). Never interpolate platform text or
    // exception detail into it — the detail goes to the debug log (admin-only) and the user gets
    // this. A `WITH USER_MODE` FLS denial on this 2026-08-20 object surfaces here rather than as a
    // raw QueryException naming a column.
    // ⚠ REWORDED 2026-08-25 from "The broker change history could not be loaded" — the payload is no
    // longer only history, and a message naming half of what failed is a message that misdirects
    // whoever is asked to fix it. `could not be loaded` is unchanged and is what the tests pin.
    private static final String READ_FAILURE_MESSAGE =
        'The broker selection could not be loaded. Refresh the page or contact your '
        + 'administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    // ── The four phrases `SelectedRow.basis` can carry. USER-FACING COPY, and the client renders
    // them verbatim — it does not re-map them, so a word changed here changes the card.
    private static final String BASIS_MANUAL = 'Manually appointed';
    private static final String BASIS_PREFERRED = 'Preferred broker';
    private static final String BASIS_SYSTEM = 'System selected by score';
    private static final String BASIS_UNKNOWN = 'Selected broker';

    /**
     * WHY this Selected row holds its slot, as one phrase. The ONE place that decision is made.
     *
     * ── 🔴 THE PRECEDENCE IS MANUAL > PREFERRED > SYSTEM, AND IT IS NOT ARBITRARY ──────────────
     * The three flags are NOT mutually exclusive in the data, so an order is required and any order
     * is a choice. `Is_Preferred_Broker__c` and `Is_System_Selected__c` genuinely cannot both be
     * true — `BovAutoSelectionService` writes an explicit `false` on each promotion for exactly that
     * reason — but `Is_Manually_Appointed__c` can accompany EITHER, because
     * `BovSubmissionService.replaceSelectedBroker` stamps it on whichever row a human promoted and a
     * preferred row is a legal challenger (the preferred-broker refusal was removed 2026-08-24).
     *
     * MANUAL WINS because the card answers "why is this broker selected?", and on such a row the
     * answer is "a human chose it" — that act is also what PERMANENTLY LOCKS auto-selection out of
     * the sale, so it is the most consequential fact the row carries. Printing "Preferred broker"
     * there would be true and useless: it would describe the broker's standing rather than the
     * selection, and would hide a deliberate override behind a passive label.
     * ⚠ The converse is safe: a preferred row that was NOT manually appointed still reads
     * "Preferred broker", and a scored winner still reads "System selected by score". No
     * combination produces a false phrase under this order — which is not true of the reverse.
     *
     * ── 🔴 `BASIS_UNKNOWN` IS NOT DEFENSIVE PADDING; IT IS A REACHABLE ROW ─────────────────────
     * A Selected row with none of the three flags exists today: anything appointed BEFORE these
     * fields were added (2026-08-24), and anything a data load or a hand edit promoted —
     * `Submission_Status__c` is READ+EDIT in `DPEG_Disposition_Edit`, so a user can create one by
     * hand. `BovAutoSelectionService` repairs the scored case when it next runs, but it never runs
     * on a locked sale. The card must say something honest about such a row rather than render a
     * dangling separator, and "Selected broker" claims nothing beyond what the status already says.
     *
     * @param submission a Selected BOV_Submission__c carrying the three flags.
     * @return one of the four phrases above; never null and never blank.
     */
    private static String basisOf(BOV_Submission__c submission) {
        if (submission.Is_Manually_Appointed__c == true) {
            return BASIS_MANUAL;
        }
        if (submission.Is_Preferred_Broker__c == true) {
            return BASIS_PREFERRED;
        }
        if (submission.Is_System_Selected__c == true) {
            return BASIS_SYSTEM;
        }
        return BASIS_UNKNOWN;
    }

    /**
     * The whole "Broker Selection" card for one disposition: the CURRENT SELECTION (preferred slot
     * first) and then every recorded broker change, newest first.
     *
     * 🔴 AN EMPTY VIEW IS A SUCCESSFUL ANSWER AND MUST NEVER BECOME AN EXCEPTION. Most dispositions
     * have no Selected broker for most of their life and never replace one, so BOTH lists empty is
     * the COMMON case here — commoner than any populated one. Turning it into a throw (or letting
     * the client treat it as one) would put a permanent error on the majority of disposition record
     * pages.
     *
     * ⚠ RETURN TYPE CHANGED 2026-08-25 from `List<ChangeRow>` to `HistoryView` — see the class
     * header for the defect that forced it. The `changes` half is byte-for-byte the old payload;
     * `selected` is new. The Jest suite pins both member names.
     *
     * ⚠ TWO QUERIES, FIXED — one per selector, neither in a loop. This method takes a single Id and
     * is called once per card render, so its budget is 2 SOQL regardless of how many brokers or
     * changes the sale has.
     *
     * @param dispositionId the Disposition__c whose card to read; null returns an empty view
     * @return a HistoryView whose `selected` and `changes` lists are always instantiated, ordered
     *         by their respective selectors, and empty when there is nothing to show
     * @throws AuraHandledException — with a fixed generic message — when either read fails
     * @example
     * BovBrokerChangeController.HistoryView view =
     *     BovBrokerChangeController.getHistory(dispositionId);
     */
    @AuraEnabled(cacheable=true)
    public static HistoryView getHistory(Id dispositionId) {
        try {
            HistoryView view = new HistoryView();
            for (BOV_Submission__c submission
                    : BovSubmissionSelector.selectSelectedSlotsByDispositionId(dispositionId)) {
                SelectedRow selectedRow = new SelectedRow();
                selectedRow.id = submission.Id;
                selectedRow.brokerName = submission.Contact_Name__c;
                selectedRow.brokerFirm = submission.Broker_Firm__c;
                selectedRow.basis = basisOf(submission);
                selectedRow.selectedDateTime = submission.LastModifiedDate;
                view.selected.add(selectedRow);
            }
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
                view.changes.add(row);
            }
            return view;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovBrokerChangeController.getHistory on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
