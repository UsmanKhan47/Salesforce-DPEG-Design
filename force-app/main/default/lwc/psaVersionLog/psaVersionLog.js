import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIMARY_CONTRACT from '@salesforce/schema/Opportunity.Primary_Contract__c';
import CR_BALL from '@salesforce/schema/Opportunity.Primary_Contract__r.Ball_In_Court__c';
import getVersions from '@salesforce/apex/PsaVersionController.getVersions';
import saveVersion from '@salesforce/apex/PsaVersionController.saveVersion';

const LEFT = { alignment: 'left' };
/**
 * [background, dot, label] soft pills per PSA_Version__c.Direction__c value (matches the lv-*
 * list chrome).
 *
 * 🔴 'Buyer' IS A REQUIRED KEY, NOT A NICETY. Direction__c carries three values since Tranche 3C
 * and PsaVersionService DERIVES which one it stores from the parent Contract Review's side of the
 * deal: 'Ours' is DPEG on both sides, while the counterparty is 'Seller' on a purchase and 'Buyer'
 * on a sale. Without this key a Buyer version fell through `|| DIRECTION.Seller` and rendered the
 * pill "Seller" — labelling the buyer as the seller on a record whose stored value was already
 * correct. That is a display defect on top of a right answer, which is the hardest kind to notice.
 *
 * The colour follows the ROLE, not the word: 'Buyer' shares the counterparty orange with 'Seller'
 * because on their own side of the deal they are the same party, and DPEG keeps blue on both.
 * Identical to lwc/loiCounterOffer's map, deliberately — the two cards sit one tab apart.
 */
const DIRECTION = {
    Seller: ['#fff1e0', '#FB8C00', 'Seller'],
    Buyer:  ['#fff1e0', '#FB8C00', 'Buyer'],
    Ours:   ['#e8f1fc', '#1E88E5', 'Ours']
};

/**
 * Ball_In_Court__c value -> badge caption. Same three-token contract as DIRECTION above: 'Us' is
 * DPEG on both sides, and the counterparty is 'Seller' on a purchase, 'Buyer' on a sale.
 *
 * ⚠ The previous code was a ternary — `=== 'Us' ? 'our court' : 'seller court'` — so EVERY
 * non-'Us' value read as "seller", which named the wrong party on a sale and would also have
 * captioned a blank field. A lookup with an explicit fallback cannot do either.
 */
const BALL_LABEL = {
    Us: 'Ball: our court',
    Seller: 'Ball: seller court',
    Buyer: 'Ball: buyer court'
};
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Version',
        fieldName: 'recordUrl',
        type: 'url',
        sortable: true,
        initialWidth: 110,
        cellAttributes: LEFT,
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    {
        label: 'From',
        fieldName: 'direction',
        type: 'pill',
        sortable: true,
        initialWidth: 100,
        typeAttributes: { wrapStyle: { fieldName: 'dirWrap' }, dotStyle: { fieldName: 'dirDot' } }
    },
    {
        // No initialWidth: this column absorbs the remaining width (fixed mode).
        label: 'Summary',
        fieldName: 'summary',
        type: 'text',
        wrapText: true,
        cellAttributes: LEFT
    },
    {
        label: 'Document',
        fieldName: 'documentUrl',
        type: 'url',
        initialWidth: 110,
        cellAttributes: LEFT,
        typeAttributes: { label: 'Open', target: '_blank' }
    },
    {
        label: 'Date',
        fieldName: 'versionDate',
        type: 'date-local',
        sortable: true,
        initialWidth: 110,
        cellAttributes: LEFT
    }
];

// PSA Version Log: the full contract negotiation history (Junior's Section 15).
// Every draft/counter is logged with who sent it; saving flips the Contract
// Review's Ball In Court. Works on the Opportunity Contract tab (via
// Primary_Contract__c) and directly on the Contract Review record page.
//
// ⚠ It does NOT derive Negotiation Status any more — that stopped on 2026-08-05 (the two counter
// values were removed from the restricted picklist); the status is moved only by the deal driver
// through Advance Stage. PsaVersionService's header carries the full note.
//
// ── SIDE-AWARENESS (Tranche 3C fix pass, 2026-08-10) ────────────────────────
// This card serves BOTH an acquisition PSA and a DISPOSITION PSA, and the counterparty's name
// inverts between them: on a purchase DPEG is the buyer and the counterparty is the SELLER; on a
// sale DPEG is the seller and the counterparty is the BUYER. PsaVersionService derives and stores
// the correct token from the parent Contract Review's record type (falling back to its
// Disposition__c lookup), so this change fixes the two places the DISPLAY still hardcoded buy-side
// wording (DIRECTION had no 'Buyer' key; ballBadgeLabel was a two-way ternary). See the token
// contract in objects/Contract_Review__c/fields/Ball_In_Court__c and
// objects/PSA_Version__c/fields/Direction__c. The identical pair of edits landed on
// lwc/loiCounterOffer in 3B.
//
// ⚠ WHAT IS *NOT* FIXED HERE, AND WHY — the `directionOptions` picker still reads "Seller sent us
// a version" / "Our redline to seller" on a disposition PSA. It is FUNCTIONALLY correct: 'Seller'
// is the incumbent wire token meaning "the counterparty" on both sides, and the service rewrites
// it to 'Buyer' before storing, so a disposition user who picks it gets the right record. Only the
// two labels read buy-side. Correcting them needs the Contract Review's SIDE on the client, and
// the only signals are RecordTypeId and Disposition__c — and `Disposition__c` is a Tranche 3C
// field whose FLS acquisitions personas are deliberately NOT granted (which is precisely why
// ContractReviewSelector.selectNegotiationContextById reads it WITH SYSTEM_MODE). Wiring it here
// would make the LIVE acquisition version card depend on an FLS grant it does not have — trading a
// wrong label for a broken card. If this is worth fixing, the safe shape is a server-supplied side
// flag on the existing getVersions response, and one shape can serve this card AND loiCounterOffer
// (review suggestion S2).
//
// ⚠ AND A MEASURED SCOPE LIMIT ON THE BALL BADGE: `hasBall` is `isOnOpportunity && !!oppBall`, and
// `oppBall` is wired only from Opportunity.Primary_Contract__r. A disposition PSA has no
// Opportunity — its Opportunity__c is deliberately blank, which is what stops
// ContractExecutionService minting a phantom acquisition Transaction — so the badge does not
// render for it TODAY at all. The ballBadgeLabel fix is therefore correctness-in-advance, not a
// visible repair; do not report it as one. The DIRECTION pill fix IS visible now: this card is on
// Contract_Review_Record_Page.
export default class PsaVersionLog extends LightningElement {
    @api recordId;
    @api objectApiName;
    columns = COLUMNS;
    sortedBy = 'versionDate';
    sortedDirection = 'desc';
    editing = false;
    direction = 'Seller';
    versionDate;
    summary;
    documentUrl;
    oppBall;
    versions = [];
    error;
    _wiredVersions;

