/**
 * Suite for c-meter-register — the property meter register plus the second entry point into
 * meter capture.
 *
 * ⚠ THE MODAL MODULE IS MOCKED, NOT SPIED. `lightning/modal`'s stub makes the static `open()`
 * THROW on purpose (mirroring `lightning/confirm`'s own shipped stub), so a suite that tried
 * to let the real `c/utilityMeterCapture.open()` run would die on module resolution rather
 * than exercise this component. Replacing the module is the repo's established answer — see
 * `sellMeterInitiateModal`'s and `brokerReplaceQuickAction`'s suites.
 *
 * ⚠ `refreshApex` is NOT auto-mocked. `@salesforce/apex` resolves to a real module whose
 * `refreshApex` is a plain function, so `expect(refreshApex).toHaveBeenCalled()` fails with
 * "received value must be a mock or spy function" — an error that reads like a broken
 * assertion rather than a missing mock.
 */
import { createElement } from 'lwc';
import MeterRegister from 'c/meterRegister';
import getRegister from '@salesforce/apex/UtilityMeterController.getRegister';
import { getRecord } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import UtilityMeterCapture from 'c/utilityMeterCapture';

jest.mock(
    '@salesforce/apex/UtilityMeterController.getRegister',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), { virtual: true });
jest.mock(
    'c/utilityMeterCapture',
    () => ({ __esModule: true, default: { open: jest.fn() } }),
    { virtual: true }
);

const RECORD_ID = 'a0a5g000000PrpAAAS';

const PROPERTY_RECORD = {
    id: RECORD_ID,
    apiName: 'Property_Asset__c',
    fields: { Property_Name__c: { value: 'Park North', displayValue: null } }
};

/** Matches UtilityMeterController.RegisterRow. */
const ROWS = [
    {
        id: 'a0z5g000000Mt1AAAS',
        name: 'MTR-00001',
        meterNumber: '5512345',
        utilityType: 'Electricity',
        unitLabel: 'Whole building',
        providerName: 'CenterPoint Energy',
        utilityAccountNumber: 'ACCT-1',
        serviceIdentifier: 'ESID-1',
        paidBy: 'Management',
        serviceStatus: 'Active',
        registerSize: 5,
        isSubMeter: false,
        masterMeterNumber: null,
        totalAllocatedPct: null,
        latestTotalCharges: 345,
        latestReadDate: '2026-02-01',
        latestVarianceAmount: 145,
        latestVariancePct: 72.5,
        latestBillId: 'a0y5g000000UbiAAAS'
    },
    {
        id: 'a0z5g000000Mt2AAAS',
        name: 'MTR-00002',
        meterNumber: '5567890',
        utilityType: 'Water',
        unitLabel: 'Suite 210',
        providerName: 'City Water',
        utilityAccountNumber: 'ACCT-2',
        serviceIdentifier: 'ESID-2',
        paidBy: 'Tenant',
        serviceStatus: 'Disconnected (Vacant)',
        registerSize: 5,
        isSubMeter: true,
        masterMeterNumber: '5512345',
        totalAllocatedPct: 100,
        latestTotalCharges: null,
        latestReadDate: null,
        latestVarianceAmount: null,
        latestVariancePct: null,
        latestBillId: null
    }
];

