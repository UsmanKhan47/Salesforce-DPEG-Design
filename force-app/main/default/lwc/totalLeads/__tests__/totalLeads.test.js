/**
 * c-total-leads — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + statCard child assertions.
 *
 * Data source: @wire(getFunnel) from LeadFunnelController.getFunnel. The JS reads
 * `data.stages` ([{ label, count }]) and ALWAYS renders one c-stat-card per fixed
 * STAGE_META entry (5 cards), defaulting each to '0' — so the card renders before
 * the wire emits and merely fills in values afterward.
 */
import { createElement } from 'lwc';
import TotalLeads from 'c/totalLeads';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';

jest.mock(
    '@salesforce/apex/LeadFunnelController.getFunnel',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const FUNNEL = {
    stages: [
        { label: 'New', count: 10 },
        { label: 'Under Review', count: 7 },
        { label: 'Qualified', count: 4 },
        { label: 'Converted', count: 20 },
        { label: 'Disqualified', count: 3 }
    ]
};

describe('c-total-leads', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-total-leads', { is: TotalLeads });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return element.shadowRoot.querySelectorAll('c-stat-card');
    }

    it('EMPTY: renders all five stage cards at 0 before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '0', '0']);
    });

    it('DATA BRANCH: maps each stage count onto its stat card', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        const stageCards = cards(element);
        expect(stageCards.length).toBe(5);

        const values = [...stageCards].map((c) => c.value);
        expect(values).toEqual(['10', '7', '4', '20', '3']);

        // Fixed labels come from STAGE_META, not the wire payload.
        expect(stageCards[0].label).toBe('New');
        expect(stageCards[3].label).toBe('Converted (Last 90 Days)');
    });

    it('DATA BRANCH: leaves an unreported stage at its 0 default', async () => {
        const element = createComponent();

        getFunnel.emit({ stages: [{ label: 'Qualified', count: 6 }] });
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        // Only Qualified (index 2) is reported; the rest stay '0'.
        expect(values).toEqual(['0', '0', '6', '0', '0']);
    });

    it('ERROR BRANCH: keeps the five 0 cards when the wire errors', async () => {
        const element = createComponent();

        getFunnel.error();
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['0', '0', '0', '0', '0']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
