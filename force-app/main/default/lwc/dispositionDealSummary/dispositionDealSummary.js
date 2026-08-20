/**
 * DEAL SUMMARY (disposition) — the NDA, LOI and PSA state of one sale, on one card, on every
 * stage. Tranche 2 Workstream C (design D5), 2026-08-20. Server half:
 * `DispositionDealSummaryController` -> `DispositionDealSummaryService` -> four selectors.
 *
 * ═══ 🔴 DATA ACCESS: IMPERATIVE APEX, WHICH DIVERGES FROM ARCHITECTURE.md §5 ═══
 * §5 ranks LDS first and Apex last, and that ranking is right for almost every card in this repo.
 * It is wrong here, and the argument is specific rather than a preference:
 *
 *   1. THE CARD NEEDS THE LATEST CHILD OF THREE DIFFERENT OBJECTS — `NDA__c`, `LOI__c` and
 *      `Contract_Review__c` — hanging off ONE `Disposition__c`, plus two counters on the parent.
 *      `getRelatedListRecords` would mean three separate wires, each sorted and truncated on the
 *      client, plus a fourth `getRecord`.
 *   2. 🔴 NONE OF THEM CAN EXPRESS THE TIE-BREAK THE READ ACTUALLY REQUIRES. "Latest" here is
 *      `ORDER BY CreatedDate DESC, Id DESC LIMIT 1`. `CreatedDate` is SECOND-granular, so two NDAs
 *      created under one Disposition inside the same second — routine in a test transaction,
 *      reachable in a bulk load or a double-click — leave a single-key sort free to return either
 *      row, and the card then shows a different NDA on every refresh.
 *      `NdaSelector.selectLatestByDispositionId` documents that tie-break as REQUIRED; a
 *      client-side sort over a page of related-list records cannot reproduce it reliably, and
 *      would be re-deriving in JavaScript exactly what SOQL already does correctly.
 *   3. ARCHITECTURE.md §5 item 3 permits imperative Apex "when LDS cannot express the query". This
 *      is that case. The controller stays thin and every query stays in a selector, so the
 *      layering rule is honoured in full.
 *
 * ⚠ THE KNOWN ALTERNATIVE, RECORDED SO IT IS NOT RE-PROPOSED AS A DISCOVERY: `NDA_Count__c` and
 * `Signed_NDA_Count__c` live on the PARENT, so a `getRecord` wire could supply the NDA *counters*
 * with no Apex. Design D5 raises that and rejects it for this build — the LOI and PSA halves need
 * Apex regardless, and splitting the card across two data sources would give it two refresh clocks
 * and two failure shapes for no reduction in server code.
 *
 * ═══ 🔴 TWO LOI FIELDS ARE EXCLUDED ON PURPOSE — DO NOT "FIX" THE OMISSION ═══
 * Both look like obvious additions to anyone reading the LOI object rather than the sell-side
 * automation, which is why the exclusions are stated here, in the DTO, and in the selector:
 *
 *   - **`LOI__c.LOI_Status__c` is EXCLUDED.** No automation ever sets it (the
 *     `LOI_Signed_Status_Sync` flow's own header says so), so on a disposition LOI it holds its
 *     `Draft` default forever. Showing it would routinely print "Draft" beside a `Stage__c` of
 *     "Executed" — a card contradicting itself. Design §0 C-10.
 *   - **`LOI__c.LOI_Signed_Date__c` is EXCLUDED.** `LOI_Signed_Status_Sync` keys on
 *     `Stage__c = 'Signed'`, the ACQUISITION terminal; the disposition terminal is `Executed`, so
 *     that flow is acquisition-only BY CONSTRUCTION and the field is STRUCTURALLY always blank on
 *     a sale. It would render a permanent em-dash that reads as missing data. Design §0 C-11.
 *
 * The LOI row therefore shows `Stage__c`, `Offer_Price__c` and `Ball_In_Court__c`. ⚠ On a sale
 * `Ball_In_Court__c = 'Seller'` means DPEG and 'Buyer' means the counterparty — the value is
 * rendered raw because this card only ever appears on a Disposition page.
 *
 * ═══ 🔴 THE COUNTERS ARE NULL, NOT ZERO, ON PRE-EXISTING ROWS ═══
 * `NDA_Count__c` / `Signed_NDA_Count__c` are maintained by the `NDA_Signed_Rollup` after-save flow
 * (not a roll-up summary — every child->Disposition relationship is a Lookup, so none is possible)
 * and hold null on any Disposition that predates it. Every reader in this repo coalesces with
 * `BLANKVALUE(...,0)`; this component does the same with `?? 0`, and it is the ONLY place the
 * coalescing happens — Apex passes the raw nulls through so the wire cannot hide a real null.
 *
 * ═══ FAIL-SOFT IS PER ROW, AND A DEGRADED ROW SAYS SO ═══
 * The service catches per read and flags the row (`ndaUnavailable`, `loiUnavailable`,
 * `psaUnavailable`, `ndaCountsUnavailable`) instead of failing the card, because this card is
 * placed UNGATED and renders on all 11 disposition stages — a whole-card error banner would be a
 * permanent fixture. The whole-card error branch below is therefore reached only when the
 * controller itself throws.
 * ⚠ A degraded row is rendered DIFFERENTLY from an empty one. `c/bovOutreach` deliberately
 * collapses the two, and design §0 C-1 found that exact collapse had been hiding a live
 * provisioning gap on the BOV NDA pill — "No NDA" forever, for every disposition-only persona,
 * with nothing on screen to suggest a permissions problem. This card keeps them distinct.
 */
