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
 * 🔴 THE RENDERED SHAPE IS A VERTICAL TIMELINE (2026-08-24).
 * ─────────────────────────────────────────────────────────────────────────────
 * Restyled to a design the user supplied. Per entry: a decorative dot-and-line rail, then
 *   line 1  {outgoing} → {incoming}, BOTH BOLD;
 *   line 2  calendar icon · date-time · "|" · reason;
 *   line 3  "Logged By:" · name;
 *   line 4  the RETAINED notes affordance (see T-NOTES-KEPT).
 * Before this it was a dt/dd tile grid (2026-08-21) and before that a two-column flex row
 * (2026-08-20). The two-column row must not come back — see T-TIMELINE.
 *
 * 🔴 WHY THESE TESTS READ ELEMENTS AND PROPERTIES, NEVER GETTERS. This repo has a measured defect
 * where a getter-only assertion stayed green while the rendered output was wrong (a getter's
 * return value is not the attribute the template writes). Everything below is queried out of
 * `shadowRoot`. And where the thing under test is a LIGHTNING BASE COMPONENT, the assertion is on
 * a PROPERTY (`iconName`, `alternativeText`, `value`) — the Jest stubs render an EMPTY template,
 * so a `textContent` assertion against one of them is vacuously green whatever the component does.
 *
 * ⚠ THE HEADLINE'S SPACES COME FROM CSS `gap`, NOT FROM THE MARKUP. The template compiler discards
 * the whitespace-only text nodes between the three spans, so `h3.textContent` is
 * "JLL→replaced byCushman & Wakefield" — correct, and not what a reader sees. The assertions
 * therefore read the individual spans and their DOM ORDER rather than the concatenated string; an
 * `h3.textContent` assertion here would be pinning an artefact of the compiler.
 */
import { createElement } from 'lwc';
import BovBrokerChangeHistory from 'c/bovBrokerChangeHistory';
import getHistory from '@salesforce/apex/BovBrokerChangeController.getHistory';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic: the
// stylesheet assertions are deliberately broad, so a comment that merely NAMED a banned value
// would fail them — which is what forces a stylesheet to describe its own rules in circumlocutions.
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

/**
 * Nothing optional at all — no reason, no logger, no notes. This fixture exists for ONE assertion
 * the others cannot make: that the "|" separator on line 2 disappears with the reason it separates.
 * Every other fixture carries a reason, so a pipe hard-coded outside the `lwc:if` would render a
 * dangling "Aug 01, 2026, 12:00 PM |" and every one of them would still pass.
 */
