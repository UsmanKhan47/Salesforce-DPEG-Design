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
 *   line 1  ONE broker name, BOLD (see below);
 *   line 2  calendar icon · date-time · "|" · reason;
 *   line 3  "Logged By:" · name;
 *   line 4  the RETAINED notes affordance (see T-NOTES-KEPT).
 * Before this it was a dt/dd tile grid (2026-08-21) and before that a two-column flex row
 * (2026-08-20). The two-column row must not come back — see T-TIMELINE.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 LINE 1 IS ONE NAME, AND WHICH NAME DEPENDS ON THE ROW SHAPE (2026-08-24).
 * ─────────────────────────────────────────────────────────────────────────────
 * The "{outgoing} → {incoming}" pairing was removed at the user's request ("just show the broker
 * name, when he was replaced, and what was the reason"). THE ROWS ARE NOT ALL THE SAME KIND, so
 * one rule cannot be tested with one fixture:
 *   • REPLACEMENT (an outgoing firm exists) → the OUTGOING firm is rendered. It is the broker who
 *     was replaced, which is what the entry records. T-BROKER-NAME.
 *   • INITIAL APPOINTMENT (no outgoing firm) → the INCOMING firm is rendered, and the entry must
 *     NOT be presented as a replacement, because nobody was replaced. T-APPOINTMENT.
 *   • Both firms are legitimately NULL-able — `Incoming_Broker_Firm__c` was null on a live
 *     retirement row on 2026-08-24 and `Outgoing_Broker_Firm__c` is null on every appointment —
 *     and a row with NEITHER must still render a word rather than a blank span, "undefined" or a
 *     bare dash. T-NULL-INCOMING and T-NO-NAME.
 * The distinction between the two shapes is carried by a shape-specific ASSISTIVE label
 * ("Replaced broker:" / "Appointed broker:") plus Reason__c on line 2, which already reads
 * "Initial Appointment" on those rows. A fixture that only ever carries two firms passes every
 * one of those rules while the card is wrong, which is why each gets its own fixture below.
 *
 * ⚠ T-NO-ARROW is an ABSENCE pin with a PRESENCE control in the same test: a card that rendered
 * no entries at all would satisfy "there is no arrow" perfectly.
 *
 * 🔴 WHY THESE TESTS READ ELEMENTS AND PROPERTIES, NEVER GETTERS. This repo has a measured defect
 * where a getter-only assertion stayed green while the rendered output was wrong (a getter's
 * return value is not the attribute the template writes). Everything below is queried out of
 * `shadowRoot`. And where the thing under test is a LIGHTNING BASE COMPONENT, the assertion is on
 * a PROPERTY (`iconName`, `alternativeText`, `value`) — the Jest stubs render an EMPTY template,
 * so a `textContent` assertion against one of them is vacuously green whatever the component does.
 *
 * ⚠ NEVER ASSERT ON `h3.textContent`. The template compiler discards the whitespace-only text node
 * between the headline's assistive label and the name, so the heading's concatenated text is
 * "Replaced broker:JLL" — an artefact of the compiler, not what anybody sees or hears. Every
 * headline assertion below reads `.bbc-name` (the visible name) and `.bbc-sr-only` (the label)
 * SEPARATELY. This is also why the label ends in a colon: without it the accessible name reads
 * "Replaced brokerJLL".
 * ⚠ THE SAME TRAP APPLIES TO LINE 2, which still IS a flex row of three siblings (timestamp, pipe,
 * reason) whose only separation is the CSS `gap` — that is where the T-CSS gap pin now points,
 * having previously pointed at the deleted `.bbc-swap`.
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

/**
 * The service records an APPOINTMENT (no incumbent) with blank outgoing columns. This is a REAL
 * live shape — every disposition's first broker row looks like this — and it is the shape a
 * headline that only knows how to print the outgoing firm gets wrong, silently, by printing
 * nothing.
 */
const APPOINTMENT_ONLY = [
    {
        id: 'a1B0000000000003AAA',
        changeNumber: 'BBC-0003',
        outgoingBrokerFirm: null,
        incomingBrokerFirm: 'Marcus & Millichap',
        reason: 'Initial Appointment',
        notes: null,
        entryDateTime: '2026-08-01T12:00:00.000Z',
        loggedBy: null
    }
];

/**
 * 🔴 A REPLACEMENT WHOSE *INCOMING* FIRM IS NULL. Not hypothetical: this was the live state of a
 * preferred-broker retirement on this org on 2026-08-24 — the incoming Contact carried no firm
 * when the change was written. Under the old arrow headline it rendered "Colliers Houston → —";
 * the row still names the broker who was replaced, so nothing about it should be blank now.
 */
