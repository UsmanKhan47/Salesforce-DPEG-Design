/**
 * c/dispositionApprovalHistory — a CONSOLIDATED, READ-ONLY chronological approval log for a
 * Disposition. BUILT 2026-08-26 AND DELIBERATELY NOT PLACED ON ANY FLEXIPAGE.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 RETRACTED IN PLACE 2026-08-31 (review W-5). THIS OPENING LINE READ: *"the CONSOLIDATED,
 *    READ-ONLY 'Approval History' card in the Disposition record page sidebar."* THAT WAS FALSE
 *    WHEN WRITTEN AND IS NOW ACTIVELY MISLEADING.
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * This bundle appears on NO FlexiPage. It was briefly placed in the Disposition record page sidebar
 * and REVERSED the same day; `Disposition_Record_Page.flexipage-meta.xml` carries the full account
 * (search that file for this bundle name) and instructs, in terms, that it must not be placed there
 * or anywhere on that page.
 *
 * ⚠ AND THE FALSE SENTENCE GOT WORSE RATHER THAN MERELY STALER. A similarly-named sibling —
 * `c/dispositionApprovalTracker`, the FIVE-ROW pending-vs-complete checklist — now occupies exactly
 * the sidebar slot this sentence described, so the claim read as an accurate description of a card
 * a reader can actually see, on the wrong bundle. The two are not variants of each other: the
 * tracker answers "which approvals are outstanding", this answers "what happened, in order".
 *
 * ⇒ STATUS: BUILT, TESTED, UNPLACED, per the user's 2026-08-31 decision ("Tracker only, leave
 * history unplaced"). It is not dead code and must not be deleted; it is a completed bundle waiting
 * on a placement decision. Anyone placing it needs that decision reversed FIRST — not a FlexiPage
 * edit — and should read the tracker's placement comment on that page before proposing one.
 *
 * ⚠ NOTHING BELOW THIS BLOCK IS AFFECTED. The behaviour, the wires and the label mapping are
 * unchanged; only the claim about where this renders was wrong.
 *
 * 🔴 WHY IT EXISTS. The disposition flow's five approvals target THREE objects: three aim at
 * `Disposition__c`, `Broker_Finalize_Approval` aims at the selected `BOV_Submission__c` and
 * `Offer_Selection_Approval` at the selected `Disposition_Offer__c`. The platform's Approval
 * History related list matches `TargetObjectId` to the record it renders on, so the last two are
 * structurally invisible on the Disposition page — the 2026-08-25 report ("I sent the disposition
 * for approval on BOV Outreach but it is not appearing on the disposition record"). The full table
 * lives in `DispositionApprovalHistoryService`'s header.
 *
 * ⚠ READ-ONLY, AND IT OFFERS NO ACTIONS ON PURPOSE. RECALL IS STILL REACHABLE ONLY FROM THE
 * STANDARD RELATED LIST (`force:relatedListContainer`, header region of the FlexiPage). Do not add
 * a Recall button here without reading that component's FlexiPage comment first — a submitted
 * disposition LOCKS (`recordEditability = AdminOnly`) and that list is the only route out.
 *
 * ── 🔴 THE STATUS LABELS ARE MAPPED HERE, NOT IN APEX, AND `Removed` IS THE REASON ────────────
 * `ProcessInstance.Status` is raw platform text: a RECALL leaves the string `Removed`, which reads
 * to a user as though someone deleted their approval. Apex publishes the raw value (so a test can
 * assert on the DATA) and this file owns the translation to "Recalled" — a copy decision, pinned in
 * Jest, changeable without a deploy. ⚠ AN UNRECOGNISED STATUS FALLS THROUGH TO ITS RAW TEXT AND A
 * NEUTRAL PILL rather than to a blank: a new platform value must degrade to something readable, not
 * to an unlabelled coloured chip.
 *
 * ── ⚠ THE SECOND WIRE IS A REFRESH TRIGGER, NOT A DATA SOURCE ─────────────────────────────────
 * `getHistory` is `cacheable=true`, so the client holds the payload and an approval decided
 * elsewhere would not appear until a manual page refresh. Every approval on this flow writes the
 * parent Disposition (a stage advance, the `Approval_Advance_Pending__c` semaphore, a broker
 * stamp), so `getRecord` on `Disposition__c.LastModifiedDate` is a cheap LDS-cached proxy for "an
 * approval just moved": when the stamp CHANGES, `refreshApex` re-fetches the trail.
 * 🔴 THE FIRST EMIT MUST NOT REFRESH. LDS answers `getRecord` on every load; refreshing on that
 * first value would issue a redundant server round trip on every single page view — the exact cost
 * `cacheable=true` was chosen to avoid. `_lastModified` therefore starts undefined and the
 * comparison is guarded on a PREVIOUS value existing.
 * ⚠ IT IS A PROXY, NOT A GUARANTEE. A rejection that changes nothing on the parent will not fire
 * it; the accepted fallback is a page refresh.
 *
 * ── DATA ACCESS ───────────────────────────────────────────────────────────────────────────────
 * Imperative Apex is correct here under ARCHITECTURE.md §5's LDS-first rule: the payload joins
 * `ProcessInstance` + `ProcessInstanceHistory` (system entities with no UI-API / GraphQL surface)
 * to three custom objects, resolved through a target-Id set that no wire adapter can express. The
 * ONE thing LDS can answer — the parent's modification stamp — is read with LDS.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import LAST_MODIFIED_FIELD from '@salesforce/schema/Disposition__c.LastModifiedDate';
import getHistory from '@salesforce/apex/DispositionApprovalHistoryController.getHistory';

const TITLE_BASE = 'Approval History';

/**
 * 🔴 NOT the empty state — this card has none by instruction (see the template). This sentence is
 * shown ONLY when the read FAILED, and it must never say anything about the sale, because the one
 * thing we know in that branch is that we do not know.
 */
