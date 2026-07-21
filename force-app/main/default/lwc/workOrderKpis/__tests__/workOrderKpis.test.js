/**
 * c-work-order-kpis — @wire-to-Apex (no-param) KPI strip.
 *
 * Data source: @wire(getHomeKpis) on WorkOrderController, returning a wrapper
 * { open, breached, dueSoon, untouched }. The `cards` getter always yields four
 * entries (?? 0), so four c-stat-card children render even before the wire
 * emits — the child value simply falls back to 0. Assertions read the public
 * `value` property on each c-stat-card host rather than reaching into the
 * child's shadow root.
 */
import { createElement } from 'lwc';
import WorkOrderKpis from 'c/workOrderKpis';
import getHomeKpis from '@salesforce/apex/WorkOrderController.getHomeKpis';

jest.mock(
    '@salesforce/apex/WorkOrderController.getHomeKpis',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const KPIS = { open: 42, breached: 7, dueSoon: 3, untouched: 5 };

describe('c-work-order-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-work-order-kpis', {
            is: WorkOrderKpis
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders four KPI cards defaulting to 0 before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect([...cards].map((c) => c.value)).toEqual([0, 0, 0, 0]);
    });

    it('DATA BRANCH: binds each KPI value and label to the wired wrapper', async () => {
        const element = createComponent();

        getHomeKpis.emit(KPIS);
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect([...cards].map((c) => c.value)).toEqual([42, 7, 3, 5]);
        expect([...cards].map((c) => c.label)).toEqual([
            'Open Work Orders',
            'Breached SLA',
            'Due Soon',
            'Untouched'
        ]);
    });

    it('ERROR BRANCH: keeps the four 0 cards and surfaces an inline alert when the wire errors', async () => {
        const element = createComponent();

        getHomeKpis.error();
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect([...cards].map((c) => c.value)).toEqual([0, 0, 0, 0]);
        // Additive error banner appears without hiding the existing zero cards.
        expect(
            element.shadowRoot.querySelector('[role="alert"]')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getHomeKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
