/**
 * c-active-transactions-list — @wire-to-Apex + NavigationMixin.
 * Combines wire-mock template 1 (Apex @wire, no params) with the navigation
 * assertion pattern from c-broker-scorecard.
 *
 * Data source: @wire(getActiveTransactions) -> TransactionController, a list of
 * transaction wrappers { id, name, propertyName, stage, price, targetClose,
 * tasksComplete, risk }. The component maps each into a datatable row and renders
 * them through the shared c-list-datatable subclass.
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
        risk: 'Watch'
    },
    {
        id: 'a0T5g00000Txn02AAB',
        name: 'TXN-0002',
        propertyName: 'Maple Center',
        stage: 'Closing Prep',
        price: 12000000,
        targetClose: '2026-08-01',
        tasksComplete: 75,
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
        ).toBe('Active Transactions (2)');

        const rows = datatable(element).data;
        expect(rows.length).toBe(2);

        expect(rows[0].name).toBe('TXN-0001');
        expect(rows[0].propertyName).toBe('Willow Creek Plaza');
        expect(rows[0].stage).toBe('Due Diligence');
        expect(rows[0].priceLabel).toBe('$4.5M');
        expect(rows[0].targetCloseLabel).toBe('Sep 15');
        expect(rows[0].tasksText).toBe('30 / 75');
        expect(rows[0].recordUrl).toBe(
            '/lightning/r/Transaction__c/a0T5g00000Txn01AAB/view'
        );

        // Whole-million price renders without a decimal; 75/75 tasks.
        expect(rows[1].priceLabel).toBe('$12M');
        expect(rows[1].targetCloseLabel).toBe('Aug 01');
        expect(rows[1].tasksText).toBe('75 / 75');
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

    it('ERROR BRANCH: keeps the empty datatable when the wire errors', async () => {
        const element = createComponent();

        getActiveTransactions.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Active Transactions (0)');
        expect(datatable(element).data).toEqual([]);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getActiveTransactions.emit(TXNS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
