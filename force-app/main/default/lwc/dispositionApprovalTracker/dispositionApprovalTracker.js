/**
 * c/dispositionApprovalTracker — the READ-ONLY "Approval Tracker" card on the Disposition record
 * page. Built 2026-08-31 (Tranche 3 item 3).
 *
 * 🔴 WHAT IT IS. FIVE FIXED ROWS, ONE PER BA APPROVAL TYPE — Sale Decision, Broker Selection, NDA
 * Issue, Final Sale Terms, Closing Wire Sign-Off — each showing where that approval stands on this
 * sale. It is a CHECKLIST: the rows that have NOT happened are as important as the ones that have,
 * so every row always renders, and "Not started" is a first-class state rather than an absence.
 *
 * ⚠ IT IS A SIBLING OF `c/dispositionApprovalHistory`, NOT AN EXTENSION OF IT. That card answers
 * *what happened, in order, with the full step trail*; this one answers *which of the five is
 * where*. Building a separate bundle rather than extending that one was a user decision at Gate 1
 * on 2026-08-31, and it is what keeps that card's pinned four-query governor assertion valid.
 *
 * ── 🔴 THE ROW THAT IS EASY TO GET BACKWARDS, AND HAS NO PRODUCTION DATA TO CATCH IT ──────────
 * ROW 2 IS RECORD-TYPE-DEPENDENT. Broker selection is TWO processes: `Broker_Finalize_Approval` on
 * an ON-market sale (raised against the selected BOV submission) and `Broker_Selection_Approval` on
 * an OFF-market one (raised against the Disposition, entry criterion `Is_On_Market__c = False`).
 * The server picks the applicable one and hands back the OTHER as `naProcessApiName` +
 * `naState = 'NotApplicable'`, which this file renders as a muted "N/A" line.
 * 🔴 THAT LINE IS NOT DECORATION. Without it the reader has no way to tell a variant that CANNOT
 * run from one that has not been started — and a row that read "Not started" on 100% of sales of
 * one record type would be the card reporting a defect that does not exist.
 *
 * ── 🔴 THE STATE LABELS ARE MAPPED HERE, NOT IN APEX, AND `Removed` IS THE REASON ─────────────
 * `ProcessInstance.Status` is raw platform text: a RECALL leaves the string `Removed`, which reads
 * to a user as though someone deleted their approval. Apex publishes the raw value (so a test can
 * assert on the DATA) and this file owns the translation to "Recalled" — a copy decision, pinned in
 * Jest, changeable without a deploy. The same idiom, and the same map, as
 * `c/dispositionApprovalHistory`. ⚠ AN UNRECOGNISED STATUS FALLS THROUGH TO ITS RAW TEXT ON A
 * NEUTRAL PILL rather than to a blank: a new platform value must degrade to something readable.
 *
 * ── ⚠ ROW COPY LIVES HERE TOO, AND ROW ORDER DOES NOT ────────────────────────────────────────
 * Apex publishes a stable `rowKey` (`SALE_DECISION`, …) and a `sequence`; this file maps the key to
 * the words a user reads. NOTHING IS RE-SORTED — the server returns the five rows in BA order and a
 * client-side sort would be a second copy of that rule. An unrecognised key falls back to the raw
 * token, so a row can never render nameless.
 *
 * ── ⚠ THE SECOND WIRE IS A REFRESH TRIGGER, NOT A DATA SOURCE ─────────────────────────────────
 * `getTracker` is `cacheable=true`, so the client holds the payload and an approval decided
 * elsewhere would not appear until a manual page refresh. Every approval on this flow writes the
 * parent Disposition (a stage advance, the `Approval_Advance_Pending__c` semaphore, a broker
 * stamp), so `getRecord` on `Disposition__c.LastModifiedDate` is a cheap LDS-cached proxy for "an
 * approval just moved".
 * 🔴 THE FIRST EMIT MUST NOT REFRESH. LDS answers `getRecord` on every load; refreshing on that
 * first value would issue a redundant server round trip on every single page view — the exact cost
 * `cacheable=true` was chosen to avoid. `_lastModified` therefore starts undefined and the
 * comparison is guarded on a PREVIOUS value existing.
 * ⚠ IT IS A PROXY, NOT A GUARANTEE. A decision that changes nothing on the parent will not fire it;
 * the accepted fallback is a page refresh.
 *
 * ── 🔴 A FAILED READ IS NOT AN EMPTY CHECKLIST, AND THE TWO BRANCHES SHARE NOTHING ────────────
 * The controller fails HARD by design: a missing grant throws rather than degrading. If this
 * component swallowed that into its normal render it would show FIVE ROWS, EVERY ONE "Not started"
 * — a confident, itemised claim that a sale which passed four approvals passed none. `isUnavailable`
 * is therefore a completely separate branch that renders NO rows at all.
 *
 * ── ⚠ IT OFFERS NO ACTIONS, AND MUST NOT GROW ANY ─────────────────────────────────────────────
 * Recall is reachable only from `force:relatedListContainer` in the FlexiPage header region, and
 * only for the three Disposition-TARGETED approvals — that component matches `TargetObjectId`. So a
 * pending `Broker_Finalize_Approval` or `Offer_Selection_Approval` is visible here and recallable
 * only from the BOV submission / offer record. Making these rows look actionable without being
 * actionable is the one way this card makes things worse.
 *
 * ── DATA ACCESS ───────────────────────────────────────────────────────────────────────────────
 * Imperative Apex is correct here under ARCHITECTURE.md §5's LDS-first rule: the payload joins
 * `ProcessInstance` (a system entity with no UI-API / GraphQL surface) to four custom objects,
 * resolved through a target-Id set no wire adapter can express, and then applies a record-type
 * branch and an aggregate. The ONE thing LDS can answer — the parent's modification stamp — is
 * read with LDS.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LAST_MODIFIED_FIELD from '@salesforce/schema/Disposition__c.LastModifiedDate';
import getTracker from '@salesforce/apex/DispositionApprovalTrackerController.getTracker';

const TITLE = 'Approval Tracker';

/**
 * 🔴 NOT an empty state — a resolvable sale ALWAYS returns five rows. This sentence is shown ONLY
 * when the read FAILED, and it must never say anything about the sale, because the one thing we
 * know in that branch is that we do not know.
 */
