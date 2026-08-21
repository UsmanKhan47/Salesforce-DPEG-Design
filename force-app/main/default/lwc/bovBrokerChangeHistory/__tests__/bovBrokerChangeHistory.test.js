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
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE TWO-COLUMN ROW IS GONE AND MUST NOT COME BACK (2026-08-21).
 * ─────────────────────────────────────────────────────────────────────────────
 * This card moved to the ~340px record-page sidebar, where the old layout (swap + notes left,
 * timestamp + reason + logger right-aligned, held apart by `justify-content: space-between`)
 * collides. It is now a <ul>/<li> of self-labelling tiles. T-NARROW / T-CSS below are
 * anti-regression pins for that, modelled on the identical pair in
 * c/competingBrokerSubmissions, which solved the same problem on Lead_Record_Page.
 *
 * EVERY BEHAVIOURAL ASSERTION FROM THE OLD LAYOUT SURVIVES IN MEANING. Three things moved:
 *   - `.bbc-row` -> `.bbc-tile`;
 *   - `.bbc-reason` / `.bbc-loggedby` now hold BARE VALUES ('Better BOV Received', 'Avery Chen')
 *     with the wording promoted to a real <dt> beside them. The tests assert BOTH halves, so a
 *     regression that drops the label is caught as well as one that drops the value;
 *   - the empty and unavailable states gained an icon and a centred layout. `.bbc-empty` is
 *     still the <p> carrying EXACTLY 'No broker changes recorded', so the falsifier that pins
 *     the two states' wording apart is unchanged.
 */
