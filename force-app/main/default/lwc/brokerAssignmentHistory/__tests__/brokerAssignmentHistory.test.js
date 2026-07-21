/**
 * c-broker-assignment-history
 * ---------------------------------------------------------------------------
 * Read-only: single @wire(getDetail, { assignmentId: '$recordId' }). Renders the
 * broker history (Active rows first, then by startDate desc), truncates long
 * notes to a 60-char preview with a "View" button, and pops a modal with the
 * full note. No imperative Apex.
 */
import { createElement } from 'lwc';
import BrokerAssignmentHistory from 'c/brokerAssignmentHistory';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getDetail',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0X0000000000001AAA';
const LONG_NOTE =
    'Outgoing broker underperformed on leasing velocity across two full quarters and was replaced.';

const DETAIL = {
    propertyName: 'Gateway Plaza',
    history: [
        {
            id: 'a0X0000000000002AAA',
            brokerName: 'Sam Okafor',
            brokerFirm: 'CBRE',
            status: 'Replaced',
            startDate: '2024-06-01',
            endDate: '2025-01-14',
            reason: 'Performance Issue',
            notes: LONG_NOTE
        },
        {
            id: RECORD_ID,
            brokerName: 'Dana Reyes',
            brokerFirm: 'Colliers International',
            status: 'Active',
            startDate: '2025-01-15',
            endDate: null,
            reason: null,
            notes: null
        }
    ]
};

describe('c-broker-assignment-history', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-broker-assignment-history', {
            is: BrokerAssignmentHistory
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-histcard')).toBeNull();
    });

    it('DATA BRANCH: renders a row per history entry, Active first', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.ba-histrow');
        expect(rows.length).toBe(2);

        const names = [...element.shadowRoot.querySelectorAll('.ba-histname')].map(
            (el) => el.textContent
        );
        // Active listing (Dana Reyes) is sorted to the top.
        expect(names[0]).toBe('Dana Reyes');
        expect(names[1]).toBe('Sam Okafor');

        // The Active row carries the "Active" badge.
        expect(element.shadowRoot.querySelector('.ba-histbadge').textContent).toBe(
            'Active'
        );
    });

    it('DATA BRANCH: truncates a long note and exposes a View button', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        const preview = element.shadowRoot.querySelector('.ba-histnotes-txt');
        expect(preview.textContent.endsWith('…')).toBe(true);
        expect(preview.textContent.length).toBeLessThan(LONG_NOTE.length);
        expect(
            element.shadowRoot.querySelector('.ba-histnotes-view')
        ).not.toBeNull();
    });

    it('NOTE MODAL: View opens a dialog showing the full note', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        element.shadowRoot.querySelector('.ba-histnotes-view').click();
        await Promise.resolve();

        const dialog = element.shadowRoot.querySelector('[role="dialog"]');
        expect(dialog).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.ba-note-full').textContent
        ).toBe(LONG_NOTE);
        expect(element.shadowRoot.querySelector('.ba-note-sub').textContent).toBe(
            'Sam Okafor'
        );
    });

    it('ERROR BRANCH: shows an inline error and no history card when the wire errors', async () => {
        const element = createComponent();

        getDetail.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ba-histcard')).toBeNull();
        expect(element.shadowRoot.querySelector('.ba-error')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getDetail.emit(DETAIL);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
