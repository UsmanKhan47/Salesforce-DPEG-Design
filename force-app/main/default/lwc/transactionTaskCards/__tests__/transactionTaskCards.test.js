/**
 * @wire to APEX (no parameters). c-transaction-task-cards reads
 *   @wire(getTaskSummary) -> TransactionController.TaskSummary
 * and renders four c-onboarding-card-child tiles. Risk icons only "light up"
 * (amber/red) when their count is non-zero; a clean wire count reads green.
 */
import { createElement } from 'lwc';
import TransactionTaskCards from 'c/transactionTaskCards';
import getTaskSummary from '@salesforce/apex/TransactionController.getTaskSummary';

jest.mock(
    '@salesforce/apex/TransactionController.getTaskSummary',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches TransactionController.TaskSummary.
const SUMMARY = {
    totalTasks: 220,
    pendingTasks: 60,
    overdueTasks: 5,
    wireTasks: 0
};

describe('c-transaction-task-cards', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-transaction-task-cards', {
            is: TransactionTaskCards
        });
        document.body.appendChild(element);
        return element;
    }

    function cards(element) {
        return [...element.shadowRoot.querySelectorAll('c-onboarding-card-child')];
    }

    it('renders four zeroed tiles before the wire resolves', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(cards(element).length).toBe(4);
        expect(cards(element).map((c) => c.value)).toEqual([
            '0',
            '0',
            '0',
            '0'
        ]);
    });

    it('DATA BRANCH: renders the four task counts and labels', async () => {
        const element = createComponent();

        getTaskSummary.emit(SUMMARY);
        await Promise.resolve();

        expect(cards(element).map((c) => c.value)).toEqual([
            '220',
            '60',
            '5',
            '0'
        ]);
        expect(cards(element).map((c) => c.label)).toEqual([
            'Total Tasks',
            'Pending',
            'At Risk',
            'Wire Tasks'
        ]);
    });

    it('DATA BRANCH: a clean (zero) wire count reads green', async () => {
        const element = createComponent();

        getTaskSummary.emit(SUMMARY);
        await Promise.resolve();

        const wireCard = cards(element)[3];
        expect(wireCard.iconColor).toBe('#2e7d32'); // green when zero
    });

    it('DATA BRANCH: open wire risks light the tile red', async () => {
        const element = createComponent();

        getTaskSummary.emit({ ...SUMMARY, wireTasks: 3 });
        await Promise.resolve();

        expect(cards(element)[3].value).toBe('3');
        expect(cards(element)[3].iconColor).toBe('#c23934'); // red when > 0
    });

    it('ERROR BRANCH: renders an inline error message instead of the task tiles', async () => {
        const element = createComponent();

        getTaskSummary.error({ message: 'Task metrics unavailable.' });
        await Promise.resolve();

        expect(cards(element).length).toBe(0);
        const err = element.shadowRoot.querySelector('.kpi-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Task metrics unavailable.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTaskSummary.emit(SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
