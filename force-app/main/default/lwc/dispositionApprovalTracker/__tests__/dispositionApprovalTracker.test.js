/**
 * c-disposition-approval-tracker
 * ---------------------------------------------------------------------------------------------
 * Read-only. TWO wires: `getTracker` (imperative Apex, `cacheable=true`) supplies the five rows,
 * and `getRecord` on `Disposition__c.LastModifiedDate` exists ONLY to trigger `refreshApex` when
 * the parent record moves.
 *
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE LOAD-BEARING FACTS, BECAUSE THE TESTS BELOW ARE SHAPED BY THEM
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * 1. FIVE ROWS, ALWAYS. This is a CHECKLIST — the un-ticked boxes are the content. A row that
 *    disappears when nothing has happened is indistinguishable from a row that passed, so
 *    "Not started" is a first-class rendered state and `T-FIVE-ROWS` pins that it renders as a
 *    WORD, not as an absence and not as a colour.
 * 2. 🔴 ROW 2 IS RECORD-TYPE-DEPENDENT AND ITS N/A LINE IS THE POINT. Broker selection is TWO
 *    processes. The server picks the applicable one and hands back the other as
 *    `naProcessApiName` + `naState: 'NotApplicable'`. If this component drops that line, the
 *    reader cannot tell "cannot run on this record type" from "has not been started", and one
 *    whole record type looks like it skips an approval. `T-NA-VARIANT` is that pin, in BOTH
 *    directions.
 * 3. EMPTY AND UNAVAILABLE ARE DIFFERENT STATES AND MUST NOT SHARE MARKUP. The controller fails
 *    HARD on a missing grant. If the failure branch rendered rows, the card would show five
 *    "Not started" boxes — a confident, itemised claim that a sale which passed four approvals
 *    passed none. `T-UNAVAILABLE` pins that the error branch renders NO rows at all.
 * 4. `Removed` -> "Recalled" IS A TRANSLATION THIS BUNDLE OWNS. Apex publishes the raw platform
 *    status; the word a user reads is decided in the JS, and `T-STATE-PILLS` is the only thing
 *    checking it. `NotStarted` -> "Not started" and `NotApplicable` -> "N/A" are the two synthetic
 *    states and are checked in the same place.
 * 5. DTO MEMBER NAMES ARE PINNED HERE. A renamed `@AuraEnabled` member on
 *    `DispositionApprovalTrackerService.TrackerRow` fails no deploy and throws nothing in the
 *    browser — the card just renders blanks.
 * 6. THE COMPONENT DOES NOT RE-SORT. Row order is the server's (the BA's numbered gates 1-5) and
 *    the fixture arrives in that order; the render must preserve it.
 *
 * ⚠ WHERE THE THING UNDER TEST IS A LIGHTNING BASE COMPONENT the assertion is on a PROPERTY
 * (`value`, `iconName`), never `textContent` — the Jest stubs render an EMPTY template, so a text
 * assertion against one of them is vacuously green whatever it does.
 * ⚠ AND NEVER ON `p.textContent` FOR A MULTI-SPAN LINE. The template compiler discards the
 * whitespace-only nodes between sibling elements, so line 2's concatenation is an artefact
 * ("Approval raised onBOV-0027|"). Every line-2 assertion reads its spans individually.
 */
import { createElement } from 'lwc';
import DispositionApprovalTracker from 'c/dispositionApprovalTracker';
import getTracker from '@salesforce/apex/DispositionApprovalTrackerController.getTracker';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic: the
// assertions below are deliberately broad, so a comment that merely NAMED a banned value would
// fail them.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'dispositionApprovalTracker.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

