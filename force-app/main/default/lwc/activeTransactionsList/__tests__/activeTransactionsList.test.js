/**
 * c-active-transactions-list — @wire-to-Apex + NavigationMixin.
 * Combines wire-mock template 1 (Apex @wire, no params) with the navigation
 * assertion pattern from c-broker-scorecard.
 *
 * Data source: @wire(getActiveTransactions) -> TransactionController, a list of
 * transaction wrappers { id, name, propertyName, stage, price, targetClose,
 * tasksComplete, tasksTotal, risk }. The component maps each into a datatable row
 * and renders them through the shared c-list-datatable subclass.
 *
 * 🔴 `tasksTotal` IS PER ROW AND IS NULLABLE — the two facts this suite exists to pin
 * (added 2026-08-12). The component used to divide by a hardcoded 75 while the record
 * page showed 82; both were wrong, because TaskFanoutService writes
 * `Tasks_Total__c = createdForTxn`, a count gated by each Transaction's own condition
 * fields. So the fixtures below carry DIFFERENT totals on purpose — two rows sharing a
 * denominator cannot falsify a reintroduced constant — and a third row carries `null`,
 * the state of every Transaction created but not yet fanned out
 * (`Tasks_Fanned_Out__c = false`). A null denominator must render the em-dash
 * placeholder and a 0%-width bar: never NaN, never Infinity, and never a substituted
 * constant.
 *
 * ROW ASSERTIONS go through c-list-datatable's `@api data` (it extends the stubbed
 * lightning/datatable base, which exposes `data`), NOT cell DOM — the custom
 * cell templates aren't rendered by the stub. So we read
 * shadowRoot.querySelector('c-list-datatable').data and assert the mapped fields.
 *
 * NAVIGATION: lightning/navigation is mocked (lwc-recipes pattern) so the mixin's
 * [Navigate] dispatches a catchable 'navigate' event and [GenerateUrl] resolves a
 * URL (connectedCallback awaits it to set the "View All" href). "View All" click
 * -> viewAll() -> Navigate to the Transaction__c list page.
 *
 * Date/money labels are computed by manual string parsing (no `new Date()`), so
 * the derived text is timezone-stable and safe to assert.
 */
import { createElement } from 'lwc';
import ActiveTransactionsList from 'c/activeTransactionsList';
import getActiveTransactions from '@salesforce/apex/TransactionController.getActiveTransactions';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', {
                            detail: { pageReference }
                        })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('/lightning/o/Transaction__c/list');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/TransactionController.getActiveTransactions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const TXNS = [
    {
        id: 'a0T5g00000Txn01AAB',
        name: 'TXN-0001',
        propertyName: 'Willow Creek Plaza',
        stage: 'Due Diligence',
        price: 4500000,
        targetClose: '2026-09-15',
        tasksComplete: 30,
        // A loan-bearing deal: the full checklist.
        tasksTotal: 82,
        risk: 'Watch'
    },
    {
        id: 'a0T5g00000Txn02AAB',
        name: 'TXN-0002',
        propertyName: 'Maple Center',
        stage: 'Closing Prep',
        price: 12000000,
        targetClose: '2026-08-01',
        tasksComplete: 64,
        // ⚠ A DIFFERENT total from row 1, deliberately: an all-cash deal skips the financing task
        // groups. Two rows sharing a denominator could not falsify a reintroduced constant.
        tasksTotal: 64,
        risk: 'Low'
    },
    {
        id: 'a0T5g00000Txn03AAB',
        name: 'TXN-0003',
        // No Property lookup and no legacy text value — Apex sends null, not an em-dash.
        propertyName: null,
        stage: 'Open Contract',
        price: 8000000,
        targetClose: '2026-10-20',
        tasksComplete: 0,
        // 🔴 NOT YET FANNED OUT. Tasks_Fanned_Out__c = false, so Tasks_Total__c is null.
        tasksTotal: null,
        risk: 'Low'
    }
];