describe('c-meter-register', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    async function mount(data = ROWS) {
        const element = createElement('c-meter-register', { is: MeterRegister });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        await Promise.resolve();

        getRecord.emit(PROPERTY_RECORD);
        if (data) {
            getRegister.emit(data);
        }
        await Promise.resolve();
        return element;
    }

    function datatableRows(element) {
        return element.shadowRoot.querySelector('c-list-datatable').data;
    }

    it('renders a live count in the card title', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('.hdr-title').textContent).toBe(
            'Meter Register (2)'
        );
    });

    it('names a sub-meter’s master inline instead of nesting the table', async () => {
        const element = await mount();
        const rows = datatableRows(element);

        expect(rows[0].meterLabel).toBe('5512345');
        // FSD 5.10.3 models a master meter with sub-meters. A flat table with the master
        // named in the label conveys that without an expandable tree.
        expect(rows[1].meterLabel).toBe('5567890 (sub of 5512345)');
    });

    it('renders the variance on the HUMAN percentage scale', async () => {
        const element = await mount();
        const rows = datatableRows(element);

        // +72.5%, NOT +7250%. The value must be the Apex-derived percentage; the stored
        // Total_Variance_Pct__c field is currently 100x its true value.
        expect(rows[0].varianceText).toBe('+$145 (+72.5%)');
    });

    it('shows a DASH, not a zero, for a meter that has never been billed', async () => {
        const element = await mount();
        const rows = datatableRows(element);

        // "No comparison yet" is a different statement from "no change", and colouring it
        // green would say the second.
        expect(rows[1].varianceText).toBe('—');
        expect(rows[1].varianceDot).toBe('');
        expect(rows[1].latestTotalCharges).toBeNull();
    });

    it('renders no "undefined" anywhere for a sparsely-populated meter', async () => {
        const element = await mount([
            {
                ...ROWS[1],
                meterNumber: null,
                utilityType: null,
                unitLabel: null,
                providerName: null,
                paidBy: null,
                serviceStatus: null,
                masterMeterNumber: null
            }
        ]);
        const rows = datatableRows(element);

        expect(JSON.stringify(rows)).not.toContain('undefined');
        expect(rows[0].utilityType).toBe('—');
        expect(rows[0].providerName).toBe('—');
    });

    it('EMPTY BRANCH: explains what to do rather than showing a bare empty table', async () => {
        const element = await mount([]);

        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
        expect(element.shadowRoot.querySelector('.mr-empty').textContent).toContain(
            'No meters recorded for this property yet'
        );
    });

    it('WIRE ERROR BRANCH: surfaces an alert and renders no table', async () => {
        const element = createElement('c-meter-register', { is: MeterRegister });
        element.recordId = RECORD_ID;
        document.body.appendChild(element);
        await Promise.resolve();

        getRegister.error({ message: 'Unable to load the meter register.' });
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toContain('Unable to load the meter register.');
        // A silently empty register is indistinguishable from a property with no meters -
        // which is exactly the state that invites someone to capture a duplicate.
        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
    });

    // ── capture hand-off ────────────────────────────────────────────────────

    it('CAPTURE: opens the modal with the property Id and name', async () => {
        UtilityMeterCapture.open.mockResolvedValue(undefined);
        const element = await mount();

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();

        expect(UtilityMeterCapture.open).toHaveBeenCalledTimes(1);
        const args = UtilityMeterCapture.open.mock.calls[0][0];
        expect(args.propertyAssetId).toBe(RECORD_ID);
        // The name comes from LDS, not from an extra Apex query for a heading string.
        expect(args.propertyName).toBe('Park North');
    });

    it('CAPTURE CANCELLED: says nothing and does not refresh', async () => {
        UtilityMeterCapture.open.mockResolvedValue(undefined);
        const element = await mount();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('CAPTURE CANCELLED as null: treated identically to undefined', async () => {
        // The Jest stub's close() with no argument arrives as detail === null while the real
        // LightningModal resolves undefined. The component must not distinguish them.
        UtilityMeterCapture.open.mockResolvedValue(null);
        const element = await mount();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('CAPTURE SAVED: toasts what happened and refreshes the register in place', async () => {
        UtilityMeterCapture.open.mockResolvedValue({
            result: { created: 2, updated: 1, skipped: 0, meterIds: [], warnings: [] }
        });
        const element = await mount();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();
        await Promise.resolve();
        await Promise.resolve();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe('2 created, 1 updated.');
        expect(refreshApex).toHaveBeenCalledTimes(1);
    });

    it('CAPTURE SAVED: a service-point warning gets its OWN sticky toast', async () => {
        UtilityMeterCapture.open.mockResolvedValue({
            result: {
                created: 1,
                updated: 0,
                skipped: 0,
                meterIds: [],
                warnings: ['Service identifier ESID-1 is already on the register under 5512345.']
            }
        });
        const element = await mount();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();
        await Promise.resolve();
        await Promise.resolve();

        expect(toastHandler).toHaveBeenCalledTimes(2);
        const warning = toastHandler.mock.calls[1][0].detail;
        expect(warning.variant).toBe('warning');
        // STICKY, because a possible physical meter swap is the one thing on this screen a
        // person has to act on later - it must not vanish after four seconds.
        expect(warning.mode).toBe('sticky');
        expect(warning.message).toContain('already on the register');
    });

    it('CAPTURE FAILED: raises a sticky error toast and does NOT refresh', async () => {
        UtilityMeterCapture.open.mockResolvedValue({
            error: { body: { message: 'The meters could not be saved.' } }
        });
        const element = await mount();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        element.shadowRoot.querySelector('.mr-capture').click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.mode).toBe('sticky');
        // Nothing was committed, so there is nothing to refresh - and refreshing would
        // suggest to the user that something changed.
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('is accessible', async () => {
        const element = await mount();
        await expect(element).toBeAccessible();
    });

    it('is accessible in its empty state', async () => {
        const element = await mount([]);
        await expect(element).toBeAccessible();
    });
});
