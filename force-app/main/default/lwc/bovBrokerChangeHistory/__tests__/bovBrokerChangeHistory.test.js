/**
 * c-bov-broker-change-history
 * ---------------------------------------------------------------------------
 * Read-only: a single `@wire(getHistory, { dispositionId: '$recordId' })`, three mutually exclusive
 * rendered states, a 60-character note preview with a View popup.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. EMPTY IS THE MAJORITY STATE OF THIS CARD and must render "No broker changes recorded" —
 *    never an error banner, never a spinner. Most dispositions never replace a broker, so a
 *    regression here would be visible on most disposition record pages in the org. The empty test
 *    below therefore also asserts the ABSENCE of an alert and of a spinner, because a passing
 *    "the sentence is present" assertion would survive both of those being added next to it.
 * 2. EMPTY AND UNAVAILABLE ARE DIFFERENT STATES AND MUST NEVER SHARE WORDING. "No broker changes
 *    recorded" is a claim about the SALE; a failed read is a fact about the READER. The tests pin
 *    that the failure path does NOT emit the empty sentence — that is the assertion that fails if
 *    somebody "simplifies" the error branch into the empty one.
 * 3. THE COMPONENT DOES NOT RE-SORT. The Apex is already ordered newest-first; these tests feed
 *    the wire an ordered payload and assert the render preserves it, so a client-side sort added
 *    later (a second, weaker copy of the server's ORDER BY) has to justify itself against
 *    `preservesTheServerOrder`.
 * 4. DTO MEMBER NAMES ARE PINNED HERE. A renamed `@AuraEnabled` member on
 *    `BovBrokerChangeController.ChangeRow` fails no deploy and throws nothing in the browser — the
 *    card just renders blanks. The fixtures below use the exact member names, so a rename that is
 *    not carried through to this file fails loudly.
 *
 * ⚠ Every event dispatched by these tests is a real DOM `click` on a real element, or a wire emit
 * through `createApexTestWireAdapter`. Nothing hand-builds a platform component's `detail` payload
 * — this repo has shipped a dead button whose tests all passed because they fabricated a
 * `lightning-datatable` rowaction shape the platform never sends.
 */
import { createElement } from 'lwc';
import BovBrokerChangeHistory from 'c/bovBrokerChangeHistory';
import getHistory from '@salesforce/apex/BovBrokerChangeController.getHistory';

