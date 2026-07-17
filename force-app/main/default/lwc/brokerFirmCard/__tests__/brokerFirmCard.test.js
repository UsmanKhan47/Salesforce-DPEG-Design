/**
 * WIRE-MOCK TEMPLATE 1 of 3 — @wire to APEX (parameterised)
 * ---------------------------------------------------------
 * Copy this shape for any component that reads data through
 * `@wire(apexMethod, { ... : '$recordId' })`.
 *
 * Demonstrated here on c-broker-firm-card, whose only data source is
 *   @wire(getBrokerFirm, { opportunityId: '$recordId' })
 *
 * KEY TECHNIQUE — register the imported Apex method as a *test wire adapter*
 * with the OFFICIAL sfdx-lwc-jest factory `createApexTestWireAdapter`, then
 * push data/errors through it:
 *   - `getBrokerFirm.emit(mockData)`  -> drives the data branch
 *   - `getBrokerFirm.error()`         -> drives the error branch
 * Both the component and this test import the SAME module path, so the
 * jest.mock() factory below makes them share ONE adapter instance (that is why
 * the factory `require()`s the util *inside* the factory — jest hoists mocks
 * above imports, and an out-of-scope variable would throw).
 *
 * The `$recordId` reactive param is satisfied by setting `element.recordId`
 * before appendChild — exactly as a record page supplies it at runtime. A
 * no-parameter wire (e.g. c-broker-stats' `@wire(getBrokerHub)`) is the same
 * pattern minus the recordId assignment.
 *
 * Conventions inherited from the canonical c-stat-card template:
 *   createElement -> Object.assign props -> appendChild -> await a microtask ->
 *   query shadowRoot; afterEach clears the DOM + jest.clearAllMocks().
 */
import { createElement } from 'lwc';
import BrokerFirmCard from 'c/brokerFirmCard';
import getBrokerFirm from '@salesforce/apex/BrokerFirmController.getBrokerFirm';

// Register getBrokerFirm as an Apex test wire adapter shared with the component.
// NOTE: keep all `import`s above this jest.mock() (LWC requires imports first);
// Jest hoists the mock above the imports at runtime regardless of source order.
jest.mock(
    '@salesforce/apex/BrokerFirmController.getBrokerFirm',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Small, realistic mock matching the BrokerFirmController wrapper the JS reads.
const FIRM_LINKED = {
    hasFirm: true,
    firmName: 'Colliers International',
    dealsSubmitted: 12,
    dealsWon: 5,
    dealsLost: 3
};
const NO_FIRM = {
    hasFirm: false,
    firmName: null,
    dealsSubmitted: 0,
    dealsWon: 0,
    dealsLost: 0
};

describe('c-broker-firm-card', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: '0065g00000AbCdEAAV' }) {
        const element = createElement('c-broker-firm-card', {
            is: BrokerFirmCard
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing until the wire emits (initial empty state)', async () => {
        const element = createComponent();

        await Promise.resolve();

        // if:true={data} is false before the adapter emits.
        expect(element.shadowRoot.querySelector('.card')).toBeNull();
    });

    it('DATA BRANCH: renders the firm heading and deal-count cards', async () => {
        const element = createComponent();

        getBrokerFirm.emit(FIRM_LINKED);
        await Promise.resolve();

        const heading = element.shadowRoot.querySelector('.firm-name');
        expect(heading.textContent).toBe(
            'Brokerage Firm - Colliers International'
        );

        const cards = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(cards.length).toBe(3);
        expect(cards[0].value).toBe(12); // Deals Submitted
        expect(cards[1].value).toBe(5); //  Deals Won
        expect(cards[2].value).toBe(3); //  Deals Lost
    });

    it('DATA BRANCH: shows the empty message when no firm is linked', async () => {
        const element = createComponent();

        getBrokerFirm.emit(NO_FIRM);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('c-onboarding-card-child').length
        ).toBe(0);
        const empty = element.shadowRoot.querySelector('.empty');
        expect(empty.textContent).toBe('No broker firm linked to this deal.');
    });

    it('ERROR BRANCH: degrades gracefully (card not rendered) when the wire errors', async () => {
        const element = createComponent();

        // getBrokerFirm.error() emits { data: undefined, error: < apex error> }.
        // This component only assigns on data, so it must stay in its empty state
        // rather than throw.
        getBrokerFirm.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getBrokerFirm.emit(FIRM_LINKED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
