/**
 * c-work-order-timeline — @wire-to-Apex (parameterised by $recordId).
 *
 * Data source: @wire(getActivity, { workOrderId: '$recordId' }) on
 * WorkOrderController, returning { entries: [...], untouched }. This is a
 * READ-ONLY view — history arrives with the nightly Yardi sync and there is no
 * compose box (contrast c-renewal-timeline). The $recordId reactive param is
 * satisfied by setting element.recordId before appendChild.
 *
 * entryDate values are fixed past ISO strings so the rendered
 * lightning-formatted-date-time stays stable across runs.
 */
import { createElement } from 'lwc';
import WorkOrderTimeline from 'c/workOrderTimeline';
import getActivity from '@salesforce/apex/WorkOrderController.getActivity';

jest.mock(
    '@salesforce/apex/WorkOrderController.getActivity',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a1O5g000000W0AaEAK';

const ACTIVITY = {
    untouched: false,
    entries: [
        {
            id: 'a1P5g000000AAaEAK',
            detail: 'Status changed to In Progress in Yardi.',
            actor: 'Yardi',
            kind: 'Status',
            entryDate: '2026-03-14T09:30:00.000Z'
        },
        {
            id: 'a1P5g000000AAbEAK',
            detail: 'Vendor Ace Mechanical assigned.',
            actor: 'M. Alvarez',
            kind: 'Vendor',
            entryDate: '2026-03-13T15:05:00.000Z'
        },
        {
            id: 'a1P5g000000AAcEAK',
            detail: 'Work order synced from Yardi Voyager.',
            actor: 'Yardi',
            kind: 'Sync',
            entryDate: '2026-03-12T06:00:00.000Z'
        }
    ]
};

const UNTOUCHED = { untouched: true, entries: [] };

describe('c-work-order-timeline', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-work-order-timeline', {
            is: WorkOrderTimeline
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.wot-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.wot-entry').length).toBe(0);
        expect(element.shadowRoot.querySelector('.wot-sub').textContent).toBe(
            '0 entries · from the nightly Yardi sync'
        );
    });

    it('DATA BRANCH: renders one entry per synced activity, newest first', async () => {
        const element = createComponent();

        getActivity.emit(ACTIVITY);
        await Promise.resolve();

        const entries = element.shadowRoot.querySelectorAll('.wot-entry');
        expect(entries.length).toBe(3);

        expect(element.shadowRoot.querySelector('.wot-sub').textContent).toBe(
            '3 entries · from the nightly Yardi sync'
        );

        const actors = [...element.shadowRoot.querySelectorAll('.wot-by')].map(
            (el) => el.textContent
        );
        expect(actors).toEqual(['Yardi', 'M. Alvarez', 'Yardi']);

        const details = [
            ...element.shadowRoot.querySelectorAll('.wot-detail')
        ].map((el) => el.textContent);
        expect(details[0]).toBe('Status changed to In Progress in Yardi.');

        // Newest entry carries the "Latest" marker.
        expect(element.shadowRoot.querySelector('.wot-latest')).not.toBeNull();
        // Read-only mirror: no compose box.
        expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
    });

    it('DATA BRANCH: surfaces the Untouched pill when nobody has acted', async () => {
        const element = createComponent();

        getActivity.emit(UNTOUCHED);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.wot-untouched').textContent
        ).toBe('Untouched');
        expect(element.shadowRoot.querySelector('.wot-empty')).not.toBeNull();
    });

    it('ERROR BRANCH: keeps the empty state and surfaces an inline alert when the wire errors', async () => {
        const element = createComponent();

        getActivity.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.wot-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelectorAll('.wot-entry').length).toBe(0);
        // Additive error banner appears alongside the existing empty content.
        expect(
            element.shadowRoot.querySelector('[role="alert"]')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getActivity.emit(ACTIVITY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