import { LightningElement, api, wire } from 'lwc';
import { formatLongDate, formatMoney } from 'c/utils';
import getDealSummary from '@salesforce/apex/DispositionDealSummaryController.getDealSummary';

// Row status -> pill tone. Anything unmapped falls back to 'neutral' so a picklist value added
// later renders its own text on a defined style rather than an unstyled pill.
const NDA_TONE = {
    Pending: 'neutral',
    'Not Sent': 'neutral',
    Sent: 'progress',
    Received: 'progress',
    Signed: 'complete',
    Declined: 'blocked'
};

// LOI__c.Stage__c carries BOTH vocabularies (the picklist is shared with the acquisition record
// type). The disposition sequence is Received -> Under Review -> Countered by DPEG -> Counter
// Received from Buyer -> Executed; the acquisition values are mapped too so a mis-typed record
// still renders sensibly rather than falling to neutral.
const LOI_TONE = {
    Received: 'progress',
    'Under Review': 'progress',
    'Countered by DPEG': 'attention',
    'Counter Received from Buyer': 'attention',
    Executed: 'complete',
    Draft: 'neutral',
    'Prepare/Review': 'progress',
    Sent: 'progress',
    Counter: 'attention',
    Submitted: 'progress',
    Negotiation: 'progress',
    Signed: 'complete',
    Completed: 'complete'
};

// Contract_Review__c.Negotiation_Status__c — the SOURCE field, not the derived Stage__c
// projection, which collapses four negotiation states into three.
const PSA_TONE = {
    'Initial Draft': 'neutral',
    Draft: 'neutral',
    Revised: 'progress',
    Negotiation: 'progress',
    'Ready for Execution': 'attention',
    Signed: 'complete',
    Executed: 'complete'
};

const UNAVAILABLE_LABEL = 'Unavailable';
const UNAVAILABLE_HINT = 'Not readable with your current permissions — contact your administrator.';

export default class DispositionDealSummary extends LightningElement {
    @api recordId;

    summary;
    loadError;

