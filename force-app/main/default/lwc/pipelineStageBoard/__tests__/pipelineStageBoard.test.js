/**
 * c-pipeline-stage-board — dual @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1), extended to TWO adapters.
 *
 * Data sources:
 *   @wire(getFunnel)     from LeadFunnelController.getFunnel       -> { stages:[{label,count}] }
 *   @wire(getStageCounts) from OpportunityFunnelController.getStageCounts -> [{label,count}]
 *
 * The board ALWAYS renders 5 lead rows (LEAD_META) + 10 opportunity rows (OPP_META)
 * = 15 `.srow`, defaulting counts to 0, and shows TOTAL pills summing each side. Each
 * wire is registered as its own shared test adapter and emitted independently.
 */
import { createElement } from 'lwc';
import PipelineStageBoard from 'c/pipelineStageBoard';
import getFunnel from '@salesforce/apex/LeadFunnelController.getFunnel';
import getStageCounts from '@salesforce/apex/OpportunityFunnelController.getStageCounts';

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

const LEAD_FUNNEL = {
    stages: [
        { label: 'New', count: 10 },
        { label: 'Under Review', count: 5 },
        { label: 'Qualified', count: 3 },
        { label: 'Converted', count: 8 },
        { label: 'Disqualified', count: 2 }
    ]
};

const OPP_COUNTS = [
    { label: 'New', count: 4 },
    { label: 'Under Review', count: 3 },
    { label: 'Underwriting', count: 6 },
    { label: 'LOI', count: 2 },
    { label: 'Closed Won', count: 5 }
];

describe('c-pipeline-stage-board', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-pipeline-stage-board', {
            is: PipelineStageBoard
        });
        document.body.appendChild(element);
        return element;
    }

    function rows(element) {
        return element.shadowRoot.querySelectorAll('.srow');
    }

    function totals(element) {
        return [...element.shadowRoot.querySelectorAll('.pill-num')].map(
            (el) => el.textContent
        );
    }

    it('EMPTY: renders 15 stage rows with zero totals before either wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(rows(element).length).toBe(15); // 5 lead + 10 opportunity rows
        expect(totals(element)).toEqual(['0', '0']); // TOTAL LEADS, TOTAL OPPORTUNITIES

        const values = [...rows(element)].map(
            (r) => r.querySelector('.row-val').textContent
        );
        expect(values.every((v) => v === '0')).toBe(true);
    });

    it('DATA BRANCH: both wires populate their side and sum the total pills', async () => {
        const element = createComponent();

        getFunnel.emit(LEAD_FUNNEL);
        getStageCounts.emit(OPP_COUNTS);
        await Promise.resolve();

        // Lead total = 10+5+3+8+2 = 28; Opp total = 4+3+6+2+5 = 20.
        expect(totals(element)).toEqual(['28', '20']);

        // First lead row (New) reflects its count.
        const leadRows = element.shadowRoot.querySelectorAll(
            '.rows-single .srow'
        );
        expect(leadRows[0].querySelector('.row-val').textContent).toBe('10');
    });

    it('DATA BRANCH: leads populate even if the opportunity wire has not emitted', async () => {
        const element = createComponent();

        getFunnel.emit(LEAD_FUNNEL);
        await Promise.resolve();

        expect(totals(element)).toEqual(['28', '0']);
    });

    it('ERROR BRANCH: both wires erroring leaves 15 rows and zero totals', async () => {
        const element = createComponent();

        getFunnel.error();
        getStageCounts.error();
        await Promise.resolve();

        expect(rows(element).length).toBe(15);
        expect(totals(element)).toEqual(['0', '0']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getFunnel.emit(LEAD_FUNNEL);
        getStageCounts.emit(OPP_COUNTS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
