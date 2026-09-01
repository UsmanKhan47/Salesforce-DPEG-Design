/**
 * c-sell-meter-list — @wire + MODAL + NavigationMixin + toast suite.
 *   - WIRE-MOCK TEMPLATE 1 (@wire Apex): getPortfolio drives the paged datatable.
 *   - WIRE-MOCK TEMPLATE 1 again: hasOverrideAccess drives the YELLOW button's
 *     enablement (2026-08-31, item 5a).
 *   - lwc-recipes navigation mock: [Navigate] dispatches a catchable 'navigate' event.
 *   - c/sellMeterInitiateModal and c/sellMeterOverrideModal both replaced with
 *     `{ open: jest.fn() }` (see below).
 *
 * Data source: @wire(getPortfolio) from SellMeterController.getPortfolio -> a LIST
 * of property-asset wrappers ordered GREEN/YELLOW/RED and paged 5-at-a-time into a
 * c-list-datatable.
 *
 * Peak sell dates use PAST dates so the countdown resolves to a stable 'Now',
 * keeping the derived Sell Meter label independent of the run date.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * ⚠ THE ROW ACTION NO LONGER CALLS APEX DIRECTLY — IT OPENS A MODAL
 * ─────────────────────────────────────────────────────────────────────────────
 * This suite previously asserted `DispositionController.findOrCreate` was called
 * from `handleRowAction`. That call is GONE. `findOrCreate` still exists in Apex
 * and is deliberately untouched, but it creates WITHOUT a record type choice and
 * WITHOUT submitting an approval, which is no longer what this button means.
 * The row now opens `c/sellMeterInitiateModal`, which owns the
 * `DispositionController.initiateAndSubmit` call; this component owns every
 * toast and the navigation.
 *
 * 🔴 `LightningModal.open()` IS A STATIC ON A CLASS, so it CANNOT be driven the
 * way a wire adapter or an imperative Apex import can — the repo-local
 * `lightning/modal` stub throws from `open()` on purpose (mirroring
 * lightning/confirm's own shipped stub) precisely so that a suite which forgot
 * to mock it fails loudly instead of silently resolving `undefined` and passing
 * every "the caller acts on the result" test while asserting nothing. Hence the
 * jest.mock of BOTH modal modules below.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 `lightning/confirm` IS NO LONGER MOCKED HERE, AND ITS ABSENCE IS THE POINT
 * ═════════════════════════════════════════════════════════════════════════════
 * Until 2026-08-31 five tests in this file were built on
 * `jest.mock('lightning/confirm')`, including a `['confirm', 'modal']` call-order
 * assertion. `LightningConfirm.open()` resolves `Promise<boolean>` and cannot
 * carry an override REASON back, so Tranche 2 item 5b replaced it with
 * `c/sellMeterOverrideModal`, which resolves `{ confirmed, reason }`. All five
 * tests are repointed at the new modal and the call-order assertion is now
 * `['override', 'initiate']` — SAME PROPERTY, different dialog.
 *
 * ⚠ THE ORDER ASSERTION IS THE ONE THAT MUST NOT BE LOST IN THE REPOINT. It pins
 * that the override question is still asked BEFORE the initiate modal opens,
 * which `handleRowAction`'s header states in terms: asking inside the initiate
 * modal would let a user fill in a record type before being told the property is
 * not at peak.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 THE OVERRIDE PERMISSION WIRE UN-RENDERS NOTHING, BUT IT DOES DISABLE THINGS
 * ═════════════════════════════════════════════════════════════════════════════
 * `_canOverride` defaults to FALSE and only flips when `hasOverrideAccess` emits
 * `true`. So a test that emits `getPortfolio` and nothing else gets a component
 * where every YELLOW row's button is DISABLED and `handleRowAction` refuses
 * 'override' — which is correct production behaviour for a non-principal, and
 * silently the wrong fixture for a test about the override FLOW.
 *
 * ⚠ EVERY OVERRIDE-FLOW TEST BELOW THEREFORE EMITS `hasOverrideAccess.emit(true)`,
 * and `emitPortfolio()` does it by default so nobody has to remember. The tests
 * that assert the DENIAL emit `false` explicitly rather than relying on the
 * default, so a future change to the default cannot make them vacuous.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING PAIRS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. confirm-then-open vs cancel-opens-nothing (YELLOW band). A confirmation
 *    that does not actually gate the next step is worse than none.
 * 2. THE BAND GATE STILL SITS IN FRONT OF THE MODAL. RED never opens it; YELLOW
 *    answers the override question FIRST. Opening the modal first and asking
 *    inside it would let a user pick a record type before being told the
 *    property is not at peak.
 * 3. `submitted === false` STILL NAVIGATES. The Disposition exists —
 *    `dispositionId` is always populated on a non-throwing return — so treating
 *    it as a failure would tell the user nothing was created about a record that
 *    is sitting there. Only the toast VARIANT differs (warning vs success).
 * 4. THE OVERRIDE REASON REACHES THE INITIATE MODAL. It is collected by
 *    c/sellMeterOverrideModal and threaded through as a pass-through @api. If
 *    the thread breaks anywhere, the audit field arrives blank and everything
 *    still reports success — so the hand-off is asserted, not assumed.
 * 5. SORTING USES RAW VALUES, NOT DISPLAY LABELS. Every sortable column binds a
 *    pre-formatted string ('$2.0M', 'Jan 1, 2020', '1.07×'), so the naive
 *    implementation orders money lexicographically and dates by month name. The
 *    SORT tests use fixtures chosen so the two orderings DIFFER — a fixture
 *    where they agree proves nothing.
 */
