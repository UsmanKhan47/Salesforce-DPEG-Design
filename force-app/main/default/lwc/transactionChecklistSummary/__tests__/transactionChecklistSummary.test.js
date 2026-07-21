/**
 * @wire to APEX (parameterised by $recordId). c-transaction-checklist-summary
 * reads @wire(getTaskGroups, { transactionId: '$recordId' }) and rolls every
 * group's complete/total into one overall progress bar.
 */
import { createElement } from 'lwc';
import TransactionChecklistSummary from 'c/transactionChecklistSummary';
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

// Matches List<TransactionTaskController.GroupRow> (only the fields this card reads).
const GROUPS = [
    { total: 10, complete: 5 },
    { total: 20, complete: 20 }
];

describe('c-transaction-checklist-summary', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: TXN_ID }) {
        const element = createElement('c-transaction-checklist-summary', {
            is: TransactionChecklistSummary
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the no-checklist state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe('—');
        expect(element.shadowRoot.querySelector('.cs-count').textContent).toBe(
            'No checklist generated yet'
        );
    });

    it('DATA BRANCH: rolls the groups into an overall percentage', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        // 25 of 30 complete -> 83%.
        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe('83%');
        expect(element.shadowRoot.querySelector('.cs-count').textContent).toBe(
            '25 of 30 complete'
        );
        expect(element.shadowRoot.querySelector('.cs-bar').style.width).toBe(
            '83%'
        );
    });

    it('DATA BRANCH: a fully complete checklist reads 100% and turns green', async () => {
        const element = createComponent();

        getTaskGroups.emit([{ total: 8, complete: 8 }]);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe(
            '100%'
        );
        expect(
            element.shadowRoot.querySelector('.cs-bar').getAttribute('style')
        ).toContain('#2e7d32');
    });

    it('ERROR BRANCH: renders a distinct error message instead of the progress bar', async () => {
        const element = createComponent();

        getTaskGroups.error({ message: 'Checklist summary unavailable.' });
        await Promise.resolve();

        // The "—" / "No checklist generated yet" copy must NOT show on a load failure.
        expect(element.shadowRoot.querySelector('.cs-pct')).toBeNull();
        const err = element.shadowRoot.querySelector('.cs-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe('Checklist summary unavailable.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
