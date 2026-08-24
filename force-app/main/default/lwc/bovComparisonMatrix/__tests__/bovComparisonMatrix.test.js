/**
 * WIRE-MOCK TEMPLATE — @wire to APEX (parameterised) + NavigationMixin + MODAL
 * ---------------------------------------------------------------------------
 * Follows the c-broker-firm-card @wire-Apex template. This component adds a
 * NavigationMixin, so it also demonstrates the project's navigation-mock
 * convention: replace lightning/navigation so Navigate DISPATCHES a 'navigate'
 * event (assertable without instance spying) and GenerateUrl RESOLVES a stable
 * URL for connectedCallback to populate the "View All" footer link.
 *
 * Data source: @wire(getSubmissions, { dispositionId: '$recordId' }).
 *   - getSubmissions.emit(rows)  -> data branch
 *   - getSubmissions.error()     -> error branch
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 RETRACTED 2026-08-24 — "THREE HEADER ACTIONS, TWO OF WHICH ARE MUTUALLY
 * EXCLUSIVE" IS NO LONGER THE SHAPE OF THIS COMPONENT.
 * ─────────────────────────────────────────────────────────────────────────────
 * What stood here (DEV-15; 2026-08-21) said: *"'Select Broker' and 'Replace
 * Broker' BOTH open c/bovReplaceBrokerModal — one bundle, one Apex method — and
 * exactly one of the two ever renders"*, and *"THE MUTUAL EXCLUSION IS ASSERTED
 * IN BOTH DIRECTIONS, AS ABSENCE. A suite that only checked 'Replace renders
 * when something is Selected' and 'Select renders when nothing is' would stay
 * green if BOTH rendered at once."*
 *
 * THE SELECT BROKER BUTTON WAS DELETED ON 2026-08-24 — the first appointment is
 * made automatically from BOV_Score__c on the server, so there is no
 * first-appointment button to press. There is no mutual exclusion left to
 * assert, because there is no second member of the pair.
 *
 * ⚠ ELEVEN TESTS IN THIS FILE WERE TOUCHED BY THAT DELETION AND THE SPLIT
 * MATTERS — read it before assuming the suite "just broke":
 *   • EIGHT clicked `.matrix-select` and died on `null.click()`. Loud, obvious,
 *     and therefore the SAFE half. They are re-homed onto Replace or Add
 *     Preferred Broker where the behaviour still exists, or deleted where it
 *     does not.
 *   • THREE asserted `expect(selectBtn(element)).toBeNull()` and would have
 *     SURVIVED, GREEN AND VACUOUS — they pass now because the button does not
 *     exist, exactly as they would if this whole component were deleted. All
 *     three were rewritten to assert the NEW reality positively (the exact
 *     buttons present, by rendered label, in template order) and to keep the
 *     Select absence as a NAMED pin rather than an accident.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 RETRACTED AGAIN, LATER THE SAME DAY — ZERO HEADER ACTIONS. NOT THREE.
 * ─────────────────────────────────────────────────────────────────────────────
 * What stood here read: *"THREE HEADER ACTIONS (2026-08-24): Add Broker
 * Response, Replace Broker, Add Preferred Broker — in that template order …
 * NONE OF THE THREE NAVIGATES."* All three MOVED to `c/bovBrokerPanel`, which
 * wraps this card and the preferred card under one header. Every sentence about
 * which modal each opens, and about none of them navigating, is still true —
 * it is true THERE. This component now renders a title, a table and a footer
 * link, and the footer link is the only thing in it that navigates.
 *
 * ⚠ BUTTON ASSERTIONS SCAN THE RENDERED `label` PROPERTY, NOT `textContent`.
 * `lightning-button`'s sfdx-lwc-jest stub renders an EMPTY template, so
 * `element.shadowRoot.textContent` contains none of these labels and a
 * `toContain('Replace Broker')` assertion on it is vacuously green in BOTH
 * directions. `buttonLabels()` below reads the property the component actually
 * set.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE BUNDLE RENDERS TWICE ON THE PAGE (2026-08-24)
 * ─────────────────────────────────────────────────────────────────────────────
 * `preferredOnly` turns this same component into the "Preferred Broker" card
 * that `c/bovBrokerPanel` mounts above the matrix. It defaults false, so every
 * existing test above exercises the matrix instance unchanged; the preferred
 * instance is created explicitly, with its props passed to `createComponent`.
 * ⚠ `createComponent()` WITH NO ARGUMENT USES ITS DEFAULT PARAMETER — passing
 * `undefined` does NOT clear it. Preferred-instance tests must pass the full
 * props object including `recordId`.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 TWENTY-FIVE TESTS LEFT THIS FILE ON 2026-08-24. THEY MOVED, THEY DID NOT DIE.
 * ═════════════════════════════════════════════════════════════════════════════
 * Every ADD RESPONSE / ADD PREFERRED / REPLACE / three-buttons-in-order test
 * moved to `lwc/bovBrokerPanel/__tests__/bovBrokerPanel.test.js` together with
 * the buttons themselves, and so did the fixtures only they used
 * (`NONE_SELECTED`, `PREFERRED_APPOINTED`, `DUPLICATE_BROKERS`,
 * `DUPLICATE_BROKERS_WITH_INCUMBENT`) and both modal mocks. Look there before
 * concluding a behaviour lost its pin.
 *
 * 🔴 WHAT REPLACED THEM HERE IS AN ABSENCE PIN OVER **BOTH** MODES. A
 * preferred-instance-only "no buttons" assertion — which is what this file used
 * to carry — became VACUOUSLY GREEN the moment the matrix instance lost its
 * buttons too: it asserts nothing this template can now get wrong. The
 * `it.each` version below runs over both instances and reds if any
 * `lightning-button` or `[slot="actions"]` comes back.
 *
 * 🔴 THE WIRE IS STILL HELD AS A WHOLE RESULT, and it still matters — it now
 * backs `@api refreshData()`, which the panel calls after every write it makes.
 * A "tidying" edit back to `wired({ data, error })` compiles, passes every
 * render test above, and silently turns that refresh into a no-op. `refreshApex`
 * is NOT auto-mocked by the sfdx-lwc-jest stub — `@salesforce/apex` resolves to a
 * real module whose `refreshApex` is a plain function — so this file carries its
 * own `jest.mock('@salesforce/apex', ...)` below to make it a spy, and the
 * `refreshData()` test asserts it is called with the SAME object the wire handed
 * the component, which is the only assertion that catches that regression.
 *
 * ⚠ NO MODAL MOCKS REMAIN IN THIS FILE, DELIBERATELY. This bundle no longer
 * imports `c/bovAddResponseModal` or `c/bovReplaceBrokerModal`; a mock for a
 * module the component does not import proves nothing and would quietly make a
 * re-added import look tested.
 */