const UNAVAILABLE = 'The approval tracker is unavailable right now.';

/**
 * Raw state -> what a human should read, and which pill to wear.
 *
 * The first six keys are RAW `ProcessInstance.Status` values and the map is copied verbatim from
 * `c/dispositionApprovalHistory` so the two cards on one page cannot describe the same approval
 * with two different words. The last two are this feature's own synthetic states — the platform
 * emits neither, so they cannot collide.
 */
const STATE_META = {
    Pending: { label: 'Pending', variant: 'pending' },
    Approved: { label: 'Approved', variant: 'approved' },
    Rejected: { label: 'Rejected', variant: 'rejected' },
    Removed: { label: 'Recalled', variant: 'neutral' },
    Reassigned: { label: 'Reassigned', variant: 'pending' },
    NoResponse: { label: 'No Response', variant: 'neutral' },
    NotStarted: { label: 'Not started', variant: 'muted' },
    NotApplicable: { label: 'N/A', variant: 'muted' }
};

/**
 * `rowKey` -> the row's heading. The BA's own five names, in the BA's own order.
 * ⚠ The ORDER is the server's; this map only supplies words.
 */
const ROW_LABELS = {
    SALE_DECISION: 'Sale Decision',
    BROKER_SELECTION: 'Broker Selection',
    NDA_ISSUE: 'NDA Issue',
    FINAL_TERMS: 'Final Sale Terms',
    CLOSING: 'Closing Wire Sign-Off'
};

/**
 * `ProcessDefinition.DeveloperName` -> a short human name, used ONLY on row 2's N/A line.
 *
 * ⚠ THESE ARE NOT THE PROCESSES' SALESFORCE LABELS AND DELIBERATELY SO. Four of the five were
 * relabelled on 2026-08-26 and two of them now both begin "Broker Selection Approval", which is
 * exactly the pair this line has to tell apart. The wording here says which MARKET each belongs to,
 * which is the distinction the reader needs.
 */
const PROCESS_LABELS = {
    Sale_Decision_Approval: 'Decide to Sell approval',
    Broker_Finalize_Approval: 'On-market (BOV) broker approval',
    Broker_Selection_Approval: 'Off-market broker approval',
    NDA_Issue_Approval: 'NDA Issue approval',
    Offer_Selection_Approval: 'Offer Selection approval',
    Closing_Approval: 'Closing approval'
};

