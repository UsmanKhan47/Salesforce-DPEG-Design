import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import METER_OBJECT from '@salesforce/schema/Meter__c';
import UTILITY_TYPE_FIELD from '@salesforce/schema/Meter__c.Utility_Type__c';
import PAID_BY_FIELD from '@salesforce/schema/Meter__c.Paid_By__c';
import SERVICE_STATUS_FIELD from '@salesforce/schema/Meter__c.Service_Status__c';
import getCaptureModel from '@salesforce/apex/UtilityMeterController.getCaptureModel';
import saveMeters from '@salesforce/apex/UtilityMeterController.saveMeters';

/**
 * c-utility-meter-capture - the FSD UAT UT-001 screen: "meter capture screen opens; meters
 * saved against property and spaces".
 *
 * A grid, not a form. FSD 5.10.1 says the utility workbooks record meters "by property and
 * space", so a 60-suite property is one save of 60 rows - not 60 record-creation flows. The
 * whole grid goes to `UtilityMeterController.saveMeters` in ONE call and is committed in one
 * transaction behind a savepoint.
 *
 * ── PICKLISTS COME FROM LDS, NOT FROM APEX ──────────────────────────────────
 * ARCHITECTURE.md section 5 is LDS-first. `getPicklistValues` means a new `Utility_Type__c`
 * value appears in this grid with no Apex change and no deploy, and it enforces the running
 * user's own FLS on the field rather than trusting a server-built list.
 *
 * ── WHAT IS NOT DEFAULTED, AND WHY ──────────────────────────────────────────
 * A blank space (`unitId === null`) means the meter serves the WHOLE BUILDING. FSD 5.10.4
 * makes that meaningful data rather than missing data, so the grid always opens with a
 * whole-building row and never defaults a blank to the first suite.
 *
 * ── EXISTING METERS ARE LOADED INTO THE GRID ────────────────────────────────
 * UT-001 can fire more than once in a property's life - a re-opened onboarding task, a
 * corrected transfer, a second transfer. Opening on an empty grid would invite a duplicate
 * register, so rows already on the register come back pre-filled and save as UPDATES.
 */
const BLANK_ROW_KEY_PREFIX = 'new-';

export default class UtilityMeterCapture extends LightningModal {
    /** The Property_Asset__c the meters belong to. Required. */
    @api propertyAssetId;
    /** Display name of that property, supplied by the opener - no query is spent on it. */
    @api propertyName;

    rows = [];
    units = [];
    error;
    warnings = [];
    _saving = false;
    _loaded = false;
    _nextKey = 0;

