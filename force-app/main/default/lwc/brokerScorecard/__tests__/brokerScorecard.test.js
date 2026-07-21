/**
 * c-broker-scorecard — @wire-to-Apex suite (with NavigationMixin).
 * Pattern: brokerFirmCard template + a navigation assertion.
 *
 * Data source: @wire(getScorecard) from
 * BrokerAssignmentController.getScorecard -> a list of broker outcome wrappers
 * { brokerId, name, firm, active, leased, disposed, total }. Renders one card per
 * broker; the "View listings" button navigates to the Broker_Assignments tab.
 *
 * Navigation is asserted with the lwc-recipes pattern: lightning/navigation is
 * mocked so the mixin's [Navigate] method dispatches a catchable 'navigate' event
 * carrying the PageReference (the sfdx-lwc-jest stub's Navigate is a no-op, and
 * the host element and component instance are different objects — so an instance
 * override cannot capture the call).
 */
import { createElement } from 'lwc';
import BrokerScorecard from 'c/brokerScorecard';
import getScorecard from '@salesforce/apex/BrokerAssignmentController.getScorecard';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', {
                            detail: { pageReference }
                        })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getScorecard',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const SCORECARD = [
    {
        brokerId: 'b1',
        name: 'Ava Broker',
        firm: 'CBRE',
        active: 4,
        leased: 2,
        disposed: 1,
        total: 7
    },
    {
        brokerId: 'b2',
        name: 'John Roe',
        firm: 'JLL',
        active: 1,
        leased: 0,
        disposed: 3,
        total: 4
    }
];

describe('c-broker-scorecard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-scorecard', {
            is: BrokerScorecard
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('.broker-card').length
        ).toBe(0);
        expect(
            element.shadowRoot.querySelector('.empty-state').textContent
        ).toBe('No broker scorecard data available.');
    });

    it('DATA BRANCH: renders one card per broker with avatar initials + counts', async () => {
        const element = createComponent();

        getScorecard.emit(SCORECARD);
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('.broker-card');
        expect(cards.length).toBe(2);

        const names = [
            ...element.shadowRoot.querySelectorAll('.broker-name')
        ].map((el) => el.textContent);
        expect(names).toEqual(['Ava Broker', 'John Roe']);

        const initials = [
            ...element.shadowRoot.querySelectorAll('.avatar')
        ].map((el) => el.textContent);
        expect(initials).toEqual(['AB', 'JR']);

        // First broker's active count appears in the big active-count element.
        expect(
            cards[0].querySelector('.active-count').textContent
        ).toBe('4');
    });

    it('navigates to the Broker_Assignments tab when "View listings" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getScorecard.emit(SCORECARD);
        await Promise.resolve();

        element.shadowRoot.querySelector('.view-btn').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(navHandler.mock.calls[0][0].detail.pageReference).toEqual({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Broker_Assignments' }
        });
    });

    it('ERROR BRANCH: renders a distinct error state (not the no-data message) when the wire errors', async () => {
        const element = createComponent();

        getScorecard.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('.broker-card').length
        ).toBe(0);
        const err = element.shadowRoot.querySelector('.scorecard-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getScorecard.emit(SCORECARD);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