import { createElement } from 'lwc';
import BovComparisonMatrix from 'c/bovComparisonMatrix';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';
import { refreshApex } from '@salesforce/apex';

jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const GenerateUrl = Symbol('GenerateUrl');
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](pageRef) {
                this.dispatchEvent(
                    new CustomEvent('navigate', { detail: pageRef })
                );
            }
            [GenerateUrl]() {
                return Promise.resolve('/lightning/o/BOV_Submission__c/list');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

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

// ⚠ `refreshApex` IS NOT AUTO-MOCKED. `@salesforce/apex` resolves to a real module whose
// `refreshApex` is a plain function, so `expect(refreshApex).toHaveBeenCalled()` fails with
// "received value must be a mock or spy function" — which reads like a broken assertion rather
// than a missing mock. No other suite in this repo asserts on it, so there was no precedent to
// copy; this is the mock the refresh assertions below need.
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), {
    virtual: true
});

const RECORD_ID = 'a0D5g000000DispEAG';

const SUBMISSIONS = [
    {
        id: 'a0X010000000001',
        name: 'BOV-0001',
        isSelected: true,
        bovScore: 88,
        brokerFirm: 'Colliers International',
        contactName: 'Jane Doe',
        bovAmount: 12500000,
        daysToMarket: 45,
        capRate: 6.25
    },
    {
        id: 'a0X010000000002',
        name: 'BOV-0002',
        isSelected: false,
        bovScore: 71,
        brokerFirm: 'JLL',
        contactName: 'John Roe',
        bovAmount: 11000000,
        daysToMarket: 60,
        capRate: 6.8
    }
];
/**
 * ⚠ NOTE WHAT `SUBMISSIONS` ABOVE DOES *NOT* CARRY: an `isPreferred` KEY AT ALL.
 * That is deliberate, and it is checked-in reality rather than a hypothetical — this component
 * ships BEFORE `Is_Preferred_Broker__c` exists in the org, so until that field and its FLS grant
 * are deployed the payload cannot carry the member no matter what `BovController.BovRow` says in
 * the repo. Every existing test in this file therefore doubles as the pin for "an ABSENT flag
 * behaves as not-preferred": those rows must land in the MATRIX, and the preferred card must
 * stay hidden.
 * `isPreferred !== true` on the matrix side is what makes that true. ⚠ THE MIRROR-IMAGE TEST
 * `isPreferred === false` ON THE PREFERRED SIDE WOULD NOT BE EQUIVALENT: an Apex `Boolean` null
 * arrives as JS `null`, not `false`, so a null would populate a card whose entire premise is
 * "this one is flagged". `=== true` is the only safe test there.
 */