    // ── LDS: picklist values ────────────────────────────────────────────────
    @wire(getObjectInfo, { objectApiName: METER_OBJECT })
    objectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId',
        fieldApiName: UTILITY_TYPE_FIELD
    })
    utilityTypePicklist;

    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId',
        fieldApiName: PAID_BY_FIELD
    })
    paidByPicklist;

    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId',
        fieldApiName: SERVICE_STATUS_FIELD
    })
    serviceStatusPicklist;

    @wire(getCaptureModel, { propertyAssetId: '$propertyAssetId' })
    wiredModel({ data, error }) {
        if (data) {
            this.units = data.units || [];
            this.rows = this.buildRows(data.existingMeters || []);
            this.error = undefined;
            this._loaded = true;
        } else if (error) {
            // Surfaced, never swallowed: an unhandled wire error leaves an empty grid that
            // looks exactly like "this property has no meters", and the user would then
            // capture a duplicate register on top of the one they cannot see.
            this.error = error;
            this._loaded = false;
        }
    }

    /**
     * Existing meters first, then one blank row so the grid is never empty on a property
     * that has no register yet.
     */
    buildRows(existing) {
        const rows = existing.map((m) => ({
            key: m.meterId,
            meterId: m.meterId,
            unitId: m.unitId,
            meterNumber: m.meterNumber,
            utilityType: m.utilityType,
            utilityAccountNumber: m.utilityAccountNumber,
            serviceIdentifier: m.serviceIdentifier,
            providerName: m.providerName,
            paidBy: m.paidBy,
            paidByReason: m.paidByReason,
            registerSize: m.registerSize,
            serviceStatus: m.serviceStatus
        }));
        rows.push(this.blankRow());
        return rows;
    }

    blankRow() {
        this._nextKey += 1;
        return {
            key: `${BLANK_ROW_KEY_PREFIX}${this._nextKey}`,
            meterId: null,
            unitId: null,
            meterNumber: '',
            utilityType: '',
            utilityAccountNumber: '',
            serviceIdentifier: '',
            providerName: '',
            paidBy: '',
            paidByReason: '',
            registerSize: null,
            serviceStatus: 'Active'
        };
    }

    // ── options ─────────────────────────────────────────────────────────────

    /**
     * Spaces at this property, with the whole-building choice FIRST.
     *
     * Its value is the empty string and not `null`: `lightning-combobox` compares option
     * values as strings, and a null-valued option cannot be selected back after a change.
     * The empty string is mapped to null on the way to Apex.
     */
    get unitOptions() {
        const options = [{ label: 'Whole building', value: '' }];
        this.units.forEach((u) => options.push({ label: u.label, value: u.id }));
        return options;
    }

    get utilityTypeOptions() {
        return this.picklistOptions(this.utilityTypePicklist);
    }

    get paidByOptions() {
        return this.picklistOptions(this.paidByPicklist);
    }

    get serviceStatusOptions() {
        return this.picklistOptions(this.serviceStatusPicklist);
    }

    picklistOptions(wireResult) {
        const values = wireResult && wireResult.data && wireResult.data.values;
        if (!values) {
            return [];
        }
        return values.map((v) => ({ label: v.label, value: v.value }));
    }

    // ── state ───────────────────────────────────────────────────────────────

    get isSaving() {
        return this._saving;
    }

    get isLoaded() {
        return this._loaded;
    }

    /** Nothing to save until at least one row carries something identifying. */
    get saveDisabled() {
        return this._saving || !this._loaded || this.filledRows().length === 0;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unable to load this property’s meters.';
    }

    get hasWarnings() {
        return this.warnings.length > 0;
    }

    /**
     * Caption for the dialog.
     *
     * Returns '' and never undefined. A getter bound to an element's ATTRIBUTE is written
     * UNCONDITIONALLY, so an undefined renders the literal string "undefined" on screen - a
     * defect this repo has shipped before. The test for this must assert the RENDERED text,
     * not the getter's return value.
     */
    get subtitle() {
        return this.propertyName ? `Meters at ${this.propertyName}` : 'Meters at this property';
    }

    /** A row counts as filled once it carries anything the service would persist. */
    filledRows() {
        return this.rows.filter(
            (r) =>
                r.meterNumber ||
                r.utilityType ||
                r.utilityAccountNumber ||
                r.serviceIdentifier ||
                r.registerSize
        );
    }

    // ── row editing ─────────────────────────────────────────────────────────

    /**
     * Writes one field of one row.
     *
     * Both the row key and the field name are read from `data-*` on the input, so one
     * handler serves every cell. The rows array is REPLACED rather than mutated in place -
     * LWC's reactivity tracks the array reference, and mutating an element of it would
     * update the model without re-rendering.
     */
    handleFieldChange(event) {
        const rowKey = event.target.dataset.key;
        const field = event.target.dataset.field;
        const raw = event.detail ? event.detail.value : event.target.value;
        const value = field === 'registerSize' ? this.toNumber(raw) : raw;
        this.rows = this.rows.map((r) => (r.key === rowKey ? { ...r, [field]: value } : r));
    }

    toNumber(raw) {
        if (raw === '' || raw === null || raw === undefined) {
            return null;
        }
        const parsed = Number(raw);
        return Number.isNaN(parsed) ? null : parsed;
    }

    handleAddRow() {
        this.rows = [...this.rows, this.blankRow()];
    }

    /**
     * Removes a row from the GRID ONLY.
     *
     * It does not delete a saved meter, and that is deliberate: FSD 5.10 asks for no delete
     * behaviour, and the meter register's whole purpose is history. A removed saved row
     * simply is not submitted, so it stays exactly as it was.
     */
    handleRemoveRow(event) {
        const rowKey = event.target.dataset.key;
        const remaining = this.rows.filter((r) => r.key !== rowKey);
        this.rows = remaining.length > 0 ? remaining : [this.blankRow()];
    }

    handleCancel() {
        // Cancel and dismiss both resolve undefined - nothing was created, so say nothing.
        this.close();
    }

    // ── save ────────────────────────────────────────────────────────────────

    /**
     * Sends the whole grid in ONE call, then closes with what happened.
     *
     * The close contract, which `c/meterRegister` and `c/onboardingChecklist` both branch on:
     *   undefined      cancelled or dismissed; nothing was created.
     *   { result }     the Apex returned a `MeterCaptureService.CaptureResult`.
     *   { error }      the Apex threw; the opener raises the toast.
     *
     * A throw CLOSES this dialog rather than keeping it open, because every refusal reachable
     * from here is terminal for this property (no create permission on `Meter__c`, a property
     * the user cannot see) rather than fixable by editing a cell and pressing save again.
     */
    async handleSave() {
        if (this.saveDisabled) {
            return;
        }
        this._saving = true;
        this.error = undefined;
        this.warnings = [];
        try {
            // ⚠ PARAMETER NAMES ARE THE APEX SIGNATURE, VERBATIM:
            // UtilityMeterController.saveMeters(Id propertyAssetId, List<MeterRow> rows).
            // A mismatch is not a compile error on either side - the call simply arrives with
            // a null argument and the service refuses it as a missing property.
            const result = await saveMeters({
                propertyAssetId: this.propertyAssetId,
                rows: this.toPayload()
            });
            this.close({ result });
        } catch (error) {
            this.close({ error });
        } finally {
            this._saving = false;
        }
    }

    /** Maps the grid onto the Apex DTO, turning the whole-building sentinel back into null. */
    toPayload() {
        return this.filledRows().map((r) => ({
            meterId: r.meterId,
            unitId: r.unitId === '' ? null : r.unitId,
            unitLabel: null,
            meterNumber: r.meterNumber,
            utilityType: r.utilityType,
            utilityAccountNumber: r.utilityAccountNumber,
            serviceIdentifier: r.serviceIdentifier,
            providerName: r.providerName,
            paidBy: r.paidBy,
            paidByReason: r.paidByReason,
            registerSize: r.registerSize,
            serviceStatus: r.serviceStatus
        }));
    }
}
