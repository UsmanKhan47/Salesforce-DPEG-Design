/**
 * @wire to APEX (no parameters). c-transaction-stage-donut reads
 *   @wire(getStageBreakdown) -> List<TransactionController.StageSlice>
 * and draws one SVG arc per non-empty stage plus a full legend (zero-count
 * stages appear in the legend but draw no arc). Empty data -> empty state.
 */
import { createElement } from 'lwc';
import TransactionStageDonut from 'c/transactionStageDonut';
import getStageBreakdown from '@salesforce/apex/TransactionController.getStageBreakdown';

jest.mock(
    '@salesforce/apex/TransactionController.getStageBreakdown',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches List<TransactionController.StageSlice>. 3 of the 5 canonical stages
// carry records; Closing Prep / Post-Closing are zero.
const BREAKDOWN = [
    { stage: 'Due Diligence', count: 3 },
    { stage: 'Open Contract', count: 2 },
    { stage: 'Closed Won', count: 1 }
];

describe('c-transaction-stage-donut', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-transaction-stage-donut', {
            is: TransactionStageDonut
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.empty').textContent).toBe(
            'No active transactions'
        );
        expect(element.shadowRoot.querySelector('.donut')).toBeNull();
    });

    it('DATA BRANCH: totals the deals and draws one arc per non-empty stage', async () => {
        const element = createComponent();

        getStageBreakdown.emit(BREAKDOWN);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.donut__total').textContent).toBe(
            '6'
        );

        // 3 stages have records -> 3 arc <circle>s (the base track circle has no
        // stroke-dasharray, so it is excluded).
        const arcs = element.shadowRoot.querySelectorAll(
            '.donut__svg circle[stroke-dasharray]'
        );
        expect(arcs.length).toBe(3);
    });

    it('DATA BRANCH: legend lists all five canonical stages, zero-count included', async () => {
        const element = createComponent();

        getStageBreakdown.emit(BREAKDOWN);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.legend__row');
        expect(rows.length).toBe(5);

        const names = [
            ...element.shadowRoot.querySelectorAll('.legend__name')
        ].map((el) => el.textContent);
        expect(names).toEqual([
            'Open Contract',
            'Due Diligence',
            'Closing Prep',
            'Post-Closing',
            'Closed Won'
        ]);

        const counts = [
            ...element.shadowRoot.querySelectorAll('.legend__count')
        ].map((el) => el.textContent);
        expect(counts).toEqual(['2', '3', '0', '0', '1']);
    });

    it('ERROR BRANCH: surfaces a distinct error message (not the no-deals empty copy)', async () => {
        const element = createComponent();

        getStageBreakdown.error({ message: 'Stage breakdown unavailable.' });
        await Promise.resolve();

        const state = element.shadowRoot.querySelector('.empty');
        expect(state).not.toBeNull();
        expect(state.textContent).toBe('Stage breakdown unavailable.');
        expect(state.getAttribute('role')).toBe('alert');
        expect(element.shadowRoot.querySelector('.donut')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getStageBreakdown.emit(BREAKDOWN);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