    directionOptions = [
        { label: 'Seller sent us a version', value: 'Seller' },
        { label: 'Our redline to seller', value: 'Ours' }
    ];

    get isOnOpportunity() {
        return this.objectApiName === 'Opportunity';
    }

    // Only wires when mounted on an Opportunity page.
    get oppRecordId() {
        return this.isOnOpportunity ? this.recordId : undefined;
    }

    primaryContractFromOpp;

    @wire(getRecord, { recordId: '$oppRecordId', fields: [PRIMARY_CONTRACT], optionalFields: [CR_BALL] })
    wiredOpp({ data, error }) {
        if (data) {
            this.primaryContractFromOpp = getFieldValue(data, PRIMARY_CONTRACT);
            this.oppBall = getFieldValue(data, CR_BALL);
        } else if (error) {
            // The version history wire owns clearing this on success; only set here.
            this.error = error;
        }
    }

    get contractReviewId() {
        return this.isOnOpportunity ? this.primaryContractFromOpp : this.recordId;
    }

    @wire(getVersions, { contractReviewId: '$contractReviewId' })
    wiredVersions(result) {
        this._wiredVersions = result;
        if (result.data) {
            this.versions = result.data.map((v) => ({
                id: v.Id,
                name: v.Name,
                direction: v.Direction__c,
                summary: v.Summary__c,
                documentUrl: v.Document_URL__c,
                versionDate: v.Version_Date__c || v.CreatedDate
            }));
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error;
            this.versions = [];
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the PSA version history.';
    }

    get hasContract() {
        return !!this.contractReviewId;
    }
    get hasVersions() {
        return this.versions && this.versions.length > 0;
    }
    get count() {
        return this.versions ? this.versions.length : 0;
    }

    get hasBall() {
        return this.isOnOpportunity && !!this.oppBall;
    }
    get ballBadgeClass() {
        return this.oppBall === 'Us' ? 'slds-badge slds-theme_warning' : 'slds-badge';
    }
    get ballBadgeLabel() {
        // Explicit lookup, never a two-way ternary — see BALL_LABEL. The fallback is deliberately
        // party-neutral: naming a party the field does not name is exactly the defect being fixed.
        return BALL_LABEL[this.oppBall] || 'Ball: with the counterparty';
    }

    get rows() {
        const data = this.versions.map((v) => {
            const [dBg, dDot, dLabel] = DIRECTION[v.direction] || DIRECTION.Seller;
            return {
                id: v.id,
                recordUrl: `/lightning/r/PSA_Version__c/${v.id}/view`,
                name: v.name,
                direction: v.direction ? dLabel : '—',
                dirWrap: pillWrap(dBg),
                dirDot: pillDot(dDot),
                summary: v.summary,
                documentUrl: v.documentUrl,
                versionDate: v.versionDate
            };
        });
        const field = this.sortedBy === 'recordUrl' ? 'name' : this.sortedBy;
        const dir = this.sortedDirection === 'asc' ? 1 : -1;
        return [...data].sort((a, b) => {
            const av = a[field] == null ? '' : a[field];
            const bv = b[field] == null ? '' : b[field];
            if (av > bv) return dir;
            if (av < bv) return -dir;
            return 0;
        });
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
    }

    handleAdd() {
        this.direction = 'Seller';
        this.versionDate = null;
        this.summary = null;
        this.documentUrl = null;
        this.editing = true;
    }
    handleCancel() {
        this.editing = false;
    }
    handleDirectionChange(e) {
        this.direction = e.detail.value;
    }
    handleDateChange(e) {
        this.versionDate = e.target.value;
    }
    handleSummaryChange(e) {
        this.summary = e.target.value;
    }
    handleUrlChange(e) {
        this.documentUrl = e.target.value;
    }

    handleSave() {
        saveVersion({
            contractReviewId: this.contractReviewId,
            direction: this.direction,
            versionDate: this.versionDate,
            summary: this.summary,
            documentUrl: this.documentUrl
        })
            .then(() => {
                this.editing = false;
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                return refreshApex(this._wiredVersions);
            })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'PSA version logged', variant: 'success' })
                );
            })
            .catch((e) => {
                const message = e && e.body && e.body.message ? e.body.message : 'Unexpected error';
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Could not log the PSA version', message, variant: 'error' })
                );
            });
    }
}