/**
 * c-disposition-approval-history
 * ---------------------------------------------------------------------------------------------
 * Read-only. TWO wires: `getHistory` (imperative Apex, `cacheable=true`) supplies the rows, and
 * `getRecord` on `Disposition__c.LastModifiedDate` exists ONLY to trigger `refreshApex` when the
 * parent record moves.
 *
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE DEFECT THIS CARD FIXES, BECAUSE THE MOST IMPORTANT TESTS BELOW ARE SHAPED BY IT
 * ═════════════════════════════════════════════════════════════════════════════════════════════
 * The disposition flow's approvals target THREE objects. `Broker_Finalize_Approval` targets a
 * `BOV_Submission__c` and `Offer_Selection_Approval` a `Disposition_Offer__c`, so the platform's
 * Approval History related list — which matches `TargetObjectId` to the record it renders on —
 * cannot show either of them on the Disposition page. A user submitted from BOV Outreach and saw
 * nothing (2026-08-25).
 * ⚠ SO "IT RENDERS SOME ROWS" IS NOT THE PROPERTY UNDER TEST. The property is that a row whose
 * TARGET IS A CHILD RECORD renders, names that child, and LINKS TO IT — `T-CHILD-TARGET` below.
 * A fixture in which every row targets the Disposition would pass a naive suite while the card was
 * still broken in exactly the reported way, which is why the default fixture deliberately mixes
 * all three target objects.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * 1. THERE IS NO EMPTY STATE, BY INSTRUCTION (2026-08-25: stop shipping hard-coded empty
 *    sentences). Zero approvals renders the title "Approval History (0)" and NOTHING ELSE.
 *    `T-NO-EMPTY-PROSE` is an ABSENCE pin, so it carries a PRESENCE CONTROL in the same test —
 *    a card that rendered nothing at all would satisfy "there is no empty sentence" perfectly.
 * 2. EMPTY AND UNAVAILABLE ARE DIFFERENT STATES AND MUST NEVER LOOK ALIKE. "(0)" is a claim about
 *    the SALE; a failed read is a fact about the READER. Showing "(0)" on a failed read would
 *    reproduce the exact wrong answer this card exists to stop showing, so `T-UNAVAILABLE` pins
 *    that the failure branch does NOT append a count.
 * 3. THE COMPONENT DOES NOT RE-SORT — either level. Row order is the selector's, step order is the
 *    service's; the fixtures arrive ordered and the render must preserve both.
 * 4. DTO MEMBER NAMES ARE PINNED HERE. A renamed `@AuraEnabled` member on
 *    `DispositionApprovalHistoryService.ApprovalRow` fails no deploy and throws nothing in the
 *    browser — the card just renders blanks.
 * 5. `Removed` -> "Recalled" IS A TRANSLATION THIS FILE OWNS. Apex publishes the raw platform
 *    status; the word a user reads is decided here, and `T-STATUS-PILLS` is the only thing
 *    checking it.
 *
 * ⚠ WHERE THE THING UNDER TEST IS A LIGHTNING BASE COMPONENT the assertion is on a PROPERTY
 * (`value`, `iconName`, `alternativeText`), never `textContent` — the Jest stubs render an EMPTY
 * template, so a text assertion against one of them is vacuously green whatever it does.
 * ⚠ AND NEVER ON `p.textContent` FOR A MULTI-SPAN LINE. The template compiler discards the
 * whitespace-only nodes between sibling elements, so line 2's concatenation is
 * "Approval forBOV-0027|Derek Simmons" — an artefact. Every line-2 assertion reads its spans
 * individually.
 */
import { createElement } from 'lwc';
import DispositionApprovalHistory from 'c/dispositionApprovalHistory';
import getHistory from '@salesforce/apex/DispositionApprovalHistoryController.getHistory';