const NULL_INCOMING = [
    {
        id: 'a1B0000000000005AAA',
        changeNumber: 'BBC-0005',
        outgoingBrokerFirm: 'Colliers Houston',
        incomingBrokerFirm: null,
        reason: 'Company Decision',
        notes: null,
        entryDateTime: '2026-08-24T10:09:00.000Z',
        loggedBy: 'Avery Chen'
    }
];

/**
 * 🔴 NEITHER FIRM. Both columns are nullable, so this row is constructible, and an audit entry
 * with a date and a reason is still worth showing. What it must NOT do is render an empty span,
 * the literal "undefined"/"null", or a bare dash where a name belongs.
 */
const NO_FIRMS = [
    {
        id: 'a1B0000000000006AAA',
        changeNumber: 'BBC-0006',
        outgoingBrokerFirm: null,
        incomingBrokerFirm: null,
        reason: 'Company Decision',
        notes: null,
        entryDateTime: '2026-05-05T07:00:00.000Z',
        loggedBy: 'Avery Chen'
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
     * The headline's two parts, read SEPARATELY and never as `h3.textContent` — the compiler eats
     * the whitespace between them, so the concatenation ("Replaced broker:JLL") is an artefact.
     * `name` is what a sighted reader sees; `label` is the visually-hidden, shape-specific word
     * that stops an APPOINTMENT being announced as a replacement.
     */
    const headline = (entry) => {
        const h = entry.querySelector('h3.bbc-broker');
        return {
            name: h.querySelector('.bbc-name').textContent,
            label: h.querySelector('.bbc-sr-only').textContent
        };
    };

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
        expect(title(element)).toBe('Broker Selection');
        // 🔴 NO SPINNER, EVER. A spinner is the only element on this card capable of hanging
        // forever, which is the specific failure the design forbids.
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('HEADER: the card reads "Broker Selection (n)" and carries an icon', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-card').iconName
        ).toBe('standard:record_update');
        // 🔴 EXACT WORDING AND EXACT COUNT. The user specified this header text; "(2)" is the
        // count of rendered entries, so a title that stopped counting would pass a `toContain`.
        expect(title(element)).toBe('Broker Selection (2)');
    });

    it('DATA: one timeline entry per change, headlined by the broker who was replaced', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(rows(element).length).toBe(2);
        expect(empty(element)).toBeNull();
        expect(unavailable(element)).toBeNull();

        const first = rows(element)[0];

        // 🔴 T-BROKER-NAME — THE HEADLINE ON A REPLACEMENT IS THE *OUTGOING* FIRM.
        // This row replaced JLL with Cushman & Wakefield. The broker who was replaced — the one
        // this entry exists to record, and the one the user asked to see — is JLL. Printing the
        // incoming firm instead is the single most likely way to get this wrong: it reads
        // perfectly, names a real firm from the same row, and is the opposite fact. The fixture
        // deliberately carries TWO DIFFERENT firms so that swapping them fails here.
        expect(headline(first).name).toBe('JLL');
        // ...and the one thing that keeps a bare firm name honest: the assistive label saying
        // which kind of row this is. Written when the card was titled "Broker Replace History",
        // where a bare name ASSERTED a replacement on an appointment row; after the 2026-08-25
        // retitle to "Broker Selection" the title no longer makes that claim, so a bare name is
        // now unlabelled rather than wrong — a weaker failure, but still the one this pins.
        expect(headline(first).label).toBe('Replaced broker:');

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

        const names = [...rows(element)].map(
            (r) => r.querySelector('.bbc-name').textContent
        );
        // Newest first, exactly as BovBrokerChangeSelector returned it. A client-side sort added
        // later would be a second copy of the server's ORDER BY — including a tie-break JS cannot
        // see — and would drift from it silently.
        // ⚠ REPOINTED 2026-08-24 from `.bbc-incoming` to the single rendered name. The two rows'
        // names are still DIFFERENT ('JLL' then 'CBRE', the two outgoing firms), so a reversed
        // list still fails — an ordering test over identical strings proves nothing.
        expect(names).toEqual(['JLL', 'CBRE']);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-APPOINTMENT — THE ROW SHAPE WHERE NOBODY WAS REPLACED.
    //
    // The service records an APPOINTMENT (no incumbent) with a NULL outgoing firm, and this is the
    // FIRST row of every disposition that ever had a broker. A headline that simply prints the
    // outgoing firm renders NOTHING here — no error, no blank-looking bug, just a missing name on
    // the one row where the incoming firm is the only broker there is. And a headline that prints
    // a name but presents it as "replaced" states something false about this sale.
    //
    // ⚠ THIS TEST REPLACES T-NO-PREVIOUS, which pinned the fallback string "No Previous Broker"
    // occupying the outgoing slot of the arrow headline. That slot no longer exists, so the old
    // assertion could not be repointed — it pinned a rendering, not a rule. The RULE it protected
    // (an appointment must not render as "undefined →" or as a bare arrow) is stronger here: the
    // appointed firm's own name is now what renders.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-APPOINTMENT: an appointment shows the APPOINTED firm and is not called a replacement', async () => {
        const element = createComponent();

        getHistory.emit(APPOINTMENT_ONLY);
        await Promise.resolve();

        expect(rows(element).length).toBe(1);
        const entry = rows(element)[0];

        // 🔴 THE INCOMING FIRM, BECAUSE THERE IS NO OUTGOING ONE. Falling back to a placeholder
        // ("No Previous Broker", an em dash, a blank) would drop the only broker this row names.
        expect(headline(entry).name).toBe('Marcus & Millichap');
        // 🔴 AND IT IS NOT ANNOUNCED AS A REPLACEMENT. Nobody was replaced on this row; the card's
        // own title says "Replace", so the label is what stops the entry asserting that somebody
        // was. This is the assertion that fails if the label is hard-coded rather than derived.
        expect(headline(entry).label).toBe('Appointed broker:');
        // The sighted reader's version of the same distinction, from Reason__c on line 2.
        expect(entry.querySelector('.bbc-reason').textContent).toBe(
            'Initial Appointment'
        );
        // 🔴 AND NOTHING ANYWHERE CLAIMS A REPLACEMENT HAPPENED.
        expect(text(element)).not.toContain('Replaced broker');

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
        // The headline is unaffected by any of the optional lines being absent — and on this
        // fixture (a replacement: Colliers → Newmark) it is still the OUTGOING firm.
        expect(headline(entry).name).toBe('Colliers');
        expect(headline(entry).label).toBe('Replaced broker:');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-NULL-INCOMING / T-NO-NAME — BOTH FIRM COLUMNS ARE NULLABLE, AND ONE OF THEM WAS NULL
    // ON LIVE DATA ON 2026-08-24. Two separate rules: an absent INCOMING firm must not disturb a
    // replacement's headline at all (the name it prints comes from the other column), and a row
    // with NEITHER firm must still print a word rather than an empty span.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-NULL-INCOMING: a replacement with no incoming firm still names the broker replaced', async () => {
        const element = createComponent();

        getHistory.emit(NULL_INCOMING);
        await Promise.resolve();

        const entry = rows(element)[0];
        // The outgoing firm is present, so this is a replacement and the headline is unaffected
        // by the null on the other side. Under the arrow headline this row read
        // "Colliers Houston → —"; the dash is now gone with the pairing that needed it.
        expect(headline(entry).name).toBe('Colliers Houston');
        expect(headline(entry).label).toBe('Replaced broker:');
        // 🔴 NO RESIDUE OF THE MISSING VALUE ANYWHERE ON THE CARD.
        expect(text(element)).not.toContain('undefined');
        expect(text(element)).not.toContain('—');
        expect(text(element)).not.toContain('Broker not recorded');
        // The rest of the entry is intact, so the assertions above are about the headline and not
        // about a card that failed to render.
        expect(entry.querySelector('.bbc-reason').textContent).toBe(
            'Company Decision'
        );
        expect(entry.querySelector('.bbc-loggedby').textContent).toBe(
            'Avery Chen'
        );
    });

    it('🔴 T-NO-NAME: a row with neither firm says so in words — never a blank span or a dash', async () => {
        const element = createComponent();

        getHistory.emit(NO_FIRMS);
        await Promise.resolve();

        expect(rows(element).length).toBe(1);
        const entry = rows(element)[0];

        // 🔴 A WORD, NOT AN ABSENCE. An empty `.bbc-name` renders as a silent gap where the most
        // important fact on the entry should be — indistinguishable from a styling bug, and
        // announced as nothing at all. The audit entry still has a date and a reason worth
        // reading, so it renders, and it says what is missing.
        expect(headline(entry).name).toBe('Broker not recorded');
        expect(headline(entry).name.trim().length).toBeGreaterThan(0);
        expect(text(element)).not.toContain('undefined');
        expect(text(element)).not.toContain('null');
        // No outgoing firm ⇒ not a replacement, whatever the reason says.
        expect(headline(entry).label).toBe('Appointed broker:');
    });

    it('🔴 T-NO-ARROW: the two-firm pairing is gone — no arrow, no "replaced by", no second firm', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        // 🔴 THE PRESENCE CONTROL FIRST. Every absence below is satisfied perfectly by a card
        // that renders nothing at all, so this test is worthless without proof that two real
        // entries, each with a real visible name, are on screen.
        expect(rows(element).length).toBe(2);
        expect(
            [...rows(element)].map((r) => r.querySelector('.bbc-name').textContent)
        ).toEqual(['JLL', 'CBRE']);

        // 1. The retired class names.
        expect(element.shadowRoot.querySelector('.bbc-swap')).toBeNull();
        expect(element.shadowRoot.querySelector('.bbc-outgoing')).toBeNull();
        expect(element.shadowRoot.querySelector('.bbc-incoming')).toBeNull();
        expect(element.shadowRoot.querySelector('.bbc-arrow')).toBeNull();

        // 2. 🔴 THE RENDERED GLYPH AND THE RELATIONSHIP WORDING — a re-added pairing usually
        //    arrives under a new class name. "replaced by" in particular must not survive as
        //    assistive text: it would announce, to a screen-reader user only, a relationship no
        //    sighted user can see, which is the exact defect the arrow's removal was meant to
        //    avoid leaving behind.
        expect(text(element)).not.toContain('→');
        expect(text(element).toLowerCase()).not.toContain('replaced by');
        expect(element.shadowRoot.innerHTML).not.toContain('→');

        // 3. 🔴 THE SECOND FIRM ITSELF. Both fixture rows pair two DIFFERENT firms, so the
        //    incoming ones are strings that can only appear if the pairing came back. (Note
        //    'JLL' is HISTORY[1]'s incoming firm AND HISTORY[0]'s outgoing firm, which is why the
        //    assertion below names 'Cushman & Wakefield' — a string that is incoming and nothing
        //    else.)
        expect(text(element)).not.toContain('Cushman & Wakefield');
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
        expect(title(element)).toBe('Broker Selection (0)');
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

        // 🔴 NO COUNT IN THE TITLE. "Broker Selection (0)" is the empty state's claim in
        // fewer words, and it is the one place the state templates cannot guard.
        expect(title(element)).toBe('Broker Selection');
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
        // the reader cannot use — and it names it EXACTLY as the entry's headline does, because
        // both go through the same `brokerNameOf` helper. A subtitle that still said
        // "JLL → Cushman & Wakefield" would be the deleted pairing surviving in a second place.
        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe('JLL');
        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe(headline(rows(element)[0]).name);

        element.shadowRoot.querySelector('.bbc-note-close').click();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.slds-modal')).toBeNull();
    });

    it('VIEW: on an appointment the popup subtitle names the same broker the headline does', async () => {
        const element = createComponent();

        // A long note on an APPOINTMENT — the row shape where the subtitle and the headline have
        // to make the SAME choice between two columns, one of which is null. They used to compose
        // that choice separately in `historyRows` and `openNote`; they now share `brokerNameOf`,
        // and this test is what keeps a future "just inline it" from re-splitting them.
        getHistory.emit([
            { ...APPOINTMENT_ONLY[0], notes: LONG_NOTE }
        ]);
        await Promise.resolve();

        rows(element)[0].querySelector('.bbc-notes-view').click();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe('Marcus & Millichap');
        expect(
            element.shadowRoot.querySelector('.bbc-note-sub').textContent
        ).toBe(headline(rows(element)[0]).name);
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

        // 🔴 THE HEADLINE MUST WRAP, NEVER TRUNCATE. At 340px a long firm name legitimately needs
        // two lines, and a name clipped to an ellipsis is worse than a wrapped one — the firm is
        // the fact the whole entry exists to record.
        // ⚠ REPOINTED 2026-08-24. This used to pin `.bbc-swap { flex-wrap: wrap }`, which is gone
        // with the arrow pairing: the headline is no longer a flex row, so `flex-wrap` on it
        // would style nothing. The rule survives as (a) the grid item's min-width, (b) :host's
        // overflow-wrap above, and (c) a ban on the two properties that would clip it.
        expect(CSS_SOURCE).toMatch(/\.bbc-broker\s*\{[^}]*min-width\s*:\s*0/);
        expect(CSS_SOURCE).not.toMatch(
            /\.bbc-(broker|name)[^{]*\{[^}]*text-overflow/
        );
        expect(CSS_SOURCE).not.toMatch(
            /\.bbc-(broker|name)[^{]*\{[^}]*white-space/
        );

        // 🔴 A GAP IS STILL LOAD-BEARING MARKUP, JUST ONE LINE FURTHER DOWN. The template compiler
        // discards the whitespace-only text nodes between sibling elements, and line 2 is three
        // real siblings — the timestamp, the "|" and the reason. With no gap the card renders
        // "Aug 19, 2026, 3:04 PM|Better BOV Received".
        // ⚠ REPOINTED 2026-08-24 from `.bbc-swap`, whose four spans this same rule used to hold
        // apart. Deleting the arrow headline deleted that anchor; it did NOT delete the trap.
        expect(CSS_SOURCE).toMatch(
            /\.bbc-meta\s*\{[^}]*gap\s*:\s*var\(--slds-g-spacing-/
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