const BARE_ENTRY = [
    {
        id: 'a1B0000000000004AAA',
        changeNumber: 'BBC-0004',
        outgoingBrokerFirm: 'Colliers',
        incomingBrokerFirm: 'Newmark',
        reason: null,
        notes: null,
        entryDateTime: '2026-06-11T08:30:00.000Z',
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

    /** One timeline entry per recorded change. */
    const rows = (el) => el.shadowRoot.querySelectorAll('.bbc-entry');
    const empty = (el) => el.shadowRoot.querySelector('.bbc-empty');
    const unavailable = (el) => el.shadowRoot.querySelector('.bbc-unavailable');
    const text = (el) => el.shadowRoot.textContent;
    const title = (el) =>
        el.shadowRoot.querySelector('span[slot="title"]').textContent.trim();

    /**
     * The headline's visible parts in DOM order, as `class -> text` pairs. Reading the ORDER is the
     * point: "Cushman & Wakefield → JLL" contains exactly the same strings as the correct headline
     * and means the opposite.
     */
    const headline = (entry) =>
        [...entry.querySelector('.bbc-swap').children].map((c) => [
            c.className,
            c.textContent
        ]);

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
        expect(title(element)).toBe('Broker Replace History');
        // 🔴 NO SPINNER, EVER. A spinner is the only element on this card capable of hanging
        // forever, which is the specific failure the design forbids.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('HEADER: the card reads "Broker Replace History (n)" and carries an icon', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-card').iconName
        ).toBe('standard:record_update');
        // 🔴 EXACT WORDING AND EXACT COUNT. The user specified this header text; "(2)" is the
        // count of rendered entries, so a title that stopped counting would pass a `toContain`.
        expect(title(element)).toBe('Broker Replace History (2)');
    });

    it('DATA: one timeline entry per change, with both stamped firm snapshots in order', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(rows(element).length).toBe(2);
        expect(empty(element)).toBeNull();
        expect(unavailable(element)).toBeNull();

        const first = rows(element)[0];

        // 🔴 THE HEADLINE, READ AS RENDERED ELEMENTS IN DOM ORDER. Outgoing, then the arrow, then
        // the assistive relationship word, then incoming. Reversing the two firms produces a
        // headline containing all the same text and asserting the opposite fact, which is exactly
        // what a set-membership assertion would miss.
        expect(headline(first)).toEqual([
            ['bbc-outgoing', 'JLL'],
            ['bbc-arrow', '→'],
            ['bbc-sr-only', 'replaced by'],
            ['bbc-incoming', 'Cushman & Wakefield']
        ]);

        // 🔴 LINE 2 — the calendar icon, the timestamp, the pipe, the reason, in that order.
        // The icon is a base component whose Jest stub renders an EMPTY template, so it is
        // asserted on its PROPERTIES; a textContent assertion against it would pass vacuously.
        const metaIcon = first.querySelector('.bbc-meta lightning-icon');
        expect(metaIcon).not.toBeNull();
        expect(metaIcon.iconName).toBe('utility:event');
        // The icon is also the timestamp's accessible label now that the "When" <dt> is gone.
        expect(metaIcon.alternativeText).toBe('Changed on');

        // The DateTime is rendered by the platform's own formatter, which is stubbed in Jest — so
        // the assertion is that the RAW value and the requested FORMAT were handed to it, not how
        // it renders. The format is what produces "Aug 19, 2026, 3:04 PM" in the browser.
        const fdt = first.querySelector('lightning-formatted-date-time');
        expect(fdt.value).toBe('2026-08-19T15:04:00.000Z');
        expect([fdt.year, fdt.month, fdt.day, fdt.hour, fdt.minute]).toEqual([
            'numeric',
            'short',
            '2-digit',
            '2-digit',
            '2-digit'
        ]);

        expect(first.querySelector('.bbc-sep').textContent).toBe('|');
        expect(first.querySelector('.bbc-reason').textContent).toBe(
            'Better BOV Received'
        );

        // 🔴 LINE 3 — the label is VISIBLE and the name is beside it. Asserting only the name
        // would let the label vanish silently, leaving an unattributed person's name under a
        // timestamp; asserting only the label would let the name vanish.
        expect(first.querySelector('.bbc-logged-label').textContent).toBe(
            'Logged By:'
        );
        expect(first.querySelector('.bbc-loggedby').textContent).toBe(
            'Avery Chen'
        );
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

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PREVIOUS — THE BRANCH A NAIVE "{outgoing} → {incoming}" TEMPLATE GETS WRONG.
    //
    // The service records an APPOINTMENT (nobody to replace) with a NULL outgoing firm. Bound
    // straight into the template that renders as "undefined → JLL"; guarded with an `lwc:if` on
    // the firm instead of a fallback STRING it renders as a bare "→ JLL". Neither is caught by a
    // test that only ever feeds the wire a two-firm row, which is why this branch gets its own.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PREVIOUS: an appointment reads "No Previous Broker → {firm}", not "undefined →"', async () => {
        const element = createComponent();

        getHistory.emit(APPOINTMENT_ONLY);
        await Promise.resolve();

        expect(rows(element).length).toBe(1);
        const entry = rows(element)[0];

        // 🔴 THE EXACT RENDERED HEADLINE, IN ORDER. Both halves matter: the fallback WORDING
        // ("No Previous Broker", not an em dash the reader has to interpret) and the fact that it
        // occupies the outgoing SLOT, so the arrow still points from it to the appointed firm.
        expect(headline(entry)).toEqual([
            ['bbc-outgoing', 'No Previous Broker'],
            ['bbc-arrow', '→'],
            ['bbc-sr-only', 'replaced by'],
            ['bbc-incoming', 'Marcus & Millichap']
        ]);

        // Asserted on the RENDERED markup, not on a getter: an undefined bound into the template
        // renders the literal string "undefined".
        expect(text(element)).not.toContain('undefined');
        expect(text(element)).not.toContain('null');

        // A null loggedBy / notes must OMIT those lines entirely — label and value together —
        // rather than render an empty one. "Logged By:" with nothing after it is worse than no
        // line at all: it names a person and then fails to.
        expect(entry.querySelector('.bbc-logged')).toBeNull();
        expect(entry.querySelector('.bbc-logged-label')).toBeNull();
        expect(entry.querySelector('.bbc-notes')).toBeNull();
    });

    it('🔴 T-NO-DANGLING-PIPE: with no reason, the separator goes too', async () => {
        const element = createComponent();

        getHistory.emit(BARE_ENTRY);
        await Promise.resolve();

        const entry = rows(element)[0];
        // The timestamp still renders — it is never null.
        expect(entry.querySelector('lightning-formatted-date-time').value).toBe(
            '2026-06-11T08:30:00.000Z'
        );
        // 🔴 ...but the pipe that separates it FROM the reason must not survive the reason. A
        // hard-coded "|" outside the lwc:if passes every other test in this file.
        expect(entry.querySelector('.bbc-sep')).toBeNull();
        expect(entry.querySelector('.bbc-reason')).toBeNull();
        expect(entry.querySelector('.bbc-meta').textContent).not.toContain('|');
        // The headline is unaffected by any of the optional lines being absent.
        expect(entry.querySelector('.bbc-outgoing').textContent).toBe(
            'Colliers'
        );
        expect(entry.querySelector('.bbc-incoming').textContent).toBe('Newmark');
    });

    it('🔴 EMPTY: says "No broker changes recorded" — with no alert and no spinner anywhere near it', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        expect(rows(element).length).toBe(0);
        expect(empty(element)).not.toBeNull();
        // 🔴 EXACTLY this sentence and nothing else in this element — the wording is what
        // separates "empty" from "unavailable".
        expect(empty(element).textContent).toBe('No broker changes recorded');
        // 🔴 The design's actual requirement is as much about what must NOT be here. Most
        // dispositions land in this state, so an alert or a spinner here would be visible across
        // most of the org's disposition pages.
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        expect(unavailable(element)).toBeNull();
        // No timeline chrome either — a rail with no entries is a line to nowhere.
        expect(element.shadowRoot.querySelector('.bbc-timeline')).toBeNull();
        expect(element.shadowRoot.querySelector('.bbc-rail')).toBeNull();

        // Structure, not a bare grey sentence: a status region with an icon.
        // ⚠ THE ASSERTION ON `.bbc-state-sub` WAS DELETED ON 2026-08-21, NOT SOFTENED. It pinned
        // 'Every broker ever appointed to this sale — nothing is deleted.' verbatim; the user
        // named that exact string as prose they did not want, so the sub-line is gone and its
        // assertion went with it. The HEADLINE assertion above is the one that mattered for this
        // test's actual claim — that EMPTY is distinguishable from LOADING and from UNAVAILABLE —
        // and it is untouched.
        const state = element.shadowRoot.querySelector('.bbc-state');
        expect(state.getAttribute('role')).toBe('status');
        expect(state.querySelector('lightning-icon').iconName).toBe(
            'utility:change_record_type'
        );
        // The count IS shown once the wire has answered, even at zero — at that point it is a
        // fact about the sale rather than a guess.
        expect(title(element)).toBe('Broker Replace History (0)');
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

        // 🔴 NO COUNT IN THE TITLE. "Broker Replace History (0)" is the empty state's claim in
        // fewer words, and it is the one place the state templates cannot guard.
        expect(title(element)).toBe('Broker Replace History');
        // ⚠ `expect(text(element)).not.toContain('nothing is deleted')` STOOD HERE AND WAS DELETED
        // ON 2026-08-21. It was a real falsifier while the intro rendered in the other two states
        // — it proved this state alone withheld the completeness claim. The 2026-08-21 removal
        // deleted that sentence EVERYWHERE, so the assertion became one that passes no matter what
        // the component does: exactly the always-green test the absence-pin rule exists to
        // prevent. The claim now lives once, in T-NO-PROSE below, run on a POPULATED fixture where
        // it can still fail.
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // `get intro()` — 'Every broker ever appointed to this sale — nothing is deleted.' — was
    // removed at the user's request; they quoted it. It rendered in TWO places, above the entry
    // list and as the empty state's sub-line, and both are gone.
    //
    // 🔴 THE PIN RUNS ON THE POPULATED FIXTURE, AND THAT IS THE WHOLE POINT. The assertion it
    // replaces (in the UNAVAILABLE test) became always-green the moment the sentence stopped
    // rendering anywhere: a card that renders NOTHING satisfies "does not contain 'nothing is
    // deleted'" just as well as a correct one. Asserting it on two rendered entries is what keeps
    // it falsifiable.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no intro sentence above the entries, and none in the empty state', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        // Guard the guard: real entries rendered, so the absences below are real.
        expect(rows(element).length).toBe(2);

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.bbc-intro')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added line usually arrives under a new class name.
        expect(text(element)).not.toContain('nothing is deleted');
        expect(text(element).toLowerCase()).not.toContain('every broker ever appointed');

        // 3. 🔴 NO DANGLING aria-describedby. The paragraph carried `id="bbc-intro"` and the list
        //    pointed at it; an aria-describedby naming an element that no longer exists promises
        //    a screen-reader user a description that resolves to nothing — strictly worse than
        //    having none. This is the assertion that catches "deleted the <p>, left the attribute".
        const list = element.shadowRoot.querySelector('.bbc-timeline');
        expect(list).not.toBeNull();
        expect(list.getAttribute('aria-describedby')).toBeNull();
        // The list's own accessible NAME is unaffected and must stay.
        expect(list.getAttribute('aria-label')).toBe('Broker changes');
    });

    it('🔴 T-NO-PROSE: the EMPTY state keeps its headline and loses only the sub-line', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        // 🔴 THE HALF THAT MUST SURVIVE. The user kept empty states explicitly: without this
        // sentence an empty audit log is indistinguishable from a broken one. A future "tidy-up"
        // that deletes the whole state to satisfy the absence half of this pin fails HERE.
        expect(empty(element)).not.toBeNull();
        expect(empty(element).textContent).toBe('No broker changes recorded');
        expect(
            element.shadowRoot.querySelector('.bbc-state').getAttribute('role')
        ).toBe('status');

        // 🔴 THE HALF THAT MUST NOT COME BACK.
        expect(element.shadowRoot.querySelector('.bbc-state-sub')).toBeNull();
        expect(text(element)).not.toContain('nothing is deleted');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-NOTES-KEPT — THE FEATURE THE SUPPLIED DESIGN DOES NOT SHOW.
    //
    // The timeline mock has three lines and no notes control. Notes__c is written by
    // c/bovReplaceBrokerModal and this card is the ONLY place in the application that reads it
    // back, so matching the mock exactly would have retired a working feature and orphaned the
    // data — silently, because a card that stops rendering something throws nothing. It is kept
    // as a quieter fourth line, labelled by a note ICON now that the "Notes" <dt> is gone.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-NOTES-KEPT: the notes line survives the restyle, icon-labelled, on the entry that has one', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const noted = rows(element)[0].querySelector('.bbc-notes');
        expect(noted).not.toBeNull();

        // The icon carries the line's accessible name — asserted on the PROPERTY, because the
        // lightning-icon stub renders an empty template and its textContent is always ''.
        const icon = noted.querySelector('lightning-icon');
        expect(icon.iconName).toBe('utility:note');
        expect(icon.alternativeText).toBe('Notes');

        // And it is genuinely absent where there is no note, rather than rendered blank.
        getHistory.emit(APPOINTMENT_ONLY);
        await Promise.resolve();
        expect(rows(element)[0].querySelector('.bbc-notes')).toBeNull();
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
        // The single-line clip is applied by a MODIFIER CLASS, and only to the long note. The
        // stylesheet's one permitted `nowrap` hangs off it (see T-CSS), so if the modifier stops
        // being emitted the clip silently stops applying.
        expect(longRow.querySelector('.bbc-notes').className).toContain(
            'bbc-notes--clip'
        );

        const shortRow = rows(element)[1];
        expect(shortRow.querySelector('.bbc-notes-txt').textContent).toBe(
            'Short note.'
        );
        expect(shortRow.querySelector('.bbc-notes-view')).toBeNull();
        expect(shortRow.querySelector('.bbc-notes').className).not.toContain(
            'bbc-notes--clip'
        );
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

    it('VIEW: the popup subtitle uses the same "No Previous Broker" wording as the headline', async () => {
        const element = createComponent();

        // A long note on an APPOINTMENT — the one row shape where the subtitle has to compose a
        // fallback. The two fallbacks live in different methods (`historyRows` and `openNote`),
        // so changing one and not the other is a live risk and shows up only here.
        getHistory.emit([
            { ...APPOINTMENT_ONLY[0], notes: LONG_NOTE }
        ]);
        await Promise.resolve();

        rows(element)[0].querySelector('.bbc-notes-view').click();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe('No Previous Broker → Marcus & Millichap');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Structural / stylesheet anti-regression pins
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-TIMELINE: a semantic list of entries, each with a decorative dot-and-line rail', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const list = element.shadowRoot.querySelector('ul.bbc-timeline');
        expect(list).not.toBeNull();
        // role="list" is NOT redundant: `list-style: none` makes WebKit drop the implicit list
        // role, and aria-label is only exposed on an element whose role supports naming. axe has
        // no rule for it, so `is accessible with rows` passing is not evidence against it.
        expect(list.getAttribute('role')).toBe('list');
        expect(list.getAttribute('aria-label')).toBe('Broker changes');

        // The entries are real <li>s — a stack of divs would leave a screen-reader user with no
        // count and no "item 1 of 2".
        const items = list.querySelectorAll('li.bbc-entry');
        expect(items.length).toBe(2);

        items.forEach((li) => {
            const rail = li.querySelector('.bbc-rail');
            expect(rail).not.toBeNull();
            // 🔴 THE RAIL IS DECORATION AND MUST SAY SO. Two empty spans announced per entry is
            // noise, and neither carries information the three text lines do not.
            expect(rail.getAttribute('aria-hidden')).toBe('true');
            expect(rail.querySelector('.bbc-dot')).not.toBeNull();
            expect(rail.querySelector('.bbc-track')).not.toBeNull();
        });

        // The shapes this replaced, named outright so a revert is caught even if class names are
        // kept: `.bbc-right` was the right-aligned second column of the 2026-08-20 flex row,
        // `.lv-scroll` is this repo's retired horizontal-overflow wrapper, and the dt/dd pairs
        // were the 2026-08-21 tile.
        expect(element.shadowRoot.querySelector('table')).toBeNull();
        expect(element.shadowRoot.querySelector('.bbc-right')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-scroll')).toBeNull();
        expect(element.shadowRoot.querySelector('dl')).toBeNull();
        expect(element.shadowRoot.querySelector('dt')).toBeNull();
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
        // before "width" is a hyphen, not a boundary). A hook fallback such as
        // `width: var(--slds-g-sizing-border-1, 1px)` is likewise not matched — the value starts
        // with `var`, not a digit — which is deliberate: the rail's hairline is a token.
        expect(CSS_SOURCE).not.toMatch(/(^|[\s;{])width\s*:\s*\d+px/);

        // The 2026-08-20 two-column row was held apart by this.
        expect(CSS_SOURCE).not.toMatch(/justify-content\s*:\s*space-between/);

        // ⚠ `nowrap` IS ALLOWED IN EXACTLY ONE PLACE — the long-note preview clip, whose full
        // text is one click away behind the View button. This is the narrowest assertion that
        // still bans it everywhere else: it fails if a SECOND occurrence appears.
        expect(CSS_SOURCE.match(/nowrap/g)).toHaveLength(1);
        expect(CSS_SOURCE).toMatch(
            /\.bbc-notes--clip\s+\.bbc-notes-txt\s*\{[^}]*white-space\s*:\s*nowrap/
        );

        // 🔴 THE TIMELINE IS SINGLE-COLUMN. A connecting line down the left is meaningless if the
        // entries it joins sit side by side, so the `repeat(auto-fill, minmax(...))` tile grid
        // that preceded it must not come back.
        expect(CSS_SOURCE).not.toMatch(/repeat\(\s*auto-fill/);

        // --- REQUIRED, and every one SELECTOR-ANCHORED ----------------------
        // An unanchored /min-width:\s*0/ passes while ANY ONE of the many occurrences survives.
        // The LOAD-BEARING one is the grid item holding all the text, beside the rail.
        expect(CSS_SOURCE).toMatch(/\.bbc-body\s*\{[^}]*min-width\s*:\s*0/);

        // overflow-wrap must be on :host, not on the entry — that is what makes it reach the
        // full-note popup and the two centred states, not just the timeline.
        expect(CSS_SOURCE).toMatch(/:host\s*\{[^}]*overflow-wrap\s*:\s*anywhere/);

        // The headline must WRAP. At 340px "No Previous Broker → Marcus & Millichap" legitimately
        // needs two lines, and a firm name clipped to an ellipsis is worse than a wrapped one —
        // the firm is the fact the whole entry exists to record.
        expect(CSS_SOURCE).toMatch(/\.bbc-swap\s*\{[^}]*flex-wrap\s*:\s*wrap/);

        // 🔴 AND IT MUST HAVE A GAP. The template compiler discards the whitespace-only text
        // nodes between the headline's spans, so with no gap the card renders
        // "JLL→Cushman & Wakefield". This is the only thing standing between the design and that.
        expect(CSS_SOURCE).toMatch(
            /\.bbc-swap\s*\{[^}]*gap\s*:\s*var\(--slds-g-spacing-/
        );

        // The rail's line must reach the next dot on its own, without anyone measuring an entry.
        expect(CSS_SOURCE).toMatch(/\.bbc-track\s*\{[^}]*flex\s*:\s*1\s+1\s+auto/);
        // ...and must STOP at the last dot rather than trailing off into the card's padding.
        expect(CSS_SOURCE).toMatch(
            /\.bbc-entry:last-child\s+\.bbc-track\s*\{[^}]*display\s*:\s*none/
        );
        // The dot is a circle by token, not by a hand-rolled radius.
        expect(CSS_SOURCE).toMatch(
            /\.bbc-dot\s*\{[^}]*border-radius\s*:\s*var\(--slds-g-radius-border-circle/
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-TOKENS — LIGHT *AND* DARK.
    //
    // The card has to be legible in both themes. Every SLDS 2 colour hook used here resolves to a
    // `light-dark(...)` pair in the dark-capable theme; a literal hex written straight into a
    // declaration resolves to ONE colour in both, which is how a dot or a connecting line ends up
    // invisible on a dark surface. jsdom cannot render either theme, and axe's colour-contrast
    // rule is inert in jsdom, so `toBeAccessible()` will never catch it — this source-text pin is
    // the only automated check there is.
    //
    // The technique: blank out every `var(--…)` INCLUDING ITS FALLBACK, then look for what is
    // left. A hex surviving that is a hex nothing can re-theme. The SLDS linter is a separate
    // command a reviewer can forget to run; this one runs with the suite.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-TOKENS: no colour is hard-coded outside a design-token fallback', () => {
        const withoutTokens = CSS_SOURCE.replace(/var\(\s*--[^()]*\)/g, 'TOKEN');

        expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3}\b/);
        expect(withoutTokens).not.toMatch(/rgba?\(/);
        expect(withoutTokens).not.toMatch(/hsla?\(/);

        // Guard the guard: the blanking regex must actually have found tokens to blank, or the
        // three assertions above are satisfied by an empty search space.
        expect((CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length).toBeGreaterThan(20);

        // 🔴 THE TWO NEW ELEMENTS SPECIFICALLY, ANCHORED. The dot and the line are the parts of
        // this design with no text fallback: if they resolve to nothing, or to white on white,
        // the timeline simply is not there and no other assertion in this file notices.
        expect(CSS_SOURCE).toMatch(
            /\.bbc-dot\s*\{[^}]*background\s*:\s*var\(--slds-g-color-/
        );
        expect(CSS_SOURCE).toMatch(
            /\.bbc-track\s*\{[^}]*background\s*:\s*var\(--slds-g-color-/
        );
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