/**
 * The pill for one raw state.
 *
 * @param {string} state Raw `ProcessInstance.Status`, or a synthetic tracker state.
 * @returns {{label: string, variant: string}} A readable label and a pill variant; falls back to
 *          the raw text on a neutral pill so an unrecognised platform value still renders a word.
 */
function stateMetaOf(state) {
    return STATE_META[state] || { label: state || 'Unknown', variant: 'neutral' };
}

export default class DispositionApprovalTracker extends LightningElement {
    @api recordId;

    _rows = [];
    _loaded = false;
    _failed = false;

    /** The wire result itself, held so `refreshApex` has something to re-provision. */
    _trackerResult;

    /** The last `LastModifiedDate` seen. Undefined until LDS answers once — see the header. */
    _lastModified;

    @wire(getTracker, { dispositionId: '$recordId' })
    wiredTracker(result) {
        this._trackerResult = result;
        if (result.data) {
            this._rows = result.data;
            this._failed = false;
            this._loaded = true;
        } else if (result.error) {
            this._rows = [];
            this._failed = true;
            this._loaded = true;
        }
    }

    /**
     * Watches the parent's modification stamp and re-fetches the cached tracker when it moves. See
     * the class header for why the first emit is deliberately inert.
     *
     * @param {object} response The LDS wire response.
     */
    @wire(getRecord, { recordId: '$recordId', fields: [LAST_MODIFIED_FIELD] })
    wiredRecord({ data }) {
        if (!data) {
            return;
        }
        const stamp = getFieldValue(data, LAST_MODIFIED_FIELD);
        if (!stamp) {
            return;
        }
        const previous = this._lastModified;
        this._lastModified = stamp;
        if (previous && previous !== stamp && this._trackerResult) {
            refreshApex(this._trackerResult);
        }
    }

    /**
     * ⚠ NO COUNT IN THE TITLE, UNLIKE THE SIBLING CARD. "(5)" would be a constant — the tracker
     * always has five rows — so it would carry no information at all, and worse, it would read like
     * the history card's count, which IS a measured fact about the sale.
     *
     * @returns {string} The card title.
     */
    get cardTitle() {
        return TITLE;
    }

    get hasRows() {
        return this._loaded && !this._failed && this._rows.length > 0;
    }

    get isUnavailable() {
        return this._loaded && this._failed;
    }

    get unavailableText() {
        return UNAVAILABLE;
    }

    /**
     * The DTO rows, decorated with the labels, booleans and class names the template needs.
     *
     * ⚠ NOTHING IS RE-SORTED. The server returns the five rows in BA sequence order and that
     * ordering is argued there; a client-side sort would be a second copy of it.
     *
     * @returns {Array<object>} View models, row 1 first.
     */
    get rows() {
        return this._rows.map((row) => {
            const meta = stateMetaOf(row.state);
            const naMeta = stateMetaOf(row.naState);
            // 🔴 `!= null` on BOTH counts, never a truthiness test: `0 of 3 approved` is the most
            // common real reading of the NDA row on the day this ships, and `!!0` is false, which
            // would hide the one line that tells the reader the denominator.
            const hasCounts =
                row.approvedCount !== undefined &&
                row.approvedCount !== null &&
                row.totalCount !== undefined &&
                row.totalCount !== null;
            return {
                rowKey: row.rowKey,
                sequence: row.sequence,
                label: ROW_LABELS[row.rowKey] || row.rowKey,
                stateLabel: meta.label,
                stateClass: `dat-pill dat-pill--${meta.variant}`,
                hasTarget: !!row.targetUrl && !!row.targetLabel,
                targetLabel: row.targetLabel || '',
                targetUrl: row.targetUrl || '',
                hasCounts,
                countText: hasCounts
                    ? `${row.approvedCount} of ${row.totalCount} approved`
                    : '',
                // 🔴 ROW 2 ONLY. Both halves must be present — a variant name with no state, or a
                // state with no variant name, would be a half-rendered claim.
                hasNaVariant: !!row.naProcessApiName && !!row.naState,
                naVariantLabel:
                    PROCESS_LABELS[row.naProcessApiName] ||
                    row.naProcessApiName ||
                    '',
                naStateLabel: naMeta.label,
                naStateClass: `dat-pill dat-pill--${naMeta.variant}`,
                hasDecided: !!row.decidedDateTime,
                decidedDateTime: row.decidedDateTime,
                hasSubmitted: !!row.submittedDateTime && !row.decidedDateTime,
                submittedDateTime: row.submittedDateTime
            };
        });
    }
}
