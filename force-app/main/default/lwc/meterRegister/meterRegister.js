import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import PROPERTY_NAME_FIELD from '@salesforce/schema/Property_Asset__c.Property_Name__c';
import getRegister from '@salesforce/apex/UtilityMeterController.getRegister';
import UtilityMeterCapture from 'c/utilityMeterCapture';

/**
 * c-meter-register - the FSD 5.10.2 meter register for one property, with each meter's
 * latest billing figures attached.
 *
 * Structure copied from `lwc/workOrderList`: `lightning-card` + a `slot="title"` block using
 * `.hdr` / `.hdr-icon` / `.hdr-title` with a live count, `c-list-datatable` with
 * `column-widths-mode="fixed"` and `hide-checkbox-column`, an `slds-text-color_error` block
 * with `role="alert"`, and a `slot="footer"` `.view-all-footer`. Its PALETTE is deliberately
 * not copied - that bundle hard-codes hex values and this one uses SLDS 2 hooks.
 *
 * ── THIS IS THE SECOND ENTRY POINT TO METER CAPTURE, AND THE LOAD-BEARING ONE ──
 * UT-001 opens the capture screen from the onboarding checklist, which only exists while a
 * property is being onboarded. The register has to be reachable at every other moment of a
 * property's life too, so the "Capture Meters" button here opens the SAME modal with the
 * same contract. Neither entry point is a copy of the other's logic.
 *
 * ── ROW ACTIONS: READ `event.detail.row`, NOT `event.detail.action` ─────────
 * `lightning-datatable` does NOT resolve `fieldName` references inside a column's
 * `typeAttributes` when it builds the `rowaction` event - it passes the RAW column definition
 * through, so `event.detail.action.name` arrives as the object `{fieldName:'actionName'}` and
 * never matches a string. Measured in this repo (`lwc/sellMeterList`), where it left eight
 * green tests on a button that had never worked. This component uses a URL column instead of
 * a row action for exactly that reason; if a row action is ever added here, resolve its name
 * from `event.detail.row`.
 */
const PILL = (bg, fg) =>
    `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};` +
    `font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;` +
    `line-height:1.4;white-space:nowrap`;
const DOT = (colour) => `width:6px;height:6px;border-radius:50%;background:${colour};flex-shrink:0`;

const COLUMNS = [
    {
        label: 'Meter',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'meterLabel' }, target: '_self' }
    },
    { label: 'Utility', fieldName: 'utilityType', type: 'text', initialWidth: 110 },
    { label: 'Space', fieldName: 'unitLabel', type: 'text' },
    { label: 'Provider', fieldName: 'providerName', type: 'text' },
    {
        label: 'Paid by',
        fieldName: 'paidBy',
        type: 'pill',
        typeAttributes: { wrapStyle: { fieldName: 'paidByWrap' }, dotStyle: { fieldName: 'paidByDot' } }
    },
    {
        label: 'Status',
        fieldName: 'serviceStatus',
        type: 'pill',
        typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } }
    },
    {
        label: 'Latest bill',
        fieldName: 'latestTotalCharges',
        type: 'currency',
        typeAttributes: { maximumFractionDigits: 2 },
        initialWidth: 120
    },
    {
        label: 'Variance',
        fieldName: 'varianceText',
        type: 'pill',
        typeAttributes: {
            wrapStyle: { fieldName: 'varianceWrap' },
            dotStyle: { fieldName: 'varianceDot' }
        },
        initialWidth: 150
    }
];

export default class MeterRegister extends NavigationMixin(LightningElement) {
    /** Property_Asset__c record Id, supplied by the record page. */
    @api recordId;

    columns = COLUMNS;
    _data = [];
    error;
    _wire;

    @wire(getRegister, { propertyAssetId: '$recordId' })
    wiredRegister(result) {
        this._wire = result;
        if (result.data) {
            this._data = result.data;
            this.error = undefined;
        } else if (result.error) {
            // Surfaced, never swallowed: an unhandled wire error renders an empty register,
            // which is indistinguishable from a property that genuinely has no meters - and
            // that is precisely the state that invites someone to capture a duplicate.
            this.error = result.error;
            this._data = [];
        }
    }

    /** LDS for the property name - no Apex query is spent on a string for a heading. */
    @wire(getRecord, { recordId: '$recordId', fields: [PROPERTY_NAME_FIELD] })
    property;

    get propertyName() {
        return getFieldValue(this.property.data, PROPERTY_NAME_FIELD) || '';
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load the meter register.';
    }

    get count() {
        return this._data.length;
    }

    get hasMeters() {
        return this._data.length > 0;
    }

