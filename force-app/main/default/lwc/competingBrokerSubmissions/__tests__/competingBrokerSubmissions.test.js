/**
 * c-competing-broker-submissions  (Broker Protection — CHUNK 4)
 * ---------------------------------------------------------------------------
 * Read-only: a single @wire(getSubmissions, { leadId: '$recordId' }) renders a
 * TILE per Competing_Broker_Submission__c with a Winner / Competing badge; a
 * wire error raises an error ShowToastEvent. No imperative Apex.
 *
 * The markup is a <ul>/<li> tile list (it used to be a 5-column <table> inside
 * an overflowing scroll wrapper, which burst the ~360px record-page sidebar).
 * T1/T2 below are anti-regression pins for that: nothing in this component may
 * scroll sideways at any container width.
 *
 * getSubmissions is mocked as an Apex *wire* adapter via createApexTestWireAdapter
 * (the repo pattern — see brokerAssignmentHistory). sa11y's toBeAccessible() is
 * registered globally by jest.setup.js -> @sa11y/jest setup() (per jest.config.js),
 * so every test opts in with an explicit toBeAccessible() call, no per-file setup().
 */
import { createElement } from 'lwc';
import CompetingBrokerSubmissions from 'c/competingBrokerSubmissions';
import getSubmissions from '@salesforce/apex/CompetingSubmissionController.getSubmissions';

jest.mock(
    '@salesforce/apex/CompetingSubmissionController.getSubmissions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = '00Q0000000000001AAA';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not
// cosmetic: the T2/T4 assertions below are deliberately broad (e.g. /nowrap/),
// so a comment that merely NAMED a banned value would fail them. That foot-gun
// used to force the .css to describe its own rules in circumlocutions; with the
// strip in place the stylesheet says `overflow-x` and `nowrap` plainly.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(
            __dirname,
            '..',
            'competingBrokerSubmissions.css'
        ),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