jest.mock(
    '@salesforce/apex/BovBrokerChangeController.getHistory',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

/** A Disposition__c Id — the anchor is the SALE, not an assignment or a submission. */
const DISPOSITION_ID = 'a0D5g000000DispEAG';

const LONG_NOTE =
    'The outgoing broker missed two consecutive marketing deadlines and the seller asked for a change before the listing went live.';

/** Server order: newest first. Index 0 is the most recent change. */
const HISTORY = [
    {
        id: 'a1B0000000000002AAA',
        changeNumber: 'BBC-0002',
        outgoingBrokerFirm: 'JLL',
        incomingBrokerFirm: 'Cushman & Wakefield',
        reason: 'Better BOV Received',
        notes: LONG_NOTE,
        entryDateTime: '2026-08-19T15:04:00.000Z',
        loggedBy: 'Avery Chen'
    },
    {
        id: 'a1B0000000000001AAA',
        changeNumber: 'BBC-0001',
        outgoingBrokerFirm: 'CBRE',
        incomingBrokerFirm: 'JLL',
        reason: 'Performance Issue',
        notes: 'Short note.',
        entryDateTime: '2026-07-02T09:15:00.000Z',
        loggedBy: 'Avery Chen'
    }
];

/** The service records an APPOINTMENT (no incumbent) with blank outgoing columns. */
const APPOINTMENT_ONLY = [
    {
        id: 'a1B0000000000003AAA',
        changeNumber: 'BBC-0003',
        outgoingBrokerFirm: null,
        incomingBrokerFirm: 'Marcus & Millichap',
        reason: 'Company Decision',
        notes: null,
        entryDateTime: '2026-08-01T12:00:00.000Z',
        loggedBy: null
    }
];

describe('c-bov-broker-change-history', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: DISPOSITION_ID }) {
        const element = createElement('c-bov-broker-change-history', {
            is: BovBrokerChangeHistory
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const rows = (el) => el.shadowRoot.querySelectorAll('.bbc-row');
    const empty = (el) => el.shadowRoot.querySelector('.bbc-empty');
    const unavailable = (el) => el.shadowRoot.querySelector('.bbc-unavailable');
    const text = (el) => el.shadowRoot.textContent;

    it('BEFORE THE WIRE ANSWERS: renders no rows, no empty state and — crucially — no spinner', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(rows(element).length).toBe(0);
        // 🔴 The empty sentence must NOT appear before the wire has answered: it is a claim about
        // the sale, and nothing is known about the sale yet.
        expect(empty(element)).toBeNull();
        expect(unavailable(element)).toBeNull();
        // 🔴 NO SPINNER, EVER. A spinner is the only element on this card capable of hanging
        // forever, which is the specific failure the design forbids.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('DATA: renders one row per recorded change, with both stamped firm snapshots', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(rows(element).length).toBe(2);
        expect(empty(element)).toBeNull();
        expect(unavailable(element)).toBeNull();

        const first = rows(element)[0];
        expect(first.querySelector('.bbc-outgoing').textContent).toBe('JLL');
        expect(first.querySelector('.bbc-incoming').textContent).toBe(
            'Cushman & Wakefield'
        );
        expect(first.querySelector('.bbc-reason').textContent).toBe(
            'Reason: Better BOV Received'
        );
        expect(first.querySelector('.bbc-loggedby').textContent).toBe(
            'Logged by Avery Chen'
        );
        // The DateTime is rendered by the platform's own formatter, which is stubbed in Jest — so
        // the assertion is that the RAW value was handed to it, not how it renders.
        expect(
            first.querySelector('lightning-formatted-date-time').value
        ).toBe('2026-08-19T15:04:00.000Z');
    });

    it('ORDER: preserves the server order and does not re-sort', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const incoming = [...rows(element)].map(
            (r) => r.querySelector('.bbc-incoming').textContent
        );
        // Newest first, exactly as BovBrokerChangeSelector returned it. A client-side sort added
        // later would be a second copy of the server's ORDER BY — including a tie-break JS cannot
        // see — and would drift from it silently.
        expect(incoming).toEqual(['Cushman & Wakefield', 'JLL']);
    });

    it('APPOINTMENT: a change with no outgoing firm NAMES that state instead of rendering a blank', async () => {
        const element = createComponent();

        getHistory.emit(APPOINTMENT_ONLY);
        await Promise.resolve();

        expect(rows(element).length).toBe(1);
        expect(rows(element)[0].querySelector('.bbc-outgoing').textContent).toBe(
            'No previous broker'
        );
        // Asserted on the RENDERED markup, not on a getter: an undefined bound into the template
        // renders the literal string "undefined".
        expect(text(element)).not.toContain('undefined');
        expect(text(element)).not.toContain('null');
        // A null loggedBy / notes must simply omit those lines, not print an empty label.
        expect(rows(element)[0].querySelector('.bbc-loggedby')).toBeNull();
        expect(rows(element)[0].querySelector('.bbc-notes')).toBeNull();
    });

    it('🔴 EMPTY: says "No broker changes recorded" — with no alert and no spinner anywhere near it', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        expect(rows(element).length).toBe(0);
        expect(empty(element)).not.toBeNull();
        expect(empty(element).textContent).toBe('No broker changes recorded');
        // 🔴 The design's actual requirement is as much about what must NOT be here. Most
        // dispositions land in this state, so an alert or a spinner here would be visible across
        // most of the org's disposition pages.
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(unavailable(element)).toBeNull();
    });

    it('🔴 UNAVAILABLE: a failed read is its OWN state — never the empty sentence, never an alert', async () => {
        const element = createComponent();

        getHistory.error();
        await Promise.resolve();

        expect(unavailable(element)).not.toBeNull();
        expect(unavailable(element).textContent).toContain('unavailable');
        // 🔴 THE CENTRAL ASSERTION. "No broker changes recorded" is a claim about the SALE; a
        // failed read knows nothing about the sale. Collapsing the two would have this card state,
        // in plain English, that nothing ever happened on a disposition where it may well have.
        expect(text(element)).not.toContain('No broker changes recorded');
        expect(empty(element)).toBeNull();
        expect(rows(element).length).toBe(0);
        // Muted, not alarming: a secondary informational card cannot read the situation well
        // enough to raise an alert, and the realistic cause is an admin-side FLS gap.
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('NOTES: clips a long note to a 60-character preview and offers View; a short note gets neither', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const longRow = rows(element)[0];
        const preview = longRow.querySelector('.bbc-notes-txt').textContent;
        expect(preview.endsWith('…')).toBe(true);
        // 60 characters plus the ellipsis, allowing for the trailing-space trim.
        expect(preview.length).toBeLessThanOrEqual(61);
        expect(LONG_NOTE.startsWith(preview.slice(0, -1).trim())).toBe(true);
        expect(longRow.querySelector('.bbc-notes-view')).not.toBeNull();

        const shortRow = rows(element)[1];
        expect(shortRow.querySelector('.bbc-notes-txt').textContent).toBe(
            'Short note.'
        );
        expect(shortRow.querySelector('.bbc-notes-view')).toBeNull();
    });

    it('VIEW: a real click on the View button opens the full note, and Close dismisses it', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.slds-modal')).toBeNull();

        // A genuine DOM click on the rendered button — the handler reads
        // event.currentTarget.dataset.id, which only exists on a real element.
        rows(element)[0].querySelector('.bbc-notes-view').click();
        await Promise.resolve();

        const modal = element.shadowRoot.querySelector('.slds-modal');
        expect(modal).not.toBeNull();
        expect(modal.getAttribute('role')).toBe('dialog');
        expect(
            element.shadowRoot.querySelector('.bbc-note-full').textContent
        ).toBe(LONG_NOTE);
        // The subtitle names WHICH change the note belongs to — a note with no context is a note
        // the reader cannot use.
        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe('JLL → Cushman & Wakefield');

        element.shadowRoot.querySelector('.bbc-note-close').click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.slds-modal')).toBeNull();
    });

    it('is accessible with rows', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible when empty — the state most disposition pages will actually render', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