// The stylesheet, read once, WITH ITS COMMENTS STRIPPED. Stripping first is not cosmetic: the
// assertions below are deliberately broad, so a comment that merely NAMED a banned value would
// fail them.
const CSS_SOURCE = require('fs')
    .readFileSync(
        require('path').join(__dirname, '..', 'dispositionApprovalHistory.css'),
        'utf8'
    )
    .replace(/\/\*[\s\S]*?\*\//g, '');

jest.mock(
    '@salesforce/apex/DispositionApprovalHistoryController.getHistory',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const DISPOSITION_ID = 'a0D5g000000DispEAG';

/**
 * 🔴 THE DEFAULT FIXTURE MIXES ALL THREE TARGET OBJECTS ON PURPOSE — see the header. Server order:
 * newest submission first.
 *   [0] targets a BOV_Submission__c   (Broker_Finalize_Approval)  — the reported blind spot
 *   [1] targets a Disposition_Offer__c (Offer_Selection_Approval) — the other blind spot
 *   [2] targets the Disposition itself (Sale_Decision_Approval)   — the control
 */
const HISTORY = [
    {
        processInstanceId: '04g0000000000001AAA',
        processName: 'Broker Finalize Approval',
        targetId: 'a0B0000000000001AAA',
        targetLabel: 'BOV-0027',
        targetDetail: 'Derek Simmons',
        targetAmount: null,
        targetUrl: '/lightning/r/BOV_Submission__c/a0B0000000000001AAA/view',
        status: 'Pending',
        submittedDateTime: '2026-08-25T09:15:00.000Z',
        submittedBy: 'Avery Chen',
        submittedComments: 'Selected on score and local coverage.',
        completedDateTime: null,
        steps: [
            {
                stepId: '04h0000000000001AAA',
                stepStatus: 'Pending',
                actorName: 'Principal Approvers',
                comments: null,
                createdDateTime: '2026-08-25T09:15:02.000Z'
            }
        ]
    },
    {
        processInstanceId: '04g0000000000002AAA',
        processName: 'Offer Selection Approval',
        targetId: 'a0C0000000000002AAA',
        targetLabel: 'OFFER-0012',
        targetDetail: null,
        targetAmount: 2040000,
        targetUrl: '/lightning/r/Disposition_Offer__c/a0C0000000000002AAA/view',
        status: 'Rejected',
        submittedDateTime: '2026-08-20T11:00:00.000Z',
        submittedBy: 'Avery Chen',
        submittedComments: null,
        completedDateTime: '2026-08-21T08:00:00.000Z',
        steps: [
            {
                stepId: '04h0000000000002AAA',
                stepStatus: 'Rejected',
                actorName: 'Nadia Rahman',
                comments: 'Price below the target sale price.',
                createdDateTime: '2026-08-21T08:00:00.000Z'
            }
        ]
    },
    {
        processInstanceId: '04g0000000000003AAA',
        processName: 'Sale Decision Approval',
        targetId: DISPOSITION_ID,
        targetLabel: 'DISP-0025',
        targetDetail: null,
        targetAmount: null,
        targetUrl: `/lightning/r/Disposition__c/${DISPOSITION_ID}/view`,
        status: 'Approved',
        submittedDateTime: '2026-08-01T08:00:00.000Z',
        submittedBy: 'Avery Chen',
        submittedComments: null,
        completedDateTime: '2026-08-02T10:30:00.000Z',
        steps: [
            {
                stepId: '04h0000000000003AAA',
                stepStatus: 'Approved',
                actorName: 'Nadia Rahman',
                comments: 'Proceed.',
                createdDateTime: '2026-08-02T10:30:00.000Z'
            }
        ]
    }
];

/**
 * 🔴 A RECALLED APPROVAL. `Removed` is the RAW platform status a recall leaves behind, and it is
 * the one status whose raw text is actively misleading to a user. Nothing else in this file proves
 * the translation happens.
 */
const RECALLED = [
    {
        ...HISTORY[2],
        processInstanceId: '04g0000000000004AAA',
        status: 'Removed',
        completedDateTime: '2026-08-03T09:00:00.000Z',
        steps: []
    }
];

/**
 * 🔴 A JUST-SUBMITTED APPROVAL WITH NO STEPS. This is REAL and it is the common shape the moment
 * after a submit: the service EXCLUDES the `Started` history row (its comment is hoisted onto
 * `submittedComments` instead), so a brand-new approval's trail is legitimately empty. The card
 * must render the entry with no step list at all — never an empty `<ul>` carrying an aria-label,
 * which announces a list of nothing.
 */
const NO_STEPS = [
    {
        ...HISTORY[0],
        processInstanceId: '04g0000000000005AAA',
        submittedComments: null,
        steps: []
    }
];

/**
 * 🔴 A ZERO-AMOUNT OFFER. `!!0` is false, so a truthiness test on the amount would silently hide
 * it — and an offer row with no amount at all is the one row a reader cannot tell apart from
 * another offer by the same broker.
 */
const ZERO_AMOUNT = [
    {
        ...HISTORY[1],
        processInstanceId: '04g0000000000006AAA',
        targetAmount: 0
    }
];

/**
 * A status the platform can emit and this component has no entry for. It must degrade to READABLE
 * TEXT on a neutral pill, never to a blank chip.
 */
const UNKNOWN_STATUS = [
    {
        ...HISTORY[2],
        processInstanceId: '04g0000000000007AAA',
        status: 'Fault'
    }
];

describe('c-disposition-approval-history', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: DISPOSITION_ID }) {
        const element = createElement('c-disposition-approval-history', {
            is: DispositionApprovalHistory
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const entries = (el) => el.shadowRoot.querySelectorAll('.dah-entry');
    const unavailable = (el) => el.shadowRoot.querySelector('.dah-unavailable');
    const text = (el) => el.shadowRoot.textContent;
    const title = (el) =>
        el.shadowRoot.querySelector('span[slot="title"]').textContent.trim();

    /** The target link on one entry — the element the whole card exists to render. */
    const targetLink = (entry) => entry.querySelector('a.dah-target');

    const pill = (entry) => entry.querySelector('[class*="dah-pill"]');

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // HEADER + STATES
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('BEFORE THE WIRE ANSWERS: no entries, no count, no spinner', async () => {
        const element = createComponent();
        await Promise.resolve();

        expect(entries(element)).toHaveLength(0);
        expect(title(element)).toBe('Approval History');
        expect(
            element.shadowRoot.querySelector('lightning-spinner')
        ).toBeNull();
    });

    it('HEADER: the card reads "Approval History (n)" and carries an icon', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        expect(title(element)).toBe('Approval History (3)');
        expect(
            element.shadowRoot.querySelector('lightning-card').iconName
        ).toBe('standard:approval');
    });

    it('DATA: one entry per approval, headlined by the process name', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const items = entries(element);
        expect(items).toHaveLength(3);
        expect(
            [...items].map((li) =>
                li.querySelector('h3.dah-process').textContent.trim()
            )
        ).toEqual([
            'Broker Finalize Approval',
            'Offer Selection Approval',
            'Sale Decision Approval'
        ]);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-CHILD-TARGET — THE WHOLE POINT OF THE COMPONENT.
    //
    // The two approvals the standard related list cannot show are the ones that target a CHILD.
    // This test asserts they are present, that each NAMES its child by number, and that each LINKS
    // to the child rather than to the Disposition — a link back to the record you are already on
    // would be indistinguishable from the bug.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-CHILD-TARGET: approvals that target a BOV or an offer are shown and link to that child', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const links = [...entries(element)].map(targetLink);

        expect(links.map((a) => a.textContent.trim())).toEqual([
            'BOV-0027',
            'OFFER-0012',
            'DISP-0025'
        ]);
        expect(links.map((a) => a.getAttribute('href'))).toEqual([
            '/lightning/r/BOV_Submission__c/a0B0000000000001AAA/view',
            '/lightning/r/Disposition_Offer__c/a0C0000000000002AAA/view',
            `/lightning/r/Disposition__c/${DISPOSITION_ID}/view`
        ]);

        // ...and NOT all pointed at the record the card is rendered on. Stated as its own
        // assertion because that is precisely the failure the href list above would hide if the
        // fixture were ever narrowed to one target object.
        expect(
            links.filter((a) => a.getAttribute('href').includes(DISPOSITION_ID))
        ).toHaveLength(1);
    });

    it('TARGET HINT: a BOV row names its broker; an offer row shows an EXACT amount', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const items = entries(element);

        expect(items[0].querySelector('.dah-detail').textContent).toBe(
            'Derek Simmons'
        );
        expect(items[0].querySelector('.dah-amount')).toBeNull();

        // 🔴 THE AMOUNT IS A NUMBER HANDED TO lightning-formatted-number, NOT A PRE-ABBREVIATED
        // STRING. "$2.0M" would render 2,040,000 and 1,960,000 identically on the one line whose
        // job is to say WHICH offer was decided. The base component is a Jest stub, so the
        // assertion is on its PROPERTY.
        const amount = items[1].querySelector(
            '.dah-amount lightning-formatted-number'
        );
        expect(amount.value).toBe(2040000);
        expect(amount.formatStyle).toBe('currency');
        expect(items[1].querySelector('.dah-detail')).toBeNull();

        // The Disposition row has neither.
        expect(items[2].querySelector('.dah-detail')).toBeNull();
        expect(items[2].querySelector('.dah-amount')).toBeNull();
    });

    it('🔴 T-ZERO-AMOUNT: an offer of 0 still renders its amount', async () => {
        const element = createComponent();

        getHistory.emit(ZERO_AMOUNT);
        await Promise.resolve();

        const amount = entries(element)[0].querySelector(
            '.dah-amount lightning-formatted-number'
        );
        expect(amount).not.toBeNull();
        expect(amount.value).toBe(0);
    });

    it('🔴 T-NO-DANGLING-SEPARATOR: a row with no hint and no amount renders no stray pipe', async () => {
        const element = createComponent();

        // The Disposition-targeted row: no detail, no amount.
        getHistory.emit([HISTORY[2]]);
        await Promise.resolve();

        const line = entries(element)[0].querySelectorAll('.dah-meta')[0];
        expect(line.querySelectorAll('.dah-sep')).toHaveLength(0);
        expect(targetLink(line.closest('.dah-entry')).textContent.trim()).toBe(
            'DISP-0025'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // STATUS PILLS
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-STATUS-PILLS: state is carried by a WORD, and "Removed" reads as "Recalled"', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const pills = [...entries(element)].map(pill);
        expect(pills.map((p) => p.textContent.trim())).toEqual([
            'Pending',
            'Rejected',
            'Approved'
        ]);
        expect(pills.map((p) => p.className)).toEqual([
            'dah-pill dah-pill--pending',
            'dah-pill dah-pill--rejected',
            'dah-pill dah-pill--approved'
        ]);

        // 🔴 THE TRANSLATION. `Removed` is what a RECALL leaves behind and is the only status
        // whose raw platform text actively misinforms a user.
        const recalled = createComponent();
        getHistory.emit(RECALLED);
        await Promise.resolve();

        const recalledPill = pill(entries(recalled)[0]);
        expect(recalledPill.textContent.trim()).toBe('Recalled');
        expect(recalledPill.className).toBe('dah-pill dah-pill--neutral');
        expect(text(recalled)).not.toContain('Removed');
    });

    it('🔴 T-UNKNOWN-STATUS: an unmapped status degrades to its raw word, never a blank chip', async () => {
        const element = createComponent();

        getHistory.emit(UNKNOWN_STATUS);
        await Promise.resolve();

        const chip = pill(entries(element)[0]);
        expect(chip.textContent.trim()).toBe('Fault');
        expect(chip.className).toBe('dah-pill dah-pill--neutral');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // SUBMITTER + TRAIL
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('SUBMITTER: who and when, plus the submit comment lifted off the excluded Started step', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const first = entries(element)[0];
        expect(first.querySelector('.dah-by').textContent).toBe('Avery Chen');
        expect(
            first.querySelector(
                '.dah-when lightning-formatted-date-time'
            ).value
        ).toBe('2026-08-25T09:15:00.000Z');
        // ⚠ SCOPED TO `.dah-submit-note`, NEVER TO A BARE `.dah-note-txt`. A STEP's comment wears
        // the same `dah-note` chrome three lines further down, so the unscoped query matches the
        // approver's comment on any row whose submitter left none — measured, and it made the
        // absence assertion below read as a failure while the card was correct.
        expect(
            first.querySelector('.dah-submit-note .dah-note-txt').textContent
        ).toBe('Selected on score and local coverage.');

        // A row with no submit comment renders no submit-note line at all — even though it DOES
        // carry an approver comment on its step, which is the whole reason this is scoped.
        expect(entries(element)[2].querySelector('.dah-submit-note')).toBeNull();
        expect(
            entries(element)[2].querySelector('.dah-step .dah-note-txt')
                .textContent
        ).toBe('Proceed.');
    });

    it('STEPS: one row per step — status, actor, when, comments — and the order is the server\'s', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        const steps = entries(element)[1].querySelectorAll('.dah-step');
        expect(steps).toHaveLength(1);
        expect(steps[0].querySelector('.dah-step-status').textContent).toBe(
            'Rejected'
        );
        expect(steps[0].querySelector('.dah-actor').textContent).toBe(
            'Nadia Rahman'
        );
        expect(steps[0].querySelector('.dah-note-txt').textContent).toBe(
            'Price below the target sale price.'
        );
        expect(
            steps[0].querySelector('lightning-formatted-date-time').value
        ).toBe('2026-08-21T08:00:00.000Z');
    });

    it('🔴 T-NO-STEPS: a just-submitted approval renders NO step list — not an empty one', async () => {
        const element = createComponent();

        getHistory.emit(NO_STEPS);
        await Promise.resolve();

        const entry = entries(element)[0];
        // PRESENCE CONTROL first: the entry itself rendered, so the absence below means something.
        expect(entry.querySelector('h3.dah-process').textContent.trim()).toBe(
            'Broker Finalize Approval'
        );
        expect(entry.querySelector('.dah-steps')).toBeNull();
        expect(entry.querySelectorAll('.dah-step')).toHaveLength(0);
    });

    it('ORDER: preserves the server order at BOTH levels and does not re-sort', async () => {
        const element = createComponent();

        // Rows arrive newest-first from the selector; steps newest-first from the service.
        const twoSteps = [
            {
                ...HISTORY[2],
                steps: [
                    {
                        stepId: '04h0000000000009AAA',
                        stepStatus: 'Approved',
                        actorName: 'Nadia Rahman',
                        comments: null,
                        createdDateTime: '2026-08-02T10:30:00.000Z'
                    },
                    {
                        stepId: '04h0000000000008AAA',
                        stepStatus: 'Reassigned',
                        actorName: 'Avery Chen',
                        comments: null,
                        createdDateTime: '2026-08-01T12:00:00.000Z'
                    }
                ]
            }
        ];
        getHistory.emit(twoSteps);
        await Promise.resolve();

        expect(
            [
                ...entries(element)[0].querySelectorAll('.dah-step-status')
            ].map((s) => s.textContent)
        ).toEqual(['Approved', 'Reassigned']);
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // EMPTY vs UNAVAILABLE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-EMPTY-PROSE: zero approvals is "(0)" and NOTHING ELSE', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        // PRESENCE CONTROL: the card and its title rendered. Without this, every absence below is
        // satisfied by a component that rendered nothing at all.
        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();
        expect(title(element)).toBe('Approval History (0)');

        expect(entries(element)).toHaveLength(0);
        expect(unavailable(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.dah-state')).toBeNull();
        // No hard-coded empty sentence of any shape (user instruction, 2026-08-25).
        expect(text(element).replace(title(element), '').trim()).toBe('');
    });

    it('🔴 T-UNAVAILABLE: a failed read is its OWN state and never claims the sale has none', async () => {
        const element = createComponent();

        getHistory.error();
        await Promise.resolve();

        expect(unavailable(element).textContent).toBe(
            'Approval history is unavailable right now.'
        );
        expect(entries(element)).toHaveLength(0);

        // 🔴 THE COUNT MUST NOT APPEAR. "(0)" is a claim about the SALE; on a failed read we know
        // nothing about the sale, and asserting it here is what stops the two states collapsing
        // into one — which would reproduce the exact wrong answer this card was built to fix.
        expect(title(element)).toBe('Approval History');
        expect(title(element)).not.toContain('(0)');
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // STYLESHEET
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('T-CSS: the stylesheet cannot produce sideways scroll at 340px', () => {
        expect(CSS_SOURCE).not.toMatch(/overflow(-x)?\s*:\s*(auto|scroll)/);
        expect(CSS_SOURCE).not.toMatch(/(^|[\s;{])width\s*:\s*\d+px/);
        expect(CSS_SOURCE).not.toMatch(/justify-content\s*:\s*space-between/);

        // 🔴 A TIMELINE IS SINGLE-COLUMN. The repo's usual narrow-column tile grid would leave the
        // rail joining nothing.
        expect(CSS_SOURCE).not.toMatch(/repeat\(\s*auto-fill/);

        // The grid item holding all the text, beside the rail. An unanchored /min-width:\s*0/
        // passes while ANY of the many occurrences survives.
        expect(CSS_SOURCE).toMatch(/\.dah-body\s*\{[^}]*min-width\s*:\s*0/);
        expect(CSS_SOURCE).toMatch(
            /:host\s*\{[^}]*overflow-wrap\s*:\s*anywhere/
        );

        // 🔴 THE PROCESS NAME WRAPS, NEVER TRUNCATES — it is the string that tells the user their
        // submission is here.
        expect(CSS_SOURCE).toMatch(/\.dah-process\s*\{[^}]*min-width\s*:\s*0/);
        expect(CSS_SOURCE).not.toMatch(/\.dah-process[^{]*\{[^}]*text-overflow/);
        expect(CSS_SOURCE).not.toMatch(/\.dah-process[^{]*\{[^}]*white-space/);

        // 🔴 THE `gap` IS LOAD-BEARING MARKUP. The compiler discards whitespace-only nodes between
        // siblings, so with no gap line 2 renders "BOV-0027|Derek Simmons".
        expect(CSS_SOURCE).toMatch(
            /\.dah-meta\s*\{[^}]*gap\s*:\s*var\(--slds-g-spacing-/
        );

        // The rail reaches the next dot without anyone measuring an entry...
        expect(CSS_SOURCE).toMatch(/\.dah-track\s*\{[^}]*flex\s*:\s*1\s+1\s+auto/);
        // ...and stops at the last one rather than trailing into the card's padding.
        expect(CSS_SOURCE).toMatch(
            /\.dah-entry:last-child\s+\.dah-track\s*\{[^}]*display\s*:\s*none/
        );
        expect(CSS_SOURCE).toMatch(
            /\.dah-dot\s*\{[^}]*border-radius\s*:\s*var\(--slds-g-radius-border-circle/
        );

        // 🔴 THE PILL MUST NOT SHRINK AWAY beside a long process name on a wrapped flex line.
        expect(CSS_SOURCE).toMatch(/\.dah-pill\s*\{[^}]*flex\s*:\s*none/);

        // The visually-hidden label must stay in the ACCESSIBILITY tree — `display: none` is the
        // one way to write this rule that removes the thing it exists to add.
        expect(CSS_SOURCE).toMatch(
            /\.dah-sr-only\s*\{[^}]*clip-path\s*:\s*inset\(50%\)/
        );
        expect(CSS_SOURCE).not.toMatch(
            /\.dah-sr-only\s*\{[^}]*display\s*:\s*none/
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 🔴 T-TOKENS — LIGHT *AND* DARK. Blank every `var(--…)` INCLUDING ITS FALLBACK, then look for
    // what is left: a hex surviving that is a hex nothing can re-theme. axe's colour-contrast rule
    // is inert in jsdom and the SLDS linter is a separate command a reviewer can forget, so this
    // source-text pin is the only automated dark-mode check that runs with the suite.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('🔴 T-TOKENS: no colour is hard-coded outside a design-token fallback', () => {
        const withoutTokens = CSS_SOURCE.replace(/var\(\s*--[^()]*\)/g, 'TOKEN');

        expect(withoutTokens).not.toMatch(/#[0-9a-fA-F]{3}\b/);
        expect(withoutTokens).not.toMatch(/rgba?\(/);
        expect(withoutTokens).not.toMatch(/hsla?\(/);

        // Guard the guard: the blanking regex must actually have found tokens to blank.
        expect(
            (CSS_SOURCE.match(/var\(\s*--slds-/g) || []).length
        ).toBeGreaterThan(20);

        // The two decorations with NO text fallback: if they resolve to nothing, the timeline
        // simply is not there and no other assertion notices.
        expect(CSS_SOURCE).toMatch(
            /\.dah-dot\s*\{[^}]*background\s*:\s*var\(--slds-g-color-/
        );
        expect(CSS_SOURCE).toMatch(
            /\.dah-track\s*\{[^}]*background\s*:\s*var\(--slds-g-color-/
        );

        // 🔴 `*-container-1` IS A SOLID DARK FILL IN THE BASE THEME, NOT A PALE TINT. Pairing it
        // with `*-base-30` text is dark-on-dark, and it passes the linter, sa11y and review.
        // The safe pill recipe is `*-base-95` + `*-base-30`/`-40` + a `*-base-80` ring.
        expect(CSS_SOURCE).not.toMatch(/\.dah-pill--[a-z]+\s*\{[^}]*container-1/);
        expect(CSS_SOURCE).toMatch(
            /\.dah-pill--approved\s*\{[^}]*background\s*:\s*var\(--slds-g-color-success-base-95/
        );
        expect(CSS_SOURCE).toMatch(
            /\.dah-pill--rejected\s*\{[^}]*background\s*:\s*var\(--slds-g-color-error-base-95/
        );
    });

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // ACCESSIBILITY
    // ─────────────────────────────────────────────────────────────────────────────────────────

    it('is accessible with rows', async () => {
        const element = createComponent();

        getHistory.emit(HISTORY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible when there is nothing to show', async () => {
        const element = createComponent();

        getHistory.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible when the read failed', async () => {
        const element = createComponent();

        getHistory.error();
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
