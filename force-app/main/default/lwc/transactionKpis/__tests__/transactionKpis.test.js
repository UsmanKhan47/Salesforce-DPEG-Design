/**
 * @wire to APEX (no parameters). c-transaction-kpis reads
 *   @wire(getKpis) -> TransactionController.TxnKpis
 * and renders four c-stat-card tiles with formatted $M / $k / day values.
 * Register getKpis as an Apex test wire adapter and drive it with .emit().
 */
import { createElement } from 'lwc';
import TransactionKpis from 'c/transactionKpis';
import getKpis from '@salesforce/apex/TransactionController.getKpis';

jest.mock(
    '@salesforce/apex/TransactionController.getKpis',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches TransactionController.TxnKpis (Decimals serialize as strings/numbers).
const KPIS = {
    activeCount: 7,
    inContractValue: 48000000,
    earnestAtRisk: 250000,
    avgTimeToCloseDays: 45,
    wireApprovalsDue: 2,
    missedFeasibilityYtd: 1
};

describe('c-transaction-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-transaction-kpis', {
            is: TransactionKpis
        });
        document.body.appendChild(element);
        return element;
    }

    function cardValues(element) {
        return [...element.shadowRoot.querySelectorAll('c-stat-card')].map(
            (c) => c.value
        );
    }

    it('renders four zeroed tiles before the wire resolves', async () => {
        const element = createComponent();

        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect(cardValues(element)).toEqual(['0', '$0', '$0', '0d']);
    });

    it('DATA BRANCH: formats each KPI ($M whole, $k, day suffix)', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        expect(cardValues(element)).toEqual(['7', '$48M', '$250k', '45d']);

        const labels = [
            ...element.shadowRoot.querySelectorAll('c-stat-card')
        ].map((c) => c.label);
        expect(labels).toEqual([
            'Active Transactions',
            'In Contract',
            'Earnest at Risk',
            'Avg Time-to-Close'
        ]);
    });

    it('DATA BRANCH: keeps a fractional $M for a non-whole in-contract total', async () => {
        const element = createComponent();

        getKpis.emit({ ...KPIS, inContractValue: 12500000, earnestAtRisk: 0 });
        await Promise.resolve();

        const values = cardValues(element);
        expect(values[1]).toBe('$13M'); // moneyWhole rounds to whole $M
        expect(values[2]).toBe('$0');
    });

    it('ERROR BRANCH: keeps the zeroed defaults when the wire errors', async () => {
        const element = createComponent();

        getKpis.error();
        await Promise.resolve();

        expect(cardValues(element)).toEqual(['0', '$0', '$0', '0d']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