import { createElement } from 'lwc';
import BovBrokerChangeHistory from 'c/bovBrokerChangeHistory';
import getHistory from '@salesforce/apex/BovBrokerChangeController.getHistory';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic: T-CSS's
// assertions are deliberately broad, so a comment that merely NAMED a banned value would fail
// them — which is what forces a stylesheet to describe its own rules in circumlocutions.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'bovBrokerChangeHistory.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

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

    const rows = (el) => el.shadowRoot.querySelectorAll('.bbc-tile');
    const empty = (el) => el.shadowRoot.querySelector('.bbc-empty');
    const unavailable = (el) => el.shadowRoot.querySelector('.bbc-unavailable');
    const text = (el) => el.shadowRoot.textContent;
    const title = (el) =>
        el.shadowRoot.querySelector('span[slot="title"]').textContent.trim();

    /** Every dt label on one tile, in template order. */
    const labels = (tile) =>
        [...tile.querySelectorAll('dt')].map((d) => d.textContent.trim());

    it('BEFORE THE WIRE ANSWERS: renders no rows, no empty state and — crucially — no spinner', async () => {
        const element = createComponent();

        await Promise.resolve();

        // The card CHROME is unconditional — an untitled fragment of text floating between two
        // proper cards is the UAT defect this rework fixed.
        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();

        expect(rows(element).length).toBe(0);
        // 🔴 The empty sentence must NOT appear before the wire has answered: it is a claim about
        // the sale, and nothing is known about the sale yet.
        expect(empty(element)).toBeNull();
        expect(unavailable(element)).toBeNull();
        // 🔴 ...and neither must a "(0)" in the TITLE, which is the same claim in fewer words and
        // is the one place the state templates cannot guard.
        expect(title(element)).toBe('Broker Change History');
        // 🔴 NO SPINNER, EVER. A spinner is the only element on this card capable of hanging
        // forever, which is the specific failure the design forbids.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('HEADER: the card carries a title and an icon once the wire answers', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-card').iconName
        ).toBe('standard:record_update');
        expect(title(element)).toBe('Broker Change History (2)');
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

        // 🔴 VALUE AND LABEL ARE ASSERTED SEPARATELY. These used to be one pre-composed string
        // ("Reason: Better BOV Received"); the wording is now a real <dt>, so a regression that
        // drops the label is a DIFFERENT failure from one that drops the value and each needs
        // its own assertion. Asserting only the value would let the labels vanish silently —
        // which in a 340px tile leaves an unidentifiable bare date and a bare name.
        expect(first.querySelector('.bbc-reason').textContent.trim()).toBe(
            'Better BOV Received'
        );
        expect(first.querySelector('.bbc-loggedby').textContent.trim()).toBe(
            'Avery Chen'
        );
        expect(labels(first)).toEqual(['When', 'Reason', 'Logged by', 'Notes']);
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
        // A null loggedBy / notes must simply omit those PAIRS — value AND label — not print an
        // empty one. An absent reason and a blank reason look identical on screen and mean
        // different things, so the <dt> has to go too.
        expect(rows(element)[0].querySelector('.bbc-loggedby')).toBeNull();
        expect(rows(element)[0].querySelector('.bbc-notes')).toBeNull();
        expect(labels(rows(element)[0])).toEqual(['When', 'Reason']);
    });

    it('🔴 EMPTY: says "No broker changes recorded" — with no alert and no spinner anywhere near it', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        expect(rows(element).length).toBe(0);
        expect(empty(element)).not.toBeNull();
        // 🔴 EXACTLY this sentence and nothing else in this element. The explanatory line lives
        // in a SIBLING <p> precisely so this assertion stays a tight pin on the wording that
        // separates "empty" from "unavailable".
        expect(empty(element).textContent).toBe('No broker changes recorded');
        // 🔴 The design's actual requirement is as much about what must NOT be here. Most
        // dispositions land in this state, so an alert or a spinner here would be visible across
        // most of the org's disposition pages.
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(unavailable(element)).toBeNull();

        // Structure, not a bare grey sentence: a status region with an icon and the explanatory
        // line. The intro wording is kept VERBATIM because "nothing is deleted" is the point of
        // an audit log — an empty audit log that does not say what it would have contained is
        // indistinguishable from a broken one.
        const state = element.shadowRoot.querySelector('.bbc-state');
        expect(state.getAttribute('role')).toBe('status');
        expect(state.querySelector('lightning-icon').iconName).toBe(
            'utility:change_record_type'
        );
        expect(state.querySelector('.bbc-state-sub').textContent).toBe(
            'Every broker ever appointed to this sale — nothing is deleted.'
        );
        // The count IS shown once the wire has answered, even at zero — at that point it is a
        // fact about the sale rather than a guess.
        expect(title(element)).toBe('Broker Change History (0)');
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
        // 🔴 AND NOT THE SHARED ERROR LOOK EITHER. `.lv-error` is this repo's cross-bundle red
        // banner; adopting it here would dress an administrator's provisioning gap up as this
        // user's incident, on a card they did not ask to interact with.
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();

        // 🔴 NO COUNT IN THE TITLE. "Broker Change History (0)" is the empty state's claim in
        // fewer words, and it is the one place the state templates cannot guard.
        expect(title(element)).toBe('Broker Change History');
        // The intro sentence is a COMPLETENESS claim ("every broker ever appointed"), and this
        // is exactly the state in which the card cannot make one.
        expect(text(element)).not.toContain('nothing is deleted');
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

    // ─────────────────────────────────────────────────────────────────────────
    // Narrow-column anti-regression pins (2026-08-21)
    // ─────────────────────────────────────────────────────────────────────────

    // T-NARROW — the direct pin. A test that merely renders would not catch a revert to the
    // two-column row; this does, in four lines.
    it('T-NARROW: renders a labelled tile list, no table and no scroll wrapper', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('table')).toBeNull();
        // `.bbc-right` was the right-aligned second column of the old flex row, and
        // `.lv-scroll` is this repo's retired horizontal-overflow wrapper.
        expect(element.shadowRoot.querySelector('.bbc-right')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-scroll')).toBeNull();

        const list = element.shadowRoot.querySelector('.bbc-list');
        expect(list).not.toBeNull();
        // role="list" is NOT redundant: `list-style: none` makes WebKit drop the implicit list
        // role, and aria-label is only exposed on an element whose role supports naming. axe has
        // no rule for it, so `is accessible with rows` passing is not evidence against it.
        expect(list.getAttribute('role')).toBe('list');
        expect(list.getAttribute('aria-label')).toBe('Broker changes');
        expect(list.querySelectorAll('li').length).toBe(2);
    });

    // T-CSS — the stylesheet pin, deliberately a SOURCE-TEXT assertion rather than a
    // measurement. WHY (do not "improve" this into a measurement): jsdom performs NO LAYOUT.
    // scrollWidth, clientWidth, offsetWidth and getBoundingClientRect() all return 0, so
    // `expect(el.scrollWidth).toBeLessThanOrEqual(el.clientWidth)` is `0 <= 0` and passes
    // vacuously WHETHER OR NOT the component overflows.
    it('T-CSS: the stylesheet cannot produce sideways scroll at 340px', () => {
        // --- BANNED --------------------------------------------------------
        // Matches the `overflow` SHORTHAND as well as `overflow-x`.
        expect(CSS_SOURCE).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);

        // No fixed pixel width on content. `min-width` / `max-width` are not matched (the char
        // before "width" is a hyphen, not a boundary).
        expect(CSS_SOURCE).not.toMatch(/(^|[\s;{])width\s*:\s*\d+px/);

        // The old two-column row was held apart by this. Named outright so a revert is caught
        // even if the class names are kept.
        expect(CSS_SOURCE).not.toMatch(/justify-content\s*:\s*space-between/);

        // ⚠ `nowrap` IS ALLOWED IN EXACTLY ONE PLACE — the long-note preview clip, whose full
        // text is one click away behind the View button. This is the narrowest assertion that
        // still bans it everywhere else: it fails if a SECOND occurrence appears.
        expect(CSS_SOURCE.match(/nowrap/g)).toHaveLength(1);
        expect(CSS_SOURCE).toMatch(
            /\.bbc-notes--clip\s+\.bbc-notes-txt\s*\{[^}]*white-space\s*:\s*nowrap/
        );

        // --- REQUIRED, and every one SELECTOR-ANCHORED ----------------------
        // An unanchored /min-width:\s*0/ passes while ANY ONE of the many occurrences survives.
        // The LOAD-BEARING one is on the grid item.
        expect(CSS_SOURCE).toMatch(/\.bbc-tile\s*\{[^}]*min-width\s*:\s*0/);

        // overflow-wrap must be on :host, not .bbc-tile — that is what makes it reach the
        // full-note popup and the two centred states, not just the tiles.
        expect(CSS_SOURCE).toMatch(/:host\s*\{[^}]*overflow-wrap\s*:\s*anywhere/);

        // The grid minimum. A bare `minmax(18rem, 1fr)` bursts any container narrower than
        // 288px — invisible at desktop width, and the ONLY place it shows is the sidebar this
        // rework exists for.
        expect(CSS_SOURCE).toMatch(/minmax\(\s*min\(\s*18rem\s*,\s*100%\s*\)/);

        // The swap must WRAP. At 340px "No previous broker → Marcus & Millichap" legitimately
        // needs two lines, and a firm name clipped to an ellipsis is worse than a wrapped one —
        // the firm is the fact the whole tile exists to record.
        expect(CSS_SOURCE).toMatch(/\.bbc-swap\s*\{[^}]*flex-wrap\s*:\s*wrap/);
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