/**
 * One preferred broker, and it is deliberately the THIN row a preferred broker really is:
 * no valuation, no days-to-market, no cap rate, no score. A preferred broker is a firm DPEG
 * would like to use — not a firm that has quoted — so a fixture carrying a full BOV response
 * would prove the card works on data the feature does not produce.
 */
const PREFERRED_ROW = {
    id: 'a0X010000000003',
    name: 'BOV-0003',
    isSelected: false,
    isPreferred: true,
    bovScore: null,
    brokerFirm: 'Cushman & Wakefield',
    contactName: 'Ada Lin',
    bovAmount: null,
    daysToMarket: null,
    capRate: null
};

/**
 * Two ordinary responses (one Selected) PLUS one preferred broker that is NOT selected.
 *
 * ⚠ STILL A REACHABLE STATE AFTER THE 2026-08-24 DECISION, WHICH IS WHY IT SURVIVES. It is
 * (a) the window between the modal's insert and `BovAutoSelectionService` promoting the row, and
 * (b) the permanent state when the disposition is LOCKED — an approval already sent means the
 * service returns without writing, so a preferred broker added afterwards stays Backup and the
 * scored winner keeps the slot.
 */
const WITH_PREFERRED = [...SUBMISSIONS, PREFERRED_ROW];

/**
 * 🔴 THE FRACTIONAL-SCORE REGRESSION TEST (added 2026-08-22,
 * manifest/bov-score-formula-conversion/, Step 3). `BOV_Score__c` is a Number(5,2) FORMULA field
 * and `BovController.BovRow.bovScore` was widened `Integer` -> `Decimal` in the same change
 * specifically because an `Integer`-typed DTO field would silently TRUNCATE a value like 82.95
 * down to 82 before it ever reached this component — a real display defect, not a rounding
 * nicety. 68.81 is the hand-verified BOV-0015 value from the approved formula (see
 * manifest/bov-score-formula-conversion/step3-package.xml), not an arbitrary fixture.
 */
const FRACTIONAL_SCORE_SUBMISSION = [
    {
        id: 'a0X010000000015',
        name: 'BOV-0015',
        isSelected: false,
        bovScore: 68.81,
        brokerFirm: 'CBRE',
        contactName: 'Pat Rivera',
        bovAmount: 1500000,
        daysToMarket: 20,
        capRate: 6.5
    }
];