jest.mock(
    '@salesforce/apex/DispositionApprovalTrackerController.getTracker',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const DISPOSITION_ID = 'a0D5g000000DispEAG';
const BOV_ID = 'a0B0000000000001AAA';
const OFFER_ID = 'a0C0000000000002AAA';

const row = (over) => ({
    rowKey: 'SALE_DECISION',
    sequence: 1,
    processApiName: 'Sale_Decision_Approval',
    naProcessApiName: null,
    naState: null,
    state: 'NotStarted',
    targetId: null,
    targetLabel: null,
    targetUrl: null,
    submittedDateTime: null,
    decidedDateTime: null,
    approvedCount: null,
    totalCount: null,
    ...over
});

/**
 * 🔴 AN **ON-MARKET** SALE MID-FLIGHT. Row 2 tracks `Broker_Finalize_Approval` and disclaims
 * `Broker_Selection_Approval`; rows 2 and 4 target CHILD records, which is why they carry links.
 */
const ON_MARKET = [
    row({
        rowKey: 'SALE_DECISION',
        sequence: 1,
        state: 'Approved',
        targetId: DISPOSITION_ID,
        targetLabel: 'DISP-0025',
        targetUrl: `/lightning/r/Disposition__c/${DISPOSITION_ID}/view`,
        submittedDateTime: '2026-08-01T08:00:00.000Z',
        decidedDateTime: '2026-08-02T10:30:00.000Z'
    }),
    row({
        rowKey: 'BROKER_SELECTION',
        sequence: 2,
        processApiName: 'Broker_Finalize_Approval',
        naProcessApiName: 'Broker_Selection_Approval',
        naState: 'NotApplicable',
        state: 'Pending',
        targetId: BOV_ID,
        targetLabel: 'BOV-0027',
        targetUrl: `/lightning/r/BOV_Submission__c/${BOV_ID}/view`,
        submittedDateTime: '2026-08-25T09:15:00.000Z'
    }),
    row({
        rowKey: 'NDA_ISSUE',
        sequence: 3,
        processApiName: 'NDA_Issue_Approval',
        state: 'Pending',
        approvedCount: 1,
        totalCount: 3
    }),
    row({
        rowKey: 'FINAL_TERMS',
        sequence: 4,
        processApiName: 'Offer_Selection_Approval',
        state: 'Removed',
        targetId: OFFER_ID,
        targetLabel: 'OFFER-0012',
        targetUrl: `/lightning/r/Disposition_Offer__c/${OFFER_ID}/view`,
        submittedDateTime: '2026-08-20T11:00:00.000Z',
        decidedDateTime: '2026-08-21T08:00:00.000Z'
    }),
    row({
        rowKey: 'CLOSING',
        sequence: 5,
        processApiName: 'Closing_Approval',
        state: 'NotStarted'
    })
];

/**
 * 🔴 THE MIRROR IMAGE — AN **OFF-MARKET** SALE. Only row 2 differs, and only in which process it
 * tracks and which it disclaims. This is the whole point of the record-type branch.
 */
const OFF_MARKET = ON_MARKET.map((r) =>
    r.rowKey === 'BROKER_SELECTION'
        ? {
              ...r,
              processApiName: 'Broker_Selection_Approval',
              naProcessApiName: 'Broker_Finalize_Approval',
              state: 'NotStarted',
              targetId: null,
              targetLabel: null,
              targetUrl: null,
              submittedDateTime: null
          }
        : r
);

/** A sale nothing has ever been submitted against — five rows, every one NotStarted. */
const UNTOUCHED = [
    row({ rowKey: 'SALE_DECISION', sequence: 1 }),
    row({
        rowKey: 'BROKER_SELECTION',
        sequence: 2,
        processApiName: 'Broker_Finalize_Approval',
        naProcessApiName: 'Broker_Selection_Approval',
        naState: 'NotApplicable'
    }),
    row({
        rowKey: 'NDA_ISSUE',
        sequence: 3,
        processApiName: 'NDA_Issue_Approval',
        approvedCount: 0,
        totalCount: 0
    }),
    row({ rowKey: 'FINAL_TERMS', sequence: 4, processApiName: 'Offer_Selection_Approval' }),
    row({ rowKey: 'CLOSING', sequence: 5, processApiName: 'Closing_Approval' })
];

/** A state the platform can emit and this component has no entry for. */
const UNKNOWN_STATE = [row({ rowKey: 'CLOSING', sequence: 5, state: 'Fault' })];

/** A row key Apex could publish that the component's copy map does not know. */
const UNKNOWN_KEY = [row({ rowKey: 'SOMETHING_NEW', sequence: 6 })];

describe('c-disposition-approval-tracker', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: DISPOSITION_ID }) {
        const element = createElement('c-disposition-approval-tracker', {
            is: DispositionApprovalTracker
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const rows = (el) => el.shadowRoot.querySelectorAll('.dat-row');
    const rowFor = (el, key) =>
        el.shadowRoot.querySelector(`.dat-row[data-key="${key}"]`);
    const text = (el) => el.shadowRoot.textContent;
    const title = (el) =>
        el.shadowRoot.querySelector('span[slot="title"]').textContent.trim();
    const pills = (node) => node.querySelectorAll('[class*="dat-pill"]');

    async function render(data, props) {
        const element = createComponent(props);
        getTracker.emit(data);
        await Promise.resolve();
        return element;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // T-FIVE-ROWS
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-FIVE-ROWS: renders five rows in server order, numbered 1-5, each named', async () => {
        const element = await render(ON_MARKET);
        const rendered = rows(element);

        expect(rendered.length).toBe(5);

        // 🔴 ORDER IS THE SERVER'S AND IS NOT RE-SORTED. The sequence IS the content — these are
        // the BA's numbered gates and "which one are we on" is the question the card answers.
        expect([...rendered].map((r) => r.dataset.key)).toEqual([
            'SALE_DECISION',
            'BROKER_SELECTION',
            'NDA_ISSUE',
            'FINAL_TERMS',
            'CLOSING'
        ]);
        expect(
            [...rendered].map((r) => r.querySelector('.dat-seq').textContent.trim())
        ).toEqual(['1', '2', '3', '4', '5']);

        // The five headings are COPY OWNED BY THIS FILE, mapped from the stable server keys.
        expect(
            [...rendered].map((r) => r.querySelector('.dat-label').textContent.trim())
        ).toEqual([
            'Sale Decision',
            'Broker Selection',
            'NDA Issue',
            'Final Sale Terms',
            'Closing Wire Sign-Off'
        ]);
    });

    it('T-FIVE-ROWS: a sale with nothing submitted still renders five rows, each saying so', async () => {
        // 🔴 THIS IS THE EMPTY STATE, AND IT IS FIVE ROWS RATHER THAN NO ROWS. A checklist whose
        // un-ticked boxes vanish cannot report that nothing has happened — the most common state
        // of a sale in its first stage, and the one a principal most needs to see.
        const element = await render(UNTOUCHED);

        expect(rows(element).length).toBe(5);
        // The word, not a colour and not an absence. Five of them, one per row.
        expect(text(element).match(/Not started/g)).toHaveLength(5);
        // No approval was raised, so no row names a target record.
        expect(element.shadowRoot.querySelectorAll('a.dat-target')).toHaveLength(0);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-NA-VARIANT — the record-type-dependent row, in both directions
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-NA-VARIANT: on-market renders the off-market variant as N/A, and vice versa', async () => {
        // 🔴 BOTH DIRECTIONS IN ONE TEST, ON PURPOSE. A swapped pair is a SYMMETRIC defect: two
        // one-direction tests would both have to be right to catch it, and whoever swaps the pair
        // is exactly the person likely to "fix" the failing one by swapping its expectation too.
        const onMarket = await render(ON_MARKET);
        const onRow = rowFor(onMarket, 'BROKER_SELECTION');
        expect(onRow.querySelector('.dat-na-label').textContent.trim()).toBe(
            'Off-market broker approval'
        );

        document.body.removeChild(onMarket);

        const offMarket = await render(OFF_MARKET);
        const offRow = rowFor(offMarket, 'BROKER_SELECTION');
        expect(offRow.querySelector('.dat-na-label').textContent.trim()).toBe(
            'On-market (BOV) broker approval'
        );
    });

    it('T-NA-VARIANT: the disclaimed variant reads "N/A", never "Not started"', async () => {
        // 🔴 THE DISTINCTION THE WHOLE LINE EXISTS FOR. "Not started" invites the reader to go and
        // start something that CANNOT run on this record type; "N/A" tells them it does not apply.
        // Getting this wrong makes one whole record type look like it skips an approval.
        const element = await render(ON_MARKET);
        const brokerRow = rowFor(element, 'BROKER_SELECTION');
        const naLine = brokerRow.querySelector('.dat-na');

        expect(naLine.textContent).toContain('N/A');
        expect(naLine.textContent).not.toContain('Not started');

        // The row's OWN state is the tracked variant's, which is independent of the N/A line.
        expect(pills(brokerRow)[0].textContent.trim()).toBe('Pending');
    });

    it('T-NA-VARIANT: only the broker row carries an N/A line — with a presence control', async () => {
        // ABSENCE PIN. Its presence control is the final expectation: a component that stopped
        // rendering the N/A line at all would satisfy "no other row has one" perfectly.
        const element = await render(ON_MARKET);

        const naLines = element.shadowRoot.querySelectorAll('.dat-na');
        expect(naLines).toHaveLength(1);
        expect(rowFor(element, 'BROKER_SELECTION').querySelector('.dat-na')).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // T-STATE-PILLS — the copy this bundle owns
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-STATE-PILLS: Removed renders as "Recalled", and the synthetic states get words', async () => {
        // 🔴 `Removed` IS THE RAW STATUS A RECALL LEAVES BEHIND and reads to a user as though
        // someone deleted their approval. Apex publishes it raw so a test can assert on the DATA;
        // the word is decided here, and this is the only thing checking it.
        const element = await render(ON_MARKET);

        expect(
            pills(rowFor(element, 'FINAL_TERMS'))[0].textContent.trim()
        ).toBe('Recalled');
        expect(text(element)).not.toContain('Removed');

        expect(pills(rowFor(element, 'SALE_DECISION'))[0].textContent.trim()).toBe(
            'Approved'
        );
        expect(pills(rowFor(element, 'CLOSING'))[0].textContent.trim()).toBe(
            'Not started'
        );
        // The N/A pill goes through the SAME map, which is why `naState` exists as a token rather
        // than as a boolean — one display path, no special case in the template.
        expect(text(element)).not.toContain('NotApplicable');
    });

    it('T-STATE-PILLS: each state wears its own variant class, and the word is never the only signal', async () => {
        const element = await render(ON_MARKET);

        expect(pills(rowFor(element, 'SALE_DECISION'))[0].className).toContain(
            'dat-pill--approved'
        );
        expect(pills(rowFor(element, 'BROKER_SELECTION'))[0].className).toContain(
            'dat-pill--pending'
        );
        expect(pills(rowFor(element, 'FINAL_TERMS'))[0].className).toContain(
            'dat-pill--neutral'
        );
        expect(pills(rowFor(element, 'CLOSING'))[0].className).toContain(
            'dat-pill--muted'
        );
    });

    it('T-STATE-PILLS: an unrecognised platform status degrades to readable text, not a blank chip', async () => {
        const element = await render(UNKNOWN_STATE);
        const pill = pills(rows(element)[0])[0];

        expect(pill.textContent.trim()).toBe('Fault');
        expect(pill.className).toContain('dat-pill--neutral');
    });

    it('T-STATE-PILLS: an unrecognised row key falls back to the raw token, never a nameless row', async () => {
        const element = await render(UNKNOWN_KEY);

        expect(rows(element)[0].querySelector('.dat-label').textContent.trim()).toBe(
            'SOMETHING_NEW'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // T-CHILD-TARGET — the rows that point somewhere else
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-CHILD-TARGET: rows 2 and 4 link to the CHILD record their approval targets', async () => {
        // 🔴 THESE TWO APPROVALS DO NOT TARGET THE RECORD THE USER IS LOOKING AT, and Recall for
        // them lives on the child, not on this page. A link back to the Disposition would be worse
        // than no link — it would look correct and go nowhere useful.
        const element = await render(ON_MARKET);

        const brokerLink = rowFor(element, 'BROKER_SELECTION').querySelector('a.dat-target');
        expect(brokerLink.textContent.trim()).toBe('BOV-0027');
        expect(brokerLink.getAttribute('href')).toBe(
            `/lightning/r/BOV_Submission__c/${BOV_ID}/view`
        );

        const offerLink = rowFor(element, 'FINAL_TERMS').querySelector('a.dat-target');
        expect(offerLink.textContent.trim()).toBe('OFFER-0012');
        expect(offerLink.getAttribute('href')).toBe(
            `/lightning/r/Disposition_Offer__c/${OFFER_ID}/view`
        );

        // A row with no approval raised has no link at all — no dangling separator, no empty <a>.
        expect(rowFor(element, 'CLOSING').querySelector('a.dat-target')).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // T-NDA-COUNT — the one row whose cardinality is not 1
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-NDA-COUNT: the NDA row shows n of m, and only the NDA row does', async () => {
        // 🔴 A SALE INVITES SEVERAL COUNTERPARTIES INTO ITS DATA ROOM, one NDA each. The pill alone
        // cannot tell the whole truth: "Pending" would let a reader assume one NDA and one
        // decision. ABSENCE PIN with its presence control in the same test.
        const element = await render(ON_MARKET);

        expect(
            rowFor(element, 'NDA_ISSUE').querySelector('.dat-count').textContent.trim()
        ).toBe('1 of 3 approved');
        expect(element.shadowRoot.querySelectorAll('.dat-count')).toHaveLength(1);
    });

    it('T-NDA-COUNT: "0 of 0 approved" renders — a zero count is not a missing count', async () => {
        // 🔴 `!!0` IS FALSE. A truthiness test on the counts would hide this line on exactly the
        // sale where the denominator matters most, and "0 of 0" is the reading on EVERY sale until
        // NDA_Issue_Approval is deployed and NDAs start being submitted.
        const element = await render(UNTOUCHED);

        expect(
            rowFor(element, 'NDA_ISSUE').querySelector('.dat-count').textContent.trim()
        ).toBe('0 of 0 approved');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-UNAVAILABLE — a failed read is not an empty checklist
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-UNAVAILABLE: a failed read renders the banner and NO rows at all', async () => {
        // 🔴 THE MOST IMPORTANT ASSERTION IN THIS FILE. The controller fails HARD on a missing
        // grant. If that were swallowed into the normal render this card would show five
        // "Not started" boxes — a confident, itemised claim that a sale which passed four
        // principal approvals passed none, on which a principal could act by re-submitting an
        // approval that is already pending.
        const element = createComponent();
        getTracker.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dat-unavailable')).not.toBeNull();
        expect(rows(element)).toHaveLength(0);
        expect(text(element)).not.toContain('Not started');
        expect(text(element)).not.toContain('Approved');
    });

    it('T-UNAVAILABLE: the failure sentence is about the READER, never about the sale', async () => {
        const element = createComponent();
        getTracker.error();
        await Promise.resolve();

        const message = element.shadowRoot
            .querySelector('.dat-unavailable')
            .textContent.trim();
        expect(message).toBe('The approval tracker is unavailable right now.');
        // "no approvals", "none", "0" would all be claims about the SALE, and the one thing this
        // branch knows is that it does not know.
        expect(message).not.toMatch(/approvals|none|0/i);
    });

    it('T-UNAVAILABLE: the title never carries a count — five is a constant, not a measurement', async () => {
        // ⚠ UNLIKE THE SIBLING HISTORY CARD, whose "(0)" IS a measured fact about the sale. "(5)"
        // here would be information-free and would read like that count.
        const element = await render(ON_MARKET);
        expect(title(element)).toBe('Approval Tracker');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // STYLE — SLDS 2 tokens, and the gaps that are markup
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('STYLE: every colour is an SLDS 2 global hook, and the AA-failing token is absent', async () => {
        // Fallbacks are allowed (and required) INSIDE a var(); a bare hex outside one is not.
        const declarations = CSS_SOURCE.replace(/var\([^)]*\)/g, 'VAR');
        expect(declarations).not.toMatch(/#[0-9a-f]{3,8}/i);

        // `--slds-g-color-neutral-base-60` is ~3.5:1 on white and fails AA; muted text uses
        // `on-surface-1`. `*-container-1` is a SOLID DARK FILL in the base theme and produces
        // dark-on-dark when used as a pill background.
        expect(CSS_SOURCE).not.toContain('--slds-g-color-neutral-base-60');
        expect(CSS_SOURCE).toContain('--slds-g-color-on-surface-1');
    });

    it('STYLE: every .dat-meta line has a gap — the separators are markup, not whitespace', async () => {
        // ⚠ THE TEMPLATE COMPILER DISCARDS WHITESPACE-ONLY TEXT NODES between sibling elements, so
        // without these gaps line 2 renders "BOV-002712 Aug 2026". This is a rendering fact, not a
        // preference.
        const metaRule = CSS_SOURCE.match(/\.dat-meta\s*\{[^}]*\}/);
        expect(metaRule).not.toBeNull();
        expect(metaRule[0]).toMatch(/gap:/);

        const headRule = CSS_SOURCE.match(/\.dat-head\s*\{[^}]*\}/);
        expect(headRule[0]).toMatch(/gap:/);
    });

    it('STYLE: rows are spaced by the item padding, never by the list gap', async () => {
        // ⚠ A `gap` sits OUTSIDE every item, which is why the sibling timeline cards use item
        // padding — and matching them is what stops four stacked sidebar cards reading as four
        // unrelated widgets.
        const listRule = CSS_SOURCE.match(/\.dat-list\s*\{[^}]*\}/);
        expect(listRule[0]).not.toMatch(/gap:/);
        const rowRule = CSS_SOURCE.match(/\.dat-row\s*\{[^}]*\}/);
        expect(rowRule[0]).toMatch(/padding-bottom:/);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // ACCESSIBILITY
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('A11Y: the populated checklist is accessible', async () => {
        const element = await render(ON_MARKET);
        await expect(element).toBeAccessible();
    });

    it('A11Y: the untouched checklist is accessible', async () => {
        const element = await render(UNTOUCHED);
        await expect(element).toBeAccessible();
    });

    it('A11Y: the unavailable branch is accessible', async () => {
        const element = createComponent();
        getTracker.error();
        await Promise.resolve();
        await expect(element).toBeAccessible();
    });
});