const UNAVAILABLE = 'Approval history is unavailable right now.';

/**
 * Raw `ProcessInstance.Status` -> what a human should read, and which pill to wear.
 * `Removed` is what a RECALL leaves behind; `NoResponse` is an approver who never acted.
 */
const STATUS_META = {
    Pending: { label: 'Pending', variant: 'pending' },
    Approved: { label: 'Approved', variant: 'approved' },
    Rejected: { label: 'Rejected', variant: 'rejected' },
    Removed: { label: 'Recalled', variant: 'neutral' },
    Reassigned: { label: 'Reassigned', variant: 'pending' },
    NoResponse: { label: 'No Response', variant: 'neutral' }
};

/**
 * The pill for one raw status.
 *
 * @param {string} status Raw `ProcessInstance.Status`.
 * @returns {{label: string, variant: string}} A readable label and a pill variant; falls back to
 *          the raw text on a neutral pill so an unrecognised platform value still renders a word.
 */
function statusMetaOf(status) {
    return STATUS_META[status] || { label: status || 'Unknown', variant: 'neutral' };
}

export default class DispositionApprovalHistory extends LightningElement {
    @api recordId;

    _rows = [];
    _loaded = false;
    _failed = false;

    /** The wire result itself, held so `refreshApex` has something to re-provision. */
    _historyResult;

    /** The last `LastModifiedDate` seen. Undefined until LDS answers once — see the header. */
    _lastModified;

    @wire(getHistory, { dispositionId: '$recordId' })
    wiredHistory(result) {
        this._historyResult = result;
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
     * Watches the parent's modification stamp and re-fetches the cached approval trail when it
     * moves. See the class header for why the first emit is deliberately inert.
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
        if (previous && previous !== stamp && this._historyResult) {
            refreshApex(this._historyResult);
        }
    }

    /**
     * "Approval History" until the wire answers, then "Approval History (n)".
     * 🔴 THE COUNT IS THIS CARD'S EMPTY STATE. `(0)` is a measured fact rather than a sentence, so
     * it cannot go stale or contradict the rows beside it.
     *
     * @returns {string} The card title.
     */
    get cardTitle() {
        return this._loaded && !this._failed
            ? `${TITLE_BASE} (${this._rows.length})`
            : TITLE_BASE;
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
     * The DTO rows, decorated with the booleans and class names the template needs.
     *
     * ⚠ NOTHING IS RE-SORTED. Both orderings — rows and steps — are already fixed server-side, in
     * two different places for two documented reasons.
     *
     * @returns {Array<object>} View models, newest approval first.
     */
    get rows() {
        return this._rows.map((row) => {
            const meta = statusMetaOf(row.status);
            const steps = row.steps || [];
            return {
                processInstanceId: row.processInstanceId,
                processName: row.processName,
                statusLabel: meta.label,
                statusClass: `dah-pill dah-pill--${meta.variant}`,
                targetId: row.targetId,
                targetLabel: row.targetLabel,
                targetUrl: row.targetUrl,
                hasDetail: !!row.targetDetail,
                targetDetail: row.targetDetail || '',
                // 🔴 `!= null`, NOT a truthiness test: a zero-amount offer is unusual but real,
                // and `!!0` is false, which would silently hide it.
                hasAmount: row.targetAmount !== undefined && row.targetAmount !== null,
                targetAmount: row.targetAmount,
                submittedDateTime: row.submittedDateTime,
                hasSubmittedBy: !!row.submittedBy,
                submittedBy: row.submittedBy || '',
                hasSubmittedComments: !!row.submittedComments,
                submittedComments: row.submittedComments || '',
                hasSteps: steps.length > 0,
                steps: steps.map((step) => ({
                    stepId: step.stepId,
                    stepStatus: step.stepStatus,
                    hasActor: !!step.actorName,
                    actorName: step.actorName || '',
                    hasComments: !!step.comments,
                    comments: step.comments || '',
                    createdDateTime: step.createdDateTime
                }))
            };
        });
    }
}
