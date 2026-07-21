/**
 * c-broker-assignment-kpis
 * ---------------------------------------------------------------------------
 * Single no-param @wire(getKpis). Maps the Kpis wrapper (total/stale/leased) onto
 * three c-stat-card children. Before the wire emits (and on error) the getter
 * falls back to zeros, so the tiles always render.
 */
import { createElement } from 'lwc';
import BrokerAssignmentKpis from 'c/brokerAssignmentKpis';
import getKpis from '@salesforce/apex/BrokerAssignmentController.getKpis';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getKpis',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const KPIS = { total: 10, active: 6, stale: 3, leased: 4 };

describe('c-broker-assignment-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-assignment-kpis', {
            is: BrokerAssignmentKpis
        });
        document.body.appendChild(element);
        return element;
    }

    function cardValues(element) {
        return [...element.shadowRoot.querySelectorAll('c-stat-card')].map(
            (c) => c.value
        );
    }

    it('renders three tiles with zeros before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(3);
        expect(cardValues(element)).toEqual([0, 0, 0]);
    });

    it('DATA BRANCH: maps total, stale and leased onto the tiles', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        expect(cardValues(element)).toEqual([10, 3, 4]);

        const labels = [...element.shadowRoot.querySelectorAll('c-stat-card')].map(
            (c) => c.label
        );
        expect(labels).toEqual([
            'Total Assignments / Active',
            'Stale',
            'Fully Leased'
        ]);
    });

    it('ERROR BRANCH: keeps the zero tiles and shows an error banner when the wire errors', async () => {
        const element = createComponent();

        getKpis.error();
        await Promise.resolve();

        expect(cardValues(element)).toEqual([0, 0, 0]);
        const banner = element.shadowRoot.querySelector('.kpi-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toBe("Couldn't load assignment KPIs.");
    });

    it('is accessible', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
