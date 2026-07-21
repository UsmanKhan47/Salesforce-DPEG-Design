/**
 * c-lead-channels — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (WIRE-MOCK TEMPLATE 1).
 *
 * Data source: @wire(getFunnel) from LeadFunnelController.getFunnel. The JS reads
 * `data.channels` ([{ label, count }]) + `data.reviewQueue` and renders one
 * c-onboarding-card-child per channel plus a trailing Review Queue tile. The whole
 * `.card` is guarded by if:true={data}, so nothing renders until the wire emits.
 */
import { createElement } from 'lwc';
import LeadChannels from 'c/leadChannels';
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
    channels: [
        { label: 'Email-to-Lead', count: 12 },
        { label: 'Broker Portal', count: 5 },
        { label: 'Manual Entry', count: 3 }
    ],
    reviewQueue: 4
};

describe('c-lead-channels', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lead-channels', { is: LeadChannels });
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

    it('DATA BRANCH: renders one tile per channel plus a Review Queue tile', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card-title').textContent).toBe(
            'Lead Channels'
        );

        const cards = tiles(element);
        expect(cards.length).toBe(4); // 3 channels + Review Queue

        // Channel counts are stringified onto the child @api value.
        expect(cards[0].value).toBe('12'); // Email-to-Lead
        expect(cards[0].label).toBe('Email-to-Lead');
        expect(cards[1].value).toBe('5'); // Broker Portal
        expect(cards[2].value).toBe('3'); // Manual Entry

        // Trailing Review Queue tile.
        expect(cards[3].value).toBe('4');
        expect(cards[3].label).toBe('Review Queue');
    });

    it('DATA BRANCH: defaults a missing reviewQueue to 0', async () => {
        const element = createComponent();

        getFunnel.emit({ channels: [{ label: 'Manual Entry', count: 1 }] });
        await Promise.resolve();

        const cards = tiles(element);
        expect(cards.length).toBe(2);
        expect(cards[1].value).toBe('0'); // reviewQueue undefined -> '0'
    });

    it('ERROR BRANCH: renders an inline error (not the tile card) when the wire errors', async () => {
        const element = createComponent();

        getFunnel.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(tiles(element).length).toBe(0);
        expect(element.shadowRoot.querySelector('.wire-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getFunnel.emit(FUNNEL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