const SUBMISSIONS = [
    {
        Id: 'a0X0000000000001AAA',
        Broker_Name__c: 'Dana Reyes',
        Broker_Email__c: 'dana.reyes@colliers.com',
        Forwarded_By_Email__c: 'intake@dpeg.com',
        Property_Address_Raw__c: '400 Congress Ave, Austin, TX 78701',
        Submitted_DateTime__c: '2025-02-10T15:30:00.000Z',
        Is_Winning_Submission__c: true
    },
    {
        Id: 'a0X0000000000002AAA',
        Broker_Name__c: 'Sam Okafor',
        Broker_Email__c: 'sam.okafor@cbre.com',
        Forwarded_By_Email__c: 'intake@dpeg.com',
        Property_Address_Raw__c: '400 Congress Ave, Austin, TX 78701',
        Submitted_DateTime__c: '2025-02-08T09:15:00.000Z',
        Is_Winning_Submission__c: false
    }
];

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-competing-broker-submissions', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-competing-broker-submissions', {
            is: CompetingBrokerSubmissions
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('HAPPY PATH: renders a tile per submission with Winner and Competing badges', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        // One tile per submission.
        const rows = element.shadowRoot.querySelectorAll('.cbs-tile');
        expect(rows.length).toBe(2);

        // Header count reflects the data.
        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Competing Broker Submissions (2)'
        );

        // Both badges present, one Winner and one Competing.
        const badgeLabels = [
            ...element.shadowRoot.querySelectorAll('lightning-badge')
        ].map((b) => b.label);
        expect(badgeLabels).toContain('Winner');
        expect(badgeLabels).toContain('Competing');

        // Broker + forwarded-by emails render via lightning-formatted-email.
        // The Forwarded By assertions are NOT decorative: rendering that field
        // as a live mailto link (rather than plain text) was an explicit user
        // decision, and T3 below only checks the <dt> LABEL — so downgrading
        // the <dd> to plain text would otherwise leave the whole suite green.
        // Both fixtures carry a forwarded-by address, hence exactly four links:
        // 2 broker + 2 forwarded-by.
        const emailValues = [
            ...element.shadowRoot.querySelectorAll('lightning-formatted-email')
        ].map((e) => e.value);
        expect(emailValues).toContain('dana.reyes@colliers.com');
        expect(emailValues).toContain('sam.okafor@cbre.com');
        expect(emailValues).toContain('intake@dpeg.com');
        expect(emailValues).toHaveLength(4);

        // Submitted date/time renders via lightning-formatted-date-time.
        const dt = element.shadowRoot.querySelector('lightning-formatted-date-time');
        expect(dt).not.toBeNull();
        expect(dt.value).toBe('2025-02-10T15:30:00.000Z');
    });

    it('EMPTY STATE: shows the empty message and no list when there are no submissions', async () => {
        const element = createComponent();

        getSubmissions.emit([]);
        await flushPromises();

        expect(element.shadowRoot.querySelector('.cbs-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.cbs-list')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('ERROR PATH: dispatches an error toast and shows no list when the wire errors', async () => {
        const element = createComponent();

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.error();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const { detail } = toastHandler.mock.calls[0][0];
        expect(detail.variant).toBe('error');
        expect(detail.title).toBe('Could not load broker submissions');
        expect(typeof detail.message).toBe('string');
        expect(detail.message.length).toBeGreaterThan(0);

        // Inline error banner replaces the list on error.
        expect(element.shadowRoot.querySelector('.lv-error')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.cbs-list')).toBeNull();
    });

    // T1 — the direct anti-regression pin. A test that merely renders would not
    // catch a revert to the old table; this does, in three lines.
    it('NO HORIZONTAL LIST VIEW: renders no table, no table head and no scroll wrapper', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        expect(element.shadowRoot.querySelector('table')).toBeNull();
        expect(element.shadowRoot.querySelector('thead')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-scroll')).toBeNull();

        // The tiles are what replaced it.
        expect(element.shadowRoot.querySelector('.cbs-list')).not.toBeNull();
    });

    // T2 — the CSS-source pin, and it is deliberately a SOURCE-TEXT assertion
    // rather than a measurement. WHY (do not "improve" this into a measurement):
    // jsdom performs NO LAYOUT. scrollWidth, clientWidth, offsetWidth and
    // getBoundingClientRect() all return 0 in this environment, so the obvious
    // test — expect(el.scrollWidth).toBeLessThanOrEqual(el.clientWidth) — is
    // `0 <= 0` and passes vacuously WHETHER OR NOT the component overflows. That
    // is a green test that proves nothing. A source-text assertion is coarse but
    // it is falsifiable: it goes red the moment someone reintroduces a horizontal
    // overflow property or a non-wrapping white-space value, or deletes either of
    // the two declarations that do the actual shrinking work (`min-width: 0`, so
    // flex/grid items may shrink below their longest unbreakable token, and
    // `overflow-wrap: anywhere`, which is the only value that affects min-content
    // sizing and which inherits into lightning-formatted-email's shadow root).
    it('NO HORIZONTAL LIST VIEW: the stylesheet cannot produce sideways scroll', () => {
        // --- BANNED (rules 1, 2, 6) -----------------------------------------
        // Matches the `overflow` SHORTHAND as well as `overflow-x`. An
        // /overflow-x/-only assertion is a hole: `.cbs-list { overflow: auto }`
        // restores exactly the horizontal scrollbar this rework removed, and
        // the test would stay green.
        expect(CSS_SOURCE).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);

        // Deliberately broader than /white-space:\s*nowrap/. The value that
        // actually threatens this layout is `flex-wrap: nowrap` on
        // .cbs-tile-head, which the white-space-specific form does not see.
        expect(CSS_SOURCE).not.toMatch(/nowrap/);

        // Rule 6 — no fixed pixel width on content. `min-width` / `max-width`
        // are not matched (the char before "width" is a hyphen, not a boundary).
        expect(CSS_SOURCE).not.toMatch(/(^|[\s;{])width\s*:\s*\d+px/);

        // --- REQUIRED (rules 3, 4, 5), and every one SELECTOR-ANCHORED ------
        // An unanchored /min-width:\s*0/ passes while ANY ONE of the eight
        // occurrences survives. Deleting the single load-bearing one — the grid
        // item, .cbs-tile — would leave the seven defensive copies on block
        // boxes holding the test green while long emails burst the tile again.
        expect(CSS_SOURCE).toMatch(/\.cbs-tile\s*\{[^}]*min-width\s*:\s*0/);

        // overflow-wrap must be on :host, not .cbs-tile — that is what makes it
        // reach the .lv-error banner and the empty state, not just the tiles.
        expect(CSS_SOURCE).toMatch(
            /:host\s*\{[^}]*overflow-wrap\s*:\s*anywhere/
        );

        // Rule 5 had no pin at all, and it is the likeliest casualty of a
        // "this looks over-complicated" edit: the simpler `minmax(18rem, 1fr)`
        // overflows any container narrower than 288px, which is invisible at
        // desktop width and only shows in the ~360px sidebar region.
        expect(CSS_SOURCE).toMatch(/minmax\(\s*min\(\s*18rem\s*,\s*100%\s*\)/);
    });

    // T3 — proves the <th scope="col"> semantics were REPLACED, not deleted: the
    // dt/dd pairs are the single-record equivalent of column-header -> cell, and
    // the labels are visible text (in a narrow tile a bare address is
    // unidentifiable without one).
    it('ACCESSIBILITY: every field keeps a visible label after the table headers were removed', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        const labels = [...element.shadowRoot.querySelectorAll('dt')].map((d) =>
            d.textContent.trim()
        );
        expect(labels).toEqual(
            expect.arrayContaining([
                'Submitted',
                'Property Address',
                'Forwarded By'
            ])
        );

        // The list keeps the label the <table> used to carry — and an EXPLICIT
        // role="list". `list-style: none` makes WebKit drop the implicit list
        // role, and aria-label is only exposed on an element whose role
        // supports naming, so without the attribute Safari/VoiceOver announces
        // neither the label nor "list, N items". axe has no rule for this, so
        // T5's toBeAccessible() passing is not evidence against it.
        const list = element.shadowRoot.querySelector('.cbs-list');
        expect(list.getAttribute('role')).toBe('list');
        expect(list.getAttribute('aria-label')).toBe(
            'Competing broker submissions'
        );
    });

    // T4 — the winner accent lands on the winner and ONLY the winner. The suite
    // previously asserted badge labels but never the row/tile accent.
    it('WINNER ACCENT: only the winning submission carries the winner tile class', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        const tiles = element.shadowRoot.querySelectorAll('.cbs-tile');
        expect(tiles.length).toBe(2);
        // Fixture row 0 is the winner; rows arrive oldest-first from the selector
        // and are NOT re-sorted client-side.
        expect(tiles[0].className).toContain('cbs-tile_winner');
        expect(tiles[1].className).not.toContain('cbs-tile_winner');

        // ...and the two DECLARATIONS that make the class visible are pinned in
        // the stylesheet source too. Without these, both the tinted surface and
        // the 3px inset accent stripe could be deleted with the class assertion
        // above — and the whole suite — still green.
        expect(CSS_SOURCE).toMatch(
            /\.cbs-tile_winner\s*\{[^}]*background\s*:[^;]*surface-container/
        );
        expect(CSS_SOURCE).toMatch(
            /\.cbs-tile_winner\s*\{[^}]*box-shadow\s*:\s*inset\s+3px\s+0\s+0/
        );
    });

    // T5 — unchanged. If axe reports `definition-list` or `heading-order`, the
    // MARKUP is wrong — fix the markup, never loosen this assertion.
    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