    @wire(getDealSummary, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = "Couldn't load the deal summary.";
            this.summary = undefined;
        }
    }

    get hasError() {
        return !!this.loadError;
    }

    get hasSummary() {
        return !!this.summary && !this.loadError;
    }

    /**
     * The three rows, in deal order (NDA -> LOI -> PSA), each fully resolved for the template.
     * Building them here rather than in markup keeps the template flat and makes every rendered
     * string assertable from Jest without reaching into private state.
     *
     * @returns {Array<object>} Row descriptors: `{ key, label, statusLabel, pillClass, metaLines,
     *   isUnavailable, hintText }`.
     */
    get rows() {
        const s = this.summary || {};
        return [
            this.buildRow({
                key: 'nda',
                label: 'NDA',
                iconName: 'utility:lock',
                status: s.ndaStatus,
                toneMap: NDA_TONE,
                exists: s.hasNda === true,
                unavailable: s.ndaUnavailable === true,
                emptyLabel: 'No NDA',
                emptyHint: 'No NDA on this sale yet',
                metaLines: this.ndaMetaLines
            }),
            this.buildRow({
                key: 'loi',
                label: 'LOI',
                iconName: 'utility:contract',
                status: s.loiStage,
                toneMap: LOI_TONE,
                exists: s.hasLoi === true,
                unavailable: s.loiUnavailable === true,
                emptyLabel: 'No LOI',
                emptyHint: 'No LOI on this sale yet',
                metaLines: this.loiMetaLines
            }),
            this.buildRow({
                key: 'psa',
                label: 'PSA',
                iconName: 'utility:signature',
                status: s.psaStatus,
                toneMap: PSA_TONE,
                exists: s.hasPsa === true,
                unavailable: s.psaUnavailable === true,
                emptyLabel: 'No PSA',
                emptyHint: 'No PSA on this sale yet',
                metaLines: this.psaMetaLines
            })
        ];
    }

    /**
     * Resolves one row's pill text, tone class and secondary lines.
     *
     * ⚠ Precedence is unavailable > exists > empty, and it matters: a row whose read FAILED must
     * never fall through to the empty-state wording, because "No LOI on this sale yet" is a claim
     * about the data rather than about the reader's access (design §0 C-1).
     *
     * @param {object} cfg Row configuration.
     * @returns {object} The rendered row descriptor. Every string member is a string — never
     *   undefined — because a getter bound to a custom element's attribute is written
     *   unconditionally and `undefined` would render as the literal text "undefined".
     */
    buildRow(cfg) {
        if (cfg.unavailable) {
            return {
                key: cfg.key,
                label: cfg.label,
                iconName: cfg.iconName,
                statusLabel: UNAVAILABLE_LABEL,
                pillClass: 'pill pill_blocked',
                metaLines: [],
                isUnavailable: true,
                hintText: UNAVAILABLE_HINT,
                hintClass: 'row-hint row-hint_alert'
            };
        }
        if (!cfg.exists) {
            return {
                key: cfg.key,
                label: cfg.label,
                iconName: cfg.iconName,
                statusLabel: cfg.emptyLabel,
                pillClass: 'pill pill_neutral',
                metaLines: [],
                isUnavailable: false,
                hintText: cfg.emptyHint,
                hintClass: 'row-hint'
            };
        }
        const status = cfg.status || '—';
        const tone = cfg.toneMap[cfg.status] || 'neutral';
        return {
            key: cfg.key,
            label: cfg.label,
            iconName: cfg.iconName,
            statusLabel: status,
            pillClass: `pill pill_${tone}`,
            metaLines: cfg.metaLines,
            isUnavailable: false,
            hintText: '',
            hintClass: 'row-hint'
        };
    }

    /**
     * NDA secondary lines: the signed-of-total counter, then the signed date.
     *
     * 🔴 `?? 0` IS THE WHOLE POINT OF THIS GETTER. `NDA_Count__c` / `Signed_NDA_Count__c` hold
     * NULL — not 0 — on every Disposition that predates the `NDA_Signed_Rollup` flow, and Apex
     * passes that null through untouched by design. Without the coalescing this line would render
     * "null of null signed".
     *
     * ⚠ The counter line is suppressed when the COUNTER read specifically failed
     * (`ndaCountsUnavailable`), which is a different failure from the NDA row's own read — the two
     * are separate objects with independent FLS and the service catches them separately, so a
     * readable status can survive an unreadable counter and vice versa.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the NDA row.
     */
    get ndaMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.ndaCountsUnavailable === true) {
            lines.push({ key: 'nda-counts', text: 'NDA counts unavailable' });
        } else {
            const signed = s.ndaSignedCount ?? 0;
            const total = s.ndaCount ?? 0;
            lines.push({ key: 'nda-counts', text: `${signed} of ${total} signed` });
        }
        if (s.ndaSignedDate) {
            lines.push({ key: 'nda-date', text: `Signed ${formatLongDate(s.ndaSignedDate)}` });
        }
        return lines;
    }

    /**
     * LOI secondary lines: offer price, then whose court the LOI sits in.
     *
     * ⚠ There is deliberately no signed-date line and no `LOI_Status__c` line — see the exclusion
     * block in this file's header. Adding either is a regression, not a widening.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the LOI row.
     */
    get loiMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.loiOfferPrice != null) {
            lines.push({ key: 'loi-price', text: formatMoney(s.loiOfferPrice) });
        }
        if (s.loiBallInCourt) {
            lines.push({ key: 'loi-court', text: `Ball in court: ${s.loiBallInCourt}` });
        }
        return lines;
    }

    /**
     * PSA secondary lines: the maintained version number, then the execution date.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the PSA row.
     */
    get psaMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.psaLatestVersion != null) {
            lines.push({ key: 'psa-version', text: `Version ${s.psaLatestVersion}` });
        }
        if (s.psaExecutionDate) {
            lines.push({ key: 'psa-date', text: `Executed ${formatLongDate(s.psaExecutionDate)}` });
        }
        return lines;
    }
}
