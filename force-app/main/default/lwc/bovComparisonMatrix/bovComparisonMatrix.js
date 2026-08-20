import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { formatMillions } from 'c/utils';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

const SELECTED_BAR = '#2e7d32';
const BACKUP_BAR = '#2BAFAC';
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Broker Firm', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'brokerFirm' }, target: '_self' } },
    { label: 'Contact', fieldName: 'contactName', type: 'text' },
    { label: 'Valuation', fieldName: 'bovAmountLabel', type: 'text' },
    { label: 'Days to Mkt', fieldName: 'daysLabel', type: 'text' },
    { label: 'Cap Rate', fieldName: 'capRateLabel', type: 'text' },
    {
        label: 'Score', fieldName: 'scoreText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:140px',
            trackStyle: 'width:90px;height:6px;background:#eef1f4;border-radius:4px;overflow:hidden',
            barStyle: { fieldName: 'scoreBar' },
            numStyle: 'font-weight:700;color:#181818;font-variant-numeric:tabular-nums',
            text: { fieldName: 'scoreText' }
        }
    },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } }
];

/**
 * c-bov-comparison-matrix — the BOV Outreach card on the Disposition record page.
 *
 * ── 🔴 THE WIRE IS HELD AS A WHOLE RESULT, NOT DESTRUCTURED ─────────────────
 * `wiredSubmissions(result)` keeps `result` in `_wired` because `refreshApex` REQUIRES the
 * un-destructured wire result object — it has no way to re-provision a wire from a `{ data, error }`
 * pair. This shape is load-bearing for the replace-broker flow below; a "tidying" edit back to
 * `wired({ data, error })` compiles, passes every render test, and silently turns the post-replace
 * refresh into a no-op, leaving the matrix showing the OLD Selected broker until a page reload.
 */
export default class BovComparisonMatrix extends NavigationMixin(LightningElement) {
    @api recordId;
    columns = COLUMNS;
    _wired;
    _data;
    loadError;
    listUrl = '#';

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this._data = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load BOV submissions.';
            this._data = [];
        }
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'BOV_Submission__c', actionName: 'list' }
        };
    }

    get count() {
        return this._data ? this._data.length : 0;
    }

    get rows() {
        if (!this._data) return [];
        return this._data.map((r) => {
            const selected = !!r.isSelected;
            const score = r.bovScore;
            return {
                id: r.id,
                recordUrl: `/lightning/r/BOV_Submission__c/${r.id}/view`,
                brokerFirm: r.brokerFirm || '—',
                contactName: r.contactName || '—',
                bovAmountLabel: formatMillions(r.bovAmount),
                daysLabel: r.daysToMarket != null ? r.daysToMarket + 'd' : '—',
                capRateLabel: r.capRate != null ? parseFloat(r.capRate).toFixed(2) + '%' : '—',
                scoreText: score != null ? String(score) : '—',
                scoreBar: score != null
                    ? `width:${Math.min(100, score)}%;height:100%;background:${selected ? SELECTED_BAR : BACKUP_BAR};border-radius:4px`
                    : 'width:0%;height:100%',
                status: selected ? 'Selected' : 'Backup',
                statusWrap: selected ? pillWrap('#e9f5ec') : pillWrap('#e8f4f3'),
                statusDot: selected ? pillDot('#3fae5e') : pillDot('#2BAFAC')
            };
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Header actions
    // ─────────────────────────────────────────────────────────────────────────

    /** The currently Selected submission, or undefined. `isSelected` is BovController's DTO name. */
    get _selected() {
        return (this._data || []).find((r) => r.isSelected === true);
    }

    /**
     * "Replace Broker" renders only when there is something to replace.
     *
     * ⚠ THE TEST IS "SOME ROW IS SELECTED", NOT "EXACTLY ONE ROW IS SELECTED", and that is a
     * deliberate narrowing of the design wording. Exclusivity is a SERVER invariant —
     * `BovSubmissionService` demotes the incumbent in the same transaction it promotes the
     * successor — so a second Selected row would be a data defect, and hiding the very button that
     * repairs it is the wrong response to one.
     */
    get canReplaceBroker() {
        return this._selected !== undefined;
    }

    /**
     * Backup submissions as ready-made radio options for the replace modal. Composed HERE, from the
     * same payload that draws the rows above, so the modal cannot show a different valuation for
     * the same broker than the matrix behind it does.
     */
    get _backupOptions() {
        return (this._data || [])
            .filter((r) => r.isSelected !== true)
            .map((r) => ({
                label: `${r.brokerFirm || 'Unnamed firm'} — ${formatMillions(r.bovAmount)}`,
                value: r.id
            }));
    }

    /**
     * "Add Broker Response" — the platform's own create screen for a BOV_Submission__c with the
     * parent pre-filled, rather than a hand-built form. `encodeDefaultFieldValues` is used instead
     * of a hand-assembled `Disposition__c=<id>` string because it URL-encodes the values; a raw
     * concatenation breaks the moment a defaulted value contains a reserved character.
     */
    handleAddResponse() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'BOV_Submission__c', actionName: 'new' },
            state: {
                defaultFieldValues: encodeDefaultFieldValues({
                    Disposition__c: this.recordId
                })
            }
        });
    }

    /**
     * Opens the replace-broker modal and, on success, refreshes THIS component's wire.
     *
     * 🔴 THE MODAL CANNOT REACH THIS COMPONENT WITH A BUBBLING DOM EVENT, so it does not try.
     * `LightningModal.open()` renders into the PLATFORM'S modal layer, not into this component's
     * template, so the modal shares no ancestor with the matrix and a `CustomEvent` — however
     * composed — has no path back here. The promise returned by `open()` is the channel, and this
     * component awaiting it is what keeps the wire's owner and its refresher the same object.
     *
     * The service's returned text already carries the "a fresh approval is required" warning. It is
     * shown VERBATIM and STICKY: it describes a consequence the user must act on, and an
     * auto-dismissing toast is exactly how that gets missed.
     */
    async handleReplaceBroker() {
        let result;
        try {
            result = await BovReplaceBrokerModal.open({
                size: 'small',
                label: 'Replace Selected Broker',
                description:
                    'Promote a backup BOV submission to Selected and demote the current broker.',
                dispositionId: this.recordId,
                backupOptions: this._backupOptions,
                currentBroker: this._selected && this._selected.brokerFirm
            });
        } catch (error) {
            this._toast(
                'Could not open the replace dialog',
                (error && error.body && error.body.message) ||
                    'The replace-broker dialog could not be opened.',
                'error'
            );
            return;
        }

        // Cancelled or dismissed — nothing changed, so say nothing.
        if (!result || !result.message) {
            return;
        }
        this._toast('Broker replaced', result.message, 'warning');
        // The swap is imperative Apex DML on records this cacheable wire already holds, so LDS has
        // no idea they changed. Without this the matrix keeps showing the old Selected broker.
        refreshApex(this._wired);
    }

    _toast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
                mode: variant === 'success' ? 'dismissable' : 'sticky'
            })
        );
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
