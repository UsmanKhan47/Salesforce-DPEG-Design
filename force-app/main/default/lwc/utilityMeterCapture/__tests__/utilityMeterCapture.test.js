/**
 * Suite for c-utility-meter-capture — the UAT UT-001 grid.
 *
 * It is a `LightningModal`, so it is mounted DIRECTLY with `createElement` and driven like
 * any other component; `LightningModal.open()` is not used here (the repo's stub makes the
 * static `open()` throw on purpose, so a caller-side test cannot silently pass while
 * asserting nothing — the OPENING components mock this module instead).
 *
 * ⚠ `close()` WITH NO ARGUMENT ARRIVES AS `detail === null`, NOT `undefined`. That is
 * `CustomEvent`'s own coercion, not a behaviour of the real `LightningModal`, whose `open()`
 * promise genuinely resolves `undefined`. Assert FALSINESS. Both openers in this feature
 * (`c/meterRegister`, `c/onboardingChecklist`) treat the two identically.
 *
 * ⚠ THE THREE `getPicklistValues` WIRES ARE FILTERED, AND A FILTERED EMIT BEFORE THE FIRST
 * MICROTASK REACHES NOBODY. Immediately after `appendChild` the wire configs are still `{}`,
 * so a filter reading `config.fieldApiName` matches nothing, the emit is silently dropped and
 * the component renders as if it had no picklist values — with no error and no warning. The
 * `mount()` helper below awaits, and the picklist emits happen only AFTER `getObjectInfo` has
 * supplied the record type Id their configs depend on.
 */
import { createElement } from 'lwc';
import UtilityMeterCapture from 'c/utilityMeterCapture';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import getCaptureModel from '@salesforce/apex/UtilityMeterController.getCaptureModel';
import saveMeters from '@salesforce/apex/UtilityMeterController.saveMeters';

