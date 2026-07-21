/**
 * c-renewal-kpis — @wire-to-Apex (no-param) KPI strip on the Lease Renewals home.
 *
 * Data source: @wire(getHomeKpis) on LeaseRenewalController, returning a wrapper
 * { active, expiring90, nonResponsive, renewedYtd }. As with c-work-order-kpis,
 * the `cards` getter always emits four entries (?? 0), so four c-stat-card
 * children render even before the wire settles. Assertions read the public
 * `value`/`label` props on each c-stat-card host.
 */
import { createElement } from 'lwc';
import RenewalKpis from 'c/renewalKpis';
import getHomeKpis from '@salesforce/apex/LeaseRenewalController.getHomeKpis';

jest.mock(
    '@salesforce/apex/LeaseRenewalController.getHomeKpis',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const KPIS = { active: 18, expiring90: 6, nonResponsive: 4, renewedYtd: 23 };

describe('c-renewal-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-renewal-kpis', {
            is: RenewalKpis
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
        expect([...cards].map((c) => c.value)).toEqual([18, 6, 4, 23]);
        expect([...cards].map((c) => c.label)).toEqual([
            'Active Renewals',
            'Expiring ≤ 90 Days',
            'Non-Responsive',
            'Renewed (YTD)'
        ]);
    });

    it('ERROR BRANCH: renders an inline error message instead of the KPI cards', async () => {
        const element = createComponent();

        getHomeKpis.error({ message: 'Renewal metrics unavailable.' });
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('c-stat-card').length).toBe(0);
        const err = element.shadowRoot.querySelector('.kpi-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Renewal metrics unavailable.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getHomeKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