describe('c-bov-comparison-matrix', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-bov-comparison-matrix', {
            is: BovComparisonMatrix
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const addBtn = (el) => el.shadowRoot.querySelector('.matrix-add');
    const replaceBtn = (el) => el.shadowRoot.querySelector('.matrix-replace');
    const preferredBtn = (el) =>
        el.shadowRoot.querySelector('.matrix-add-preferred');
    /**
     * 🔴 KEPT AFTER THE BUTTON WAS DELETED, ON PURPOSE. `.matrix-select` no longer exists in the
     * template, so this always returns null — which is exactly why it is still here: an absence
     * pin needs a way to name the thing that must stay absent. It is never dereferenced.
     */
    const selectBtn = (el) => el.shadowRoot.querySelector('.matrix-select');

    /**
     * Every rendered button's LABEL, in template order.
     *
     * 🔴 THE `label` PROPERTY, NOT `textContent`. sfdx-lwc-jest's `lightning-button` stub renders
     * an EMPTY template — it has no text node at all — so `shadowRoot.textContent` contains none
     * of these strings and any assertion against it passes whether the button is there or not.
     * This helper reads what the component actually set on the element.
     */
    const buttonLabels = (el) =>
        [...el.shadowRoot.querySelectorAll('lightning-button')].map(
            (b) => b.label
        );

    /** The datatable's rendered `columns` PROPERTY — not the component's getter. */
    const columnLabels = (el) => {
        const table = el.shadowRoot.querySelector('c-list-datatable');
        return table ? table.columns.map((c) => c.label) : null;
    };

    const preferredInstance = (props = {}) =>
        createComponent({
            recordId: RECORD_ID,
            preferredOnly: true,

            ...props
        });

    it('renders a zero count and an empty datatable before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const title = element.shadowRoot.querySelector('span[slot="title"]');
        expect(title.textContent).toBe('BOV Comparison Matrix (0)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toEqual([]);
    });

    it('DATA BRANCH: maps submissions into datatable rows and the count', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        const title = element.shadowRoot.querySelector('span[slot="title"]');
        expect(title.textContent).toBe('BOV Comparison Matrix (2)');

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(2);

        const first = table.data[0];
        expect(first.brokerFirm).toBe('Colliers International');
        expect(first.bovAmountLabel).toBe('$12.5M');
        expect(first.daysLabel).toBe('45d');
        expect(first.capRateLabel).toBe('6.25%');
        expect(first.scoreText).toBe('88');
        expect(first.status).toBe('Selected');

        expect(table.data[1].status).toBe('Backup');
    });

    it('🔴 DATA BRANCH: a FRACTIONAL bovScore is NOT truncated (regression, Step 3)', async () => {
        const element = createComponent();

        getSubmissions.emit(FRACTIONAL_SCORE_SUBMISSION);
        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        // 🔴 THE ASSERTION THAT MATTERS: '68.81', NOT '68'. `String(68.81)` preserves both decimal
        // places; `String(Math.trunc(68.81))` or an upstream `.intValue()` would have collapsed
        // this to '68' with no error anywhere in the chain — exactly the defect an Integer-typed
        // BovRow.bovScore produced before this wave widened it to Decimal.
        expect(table.data[0].scoreText).toBe('68.81');
    });

    it('ERROR BRANCH: shows an error banner and keeps the count at zero', async () => {
        const element = createComponent();

        getSubmissions.error();
        await Promise.resolve();

        const title = element.shadowRoot.querySelector('span[slot="title"]');
        expect(title.textContent).toBe('BOV Comparison Matrix (0)');
        expect(
            element.shadowRoot.querySelector('c-list-datatable').data
        ).toEqual([]);

        const banner = element.shadowRoot.querySelector('.matrix-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toBe("Couldn't load BOV submissions.");
    });

    it('populates the "View All" footer link via NavigationMixin.GenerateUrl', async () => {
        const element = createComponent();

        // connectedCallback resolves GenerateUrl -> listUrl; flush both the
        // promise resolution and the re-render microtasks.
        await Promise.resolve();
        await Promise.resolve();

        const link = element.shadowRoot.querySelector('.view-all-footer a');
        expect(link.getAttribute('href')).toBe(
            '/lightning/o/BOV_Submission__c/list'
        );
    });

    it('navigates to the BOV Submission list when "View All" is clicked', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        await Promise.resolve();

        element.shadowRoot.querySelector('.view-all-footer a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('BOV_Submission__c');
        expect(pageRef.attributes.actionName).toBe('list');
    });

    it('🔴 the preferred row is EXCLUDED from the matrix instance — rows and count', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        // Three rows came off the wire; the matrix shows the two responses.
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.map((r) => r.id)).toEqual([
            'a0X010000000001',
            'a0X010000000002'
        ]);
        // The COUNT follows the rows. A title reading "(3)" over a two-row table
        // is the defect a `_data.length` count would have produced.
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('BOV Comparison Matrix (2)');

        // 🔴 THE THIRD ASSERTION THAT USED TO BE HERE MOVED, IT WAS NOT DROPPED.
        // This test also clicked Replace Broker and proved the preferred row was
        // excluded from the picker's `backupOptions`. That button — and the
        // `_backupOptions` getter behind it — now live on `c/bovBrokerPanel`,
        // and the assertion moved to that bundle's suite verbatim. Leaving a
        // dead copy here would have needed a modal mock in a bundle that no
        // longer imports one.
    });

    it('🔴 refreshData() re-provisions THIS instance — and needs the UN-destructured wire result', async () => {
        // 🔴 THE ONLY FALSIFIER FOR THE `_wired` INVARIANT. `refreshApex` cannot
        // re-provision from a `{ data, error }` pair, so a "tidying" edit to
        // `wiredSubmissions({ data, error })` compiles, leaves every render test
        // in this file green, and silently turns the panel's post-save refresh
        // into a no-op — the card keeps showing pre-save rows until a reload,
        // which is the exact bug the in-place-modal rework exists to prevent.
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        element.refreshData();

        expect(refreshApex).toHaveBeenCalledTimes(1);
        // ⚠ ASSERTED ON THE ARGUMENT, NOT JUST THE CALL COUNT. A destructured
        // wire would still call refreshApex — with `undefined`.
        const passed = refreshApex.mock.calls[0][0];
        expect(passed).toBeDefined();
        expect(passed.data).toEqual(SUBMISSIONS);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // THE PREFERRED-BROKER CARD — the second instance of this same bundle
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 PREFERRED CARD: renders NOTHING when no broker is flagged preferred', async () => {
        const element = preferredInstance();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // 🔴 THE WHOLE CARD IS ABSENT — not an empty card, not a header with a
        // "(0)". The user asked for it to be hidden entirely.
        expect(element.shadowRoot.querySelector('lightning-card')).toBeNull();
        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
        expect(
            element.shadowRoot.querySelector('span[slot="title"]')
        ).toBeNull();

        // ⚠ GUARD THE GUARD: the matrix instance on the SAME payload does render,
        // so the absence above is the `preferredOnly` gate and not a component
        // that failed to mount at all.
        const control = createComponent();
        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();
        expect(control.shadowRoot.querySelector('lightning-card')).not.toBeNull();
    });

    it('🔴 PREFERRED CARD: appears once a broker is flagged, titled "Preferred Broker" (singular)', async () => {
        const element = preferredInstance();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();
        // SINGULAR, AND NO COUNT. Exactly one preferred broker exists per
        // disposition, so "(1)" would be the only number it could ever show.
        const title = element.shadowRoot.querySelector('span[slot="title"]');
        expect(title.textContent).toBe('Preferred Broker');
        expect(title.textContent).not.toContain('(');

        // ONLY the preferred row — the two ordinary responses stay in the matrix.
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.map((r) => r.id)).toEqual([PREFERRED_ROW.id]);
        expect(table.data[0].brokerFirm).toBe('Cushman & Wakefield');
        expect(table.data[0].contactName).toBe('Ada Lin');
    });

    /**
     * ══════════════════════════════════════════════════════════════════════════
     * 🔴 WIDENED FROM ONE MODE TO BOTH ON 2026-08-24 — OR IT WOULD BE VACUOUS.
     * ══════════════════════════════════════════════════════════════════════════
     * This test was `PREFERRED CARD: NO BUTTONS AT ALL`, and it proved something
     * real while the MATRIX instance carried three buttons and only the preferred
     * instance suppressed them with `hide-actions`. All three buttons have now
     * moved to `c/bovBrokerPanel`, so a preferred-instance-only assertion passes
     * whatever this template does — it is exactly the "deleting an element
     * vacuates the absence pin" trap: green, and blind.
     *
     * Run over BOTH modes it is falsifiable again, and it is now the pin for the
     * whole button move: re-add any `lightning-button` to this template, in
     * either mode, and this reds.
     */
    it.each([
        ['MATRIX instance', () => createComponent()],
        ['PREFERRED instance', () => preferredInstance()]
    ])(
        '🔴 NO BUTTONS AND NO ACTION REGION — %s (the buttons live on c-bov-broker-panel)',
        async (_label, make) => {
            const element = make();

            getSubmissions.emit(WITH_PREFERRED);
            await Promise.resolve();

            // Guard the guard first: the card really is on screen, so the
            // emptiness below is an absence of buttons and not of card.
            expect(
                element.shadowRoot.querySelector('lightning-card')
            ).not.toBeNull();

            // 🔴 ZERO. Not "no Replace Broker" — zero buttons of any kind, and
            // none of the four historical class hooks.
            expect(buttonLabels(element)).toEqual([]);
            expect(addBtn(element)).toBeNull();
            expect(replaceBtn(element)).toBeNull();
            expect(preferredBtn(element)).toBeNull();
            expect(selectBtn(element)).toBeNull();

            // ⚠ THE SLOT ITSELF IS GONE, NOT JUST ITS CONTENTS. An empty
            // `<div slot="actions">` still occupies lightning-card's header
            // action region and still renders an empty button-group inside it.
            expect(
                element.shadowRoot.querySelector('[slot="actions"]')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('lightning-button-group')
            ).toBeNull();
        }
    );

    it('🔴 the bundle no longer HAS a hideActions input — the flag went with the buttons', () => {
        // ⚠ THE PUBLIC API IS READ OFF THE ELEMENT'S PROTOTYPE, and the element
        // is built WITHOUT `Object.assign`. MEASURED, because the obvious form
        // is wrong: `Object.assign(element, { hideActions: true })` defines a
        // plain OWN property whatever the component declares, so
        // `expect(element.hideActions).toBeUndefined()` reads back `true` and
        // reds on a component that has no such `@api` at all.
        //
        // The point is not that the flag was unnecessary: it is that a flag
        // which suppresses a region that no longer exists is a false
        // reassurance. If `@api hideActions` is reinstated, this reds.
        const element = createElement('c-bov-comparison-matrix', {
            is: BovComparisonMatrix
        });
        const proto = Object.getPrototypeOf(element);

        expect('hideActions' in proto).toBe(false);
        // Guard the guard: two `@api` members that DO survive, read the same
        // way. Without these the assertion above passes on a typo in the
        // property name, or on a component that failed to define any API.
        expect('preferredOnly' in proto).toBe(true);
        expect('refreshData' in proto).toBe(true);
    });

    it('🔴 PREFERRED CARD: NO STATUS COLUMN — and the matrix still has one', async () => {
        const element = preferredInstance();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        // ⚠ READ OFF THE RENDERED `c-list-datatable`'s `columns` PROPERTY, not
        // off the component's getter. The getter could be right while the
        // template still bound the module constant.
        expect(columnLabels(element)).toEqual([
            'Broker Firm',
            'Contact',
            'Valuation',
            'Days to Mkt',
            'Cap Rate',
            'Score'
        ]);
        expect(columnLabels(element)).not.toContain('Status');

        // 🔴 THE OTHER HALF, WITHOUT WHICH THIS PROVES NOTHING: the matrix
        // instance on the same payload KEEPS its Status column. An assertion
        // that only checked the preferred card would stay green if Status were
        // deleted from COLUMNS outright.
        const control = createComponent();
        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();
        expect(columnLabels(control)).toContain('Status');
        expect(columnLabels(control)).toHaveLength(7);
    });

    it('PREFERRED CARD is accessible', async () => {
        const element = preferredInstance();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
