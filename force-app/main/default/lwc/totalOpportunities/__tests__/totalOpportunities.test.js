/**
 * c-total-opportunities — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1) + statCard child assertions.
 *
 * Data source: @wire(getStageCounts) from
 * OpportunityFunnelController.getStageCounts -> a LIST of { label, count } rows.
 * The JS ALWAYS renders one c-stat-card per fixed STAGE_META entry (9 cards),
 * defaulting each to '0' — so the card renders before the wire emits.
 */
import { createElement } from 'lwc';
import TotalOpportunities from 'c/totalOpportunities';
import getStageCounts from '@salesforce/apex/OpportunityFunnelController.getStageCounts';

jest.mock(
    '@salesforce/apex/OpportunityFunnelController.getStageCounts',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const STAGE_COUNTS = [
    { label: 'New', count: 8 },
    { label: 'Under Review', count: 6 },
    { label: 'Development Review', count: 3 },
    { label: 'Construction Review', count: 2 },
    { label: 'Underwriting', count: 5 },
    { label: 'LOI', count: 4 },
    { label: 'Under Contract (PSA)', count: 7 },
    { label: 'Closed Won', count: 9 },
    { label: 'Dead/Pass', count: 1 }
];

describe('c-total-opportunities', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-total-opportunities', {
            is: TotalOpportunities
        });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return element.shadowRoot.querySelectorAll('c-stat-card');
    }

    it('EMPTY: renders all nine stage cards at 0 before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const stageCards = cards(element);
        expect(stageCards.length).toBe(9);
        expect([...stageCards].every((c) => c.value === '0')).toBe(true);
    });

    it('DATA BRANCH: maps each stage count onto its stat card', async () => {
        const element = createComponent();

        getStageCounts.emit(STAGE_COUNTS);
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        expect(values).toEqual(['8', '6', '3', '2', '5', '4', '7', '9', '1']);

        // Fixed labels from STAGE_META (with the "Last 90 Days" suffixes).
        //
        // ⚠ Both assertions pin a key/label DIVERGENCE, which is the point of them. The wire
        // payload above carries the stage API values 'Under Contract (PSA)' and 'Dead/Pass'; the
        // rendered labels drop '(PSA)' and '/Pass' respectively so the card does not read
        // 'Under Contract (PSA) (Last 90 Days)'. A future edit that "tidies" the label back to the
        // stage value reds here.
        const labels = [...cards(element)].map((c) => c.label);
        expect(labels[6]).toBe('Under Contract (Last 90 Days)');
        expect(labels[8]).toBe('Dead (Last 90 Days)');
    });

    it('DATA BRANCH: ignores unknown labels and defaults unreported stages to 0', async () => {
        const element = createComponent();

        // ⚠ '__NOT_A_REAL_STAGE__' is a DELIBERATELY SYNTHETIC value, not a real Opportunity
        // stage. The point of this fixture is only that the label is absent from STAGE_META, so
        // the component drops the row instead of rendering a tenth card. A value that can never
        // exist in the OpportunityStage picklist keeps that intent readable on its own and keeps
        // the test independent of which stages the org happens to have configured — the previous
        // fixture used a real-but-unmapped stage, which quietly lost its meaning the moment that
        // stage was retired from the picklist.
        getStageCounts.emit([
            { label: 'LOI', count: 12 },
            { label: '__NOT_A_REAL_STAGE__', count: 99 } // not in STAGE_META -> ignored
        ]);
        await Promise.resolve();

        const values = [...cards(element)].map((c) => c.value);
        // LOI is index 5; everything else stays '0'; 99 never appears.
        expect(values).toEqual(['0', '0', '0', '0', '0', '12', '0', '0', '0']);
        expect(values).not.toContain('99');
    });

    it('ERROR BRANCH: keeps the nine 0 cards and surfaces an inline alert when the wire errors', async () => {
        const element = createComponent();

        getStageCounts.error();
        await Promise.resolve();

        expect([...cards(element)].every((c) => c.value === '0')).toBe(true);
        // Additive error banner appears without hiding the existing zero cards.
        expect(
            element.shadowRoot.querySelector('[role="alert"]')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getStageCounts.emit(STAGE_COUNTS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
