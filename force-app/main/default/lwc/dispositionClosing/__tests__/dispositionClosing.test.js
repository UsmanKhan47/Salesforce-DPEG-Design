/**
 * WIRE-MOCK TEMPLATE — @wire to APEX (parameterised)
 * --------------------------------------------------
 * Follows the c-broker-firm-card @wire-Apex template. Single data source:
 *   @wire(getClosingSummary, { dispositionId: '$recordId' })
 * The card is gated behind if:true={row}. The "Not yet active" status badge is
 * shown only while row.psaExecuted is false, and the four stat labels flip on
 * the boolean flags in the wrapper — so both branches are exercised here.
 */
import { createElement } from 'lwc';
import DispositionClosing from 'c/dispositionClosing';
import getClosingSummary from '@salesforce/apex/DispositionController.getClosingSummary';

jest.mock(
    '@salesforce/apex/DispositionController.getClosingSummary',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const EXECUTED = {
    assetName: 'Oak Plaza',
    psaExecuted: true,
    titleCompany: 'First American Title',
    closingStatementUploaded: true,
    wireCreated: true
};
const PENDING = {
    assetName: 'Oak Plaza',
    psaExecuted: false,
    titleCompany: null,
    closingStatementUploaded: false,
    wireCreated: false
};

describe('c-disposition-closing', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-disposition-closing', {
            is: DispositionClosing
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing until the summary wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
    });

    it('DATA BRANCH (executed): hides the status badge and shows completed labels', async () => {
        const element = createComponent();

        getClosingSummary.emit(EXECUTED);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.status-badge')).toBeNull();

        const cards = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('Executed'); //     PSA Executed
        expect(cards[1].value).toBe('First American Title'); // Title Company
        expect(cards[2].value).toBe('Uploaded'); //     Closing Statement
        expect(cards[3].value).toBe('Created'); //      Wire
    });

    it('DATA BRANCH (pending): shows the "Not yet active" badge and pending labels', async () => {
        const element = createComponent();

        getClosingSummary.emit(PENDING);
        await Promise.resolve();

        const badge = element.shadowRoot.querySelector('.status-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toContain('Not yet active for Oak Plaza');

        const cards = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(cards[0].value).toBe('Pending'); //         PSA Executed
        expect(cards[1].value).toBe('TBD'); //             Title Company
        expect(cards[2].value).toBe('Not uploaded'); //    Closing Statement
        expect(cards[3].value).toBe('Not created'); //     Wire
    });

    it('ERROR BRANCH: renders an inline error state and hides the card when the wire errors', async () => {
        const element = createComponent();

        getClosingSummary.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        const err = element.shadowRoot.querySelector('.wire-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getClosingSummary.emit(EXECUTED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