jest.mock(
    '@salesforce/apex/UtilityMeterController.getCaptureModel',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/UtilityMeterController.saveMeters',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const ASSET_ID = 'a0a5g000000PrpAAAS';
const EXISTING_METER_ID = 'a0z5g000000MtrAAAS';
const RECORD_TYPE_ID = '012000000000000AAA';

const OBJECT_INFO = { apiName: 'Meter__c', defaultRecordTypeId: RECORD_TYPE_ID };

const PICKLISTS = {
    Utility_Type__c: {
        values: [
            { label: 'Electricity', value: 'Electricity' },
            { label: 'Water', value: 'Water' },
            { label: 'Sewer', value: 'Sewer' },
            { label: 'Gas', value: 'Gas' },
            { label: 'Trash', value: 'Trash' }
        ]
    },
    Paid_By__c: {
        values: [
            { label: 'Tenant', value: 'Tenant' },
            { label: 'Management', value: 'Management' },
            { label: 'Shared', value: 'Shared' }
        ]
    },
    Service_Status__c: {
        values: [
            { label: 'Active', value: 'Active' },
            { label: 'Disconnected (Vacant)', value: 'Disconnected (Vacant)' },
            { label: 'Transferred', value: 'Transferred' },
            { label: 'Inactive', value: 'Inactive' }
        ]
    }
};

/** Matches UtilityMeterController.CaptureModel. */
const MODEL_WITH_EXISTING = {
    propertyAssetId: ASSET_ID,
    units: [
        { id: 'a0u5g000000Un1AAAS', label: 'Suite 100', status: 'Occupied' },
        { id: 'a0u5g000000Un2AAAS', label: 'Suite 210', status: 'Vacant' }
    ],
    existingMeters: [
        {
            meterId: EXISTING_METER_ID,
            unitId: 'a0u5g000000Un1AAAS',
            unitLabel: 'Suite 100',
            meterNumber: '5512345',
            utilityType: 'Electricity',
            utilityAccountNumber: 'ACCT-99',
            serviceIdentifier: 'ESID-1008901234567',
            providerName: 'CenterPoint Energy',
            paidBy: 'Tenant',
            paidByReason: null,
            registerSize: 5,
            serviceStatus: 'Active'
        }
    ]
};

const EMPTY_MODEL = { propertyAssetId: ASSET_ID, units: [], existingMeters: [] };

describe('c-utility-meter-capture', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    /**
     * Mounts, then supplies object info, then the three FILTERED picklist emits, then the
     * capture model — in that order, with a microtask between each, because each wire's
     * config depends on the value emitted before it.
     */
    async function mount(model = MODEL_WITH_EXISTING) {
        const element = createElement('c-utility-meter-capture', { is: UtilityMeterCapture });
        element.propertyAssetId = ASSET_ID;
        element.propertyName = 'Park North';
        document.body.appendChild(element);
        await Promise.resolve();

        getObjectInfo.emit(OBJECT_INFO);
        await Promise.resolve();

        // Filtered per field: an unfiltered emit would give all three comboboxes the SAME
        // options and the suite would pass on a component that wired the wrong field.
        Object.keys(PICKLISTS).forEach((field) => {
            getPicklistValues.emit(
                PICKLISTS[field],
                (config) => config.fieldApiName && config.fieldApiName.fieldApiName === field
            );
        });
        await Promise.resolve();

        if (model) {
            getCaptureModel.emit(model);
            await Promise.resolve();
        }
        return element;
    }

    function rows(element) {
        return element.shadowRoot.querySelectorAll('.umc-row');
    }

    it('renders the property name in its subtitle', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('.umc-subtitle').textContent).toBe(
            'Meters at Park North'
        );
    });

    it('renders no "undefined" when the property name was not supplied', async () => {
        // A getter bound to an element's text is written unconditionally, so an undefined
        // renders as the literal word. Asserted on the RENDERED text, not on the getter.
        const element = createElement('c-utility-meter-capture', { is: UtilityMeterCapture });
        element.propertyAssetId = ASSET_ID;
        document.body.appendChild(element);
        await Promise.resolve();

        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.querySelector('.umc-subtitle').textContent).toBe(
            'Meters at this property'
        );
    });

    it('PRE-FILLS existing meters rather than opening an empty grid', async () => {
        const element = await mount();

        // One existing meter + one blank row. UT-001 can fire more than once in a property's
        // life; an empty grid would invite a duplicate register.
        expect(rows(element).length).toBe(2);
        const meterNumbers = [
            ...element.shadowRoot.querySelectorAll('.umc-number')
        ].map((el) => el.value);
        expect(meterNumbers).toEqual(['5512345', '']);
    });

    it('offers Whole building FIRST among the spaces', async () => {
        const element = await mount();

        const options = element.shadowRoot.querySelector('.umc-unit').options;
        expect(options[0]).toEqual({ label: 'Whole building', value: '' });
        expect(options.map((o) => o.label)).toEqual([
            'Whole building',
            'Suite 100',
            'Suite 210'
        ]);
    });

    it('drives each combobox from its OWN picklist field', async () => {
        const element = await mount();

        expect(
            element.shadowRoot.querySelector('.umc-type').options.map((o) => o.value)
        ).toEqual(['Electricity', 'Water', 'Sewer', 'Gas', 'Trash']);
        expect(
            element.shadowRoot.querySelector('.umc-paidby').options.map((o) => o.value)
        ).toEqual(['Tenant', 'Management', 'Shared']);
        expect(
            element.shadowRoot.querySelector('.umc-status').options.map((o) => o.value)
        ).toEqual([
            'Active',
            'Disconnected (Vacant)',
            'Transferred',
            'Inactive'
        ]);
    });

    it('starts with Save disabled on an empty grid and enables it once a row is filled', async () => {
        const element = await mount(EMPTY_MODEL);
        const save = element.shadowRoot.querySelector('.umc-save');
        expect(save.disabled).toBe(true);

        const numberInput = element.shadowRoot.querySelector('.umc-number');
        numberInput.value = 'NEW-1';
        numberInput.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'NEW-1' } })
        );
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.umc-save').disabled).toBe(false);
    });

    it('adds and removes grid rows, and never leaves the grid with none', async () => {
        const element = await mount(EMPTY_MODEL);
        expect(rows(element).length).toBe(1);

        element.shadowRoot.querySelector('.umc-add').click();
        await Promise.resolve();
        expect(rows(element).length).toBe(2);

        element.shadowRoot.querySelectorAll('.umc-remove')[0].click();
        await Promise.resolve();
        expect(rows(element).length).toBe(1);

        // Removing the last row re-seeds a blank one - an empty grid would strand the user
        // with nothing to type into and no way back.
        element.shadowRoot.querySelectorAll('.umc-remove')[0].click();
        await Promise.resolve();
        expect(rows(element).length).toBe(1);
    });

    it('SAVE: sends the whole grid in one call and maps whole-building back to null', async () => {
        saveMeters.mockResolvedValue({
            created: 1,
            updated: 1,
            skipped: 0,
            meterIds: [],
            warnings: []
        });
        const element = await mount();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        // Fill the blank row; leave its Space on the whole-building sentinel.
        const blankNumber = element.shadowRoot.querySelectorAll('.umc-number')[1];
        blankNumber.dispatchEvent(new CustomEvent('change', { detail: { value: 'NEW-1' } }));
        await Promise.resolve();

        element.shadowRoot.querySelector('.umc-save').click();
        await Promise.resolve();
        await Promise.resolve();

        expect(saveMeters).toHaveBeenCalledTimes(1);
        const payload = saveMeters.mock.calls[0][0];
        // PARAMETER NAMES ARE THE APEX SIGNATURE VERBATIM - a mismatch is not a compile error
        // on either side, the call just arrives with a null argument.
        expect(payload.propertyAssetId).toBe(ASSET_ID);
        expect(payload.rows.length).toBe(2);
        expect(payload.rows[0].meterId).toBe(EXISTING_METER_ID);
        expect(payload.rows[1].meterId).toBeNull();
        // The combobox sentinel is the EMPTY STRING (a null-valued option cannot be selected
        // back), and it must arrive at Apex as a real null - a blank space is meaningful data
        // meaning "whole building", not a missing value.
        expect(payload.rows[1].unitId).toBeNull();
    });

    it('SAVE: closes with { result } so the opener can toast and refresh', async () => {
        const result = {
            created: 2,
            updated: 0,
            skipped: 1,
            meterIds: [],
            warnings: ['Service identifier ESID-1 is already on the register…']
        };
        saveMeters.mockResolvedValue(result);
        const element = await mount(EMPTY_MODEL);
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        element.shadowRoot
            .querySelector('.umc-number')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'NEW-1' } }));
        await Promise.resolve();
        element.shadowRoot.querySelector('.umc-save').click();
        await Promise.resolve();
        await Promise.resolve();

        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ result });
    });

    it('SAVE ERROR: closes with { error } rather than trapping the user in the dialog', async () => {
        const error = { body: { message: 'The meters could not be saved.' } };
        saveMeters.mockRejectedValue(error);
        const element = await mount(EMPTY_MODEL);
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        element.shadowRoot
            .querySelector('.umc-number')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'NEW-1' } }));
        await Promise.resolve();
        element.shadowRoot.querySelector('.umc-save').click();
        await Promise.resolve();
        await Promise.resolve();

        // Every refusal reachable from here is terminal FOR THIS PROPERTY (no create rights
        // on Meter__c, a property the user cannot see) rather than fixable by editing a cell,
        // so keeping the form open would invite a pointless retry.
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ error });
    });

    it('CANCEL resolves falsy, so the opener says nothing', async () => {
        const element = await mount();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        element.shadowRoot.querySelector('.umc-cancel').click();
        await Promise.resolve();

        expect(saveMeters).not.toHaveBeenCalled();
        expect(closeHandler).toHaveBeenCalledTimes(1);
        // FALSINESS, never toBeUndefined(): close() with no argument arrives as detail === null
        // here (CustomEvent spec-defaults detail to null) while the real LightningModal
        // resolves undefined.
        expect(closeHandler.mock.calls[0][0].detail).toBeFalsy();
    });

    it('SAVE does nothing while the grid is empty', async () => {
        const element = await mount(EMPTY_MODEL);

        element.shadowRoot.querySelector('.umc-save').click();
        await Promise.resolve();

        expect(saveMeters).not.toHaveBeenCalled();
    });

    it('WIRE ERROR: surfaces an alert instead of an empty grid', async () => {
        const element = createElement('c-utility-meter-capture', { is: UtilityMeterCapture });
        element.propertyAssetId = ASSET_ID;
        document.body.appendChild(element);
        await Promise.resolve();

        getCaptureModel.error({ message: 'Unable to load this property’s meters.' });
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        // An empty grid on a failed read looks exactly like "this property has no meters",
        // and the user would then capture a duplicate register on top of one they cannot see.
        expect(element.shadowRoot.querySelectorAll('.umc-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.umc-save').disabled).toBe(true);
    });

    it('is accessible', async () => {
        const element = await mount();
        await expect(element).toBeAccessible();
    });
});
