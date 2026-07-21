/**
 * @wire to APEX (parameterised by $recordId). c-transaction-phase-cards reads
 *   @wire(getTaskGroups, { transactionId: '$recordId' })
 * and rolls the lettered task groups into the four deal phases
 * (open: A,B / dd: C-H2 / close: I / post: J), rendering a
 * c-onboarding-card-child per phase that turns green when the phase is done.
 */
import { createElement } from 'lwc';
import TransactionPhaseCards from 'c/transactionPhaseCards';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';

jest.mock(
    '@salesforce/apex/TransactionTaskController.getTaskGroups',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const TXN_ID = 'a0A5g000000TxnAEAS';

// Matches List<TransactionTaskController.GroupRow> (letter + complete/total drive the rollup).
const GROUPS = [
    { letter: 'A', complete: 3, total: 3 },
    { letter: 'B', complete: 2, total: 4 }, // open: 5/7 (not done)
    { letter: 'C', complete: 5, total: 5 }, // dd: 5/5 (done)
    { letter: 'I', complete: 0, total: 2 }, // close: 0/2
    { letter: 'J', complete: 1, total: 1 } // post: 1/1 (done)
];

describe('c-transaction-phase-cards', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: TXN_ID }) {
        const element = createElement('c-transaction-phase-cards', {
            is: TransactionPhaseCards
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return [...element.shadowRoot.querySelectorAll('c-onboarding-card-child')];
    }

    it('renders four zeroed phase cards before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(cards(element).length).toBe(4);
        expect(cards(element).map((c) => c.value)).toEqual([
            '0 / 0',
            '0 / 0',
            '0 / 0',
            '0 / 0'
        ]);
    });

    it('DATA BRANCH: rolls lettered groups into the four phase totals', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        expect(cards(element).map((c) => c.value)).toEqual([
            '5 / 7', // Open Contract (A+B)
            '5 / 5', // Due Diligence (C)
            '0 / 2', // Closing (I)
            '1 / 1' // Post Closing (J)
        ]);
        expect(cards(element).map((c) => c.label)).toEqual([
            'Open Contract',
            'Due Diligence',
            'Closing',
            'Post Closing'
        ]);
    });

    it('DATA BRANCH: a fully complete phase turns green (done)', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        const [open, dd, close] = cards(element);
        expect(dd.done).toBe(true);
        expect(dd.iconColor).toBe('#2e7d32'); // green
        expect(open.done).toBe(false);
        expect(close.done).toBe(false);
    });

    it('ERROR BRANCH: renders an inline error message instead of the phase cards', async () => {
        const element = createComponent();

        getTaskGroups.error({ message: 'Phase progress unavailable.' });
        await Promise.resolve();

        expect(cards(element).length).toBe(0);
        const err = element.shadowRoot.querySelector('.kpi-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Phase progress unavailable.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
