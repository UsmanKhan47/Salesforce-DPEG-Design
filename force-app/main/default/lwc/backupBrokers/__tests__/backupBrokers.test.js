/**
 * c-backup-brokers — @wire-to-Apex suite.
 * Pattern: brokerFirmCard template (createApexTestWireAdapter + emit/error).
 *
 * Data source: @wire(getSubmissions, { dispositionId: '$recordId' }) from
 * BovController.getSubmissions -> List of BOV submission wrappers. The component
 * filters out the SELECTED submission (r.isSelected) and lists the rest as the
 * "backup" brokers.
 */
import { createElement } from 'lwc';
import BackupBrokers from 'c/backupBrokers';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

jest.mock(
    '@salesforce/apex/BovController.getSubmissions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Wrapper shape read by the JS: { id, isSelected, brokerFirm, contactName,
// bovScore, bovAmount }. The first is the SELECTED winner (excluded from rows).
const SUBMISSIONS = [
    {
        id: 'a0X5g000000AAA1EAM',
        isSelected: true,
        brokerFirm: 'CBRE',
        contactName: 'Jane Doe',
        bovScore: 92,
        bovAmount: 14200000
    },
    {
        id: 'a0X5g000000AAA2EAM',
        isSelected: false,
        brokerFirm: 'Colliers',
        contactName: 'John Roe',
        bovScore: 74,
        bovAmount: 9800000
    },
    {
        id: 'a0X5g000000AAA3EAM',
        isSelected: false,
        brokerFirm: 'JLL',
        contactName: null,
        bovScore: null,
        bovAmount: null
    }
];

describe('c-backup-brokers', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-backup-brokers', {
            is: BackupBrokers
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty message before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.broker-row').length).toBe(
            0
        );
        expect(
            element.shadowRoot.querySelector('.empty-msg').textContent
        ).toBe('No backup brokers.');
    });

    it('DATA BRANCH: lists only the non-selected submissions', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.broker-row');
        expect(rows.length).toBe(2); // the selected winner is excluded

        const names = [
            ...element.shadowRoot.querySelectorAll('.broker-name')
        ].map((el) => el.textContent);
        expect(names).toEqual(['Colliers · John Roe', 'JLL · —']);

        const metas = [
            ...element.shadowRoot.querySelectorAll('.broker-meta')
        ].map((el) => el.textContent);
        // bovAmount 9.8M -> $9.8M; null score/amount -> em dash.
        expect(metas).toEqual([
            'Score 74 · $9.8M',
            'Score — · —'
        ]);
    });

    it('DATA BRANCH: shows the empty message when every submission is selected', async () => {
        const element = createComponent();

        getSubmissions.emit([SUBMISSIONS[0]]); // only the selected winner
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.broker-row').length).toBe(
            0
        );
        expect(element.shadowRoot.querySelector('.empty-msg')).not.toBeNull();
    });

    it('ERROR BRANCH: degrades to the empty message when the wire errors', async () => {
        const element = createComponent();

        getSubmissions.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.broker-row').length).toBe(
            0
        );
        expect(element.shadowRoot.querySelector('.empty-msg')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
