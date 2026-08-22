/**
 * Suite for c-utility-bill-detail — a READ-ONLY component backed by one Apex wire, so this
 * uses the `createApexTestWireAdapter` + `.emit()` / `.error()` pattern throughout.
 *
 * The wire is UNFILTERED here (only one instance of the adapter exists on this component),
 * so no microtask wait is needed before emitting. Do not copy that shortcut into a suite with
 * two instances of the same adapter: immediately after `appendChild` the wire configs are
 * still `{}`, so a FILTERED emit matches nothing, reaches nobody, and produces no warning at
 * all — the component just renders its empty state.
 */
import { createElement } from 'lwc';
import UtilityBillDetail from 'c/utilityBillDetail';
import getBillDetail from '@salesforce/apex/UtilityBillController.getBillDetail';

jest.mock(
    '@salesforce/apex/UtilityBillController.getBillDetail',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0y5g000000UbiAAAS';

/** Matches UtilityBillController.BillDetail. The FSD 5.10.5 worked example. */
const DETAIL = {
    id: RECORD_ID,
    name: 'UB-00002',
    meterId: 'a0z5g000000MtrAAAS',
    meterNumber: '5512345',
    utilityType: 'Electricity',
    serviceIdentifier: 'ESID-1008901234567',
    propertyName: 'Park North',
    unitLabel: 'Suite 210',
    billDate: '2026-02-06',
    readDate: '2026-02-01',
    previousReading: 1100,
    currentReading: 1250,
    consumption: 150,
    totalCharges: 345,
    ratePerUnit: 2.3,
    priorBillId: 'a0y5g000000UbhAAAS',
    priorBillName: 'UB-00001',
    priorReadDate: '2026-01-01',
    priorConsumption: 100,
    priorTotalCharges: 200,
    priorRatePerUnit: 2,
    usageVariance: 100,
    rateVariance: 45,
    totalVariance: 145,
    totalVariancePct: 72.5,
    hasPrior: true,
    chargeLines: [
        { id: 'a105g000000ClAAAA0', chargeType: 'Energy', amount: 300, sharePct: 87 },
        { id: 'a105g000000ClBAAA0', chargeType: 'Taxes', amount: 45, sharePct: 13 }
    ],
    consumptionWarning: null
};

describe('c-utility-bill-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-utility-bill-detail', { is: UtilityBillDetail });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing but its header before the wire emits', async () => {
        const element = createComponent();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubd')).toBeNull();
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
    });

    it('DATA BRANCH: renders the readings, the meter and the location', async () => {
        const element = createComponent();
        getBillDetail.emit(DETAIL);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubd-subject').textContent).toBe(
            'Electricity · 5512345'
        );
        expect(element.shadowRoot.querySelector('.ubd-location').textContent).toBe(
            'Park North · Suite 210'
        );
        const values = element.shadowRoot.querySelectorAll(
            '.ubd-val lightning-formatted-number'
        );
        expect(values[0].value).toBe(1100);
        expect(values[1].value).toBe(1250);
        expect(values[2].value).toBe(150);
        expect(values[3].value).toBe(2.3);
        expect(values[4].value).toBe(345);
    });

    it('hands the decomposition to c-utility-bill-variance, percentage included', async () => {
        const element = createComponent();
        getBillDetail.emit(DETAIL);
        await Promise.resolve();

        const panel = element.shadowRoot.querySelector('c-utility-bill-variance');
        expect(panel).not.toBeNull();
        expect(panel.usageVariance).toBe(100);
        expect(panel.rateVariance).toBe(45);
        expect(panel.totalVariance).toBe(145);
        // 72.5, NOT 7250: the value must come from UtilityBillController.variancePct, never
        // from the stored Total_Variance_Pct__c field, which is 100x its true value.
        expect(panel.totalVariancePct).toBe(72.5);
        expect(panel.hasPrior).toBe(true);
        expect(panel.priorBillLabel).toBe('UB-00001 (read 2026-01-01)');
    });

    it('renders the charge components with their share of the bill', async () => {
        const element = createComponent();
        getBillDetail.emit(DETAIL);
        await Promise.resolve();

        const types = [...element.shadowRoot.querySelectorAll('.ubd-charge-type')].map(
            (el) => el.textContent
        );
        expect(types).toEqual(['Energy', 'Taxes']);
        const shares = [...element.shadowRoot.querySelectorAll('.ubd-charge-share')].map(
            (el) => el.textContent
        );
        // The share is what tells a reviewer where to look without opening every line.
        expect(shares).toEqual(['87% of bill', '13% of bill']);
        expect(element.shadowRoot.querySelector('.ubd-section').textContent).toBe(
            'Charge components (2)'
        );
    });

    it('renders no "undefined" when a component has no computable share', async () => {
        // sharePct is null when the bill totals zero. A getter bound to an attribute is
        // written UNCONDITIONALLY, so an undefined would render as the literal text.
        const element = createComponent();
        getBillDetail.emit({
            ...DETAIL,
            totalCharges: 0,
            chargeLines: [
                { id: 'a105g000000ClCAAA0', chargeType: 'Energy', amount: 0, sharePct: null }
            ]
        });
        await Promise.resolve();

        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.querySelector('.ubd-charge-share').textContent).toBe('');
    });

    it('explains an empty bill rather than showing an empty list', async () => {
        const element = createComponent();
        getBillDetail.emit({ ...DETAIL, totalCharges: 0, chargeLines: [] });
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubd-empty').textContent).toContain(
            'No charge components recorded yet'
        );
    });

    it('a first bill passes hasPrior=false down and names no prior', async () => {
        const element = createComponent();
        getBillDetail.emit({
            ...DETAIL,
            hasPrior: false,
            priorBillId: null,
            priorBillName: null,
            priorReadDate: null,
            usageVariance: null,
            rateVariance: null,
            totalVariance: null,
            totalVariancePct: null
        });
        await Promise.resolve();

        const panel = element.shadowRoot.querySelector('c-utility-bill-variance');
        expect(panel.hasPrior).toBe(false);
        // '' and not undefined - see the note above about attribute stringification.
        expect(panel.priorBillLabel).toBe('');
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('shows the rollover-or-swap notice when consumption was REFUSED', async () => {
        const warning =
            'Consumption was not calculated: this bill’s current reading is lower than its '
            + 'previous reading.';
        const element = createComponent();
        getBillDetail.emit({ ...DETAIL, consumption: null, consumptionWarning: warning });
        await Promise.resolve();

        const notice = element.shadowRoot.querySelector('.ubd-warning');
        expect(notice).not.toBeNull();
        expect(notice.textContent).toContain('lower than its previous reading');
    });

    it('shows NO notice on an ordinary bill', async () => {
        // The falsifier. Without this, a notice rendered unconditionally would still pass the
        // test above and would appear on every bill in the org.
        const element = createComponent();
        getBillDetail.emit(DETAIL);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubd-warning')).toBeNull();
    });

    it('WIRE ERROR BRANCH: renders an inline alert instead of an empty panel', async () => {
        const element = createComponent();
        // The adapter's error(body) argument BECOMES error.body - do not wrap it in another
        // { body: ... } layer, or the component reads undefined and silently falls back to its
        // own generic message, which makes the assertion pass for the wrong reason.
        getBillDetail.error({ message: 'This information could not be loaded.' });
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toContain('could not be loaded');
        // And the panel is NOT rendered: an error plus a rendered panel would show stale or
        // blank figures beside the error message.
        expect(element.shadowRoot.querySelector('.ubd')).toBeNull();
    });

    it('WIRE ERROR BRANCH: falls back to its own message when the error has no body', async () => {
        const element = createComponent();
        // MEASURED: a bare error() AND error(null) both supply the platform's own default
        // body ('An internal server error has occurred'), so neither reaches the fallback. An
        // empty object is a body with no message, which is the real no-message case.
        getBillDetail.error({});
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain(
            'Unable to load this utility bill.'
        );
    });

    it('is accessible', async () => {
        const element = createComponent();
        getBillDetail.emit(DETAIL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
