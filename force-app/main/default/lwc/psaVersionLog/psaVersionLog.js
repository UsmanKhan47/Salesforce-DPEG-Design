import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIMARY_CONTRACT from '@salesforce/schema/Opportunity.Primary_Contract__c';
import CR_BALL from '@salesforce/schema/Opportunity.Primary_Contract__r.Ball_In_Court__c';
import getVersions from '@salesforce/apex/PsaVersionController.getVersions';
import saveVersion from '@salesforce/apex/PsaVersionController.saveVersion';

const LEFT = { alignment: 'left' };
// [background, dot, label] soft pills per direction (matches the lv-* list chrome).
const DIRECTION = {
    Seller: ['#fff1e0', '#FB8C00', 'Seller'],
    Ours:   ['#e8f1fc', '#1E88E5', 'Ours']
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
// Review's Ball In Court and derives its Negotiation Status. Works on the
// Opportunity Contract tab (via Primary_Contract__c) and directly on the
// Contract Review record page.
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
    wiredOpp({ data }) {
        if (data) {
            this.primaryContractFromOpp = getFieldValue(data, PRIMARY_CONTRACT);
            this.oppBall = getFieldValue(data, CR_BALL);
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
        }
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
        return this.oppBall === 'Us' ? 'Ball: our court' : 'Ball: seller court';
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