describe('c-active-transactions-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-active-transactions-list', {
            is: ActiveTransactionsList
        });
        document.body.appendChild(element);
        return element;
    }

    function datatable(element) {
        return element.shadowRoot.querySelector('c-list-datatable');
    }

    it('renders an empty datatable + (0) count before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Active Transactions (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('DATA BRANCH: maps each transaction into a datatable row', async () => {
        const element = createComponent();

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Active Transactions (3)');

        const rows = datatable(element).data;
        expect(rows.length).toBe(3);

        expect(rows[0].name).toBe('TXN-0001');
        expect(rows[0].propertyName).toBe('Willow Creek Plaza');
        expect(rows[0].stage).toBe('Due Diligence');
        expect(rows[0].priceLabel).toBe('$4.5M');
        expect(rows[0].targetCloseLabel).toBe('Sep 15');
        expect(rows[0].tasksText).toBe('30 / 82');
        expect(rows[0].recordUrl).toBe(
            '/lightning/r/Transaction__c/a0T5g00000Txn01AAB/view'
        );

        // Whole-million price renders without a decimal.
        expect(rows[1].priceLabel).toBe('$12M');
        expect(rows[1].targetCloseLabel).toBe('Aug 01');
        // 🔴 THE DENOMINATOR IS THIS ROW'S OWN, not row 0's and not a constant. A reintroduced
        // `TASKS_TOTAL` would show '64 / 75' here and this assertion is what would catch it.
        expect(rows[1].tasksText).toBe('64 / 64');
    });

    it('PER-ROW DENOMINATOR: a complete checklist uses the completion colour, a partial one does not', async () => {
        const element = createComponent();

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        const rows = datatable(element).data;

        // 30 of 82 — partial: teal bar, width 37%.
        expect(rows[0].tasksBar).toContain('width:37%');
        expect(rows[0].tasksBar).toContain('#2BAFAC');

        // 64 of 64 — complete AGAINST ITS OWN TOTAL: green bar, width 100%. Under the old
        // hardcoded 75 this row was 85% and never turned green, which is the visible half of
        // the defect.
        expect(rows[1].tasksBar).toContain('width:100%');
        expect(rows[1].tasksBar).toContain('#2e7d32');
    });

    /**
     * FALSIFIER FOR THE TERMINAL STAGE KEY IN THE `STAGE` COLOUR MAP.
     *
     * The shared TXNS fixture seeds only Due Diligence / Closing Prep / Open Contract, so the
     * terminal key was never exercised. While it was stale ('Closed Won', before the 2026-08-28
     * rename) every row still mapped, the badge simply fell through to FALLBACK grey, and this
     * whole suite stayed green — the same silent shape found in c-transaction-critical-dates.
     *
     * Row 2 is a deliberately unmapped stage so FALLBACK is proven DISTINGUISHABLE rather than
     * assumed; without it, "resolves to green" could not be told apart from "everything is green".
     *
     * 🔴 The last block is the non-crossing proof. `STAGE` and `RISK` BOTH have a 'Closed' key
     * against two DIFFERENT fields (Stage__c and Risk__c) with two DIFFERENT colour pairs, so a
     * future "dedupe these maps" refactor has an assertion standing in its way.
     */
    it('TERMINAL STAGE: the Closed key resolves to its own colours, not FALLBACK and not Risk__c', async () => {
        const element = createComponent();

        getActiveTransactions.emit([
            { ...TXNS[0], id: 'a0T5g00000Txn04AAB', name: 'TXN-0004', stage: 'Closed', risk: 'Closed' },
            { ...TXNS[0], id: 'a0T5g00000Txn05AAB', name: 'TXN-0005', stage: 'Not A Stage', risk: 'Low' }
        ]);
        await Promise.resolve();

        const [closed, unmapped] = datatable(element).data;

        // STAGE['Closed'] = ['#e9f5ec', '#3fae5e'] — the green pair.
        expect(closed.stageWrap).toContain('#e9f5ec');
        expect(closed.stageDot).toContain('#3fae5e');

        // FALLBACK = ['#eef1f4', '#94a3b8'] — what an unknown (or stale) key produces.
        expect(closed.stageWrap).not.toContain('#eef1f4');
        expect(unmapped.stageWrap).toContain('#eef1f4');
        expect(unmapped.stageDot).toContain('#94a3b8');

        // RISK['Closed'] = ['#edf0f4', '#3b5a8c'] — same key string, different field, different
        // colours. The two pills must resolve independently.
        expect(closed.riskWrap).toContain('#edf0f4');
        expect(closed.riskDot).toContain('#3b5a8c');
        expect(closed.stageDot).not.toContain('#3b5a8c');
        expect(closed.riskDot).not.toContain('#3fae5e');
    });

    it('NULL DENOMINATOR: an un-fanned-out checklist renders an em-dash and an empty bar, never NaN', async () => {
        const element = createComponent();

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        const row = datatable(element).data[2];

        // 🔴 No denominator means no ratio to state. Not '0 / 0', not '0 / 75', not '0 / null'.
        expect(row.tasksText).toBe('—');
        // The division must never have happened: NaN/Infinity in the width string would render as
        // an invisibly broken bar rather than an obviously empty one.
        expect(row.tasksBar).toContain('width:0%');
        expect(row.tasksBar).not.toContain('NaN');
        expect(row.tasksBar).not.toContain('Infinity');
        // And it is NOT treated as complete — the green "done" colour must not appear.
        expect(row.tasksBar).toContain('#2BAFAC');

        // A Transaction with no Property lookup still falls back to the placeholder.
        expect(row.propertyName).toBe('—');
    });

    it('navigates to the Transaction__c list page when "View All" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail.pageReference).toEqual({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Transaction__c',
                actionName: 'list'
            }
        });
    });

    it('ERROR BRANCH: shows an inline error (not the datatable) when the wire errors', async () => {
        const element = createComponent();

        getActiveTransactions.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Active Transactions (0)');
        expect(datatable(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.wire-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
