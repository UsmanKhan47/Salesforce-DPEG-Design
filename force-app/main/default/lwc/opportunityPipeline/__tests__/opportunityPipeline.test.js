/**
 * c-opportunity-pipeline — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1).
 *
 * Data source: @wire(getPipelineSnapshot) from
 * OpportunityFunnelController.getPipelineSnapshot -> a scalar wrapper
 * { openDeals, pipelineValue, landDeals, commercialDeals }. Renders four
 * c-onboarding-card-child tiles; Pipeline Value runs through the compact-money
 * formatter. The whole `.card` is guarded by if:true={data}.
 */
import { createElement } from 'lwc';
import OpportunityPipeline from 'c/opportunityPipeline';
import getPipelineSnapshot from '@salesforce/apex/OpportunityFunnelController.getPipelineSnapshot';

jest.mock(
    '@salesforce/apex/OpportunityFunnelController.getPipelineSnapshot',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const SNAPSHOT = {
    openDeals: 14,
    pipelineValue: 2500000,
    landDeals: 5,
    commercialDeals: 9
};

describe('c-opportunity-pipeline', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-opportunity-pipeline', {
            is: OpportunityPipeline
        });
        document.body.appendChild(element);
        return element;
    }

    function tiles(element) {
        return element.shadowRoot.querySelectorAll('c-onboarding-card-child');
    }

    it('EMPTY: renders nothing until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(tiles(element).length).toBe(0);
    });

    it('DATA BRANCH: renders the four snapshot tiles with compact money', async () => {
        const element = createComponent();

        getPipelineSnapshot.emit(SNAPSHOT);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card-title').textContent).toBe(
            'Pipeline Snapshot'
        );

        const cards = tiles(element);
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('14'); // Open Deals
        expect(cards[1].value).toBe('$2.5M'); // Pipeline Value ($2,500,000)
        expect(cards[2].value).toBe('5'); // Land Deals
        expect(cards[3].value).toBe('9'); // Commercial Deals
    });

    it('DATA BRANCH: formats a zero pipeline value as $0', async () => {
        const element = createComponent();

        getPipelineSnapshot.emit({
            openDeals: 0,
            pipelineValue: 0,
            landDeals: 0,
            commercialDeals: 0
        });
        await Promise.resolve();

        expect(tiles(element)[1].value).toBe('$0');
    });

    it('ERROR BRANCH: hides the card and renders an inline error alert when the wire errors', async () => {
        const element = createComponent();

        getPipelineSnapshot.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(element.shadowRoot.querySelector('[role="alert"]')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPipelineSnapshot.emit(SNAPSHOT);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