import { createElement } from 'lwc';
import SellMeterList from 'c/sellMeterList';
import getPortfolio from '@salesforce/apex/SellMeterController.getPortfolio';
import hasOverrideAccess from '@salesforce/apex/SellMeterController.hasOverrideAccess';
import SellMeterOverrideModal from 'c/sellMeterOverrideModal';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/asset-list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/SellMeterController.getPortfolio',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/SellMeterController.hasOverrideAccess',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Both modals are replaced wholesale: only their static `open()` is part of this
// component's contract. Each modal's OWN behaviour is proved in its own suite.
jest.mock('c/sellMeterInitiateModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock('c/sellMeterOverrideModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

// Mixed-band portfolio (emitted out of band order to prove the GREEN/YELLOW/RED sort).
const PORTFOLIO = [
    { id: 'a0P0000000000RED', name: 'Cedar Commons', noi: 500000, mktCapRate: 8.0, targetPrice: 6000000, meterScore: 1.0417, peakSellDate: '2020-06-01', projectedValueAtPeak: 6500000, sellMeter: 'RED' },
    { id: 'a0P000000000GRN', name: 'Gateway Plaza', noi: 2000000, mktCapRate: 6.5, targetPrice: 30000000, meterScore: 1.0256, peakSellDate: '2020-01-01', projectedValueAtPeak: 34000000, sellMeter: 'GREEN' },
    { id: 'a0P000000000YEL', name: 'Harbor Point', noi: 1200000, mktCapRate: 7.2, targetPrice: 15000000, meterScore: 1.1111, peakSellDate: '2020-03-01', projectedValueAtPeak: 16000000, sellMeter: 'YELLOW' }
];

// 6 GREEN rows to exercise the pager cleanly.
const SIX_GREEN = Array.from({ length: 6 }, (_, i) => ({
    id: `a0P00000000000${i}`,
    name: `Asset ${i}`,
    noi: 1000000,
    mktCapRate: 6.0,
    targetPrice: 10000000,
    meterScore: 1.6667,
    peakSellDate: '2020-01-01',
    projectedValueAtPeak: 11000000,
    sellMeter: 'GREEN'
}));

/**
 * ═══════════════════════════════════════════════════════════════════════════════
 * 🔴 SPLICE REMOVAL FIXTURE — SIX ROWS, THE ONLY RED BEYOND INDEX 4
 * ═══════════════════════════════════════════════════════════════════════════════
 * Until 2026-08-31 `allRows` spliced the first RED row up into the last visible
 * slot of page 1, "so the opening screen showcases all three states". The user
 * removed that behaviour outright at Gate 1 (design decision D-8).
 *
 * 🔴 THE HACK HAD NO TEST WHEN IT WAS REMOVED, which is why this fixture exists.
 * Neither pre-existing fixture reached the branch: PORTFOLIO has 3 rows, so page 1
 * already contained the RED, and SIX_GREEN's own comment said "no RED -> no page-1
 * reorder". Any change to the splice — including deleting it — passed the suite
 * silently.
 *
 * This fixture is the regression net that was owed, BUILT AND THEN INVERTED: it
 * drives the branch the splice used to take (5 non-RED rows first, the only RED
 * last) and asserts the RED row is NOT pulled onto page 1. It is the only thing in
 * the repo that can tell a re-added splice from plain band order — every other
 * fixture is green under both implementations.
 *
 * ⚠ THE 5 NON-RED ROWS ARE GREEN+YELLOW MIXED ON PURPOSE. An all-GREEN page 1
 * would still be band-ordered under a broken comparator that happened to sort
 * GREEN first by accident.
 */
const SIX_WITH_LATE_RED = [
    { id: 'a0P00000000000A', name: 'Alpha Center', noi: 1000000, mktCapRate: 5.0, targetPrice: 18000000, meterScore: 1.11, peakSellDate: '2020-01-01', projectedValueAtPeak: 21000000, sellMeter: 'GREEN' },
    { id: 'a0P00000000000B', name: 'Bravo Plaza', noi: 1100000, mktCapRate: 5.0, targetPrice: 19000000, meterScore: 1.16, peakSellDate: '2020-01-02', projectedValueAtPeak: 22000000, sellMeter: 'GREEN' },
    { id: 'a0P00000000000C', name: 'Charlie Court', noi: 1200000, mktCapRate: 5.0, targetPrice: 20000000, meterScore: 1.2, peakSellDate: '2020-01-03', projectedValueAtPeak: 23000000, sellMeter: 'GREEN' },
    { id: 'a0P00000000000D', name: 'Delta Commons', noi: 1300000, mktCapRate: 5.0, targetPrice: 21000000, meterScore: 1.24, peakSellDate: '2020-01-04', projectedValueAtPeak: 24000000, sellMeter: 'YELLOW' },
    { id: 'a0P00000000000E', name: 'Echo Park', noi: 1400000, mktCapRate: 5.0, targetPrice: 22000000, meterScore: 1.27, peakSellDate: '2020-01-05', projectedValueAtPeak: 25000000, sellMeter: 'YELLOW' },
    { id: 'a0P00000000000F', name: 'Foxtrot Field', noi: 1500000, mktCapRate: 5.0, targetPrice: 23000000, meterScore: 1.3, peakSellDate: '2020-01-06', projectedValueAtPeak: 26000000, sellMeter: 'RED' }
];

/**
 * ═══════════════════════════════════════════════════════════════════════════════
 * 🔴 SORT FIXTURE — CHOSEN SO RAW ORDER AND LABEL ORDER DISAGREE
 * ═══════════════════════════════════════════════════════════════════════════════
 * A fixture where the two orderings agree proves nothing at all, and that is the
 * easy mistake here — most small demo portfolios happen to sort the same either
 * way. Each column below is rigged so a NAIVE sort on the displayed string gives
 * a DIFFERENT answer from the correct sort on the raw value:
 *
 *   noi        2,000,000 / 10,000,000 / 500,000 -> '$2.0M' / '$10.0M' / '$0.5M'
 *              lexicographic: $0.5M, $10.0M, $2.0M   correct: 0.5M, 2M, 10M
 *   mktCapRate 9.5 / 10.5 / 6.0                 -> '9.5%' / '10.5%' / '6.0%'
 *              lexicographic: '10.5%', '6.0%', '9.5%'  correct: 6.0, 9.5, 10.5
 *   peakDate   2019-11-02 / 2020-03-01 / 2020-01-15
 *              -> 'Nov 2, 2019' / 'Mar 1, 2020' / 'Jan 15, 2020'
 *              alphabetical: 'Jan 15, 2020', 'Mar 1, 2020', 'Nov 2, 2019' (WRONG YEAR ORDER)
 *              correct: Nov 2019, Jan 2020, Mar 2020
 *   meterScore 1.9 / 11.2 / 0.75                -> '1.90×' / '11.20×' / '0.75×'
 *              lexicographic: '0.75×', '1.90×', '11.20×' — happens to agree, so
 *              meterScore is NOT the column the sort correctness rests on; it is
 *              asserted for completeness only.
 *
 * The bands are also mixed so a sort must visibly OVERRIDE band order — a sort
 * that silently kept band ordering as a primary key would pass on a single-band
 * fixture.
 */
const SORT_PORTFOLIO = [
    { id: 'a0P0000000000S1', name: 'Zebra Tower', noi: 2000000, mktCapRate: 9.5, targetPrice: 12000000, meterScore: 1.9, peakSellDate: '2019-11-02', projectedValueAtPeak: 21000000, sellMeter: 'RED' },
    { id: 'a0P0000000000S2', name: 'Apple Yard', noi: 10000000, mktCapRate: 10.5, targetPrice: 90000000, meterScore: 11.2, peakSellDate: '2020-03-01', projectedValueAtPeak: 99000000, sellMeter: 'YELLOW' },
    { id: 'a0P0000000000S3', name: 'Mango Walk', noi: 500000, mktCapRate: 6.0, targetPrice: 11000000, meterScore: 0.75, peakSellDate: '2020-01-15', projectedValueAtPeak: 9000000, sellMeter: 'GREEN' }
];

/**
 * 🔴 THE MEMBER NAMES BELOW ARE THE SERVER'S — `DispositionService.InitiateOutcome`
 * declares `dispositionId`, `submitted`, `message`. A Jest fixture DEFINES the
 * payload locally, so it proves the component reads its OWN fixture and never
 * that the fixture matches Apex. If the Apex DTO is renamed, this file and
 * `sellMeterList._handleOutcome` stay green while the component reads
 * `undefined` and navigates nowhere. Re-check against the Apex, not against a
 * green suite.
 */
const OUTCOME_SUBMITTED = {
    dispositionId: 'a0D0000000000001',
    submitted: true,
    message: 'Disposition created and submitted for approval.'
};
const OUTCOME_NOT_SUBMITTED = {
    dispositionId: 'a0D0000000000002',
    submitted: false,
    message: 'Created, but no approval process accepted the submission.'
};

const OVERRIDE_REASON = 'Fund matures in Q3 and the buyer pool is deep.';

function datatable(element) {
    return element.shadowRoot.querySelector('c-list-datatable');
}

// A MACROTASK, not a bare microtask. The override path awaits the override-modal
// promise BEFORE the initiate-modal promise, so a single Promise.resolve() does not
// reliably drain the chain.
function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-sell-meter-list', () => {
    beforeEach(() => {
        // Default happy state for the override dialog: the user confirms, with a reason.
        SellMeterOverrideModal.open.mockResolvedValue({
            confirmed: true,
            reason: OVERRIDE_REASON
        });
        // Default modal result: dismissed. Each test that cares sets its own.
        SellMeterInitiateModal.open.mockResolvedValue(undefined);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-list', {
            is: SellMeterList
        });
        document.body.appendChild(element);
        return element;
    }

    /**
     * Emits the portfolio AND the override permission.
     *
     * ⚠ `canOverride` DEFAULTS TO `true` HERE, WHICH IS THE OPPOSITE OF THE COMPONENT'S
     * OWN DEFAULT, AND THAT IS DELIBERATE. Most tests in this file are about the override
     * FLOW, and a component whose permission wire never answered refuses 'override'
     * silently — so those tests would go green while exercising the denial path instead.
     * The denial tests below pass `false` EXPLICITLY rather than relying on any default,
     * so they cannot be made vacuous by a change to this helper.
     */
    async function emitPortfolio(element, data = PORTFOLIO, canOverride = true) {
        getPortfolio.emit(data);
        hasOverrideAccess.emit(canOverride);
        await Promise.resolve();
        return element;
    }

    /**
     * ⚠ LEGACY / STATIC-COLUMN SHAPE — `detail.action.name` as a real STRING.
     *
     * 🔴 THE PLATFORM DOES NOT SEND THIS for the Action column in this component.
     * It is retained ON PURPOSE for exactly two jobs, and no other test may use it:
     *   1. driving an ARBITRARY action name that no row could ever produce (the
     *      unknown-action guard), and
     *   2. covering the defensive string branch of `_resolveActionName`, which
     *      must keep winning for a statically-named column or a future platform
     *      version that does resolve `typeAttributes`.
     *
     * Every band-behaviour test uses `fireRealRowAction` instead. This helper
     * being the DEFAULT is what let the silent-no-op defect ship green.
     *
     * `row` must be the FORMATTED row (`c-list-datatable`.data[i]), not a
     * hand-written `{ id, name }` stub — that is what the platform datatable
     * passes back, and the component reads `noiLabel` / `capRateLabel` /
     * `targetLabel` / `peakDateLabel` off it to populate the modal.
     */
    function fireLegacyStringRowAction(element, name, row) {
        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', { detail: { action: { name }, row } })
        );
    }

    /**
     * ─────────────────────────────────────────────────────────────────────────
     * 🔴 THE PAYLOAD THE REAL `lightning-datatable` ACTUALLY EMITS
     * ─────────────────────────────────────────────────────────────────────────
     * `lightning-datatable` does NOT resolve `fieldName` references inside a
     * column's `typeAttributes` when it builds the `rowaction` event. It passes
     * the RAW COLUMN DEFINITION through as `detail.action`, so
     * `detail.action.name` is the OBJECT `{ fieldName: 'actionName' }` — never
     * the string `'initiate'`. Only `detail.row` carries the resolved per-row
     * values.
     *
     * Measured in the live org (Copperfield Town Center, 2026-08-20):
     *   resolved name='[object Object]'  →  handler returned silently
     *
     * ⚠ THIS HELPER EXISTS BECAUSE THE SUITE PREVIOUSLY LIED. `fireRowAction`
     * used to send `detail.action = { name: 'initiate' }` — a plain string,
     * which the platform never sends. Every row-action test was green while the
     * button did nothing in production. Do NOT "simplify" this back to a string;
     * the string shape is covered by exactly one deliberately-labelled legacy
     * test below.
     */
    function fireRealRowAction(element, row) {
        datatable(element).dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: {
                        label: { fieldName: 'actionLabel' },
                        name: { fieldName: 'actionName' },
                        variant: { fieldName: 'actionVariant' },
                        disabled: { fieldName: 'actionDisabled' }
                    },
                    row
                }
            })
        );
    }

    /** Fires the datatable's `sort` event the way the platform does. */
    function fireSort(element, fieldName, sortDirection) {
        datatable(element).dispatchEvent(
            new CustomEvent('sort', { detail: { fieldName, sortDirection } })
        );
    }

    /** Sorted GREEN, YELLOW, RED — see the DATA BRANCH test. */
    const GREEN = 0;
    const YELLOW = 1;
    const RED = 2;
    const rowAt = (element, i) => datatable(element).data[i];
    const names = (element) => datatable(element).data.map((r) => r.name);

    // ── THE REAL DATATABLE PAYLOAD ───────────────────────────────────────────
    // These three are the regression net for the silent-no-op defect. They send
    // the UNRESOLVED column definition the platform really emits; the action
    // name must be recovered from the ROW.

    it('🔴 REAL PAYLOAD (GREEN): unresolved action.name still opens the modal', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();
        await emitPortfolio(element);

        const row = rowAt(element, GREEN);
        // Precondition: the ROW is where the real name lives.
        expect(row.actionName).toBe('initiate');

        fireRealRowAction(element, row);
        await flushPromises();
        await flushPromises();

        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000GRN'
        );
    });

    it('🔴 REAL PAYLOAD (YELLOW): unresolved action.name still asks the override question, then opens', async () => {
        const callOrder = [];
        SellMeterOverrideModal.open.mockImplementation(() => {
            callOrder.push('override');
            return Promise.resolve({ confirmed: true, reason: OVERRIDE_REASON });
        });
        SellMeterInitiateModal.open.mockImplementation(() => {
            callOrder.push('initiate');
            return Promise.resolve({ outcome: OUTCOME_SUBMITTED });
        });

        const element = createComponent();
        await emitPortfolio(element);

        const row = rowAt(element, YELLOW);
        expect(row.actionName).toBe('override');

        fireRealRowAction(element, row);
        await flushPromises();
        await flushPromises();
        await flushPromises();

        // The band gate still sits IN FRONT of the initiate modal.
        expect(callOrder).toEqual(['override', 'initiate']);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000YEL'
        );
    });

    it('🔴 REAL PAYLOAD (RED): unresolved action.name is still inert for a hold', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const row = rowAt(element, RED);
        expect(row.actionName).toBe('hold');

        fireRealRowAction(element, row);
        await flushPromises();

        // Recovering the name from the row must not accidentally make RED live.
        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('EMPTY: zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (0)');
        expect(datatable(element).data).toEqual([]);
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '0 of 0'
        );
    });

    it('DATA BRANCH: orders GREEN/YELLOW/RED and formats each row', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const rows = datatable(element).data;
        expect(rows.length).toBe(3);
        // Emitted RED/GREEN/YELLOW -> ordered GREEN, YELLOW, RED.
        expect(rows.map((r) => r.name)).toEqual([
            'Gateway Plaza',
            'Harbor Point',
            'Cedar Commons'
        ]);

        // GREEN row: compact money, cap-rate %, actionable "Initiate" button.
        expect(rows[0].noiLabel).toBe('$2.0M');
        expect(rows[0].capRateLabel).toBe('6.5%');
        expect(rows[0].actionLabel).toBe('Initiate');
        expect(rows[0].actionName).toBe('initiate');
        expect(rows[0].actionDisabled).toBe(false);

        // RED row: Hold action is disabled.
        expect(rows[2].actionLabel).toBe('Hold');
        expect(rows[2].actionDisabled).toBe(true);

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (3)');
    });

    it('PAGER: 6 rows page into 5 + 1 and next advances the window', async () => {
        const element = createComponent();
        await emitPortfolio(element, SIX_GREEN);

        expect(datatable(element).data.length).toBe(5); // page 1
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '1–5 of 6'
        );
        expect(element.shadowRoot.querySelector('.sm-pager')).not.toBeNull();

        // Buttons: [0] prev (disabled on page 1), [1] next.
        const btns = element.shadowRoot.querySelectorAll('.sm-pgbtn');
        expect(btns[0].disabled).toBe(true);
        btns[1].click();
        await Promise.resolve();

        expect(datatable(element).data.length).toBe(1); // page 2 remainder
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '6–6 of 6'
        );
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ITEM 3 — THE METER SCORE COLUMN (story 10, 2026-08-31)
    // ═════════════════════════════════════════════════════════════════════════

    it('METER SCORE: formatted as a 2-decimal multiple with the × sign', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const rows = datatable(element).data;
        // 1.0256 -> '1.03×'; 1.1111 -> '1.11×'; 1.0417 -> '1.04×'
        expect(rows.map((r) => r.meterScoreLabel)).toEqual([
            '1.03×',
            '1.11×',
            '1.04×'
        ]);
    });

    /**
     * 🔴 U+00D7 MULTIPLICATION SIGN, NOT THE LETTER 'x'. A screen reader announces
     * `×` as "times" and `x` as the letter "ex", and the value's whole meaning is
     * "N times the target price". The two are indistinguishable at a glance in a
     * diff, which is exactly why this is a codepoint assertion and not a substring.
     */
    it('🔴 METER SCORE: the multiplication sign is U+00D7, not the letter x', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const label = rowAt(element, GREEN).meterScoreLabel;
        expect(label.charCodeAt(label.length - 1)).toBe(0x00d7);
        expect(label).not.toMatch(/x$/);
    });

    /**
     * One dash covers three distinct server-side causes (null NOI, null/zero cap
     * rate, null/zero target price) — the server already collapses them to a null
     * `meterScore`, and a table cell has no room to distinguish them.
     *
     * ⚠ PRESENCE CONTROL IN THE SAME TEST: the second row has a real score, so the
     * dash cannot be passing because the column was deleted.
     */
    it('METER SCORE: null renders — matching every other formatter here', async () => {
        const element = createComponent();
        await emitPortfolio(element, [
            { ...PORTFOLIO[1], meterScore: null },
            { ...PORTFOLIO[2], meterScore: 2.5 }
        ]);

        const rows = datatable(element).data;
        expect(rows[0].meterScoreLabel).toBe('—');
        expect(rows[1].meterScoreLabel).toBe('2.50×');
    });

    it('METER SCORE: the column sits immediately LEFT of the Sell Meter pill', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const cols = datatable(element).columns;
        const scoreIndex = cols.findIndex((c) => c.fieldName === 'meterScoreLabel');
        const pillIndex = cols.findIndex((c) => c.fieldName === 'sellMeter');

        expect(scoreIndex).toBeGreaterThan(-1);
        expect(cols[scoreIndex].label).toBe('Meter Score');
        expect(pillIndex).toBe(scoreIndex + 1);
        // ⚠ The datatable stub renders NOTHING, so column ORDER can only be
        // asserted on the `columns` property. Whether the header actually appears
        // at that width is a browser check (design gate G-5).
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ITEM 4 — SORTING
    // ═════════════════════════════════════════════════════════════════════════

    it('SORT: every data column is sortable and the Action column is not', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        const cols = datatable(element).columns;
        const byField = {};
        cols.forEach((c) => {
            if (c.fieldName) byField[c.fieldName] = c;
        });

        [
            'recordUrl',
            'noiLabel',
            'capRateLabel',
            'targetLabel',
            'peakDateLabel',
            'peakValueLabel',
            'meterScoreLabel',
            'sellMeter'
        ].forEach((f) => {
            expect(byField[f].sortable).toBe(true);
        });

        // The button column has no value to order by — its label is a pure function
        // of the band, which the Sell Meter column already sorts on.
        const action = cols.find((c) => c.type === 'button');
        expect(action.sortable).toBeUndefined();
    });

    it('SORT: sorted-by and sorted-direction reach the datatable so the header arrow renders', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        // Absence first: nothing is sorted until the user asks.
        expect(datatable(element).sortedBy).toBeUndefined();

        fireSort(element, 'noiLabel', 'desc');
        await Promise.resolve();

        expect(datatable(element).sortedBy).toBe('noiLabel');
        expect(datatable(element).sortedDirection).toBe('desc');
    });

    /**
     * 🔴 THE CENTRAL SORT ASSERTION. `noiLabel` holds '$2.0M' / '$10.0M' / '$0.5M',
     * and a lexicographic sort of those gives $0.5M, $10.0M, $2.0M — i.e. Mango
     * Walk, Apple Yard, Zebra Tower. The correct raw-value order is Mango Walk
     * (500K), Zebra Tower (2M), Apple Yard (10M). The two DIFFER, so this test
     * fails against the naive implementation rather than passing by luck.
     */
    it('🔴 SORT (NOI asc): orders by the RAW number, not by the $M label', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'noiLabel', 'asc');
        await Promise.resolve();

        expect(names(element)).toEqual(['Mango Walk', 'Zebra Tower', 'Apple Yard']);
        // The lexicographic answer, spelled out so a future reader can see the two
        // orderings really do differ on this fixture.
        expect(names(element)).not.toEqual([
            'Mango Walk',
            'Apple Yard',
            'Zebra Tower'
        ]);
    });

    it('SORT (NOI desc): reverses', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'noiLabel', 'desc');
        await Promise.resolve();

        expect(names(element)).toEqual(['Apple Yard', 'Zebra Tower', 'Mango Walk']);
    });

    /**
     * 🔴 `peakDateLabel` holds 'Nov 2, 2019' / 'Mar 1, 2020' / 'Jan 15, 2020'. Sorted
     * alphabetically that is Jan 2020, Mar 2020, Nov 2019 — the wrong YEAR order, and
     * the failure looks plausible enough on screen to survive a review. The raw
     * 'YYYY-MM-DD' strings sort chronologically under a plain string compare.
     */
    it('🔴 SORT (peak date asc): chronological, not alphabetical by month name', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'peakDateLabel', 'asc');
        await Promise.resolve();

        expect(names(element)).toEqual(['Zebra Tower', 'Mango Walk', 'Apple Yard']);
        // The alphabetical answer, for contrast.
        expect(names(element)).not.toEqual([
            'Mango Walk',
            'Apple Yard',
            'Zebra Tower'
        ]);
    });

    /** '10.5%' < '6.0%' lexicographically. The raw numbers do not agree. */
    it('🔴 SORT (cap rate asc): numeric, and does not break at 10%', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'capRateLabel', 'asc');
        await Promise.resolve();

        expect(names(element)).toEqual(['Mango Walk', 'Zebra Tower', 'Apple Yard']);
    });

    /**
     * 🔴 `recordUrl` IS A RECORD URL. Sorting the Property column on it orders by
     * record Id — a stable-looking, completely meaningless order. It must be
     * remapped to `name`, per the `lwc/loiCounterOffer` precedent.
     */
    it('🔴 SORT (Property asc): orders by NAME, not by the record URL', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'recordUrl', 'asc');
        await Promise.resolve();

        expect(names(element)).toEqual(['Apple Yard', 'Mango Walk', 'Zebra Tower']);
        // Id order for this fixture is S1, S2, S3 = Zebra, Apple, Mango — different.
        expect(names(element)).not.toEqual([
            'Zebra Tower',
            'Apple Yard',
            'Mango Walk'
        ]);
    });

    /**
     * The pill column sorts by BAND RANK, not by its own text. 'Sell now' /
     * 'Getting Close' / 'Hold - Not yet' have no useful alphabetical order, and the
     * countdown suffix makes it worse.
     */
    it('SORT (Sell Meter asc): orders by band rank, not by the pill text', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'sellMeter', 'asc');
        await Promise.resolve();

        // GREEN, YELLOW, RED = Mango Walk, Apple Yard, Zebra Tower.
        expect(names(element)).toEqual(['Mango Walk', 'Apple Yard', 'Zebra Tower']);

        fireSort(element, 'sellMeter', 'desc');
        await Promise.resolve();
        expect(names(element)).toEqual(['Zebra Tower', 'Apple Yard', 'Mango Walk']);
    });

    it('SORT (meter score asc): orders by the raw multiple', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'meterScoreLabel', 'asc');
        await Promise.resolve();

        // 0.75, 1.9, 11.2
        expect(names(element)).toEqual(['Mango Walk', 'Zebra Tower', 'Apple Yard']);
    });

    /**
     * Nulls sort LAST in both directions. Every money and date column here is
     * genuinely nullable, and letting '—' rows float to the top of a descending
     * sort would bury the largest values — the answer the user clicked the header
     * to see — under rows that have no value at all.
     */
    it('SORT: null values sort LAST in both directions', async () => {
        const element = createComponent();
        await emitPortfolio(element, [
            { ...SORT_PORTFOLIO[0], noi: null },
            SORT_PORTFOLIO[1],
            SORT_PORTFOLIO[2]
        ]);

        fireSort(element, 'noiLabel', 'asc');
        await Promise.resolve();
        expect(names(element)[2]).toBe('Zebra Tower');

        fireSort(element, 'noiLabel', 'desc');
        await Promise.resolve();
        expect(names(element)[2]).toBe('Zebra Tower');
    });

    /**
     * Sorting from page 3 without a reset lands the user on rows 11-15 of a
     * completely different ordering — an arbitrary window of a list they have just
     * reordered. Sorting is a request to see the top of something.
     */
    it('🔴 SORT: resets the pager to page 1', async () => {
        const element = createComponent();
        await emitPortfolio(element, SIX_GREEN);

        element.shadowRoot.querySelectorAll('.sm-pgbtn')[1].click();
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '6–6 of 6'
        );

        fireSort(element, 'noiLabel', 'asc');
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.sm-range').textContent).toBe(
            '1–5 of 6'
        );
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ITEM 4 (D-8) — THE RED SPLICE IS GONE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE SPLICE-REMOVAL PIN, AND THE ONLY TEST IN THE REPO THAT REACHES THE
     * BRANCH AT ALL. Until 2026-08-31 `allRows` pulled the first RED row up into
     * the last visible slot of page 1 "so the opening screen showcases all three
     * states". The user removed that outright at Gate 1 (design decision D-8).
     *
     * The fixture is the regression net the hack never had — 6 rows with the only
     * RED at index 5 — built to drive the branch and then INVERTED to assert its
     * absence. The precondition assertions below are what stop it going vacuous:
     * if the fixture ever stops having a late RED, it stops testing anything and
     * says so instead of passing.
     */
    it('🔴 SPLICE REMOVED: a late RED row stays on page 2 in the default view', async () => {
        const element = createComponent();
        await emitPortfolio(element, SIX_WITH_LATE_RED);

        // PRECONDITIONS — without these the assertion below is vacuous.
        expect(SIX_WITH_LATE_RED.filter((r) => r.sellMeter === 'RED').length).toBe(1);
        expect(SIX_WITH_LATE_RED.findIndex((r) => r.sellMeter === 'RED')).toBe(5);
        expect(SIX_WITH_LATE_RED.length).toBeGreaterThan(5);

        // Page 1 is the five non-RED rows in band order. Under the old splice the
        // last slot would hold 'Foxtrot Field' instead of 'Echo Park'.
        expect(names(element)).toEqual([
            'Alpha Center',
            'Bravo Plaza',
            'Charlie Court',
            'Delta Commons',
            'Echo Park'
        ]);
        expect(names(element)).not.toContain('Foxtrot Field');

        // Presence control: the RED row EXISTS, it is simply on page 2. Without
        // this half, the absence above would also pass if the row were dropped.
        element.shadowRoot.querySelectorAll('.sm-pgbtn')[1].click();
        await Promise.resolve();
        expect(names(element)).toEqual(['Foxtrot Field']);
    });

    it('SPLICE REMOVED: band order still governs the default (unsorted) view', async () => {
        const element = createComponent();
        await emitPortfolio(element, SIX_WITH_LATE_RED);

        // GREEN rows first, then YELLOW — the ordering the opening screen is for.
        const rows = datatable(element).data;
        expect(rows.map((r) => r.sellMeter.split(' |')[0])).toEqual([
            'Sell now',
            'Sell now',
            'Sell now',
            'Getting Close',
            'Getting Close'
        ]);
    });

    /**
     * Band order governs the UNSORTED view only. Once the user sorts, their column
     * wins outright — band order is not applied as a hidden tiebreak, because a
     * user who sorted by NOI asked for NOI order and a secondary key they cannot
     * see produces an order they cannot predict from the header they clicked.
     */
    it('🔴 SORT OVERRIDES BAND ORDER — a RED row can reach position 1', async () => {
        const element = createComponent();
        await emitPortfolio(element, SIX_WITH_LATE_RED);

        // Control: RED is last in the default view.
        expect(names(element)[0]).toBe('Alpha Center');

        fireSort(element, 'noiLabel', 'desc');
        await Promise.resolve();

        // Foxtrot Field (RED) has the highest NOI — 1.5M — so it now leads.
        expect(names(element)[0]).toBe('Foxtrot Field');
    });

    // ── GREEN: straight to the modal, no override question ───────────────────

    it('ROW ACTION (initiate): opens the modal with the PRE-FORMATTED row summary', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();
        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        // GREEN goes straight there — no override question.
        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);

        const args = SellMeterInitiateModal.open.mock.calls[0][0];
        expect(args.assetId).toBe('a0P000000000GRN');
        expect(args.propertyName).toBe('Gateway Plaza');
        // Handed over ALREADY FORMATTED, so the popup and the row behind it
        // cannot show different numbers for the same property.
        expect(args.noiLabel).toBe('$2.0M');
        expect(args.capRateLabel).toBe('6.5%');
        expect(args.targetLabel).toBe('$30.0M');
        expect(args.peakDateLabel).toBe('Jan 1, 2020');
        // 🔴 GREEN CARRIES NO OVERRIDE REASON. A reason on an initiate nobody
        // overrode would populate an audit field that means "a principal overrode
        // the meter" on a create where nobody did.
        expect(args.overrideReason).toBeNull();
    });

    it('SUCCESS: toasts success and navigates to the new Disposition', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        // The server's authored message is shown, not a re-authored client copy.
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            OUTCOME_SUBMITTED.message
        );

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe('a0D0000000000001');
    });

    it('🔴 NOT SUBMITTED: WARNING toast and STILL NAVIGATES — the record exists', async () => {
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_NOT_SUBMITTED
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('warning');
        expect(toast.message).toBe(OUTCOME_NOT_SUBMITTED.message);
        // Sticky: this is the only notice that an approval still has to be
        // raised by hand, and the navigation below happens in the same tick.
        expect(toast.mode).toBe('sticky');

        // The whole point: navigation is NOT conditional on `submitted`.
        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(
            navHandler.mock.calls[0][0].detail.pageReference.attributes.recordId
        ).toBe('a0D0000000000002');
    });

    it('DISMISSED: closing the modal creates nothing and says nothing', async () => {
        SellMeterInitiateModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('REFUSED SERVER-SIDE: surfaces the sell-meter message VERBATIM and does not navigate', async () => {
        // DispositionService's gate refuses with an authored, user-safe message.
        // It must reach the toast intact rather than being replaced by generic
        // wording — that is the whole reason DispositionController has a
        // dedicated SellMeterGateException catch.
        SellMeterInitiateModal.open.mockResolvedValue({
            error: {
                body: {
                    message:
                        'This property is not ready to sell - its peak sell date is more than 90 days away, so a disposition cannot be initiated yet.'
                }
            }
        });
        const consoleError = jest
            .spyOn(console, 'error')
            .mockImplementation(() => {});

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('error');
        expect(toast.mode).toBe('sticky');
        expect(toast.message).toContain('not ready to sell');
        expect(navHandler).not.toHaveBeenCalled();

        consoleError.mockRestore();
    });

    // ── RED: inert. The band gate is IN FRONT of the modal, not inside it ────

    it('ROW ACTION (hold): the red row is inert — no override question, no modal', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, RED));
        await flushPromises();

        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('ROW ACTION (unknown action): still inert — the guard accepts exactly two names', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        // Unknown name via the ROW (the branch that now decides in production).
        fireRealRowAction(element, {
            ...rowAt(element, GREEN),
            actionName: 'somethingElse'
        });
        await flushPromises();

        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    it('LEGACY STRING SHAPE: a real string action.name still wins over the row', async () => {
        // Covers the defensive branch of `_resolveActionName`. A statically-named
        // column (or a future platform version that DOES resolve typeAttributes)
        // sends a genuine string, and it must take precedence over `row.actionName`
        // rather than being ignored in favour of it.
        const element = createComponent();
        await emitPortfolio(element);

        // Row says 'initiate' (GREEN); the explicit string says 'somethingElse'.
        // If the string branch were dropped, this would fall through to the row.
        fireLegacyStringRowAction(element, 'somethingElse', rowAt(element, GREEN));
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();

        // And the accepted string name drives the modal off a resolved row.
        fireLegacyStringRowAction(element, 'initiate', rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000GRN'
        );
    });

    // ── YELLOW: the override question comes FIRST, and carries a reason ──────

    it('ROW ACTION (override confirmed): asks FIRST, then opens the same modal', async () => {
        const callOrder = [];
        SellMeterOverrideModal.open.mockImplementation(() => {
            callOrder.push('override');
            return Promise.resolve({ confirmed: true, reason: OVERRIDE_REASON });
        });
        SellMeterInitiateModal.open.mockImplementation(() => {
            callOrder.push('initiate');
            return Promise.resolve({ outcome: OUTCOME_SUBMITTED });
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();
        await flushPromises();

        // 🔴 ORDER IS THE POINT. Asking inside the initiate modal instead would let
        // a user fill in a record type before being told the property is not at peak.
        expect(callOrder).toEqual(['override', 'initiate']);

        // The dialog has to be able to name the property, or the user is confirming
        // a word rather than a decision. (The MESSAGE now lives inside the modal —
        // its own suite pins that the name is rendered; this pins the hand-off.)
        const overrideArgs = SellMeterOverrideModal.open.mock.calls[0][0];
        expect(overrideArgs.propertyName).toBe('Harbor Point');

        // Identical modal call to the Initiate path — an override must not diverge.
        expect(SellMeterInitiateModal.open.mock.calls[0][0].assetId).toBe(
            'a0P000000000YEL'
        );

        // A DISTINCT success toast: the user must be able to tell an override
        // apart from a routine initiate.
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.title).toContain('override');

        expect(navHandler).toHaveBeenCalledTimes(1);
    });

    /**
     * 🔴 THE REASON THREAD. It is collected by c/sellMeterOverrideModal, handed to
     * c/sellMeterInitiateModal as a pass-through @api, and forwarded by that modal
     * to Apex as `initiateAndSubmit`'s third argument. If the thread breaks
     * ANYWHERE the audit field arrives blank and every layer still reports success
     * — there is no error, no toast and no log. So the hand-off is asserted rather
     * than assumed, at the one boundary this component owns.
     */
    it('🔴 OVERRIDE REASON: threaded from the override dialog into the initiate modal', async () => {
        SellMeterOverrideModal.open.mockResolvedValue({
            confirmed: true,
            reason: OVERRIDE_REASON
        });
        SellMeterInitiateModal.open.mockResolvedValue({
            outcome: OUTCOME_SUBMITTED
        });

        const element = createComponent();
        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();
        await flushPromises();

        expect(SellMeterInitiateModal.open.mock.calls[0][0].overrideReason).toBe(
            OVERRIDE_REASON
        );
    });

    it('ROW ACTION (override cancelled): opens nothing and says nothing', async () => {
        SellMeterOverrideModal.open.mockResolvedValue({ confirmed: false });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();

        expect(SellMeterOverrideModal.open).toHaveBeenCalledTimes(1);
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
        // No toast on cancel — the user already knows they cancelled.
        expect(toastHandler).not.toHaveBeenCalled();
        expect(navHandler).not.toHaveBeenCalled();
    });

    /**
     * A DISMISS resolves `undefined`, not `{ confirmed: false }` — that is
     * LightningModal's own behaviour and the override modal cannot intercept it.
     * The caller's guard is `answer && answer.confirmed === true`, and this is the
     * test that fails if someone "simplifies" it to `!answer.confirmed`.
     */
    it('🔴 ROW ACTION (override DISMISSED, resolves undefined): opens nothing', async () => {
        SellMeterOverrideModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    /**
     * A modal-layer failure is a REFUSAL, not a pass. A prompt that could not be
     * shown has not been answered, and proceeding on a question nobody saw is the
     * one outcome this dialog exists to prevent.
     */
    it('🔴 OVERRIDE DIALOG FAILS TO OPEN: refuses rather than proceeding', async () => {
        SellMeterOverrideModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );
        const consoleError = jest
            .spyOn(console, 'error')
            .mockImplementation(() => {});

        const element = createComponent();
        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();

        consoleError.mockRestore();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // ITEM 5a — THE PRINCIPAL GATE ON THE CLIENT
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 D-11: A NON-PRINCIPAL SEES THE BUTTON, STILL LABELLED "Override",
     * DISABLED — mirroring the RED "Hold" idiom already in this column. Hiding it
     * would leave a blank cell, which reads as a rendering fault rather than as a
     * permission.
     *
     * ⚠ PRESENCE-THEN-ABSENCE ON ONE INSTANCE. The enabled state is asserted from
     * the same component after the permission flips, so neither half can pass
     * because the button was deleted.
     */
    it('🔴 OVERRIDE GATE: YELLOW is disabled for a non-principal and enabled for a principal', async () => {
        const element = createComponent();
        await emitPortfolio(element, PORTFOLIO, false);

        let yellow = rowAt(element, YELLOW);
        expect(yellow.actionLabel).toBe('Override');
        expect(yellow.actionName).toBe('override');
        expect(yellow.actionDisabled).toBe(true);

        hasOverrideAccess.emit(true);
        await Promise.resolve();

        yellow = rowAt(element, YELLOW);
        expect(yellow.actionLabel).toBe('Override');
        expect(yellow.actionDisabled).toBe(false);
    });

    /**
     * 🔴 GREEN INITIATE STAYS OPEN TO ANALYSTS. This is the over-reach control: an
     * enablement rule applied to the whole Action column instead of the YELLOW
     * branch would close Initiate to every non-principal, which no story asks for
     * and which is the design's named hazard for this item.
     */
    it('🔴 OVERRIDE GATE: GREEN Initiate is NOT affected by the permission', async () => {
        const element = createComponent();
        await emitPortfolio(element, PORTFOLIO, false);

        expect(rowAt(element, GREEN).actionLabel).toBe('Initiate');
        expect(rowAt(element, GREEN).actionDisabled).toBe(false);
        // And RED is still disabled for its own, unrelated reason.
        expect(rowAt(element, RED).actionDisabled).toBe(true);
    });

    /**
     * The dispatcher refuses 'override' independently of the disabled attribute. A
     * disabled attribute is a rendering instruction; this handler is reachable from
     * a `rowaction` event, and this component's own history is a lesson in how far
     * a row-action payload can diverge from what the column definition says.
     */
    it('🔴 OVERRIDE GATE: a non-principal firing the row action opens nothing', async () => {
        const element = createComponent();
        await emitPortfolio(element, PORTFOLIO, false);

        fireRealRowAction(element, rowAt(element, YELLOW));
        await flushPromises();
        await flushPromises();

        expect(SellMeterOverrideModal.open).not.toHaveBeenCalled();
        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
    });

    /**
     * 🔴 THE WIRE HAS NOT ANSWERED YET. The flag defaults to FALSE so the button is
     * disabled during the round trip — a control that appeared and then withdrew
     * would read as a bug and is clickable in the gap.
     */
    it('🔴 OVERRIDE GATE: disabled before the permission wire answers', async () => {
        const element = createComponent();
        getPortfolio.emit(PORTFOLIO);   // deliberately WITHOUT the permission wire
        await Promise.resolve();

        expect(rowAt(element, YELLOW).actionDisabled).toBe(true);

        // Presence control: it does open once the answer arrives.
        hasOverrideAccess.emit(true);
        await Promise.resolve();
        expect(rowAt(element, YELLOW).actionDisabled).toBe(false);
    });

    /**
     * 🔴 FAILS CLOSED ON A WIRE ERROR, AND DOES NOT RAISE THE LIST'S ERROR BANNER.
     * A permission check that faulted is not a failure to load the list — the table
     * is fine and the user can still Initiate GREEN rows and read every number.
     * Replacing a working page with "Sell meter list could not be loaded" because a
     * permission check faulted is the wrong degradation.
     */
    it('🔴 OVERRIDE GATE: a wire error disables the button and leaves the list intact', async () => {
        const consoleError = jest
            .spyOn(console, 'error')
            .mockImplementation(() => {});

        const element = createComponent();
        getPortfolio.emit(PORTFOLIO);
        hasOverrideAccess.error();
        await Promise.resolve();

        expect(rowAt(element, YELLOW).actionDisabled).toBe(true);
        // The list is still rendered and the error banner is NOT shown.
        expect(datatable(element).data.length).toBe(3);
        expect(element.shadowRoot.querySelector('.sm-error')).toBeNull();
        // GREEN still works — the degradation is narrow.
        expect(rowAt(element, GREEN).actionDisabled).toBe(false);

        consoleError.mockRestore();
    });

    // ── REMAINING BOUNDARIES ─────────────────────────────────────────────────

    it('ROW ACTION with no asset id: toasts and never opens the modal', async () => {
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await emitPortfolio(element);

        // Legacy string shape ON PURPOSE: the row is deliberately malformed (no id
        // and no actionName), so the accepted action name has to come from the
        // string branch for the missing-id guard to be reachable at all.
        fireLegacyStringRowAction(element, 'initiate', { name: 'Orphan row' });
        await flushPromises();

        expect(SellMeterInitiateModal.open).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
    });

    it('MODAL FAILS TO OPEN: distinct message, no navigation', async () => {
        SellMeterInitiateModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        await emitPortfolio(element);

        fireRealRowAction(element, rowAt(element, GREEN));
        await flushPromises();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        // Nothing was created and nothing was even attempted, so this must NOT
        // reuse the server-refusal wording.
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the initiate dialog'
        );
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: empty datatable + inline error banner when the portfolio wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        expect(datatable(element).data).toEqual([]);
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Sell Meter (0)');
        // Wire failure surfaces an inline error banner instead of a silent empty list.
        expect(element.shadowRoot.querySelector('.sm-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();
        await emitPortfolio(element);

        await expect(element).toBeAccessible();
    });

    it('is accessible after sorting', async () => {
        const element = createComponent();
        await emitPortfolio(element, SORT_PORTFOLIO);

        fireSort(element, 'meterScoreLabel', 'desc');
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