    get rows() {
        return this._data.map((m) => {
            const paid = m.paidBy || '—';
            const paidColour =
                paid === 'Tenant' ? '#146830' : paid === 'Management' ? '#8B1A1A' : '#7A4A00';
            const active = m.serviceStatus === 'Active';
            const statusColour = active ? '#22A652' : '#5A5752';
            const variance = this.varianceCell(m);
            return {
                id: m.id,
                recordUrl: `/lightning/r/Meter__c/${m.id}/view`,
                // A sub-meter reads as "1234 (sub of 1200)" so the master/sub relationship is
                // visible in a flat table without an expandable tree.
                meterLabel: m.isSubMeter
                    ? `${m.meterNumber || m.name} (sub of ${m.masterMeterNumber || '—'})`
                    : m.meterNumber || m.name,
                utilityType: m.utilityType || '—',
                unitLabel: m.unitLabel || '—',
                providerName: m.providerName || '—',
                paidBy: paid,
                paidByWrap: PILL(`${paidColour}18`, paidColour),
                paidByDot: DOT(paidColour),
                serviceStatus: m.serviceStatus || '—',
                statusWrap: PILL(active ? '#EBF9F1' : '#F3F3F3', active ? '#146830' : '#5A5752'),
                statusDot: DOT(statusColour),
                latestTotalCharges: m.latestTotalCharges,
                varianceText: variance.text,
                varianceWrap: variance.wrap,
                varianceDot: variance.dot
            };
        });
    }

    /**
     * The variance pill.
     *
     * `latestVariancePct` is the APEX-DERIVED percentage, not the stored
     * `Total_Variance_Pct__c` field - that formula is currently 100x its true value and would
     * render "+10000%" for a doubling. See `UtilityBillController`'s class header.
     *
     * A meter with no prior bill shows an em dash and no dot: "no comparison yet" is a
     * different statement from "no change", and colouring it green would say the second.
     */
    varianceCell(meter) {
        if (meter.latestVarianceAmount === null || meter.latestVarianceAmount === undefined) {
            return { text: '—', wrap: PILL('#F3F3F3', '#5A5752'), dot: '' };
        }
        const up = meter.latestVarianceAmount > 0;
        const colour = up ? '#8B1A1A' : '#146830';
        const pct =
            meter.latestVariancePct === null || meter.latestVariancePct === undefined
                ? ''
                : ` (${up ? '+' : ''}${meter.latestVariancePct}%)`;
        const money = Math.round(Math.abs(meter.latestVarianceAmount));
        return {
            text: `${up ? '+' : '-'}$${money}${pct}`,
            wrap: PILL(up ? '#FDF0F0' : '#EBF9F1', colour),
            dot: DOT(up ? '#D93636' : '#22A652')
        };
    }

    // ── capture ─────────────────────────────────────────────────────────────

    /**
     * Opens the same capture grid UT-001 opens, and refreshes the register in place from
     * whatever it returns.
     *
     * The modal's close contract, verbatim:
     *   undefined    cancelled or dismissed - say nothing.
     *   { result }   a `MeterCaptureService.CaptureResult`.
     *   { error }    the Apex threw.
     */
    async handleCapture() {
        const outcome = await UtilityMeterCapture.open({
            size: 'large',
            label: 'Capture Meters',
            description: 'Record the utility meters installed at this property and its spaces.',
            propertyAssetId: this.recordId,
            propertyName: this.propertyName
        });
        // Falsiness, not `=== undefined`: the Jest stub's close() with no argument arrives as
        // `detail === null` (CustomEvent spec-defaults detail to null) while the real
        // LightningModal resolves undefined. Both must be treated identically.
        if (!outcome) {
            return;
        }
        if (outcome.error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not save the meters',
                    message:
                        (outcome.error.body && outcome.error.body.message) ||
                        'Unexpected error saving the meters.',
                    variant: 'error',
                    mode: 'sticky'
                })
            );
            return;
        }
        const result = outcome.result || {};
        const saved = (result.created || 0) + (result.updated || 0);
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Meters saved',
                message: `${result.created || 0} created, ${result.updated || 0} updated.`,
                variant: saved > 0 ? 'success' : 'info'
            })
        );
        // Service-point warnings are STICKY and separate: they name a possible physical meter
        // swap, which is the one thing on this screen a person has to act on later.
        (result.warnings || []).forEach((warning) => {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Check this service point',
                    message: warning,
                    variant: 'warning',
                    mode: 'sticky'
                })
            );
        });
        await refreshApex(this._wire);
    }

    // ── navigation ──────────────────────────────────────────────────────────

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Meter__c', actionName: 'list' }
        };
    }

    listUrl = '#';

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    viewAll(event) {
        if (event) {
            event.preventDefault();
        }
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
