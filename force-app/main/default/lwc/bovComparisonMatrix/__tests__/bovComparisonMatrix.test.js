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
 * THREE HEADER ACTIONS (2026-08-24): Add Broker Response, Replace Broker,
 * Add Preferred Broker — in that template order.
 * ─────────────────────────────────────────────────────────────────────────────
 * "Add Broker Response" and "Add Preferred Broker" open the SAME
 * c/bovAddResponseModal bundle, differing only in `isPreferred`. "Replace
 * Broker" opens c/bovReplaceBrokerModal and is the only surviving client route
 * into BovSubmissionService.replaceSelectedBroker. NONE OF THE THREE NAVIGATES.
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
 * `preferredOnly` + `hideActions` turn this same component into the "Preferred
 * Broker" card that `dispositionMain` mounts above the matrix. Both default
 * false, so every existing test above exercises the matrix instance unchanged;
 * the preferred instance is created explicitly, with its props passed to
 * `createComponent`.
 * ⚠ `createComponent()` WITH NO ARGUMENT USES ITS DEFAULT PARAMETER — passing
 * `undefined` does NOT clear it. Preferred-instance tests must pass the full
 * props object including `recordId`.
 *
 * 🔴 "ADD BROKER RESPONSE" USED TO NAVIGATE, AND THAT WAS THE UAT BUG
 * (2026-08-21). It called NavigationMixin.Navigate with `actionName: 'new'` on
 * BOV_Submission__c, and the platform's post-save behaviour for a record created
 * that way is to navigate TO the new record — so saving a response threw the
 * user off the Disposition page. `ADD RESPONSE: never navigates` below is the
 * anti-regression pin, and it is deliberately an assertion about ABSENCE:
 * asserting only that the modal opened would stay green if a Navigate call were
 * added back beside it.
 *
 * 🔴 THE WIRE IS NOW HELD AS A WHOLE RESULT so `refreshApex` can re-provision it
 * after a replace. A "tidying" edit back to `wired({ data, error })` compiles,
 * passes every render test above, and silently turns the post-replace refresh
 * into a no-op — leaving the matrix showing the OLD Selected broker until a page
 * reload. `refreshApex` is NOT auto-mocked by the sfdx-lwc-jest stub — `@salesforce/apex`
 * resolves to a real module whose `refreshApex` is a plain function, so this file carries
 * its own `jest.mock('@salesforce/apex', ...)` below to make it a spy — and the test
 * below asserts it is called with the SAME object the wire handed the component,
 * which is the only assertion that actually catches that regression.
 *
 * 🔴 `LightningModal.open()` IS A STATIC ON A CLASS and cannot be driven like a
 * wire adapter, so both modals are mocked wholesale here. Their own behaviour is
 * proved in lwc/bovReplaceBrokerModal/__tests__ and
 * lwc/bovAddResponseModal/__tests__.
 */
import { createElement } from 'lwc';
import BovComparisonMatrix from 'c/bovComparisonMatrix';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';
import { refreshApex } from '@salesforce/apex';
import BovAddResponseModal from 'c/bovAddResponseModal';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';

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

jest.mock('c/bovReplaceBrokerModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

jest.mock('c/bovAddResponseModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

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

/** Every submission still Backup — the pre-selection state. */
const NONE_SELECTED = SUBMISSIONS.map((s) => ({ ...s, isSelected: false }));

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
 * 🔴 THE STEADY STATE AFTER THE 2026-08-24 DECISION: the preferred broker HOLDS the single
 * `Selected` slot and every scored response has been demoted to `Backup` by
 * `BovAutoSelectionService`.
 *
 * This fixture is what makes the `_selected` widening falsifiable. Read against `_visible`
 * (non-preferred rows only) NOTHING here is Selected, so `canReplaceBroker` goes false and the
 * Replace Broker button disappears from the only card that has buttons — leaving no route in the
 * entire UI to replace an appointed broker, with no error anywhere.
 */
const PREFERRED_APPOINTED = [
    ...SUBMISSIONS.map((sub) => ({ ...sub, isSelected: false })),
    { ...PREFERRED_ROW, isSelected: true }
];

/**
 * The duplicate-broker pair WITH an incumbent, so the Replace path can reach them.
 *
 * 🔴 WHY THIS FIXTURE EXISTS AT ALL. The em-dash and duplicate-name assertions below were
 * originally driven through "Select Broker", which offered EVERY row because nothing was
 * Selected. That button is gone, and `_backupOptions` is now only reachable through Replace —
 * which only renders once something IS Selected. Re-homing those two tests therefore needed a
 * fixture with an incumbent; deleting them instead would have quietly dropped `brokerOptionLabel`'s
 * two hardest cases, which are properties of THIS ORG'S DATA and did not go anywhere.
 */
const DUPLICATE_BROKERS_WITH_INCUMBENT = () => [
    { ...SUBMISSIONS[0] },
    ...DUPLICATE_BROKERS
];

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

/**
 * 🔴 THE REAL SHAPE OF THIS ORG'S DATA, NOT A CONVENIENT ONE. Six broker Contacts exist TWICE
 * with an identical name AND an identical firm, and seven Contacts on the Broker record type are
 * not brokers at all. Neither is filtered or de-duplicated — that is the user's decision — so the
 * PICKER has to be legible anyway. These two rows are the duplicate case: same firm, same contact,
 * different submission. Scores are null because these fixtures' Disposition carries no
 * Asking_Price__c — 🔴 RETRACTED 2026-08-22 (manifest/bov-score-formula-conversion/, Step 3):
 * `BOV_Score__c` IS a formula now, so "until it becomes one" is stale; a null score is a property
 * of the missing asking price, not of the field's type.
 */
const DUPLICATE_BROKERS = [
    {
        id: 'a0X010000000011',
        name: 'BOV-0011',
        isSelected: false,
        bovScore: null,
        brokerFirm: 'Marcus Whitfield Realty',
        contactName: 'Marcus Whitfield',
        bovAmount: 9400000,
        daysToMarket: 70,
        capRate: 6.1
    },
    {
        id: 'a0X010000000012',
        name: 'BOV-0012',
        isSelected: false,
        bovScore: null,
        brokerFirm: 'Marcus Whitfield Realty',
        contactName: 'Marcus Whitfield',
        bovAmount: 9400000,
        daysToMarket: 70,
        capRate: 6.1
    }
];

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-bov-comparison-matrix', () => {
    beforeEach(() => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);
        BovAddResponseModal.open.mockResolvedValue(undefined);
    });

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
            hideActions: true,
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

    // ─────────────────────────────────────────────────────────────────────────
    // Header actions
    // ─────────────────────────────────────────────────────────────────────────

    it('ADD RESPONSE: opens the in-place dialog for THIS disposition', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
        const args = BovAddResponseModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe(RECORD_ID);
        // A label and a description are what LightningModal exposes to assistive
        // tech; a dialog with neither announces as an unnamed region.
        expect(args.label).toBe('Add Broker Response');
        expect(typeof args.description).toBe('string');
        expect(args.description.length).toBeGreaterThan(0);
    });

    it('🔴 ADD RESPONSE: never navigates — this is the UAT redirect regression pin', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        // 🔴 THE ASSERTION IS ABOUT ABSENCE, DELIBERATELY. The previous
        // implementation navigated to `standard__objectPage` / `actionName:
        // 'new'`, and the platform's post-save behaviour for a record created
        // that way is to navigate TO the new record — so the user was thrown off
        // the Disposition page. A test that only asserted "the modal opened"
        // would stay green if a Navigate call were reinstated beside it.
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('🔴 ADD RESPONSE SUCCESS: toasts, then refreshes THIS wire in place', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000009AAA',
            name: 'BOV-0021'
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        const navHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.variant).toBe('success');
        expect(toast.message).toContain('BOV-0021');
        // Nothing to act on later, so this one may auto-dismiss — unlike the
        // replace flow's "a fresh approval is required" warning.
        expect(toast.mode).toBe('dismissable');

        // 🔴 The record was created by a form this cacheable wire knows nothing
        // about, so LDS has no idea the list changed. Asserted with the WIRE
        // RESULT OBJECT, which is what pins the un-destructured
        // `wiredSubmissions(result)` shape — the only thing refreshApex can
        // re-provision.
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(refreshApex.mock.calls[0][0]).toHaveProperty('data');

        // Still on the disposition page. This is the whole point of the change.
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('ADD RESPONSE CANCELLED: no toast and no refresh', async () => {
        BovAddResponseModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ADD RESPONSE: a modal that fails to OPEN toasts and does not refresh', async () => {
        BovAddResponseModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the response dialog'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE FOUR BUTTON-VISIBILITY TESTS, REWRITTEN 2026-08-24.
    //
    // THREE OF THE FOUR (`…and SELECT BROKER disappears`, `NEITHER broker button
    // renders on an EMPTY matrix`, `…on the wire ERROR branch`) ASSERTED ONLY
    // `expect(selectBtn(element)).toBeNull()`. When the Select Broker button was
    // deleted they did not fail — they went GREEN AND VACUOUS, and would have
    // passed identically if this entire component had been deleted. Each is
    // rewritten below to assert POSITIVELY what is on screen, by rendered label,
    // in template order; the Select absence survives as ONE NAMED PIN rather
    // than as three accidents.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 THE THREE BUTTONS, IN ORDER — and Select Broker is gone by name', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        // POSITIVE, AND ORDERED. `toEqual` on the array pins the ORDER the user
        // asked for (Add Broker Response, Replace Broker, Add Preferred Broker)
        // and pins the COUNT — a fourth button appearing fails here.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker',
            'Add Preferred Broker'
        ]);

        // 🔴 THE ABSENCE PIN, ASSERTED TWO WAYS BECAUSE ONE IS NOT ENOUGH.
        // By class, which catches the button coming back as it was; and by
        // rendered LABEL, which catches it coming back under a new class name —
        // the far likelier shape of a reinstatement.
        expect(selectBtn(element)).toBeNull();
        expect(buttonLabels(element)).not.toContain('Select Broker');
    });

    it('REPLACE BROKER is HIDDEN until a submission is Selected — and NOTHING takes its place', async () => {
        const element = createComponent();

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        // 🔴 THIS IS THE BEHAVIOUR CHANGE, AND IT IS THE POINT OF THE WHOLE
        // TRANCHE. Until 2026-08-24 "Select Broker" rendered here, because a
        // disposition with no appointed broker needed a human to appoint one.
        // Selection is automatic now, so the pre-appointment state offers NO
        // broker button at all — the server is what fills that gap.
        expect(replaceBtn(element)).toBeNull();
        expect(selectBtn(element)).toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
    });

    it('🔴 EMPTY MATRIX: no broker button, but BOTH add buttons — an empty sale is exactly when you add one', async () => {
        const element = createComponent();

        getSubmissions.emit([]);
        await Promise.resolve();

        expect(replaceBtn(element)).toBeNull();
        expect(selectBtn(element)).toBeNull();
        // ⚠ "Add Preferred Broker" IS OFFERED ON AN EMPTY MATRIX AND THAT IS
        // DELIBERATE — the difference from the deleted Select Broker button,
        // whose `count > 0` term existed because appointing from an empty list
        // is meaningless. Recording a preferred broker before any response has
        // arrived is not meaningless; it is the normal case.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
    });

    it('🔴 WIRE ERROR BRANCH: no broker button, and the error banner is what the user sees', async () => {
        const element = createComponent();

        getSubmissions.error();
        await Promise.resolve();

        // The error branch sets `_data = []`. Offering to replace a broker from a
        // list that failed to load is offering to choose blind.
        expect(replaceBtn(element)).toBeNull();
        expect(selectBtn(element)).toBeNull();
        // ⚠ GUARD THE GUARD: the card genuinely rendered, so the two absences
        // above are real absences rather than an unrendered component. This is
        // the assertion the three vacuous tests lacked.
        expect(element.shadowRoot.querySelector('.matrix-error')).not.toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Add Preferred Broker'
        ]);
    });

    it('REPLACE: opens the modal with ONLY the backups and names the incumbent', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        const args = BovReplaceBrokerModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe(RECORD_ID);
        expect(args.currentBroker).toBe('Colliers International');
        expect(args.isFirstAppointment).toBe(false);
        // The Selected row is excluded — promoting the incumbent to itself is not
        // an operation. Options are composed here, from the SAME payload that
        // draws the rows, so the modal cannot show a different valuation.
        expect(args.backupOptions).toEqual([
            {
                label: 'JLL — John Roe · $11.0M · Score 71 · BOV-0002',
                value: 'a0X010000000002'
            }
        ]);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE EIGHT SELECT-BROKER TESTS, ACCOUNTED FOR ONE BY ONE (2026-08-24).
    //
    // All eight clicked `.matrix-select` and broke loudly on `null.click()`.
    // What happened to each, so nothing is "lost" silently:
    //
    //  1. `SELECT: opens the SAME modal bundle in first-appointment mode with
    //     EVERY submission`               DELETED. It asserted the behaviour of
    //     a button that no longer exists. `isFirstAppointment: true` is still
    //     supported by c/bovReplaceBrokerModal and by the Apex behind it — this
    //     component simply has no route to it any more, so there is nothing here
    //     to test. It is NOT dead server code: c/brokerListing still opens that
    //     modal from the Active Listing stage.
    //  2. `a null score renders an EM DASH`     RE-HOMED onto Replace, below.
    //  3. `two brokers with an IDENTICAL name`  RE-HOMED onto Replace, below.
    //  4. `SELECT SUCCESS … STICKY`             DELETED — `REPLACE SUCCESS`
    //     below asserts the identical shape (server message verbatim, sticky
    //     mode, refreshApex with the wire result) through the SAME
    //     `_openBrokerModal`, which is now that method's only caller.
    //  5. `SELECT CANCELLED`                    DELETED — `REPLACE CANCELLED`.
    //  6. `SELECT: fails to OPEN`               DELETED — `REPLACE: fails to
    //     OPEN` covers it; the distinct-title assertion it carried existed only
    //     to prove two callers were reaching one method, and there is one now.
    //  7. `SELECT: never navigates`             RE-HOMED onto Replace, below —
    //     "no header action navigates" is still a live rule and was, before this
    //     change, pinned for Add Response and Select but NOT for Replace.
    //  8. `REPLACE BROKER is HIDDEN … SELECT BROKER takes its place` — rewritten
    //     above with the other visibility tests.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 REPLACE: a null score renders an EM DASH, never 0 (re-homed from SELECT)', async () => {
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS_WITH_INCUMBENT());
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const labels = BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions.map(
            (o) => o.label
        );
        // `0` is a real and terrible score; printing it for "not computed" would
        // tell the user something false about the broker on that line. Still true
        // after the formula conversion: a null score means the parent carries no
        // Asking_Price__c, not that the broker scored nothing.
        expect(labels[0]).toContain('Score —');
        expect(labels[0]).not.toContain('Score 0');
    });

    it('🔴 REPLACE: two brokers with an IDENTICAL name and firm are still distinguishable (re-homed from SELECT)', async () => {
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS_WITH_INCUMBENT());
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const labels = BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions.map(
            (o) => o.label
        );
        // The falsifier for "firm alone is enough". These two rows share the firm,
        // the contact, the amount and the cap rate — this org really does hold six
        // such Contact pairs. The submission's own auto-number is what separates
        // them, and without it the user picks at random between two identical lines.
        expect(labels).toHaveLength(2);
        expect(labels[0]).not.toBe(labels[1]);
        expect(labels[0]).toContain('BOV-0011');
        expect(labels[1]).toContain('BOV-0012');
    });

    it('REPLACE: never navigates (re-homed from SELECT)', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        // Every header action opens a LightningModal over this page. The one
        // navigation this component performs is the "View All" FOOTER link.
        expect(navHandler).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // ADD PREFERRED BROKER (2026-08-24)
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 ADD PREFERRED: opens the SAME add-response bundle with isPreferred TRUE', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        // 🔴 THE SAME BUNDLE, NOT A SECOND ONE. Forking c/bovAddResponseModal
        // would fork its field set, both of its submit paths, its
        // validation-rule error surface and its create-only contract.
        expect(BovAddResponseModal.open).toHaveBeenCalledTimes(1);
        expect(BovReplaceBrokerModal.open).not.toHaveBeenCalled();

        const args = BovAddResponseModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe(RECORD_ID);
        // 🔴 THE ONE ARGUMENT THAT MAKES IT A PREFERRED BROKER. Without it the
        // dialog saves an ordinary Backup response into the matrix below and
        // says "saved" — there is no other signal anywhere that it went wrong.
        expect(args.isPreferred).toBe(true);
        // The dialog's announced title. The user asked for this string by name.
        expect(args.label).toBe('Add Preferred Broker');
        expect(typeof args.description).toBe('string');
        expect(args.description.length).toBeGreaterThan(0);
    });

    it('🔴 ADD RESPONSE passes isPreferred FALSE — the default path is not the preferred path', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        addBtn(element).click();
        await flushPromises();

        const args = BovAddResponseModal.open.mock.calls[0][0];
        // ⚠ EXPLICIT `false`, NOT `undefined`. Both produce the response mode in
        // the modal, but asserting the value pins that the two buttons pass
        // DIFFERENT configs through one shared `_openAddModal` — the failure
        // this catches is a copy-paste that hardcodes `true` for both.
        expect(args.isPreferred).toBe(false);
        expect(args.label).toBe('Add Broker Response');
    });

    it('ADD PREFERRED SUCCESS: toasts in PREFERRED wording, then refreshes THIS wire', async () => {
        BovAddResponseModal.open.mockResolvedValue({
            recordId: 'a0X010000000031AAA',
            name: 'BOV-0031'
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        // 🔴 NOT "Broker response logged". The two buttons put the record in
        // DIFFERENT CARDS on this page, and telling a user their "broker
        // response" was logged when it went to the card above is how a support
        // ticket starts.
        expect(toast.title).toBe('Preferred broker added');
        expect(toast.message).toContain('BOV-0031');
        expect(toast.message).toContain('preferred');
        expect(toast.variant).toBe('success');

        // 🔴 THE REFRESH IS WHAT MAKES THE PREFERRED CARD APPEAR AT ALL — that
        // card is gated on there being a preferred broker, and it learns that
        // from this wire. Without this, the user saves and watches nothing
        // happen.
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(refreshApex.mock.calls[0][0]).toHaveProperty('data');
    });

    it('ADD PREFERRED CANCELLED: no toast and no refresh', async () => {
        BovAddResponseModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ADD PREFERRED: a modal that fails to OPEN toasts its OWN title and does not refresh', async () => {
        BovAddResponseModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        // Distinct from the add-response title. The two buttons share one
        // implementation, so a title collision here would mean the config object
        // is not actually reaching `_openAddModal`.
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the preferred broker dialog'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ADD PREFERRED: never navigates', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        preferredBtn(element).click();
        await flushPromises();

        expect(navHandler).not.toHaveBeenCalled();
    });

    it('🔴 ADD PREFERRED BROKER is HIDDEN once one exists — exactly one per disposition', async () => {
        const element = createComponent();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        // 🔴 HIDDEN, NOT DISABLED. There is no server-side uniqueness guard on
        // Is_Preferred_Broker__c — no validation rule, no trigger — so this
        // getter is the ONLY thing enforcing "exactly one". A button that is
        // always offered and never refused would create a second one.
        expect(preferredBtn(element)).toBeNull();
        expect(buttonLabels(element)).not.toContain('Add Preferred Broker');
        // The other two are untouched by the preferred row.
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker'
        ]);
    });

    it('🔴 the preferred row is EXCLUDED from the matrix instance — rows, count and the picker', async () => {
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

        replaceBtn(element).click();
        await flushPromises();

        // 🔴 AND OUT OF THE REPLACE PICKER. ⚠ THE REASON CHANGED 2026-08-24 AND
        // THE ASSERTION DID NOT. It used to be "replaceSelectedBroker knows
        // nothing about Is_Preferred_Broker__c and would appoint this row,
        // putting a broker with NO BOV amount into Broker_Finalize_Approval".
        // Appointing a preferred broker is now the INTENDED outcome, so that is
        // no longer a hazard. The row is excluded here because this fixture is
        // the pre-promotion / locked state — the preferred row is not the
        // incumbent yet, and the picker's job is to offer SCORED alternatives to
        // whoever holds the slot, not to offer the preferred broker as one of
        // them. See the APPOINTED PREFERRED tests below for the steady state,
        // where it is excluded as the incumbent instead.
        const options =
            BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions;
        expect(options.map((o) => o.value)).toEqual(['a0X010000000002']);
        expect(options.map((o) => o.value)).not.toContain(PREFERRED_ROW.id);
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

    it('🔴 PREFERRED CARD: NO BUTTONS AT ALL, and no action region to hold one', async () => {
        const element = preferredInstance();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        // Guard the guard first: the card really is on screen, so the emptiness
        // below is an absence of buttons and not an absence of card.
        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();

        // 🔴 ZERO. Not "no Replace Broker" — zero buttons of any kind.
        expect(buttonLabels(element)).toEqual([]);
        expect(addBtn(element)).toBeNull();
        expect(replaceBtn(element)).toBeNull();
        expect(preferredBtn(element)).toBeNull();
        expect(selectBtn(element)).toBeNull();
        // ⚠ THE SLOT ITSELF IS GONE, NOT JUST ITS CONTENTS. An empty
        // `<div slot="actions">` still occupies lightning-card's header action
        // region and still renders an empty button-group inside it.
        expect(element.shadowRoot.querySelector('div[slot="actions"]')).toBeNull();
        expect(
            element.shadowRoot.querySelector('lightning-button-group')
        ).toBeNull();
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

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE PREFERRED BROKER HOLDS THE SELECTED SLOT (user decision, 2026-08-24)
    //
    // The scored field is all Backup; the appointed broker is the preferred one.
    // These four tests exist because the FIRST implementation of `_selected`
    // narrowed it to `_visible` and NOT ONE EXISTING TEST WENT RED when that was
    // widened back — the suite was blind to this whole state.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 APPOINTED PREFERRED: REPLACE BROKER still renders on the matrix — the only route to swap an appointed broker', async () => {
        const element = createComponent();

        getSubmissions.emit(PREFERRED_APPOINTED);
        await Promise.resolve();

        // 🔴 THE FALSIFIER FOR `_selected` READING `_data` RATHER THAN `_visible`.
        // Every row the MATRIX shows is Backup here, so a `_visible`-scoped
        // `_selected` is undefined and this button silently disappears. The
        // preferred card above has no buttons by requirement, so that would leave
        // no way anywhere in the UI to replace an appointed broker.
        expect(replaceBtn(element)).not.toBeNull();
        expect(buttonLabels(element)).toEqual([
            'Add Broker Response',
            'Replace Broker'
        ]);
        // Add Preferred Broker stays hidden — one preferred broker already exists.
        expect(preferredBtn(element)).toBeNull();
    });

    it('🔴 APPOINTED PREFERRED: the Replace dialog NAMES the preferred broker as the incumbent', async () => {
        const element = createComponent();

        getSubmissions.emit(PREFERRED_APPOINTED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const args = BovReplaceBrokerModal.open.mock.calls[0][0];
        // The incumbent is a row this card does not display. Naming it anyway is
        // the point: the user is being told which broker they are replacing, and
        // "undefined" or a scored broker's name would both be lies.
        expect(args.currentBroker).toBe('Cushman & Wakefield');
        expect(args.isFirstAppointment).toBe(false);
    });

    it('🔴 APPOINTED PREFERRED: the picker offers the scored responses and NOT the incumbent', async () => {
        const element = createComponent();

        getSubmissions.emit(PREFERRED_APPOINTED);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        const options =
            BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions;
        // BOTH scored rows are offered — neither is Selected any more.
        expect(options.map((o) => o.value)).toEqual([
            'a0X010000000001',
            'a0X010000000002'
        ]);
        // ⚠ THE PREFERRED ROW IS EXCLUDED FOR A REASON THAT CHANGED ON
        // 2026-08-24. It is no longer "a preferred row must never be promoted to
        // Selected" — it already IS Selected. It is excluded because it is the
        // INCUMBENT, which is what this picker has always excluded: promoting a
        // broker to itself is not an operation and the server refuses it.
        expect(options.map((o) => o.value)).not.toContain(PREFERRED_ROW.id);
    });

    it('🔴 APPOINTED PREFERRED: the preferred card STILL has no buttons, even holding the slot', async () => {
        const element = preferredInstance();

        getSubmissions.emit(PREFERRED_APPOINTED);
        await Promise.resolve();

        // ⚠ THIS IS THE OTHER HALF OF WIDENING `_selected`. `canReplaceBroker` is
        // now TRUE on this instance (a Selected row is in `_data`), so the only
        // thing keeping the card button-free is `hideActions`. If that ever
        // regressed, a Replace Broker button would appear on the preferred card —
        // and its picker would be built from `_visible`, i.e. preferred rows only.
        expect(element.shadowRoot.querySelector('lightning-card')).not.toBeNull();
        expect(buttonLabels(element)).toEqual([]);
        expect(element.shadowRoot.querySelector('div[slot="actions"]')).toBeNull();
        // And it shows the appointed broker, with no Status column to say so.
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.map((r) => r.id)).toEqual([PREFERRED_ROW.id]);
        expect(columnLabels(element)).not.toContain('Status');
    });

    it('PREFERRED CARD is accessible', async () => {
        const element = preferredInstance();

        getSubmissions.emit(WITH_PREFERRED);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('🔴 REPLACE SUCCESS: toasts the SERVER message sticky, then refreshes THIS wire', async () => {
        const serverMessage =
            'JLL is now the selected broker. A fresh broker approval is required.';
        BovReplaceBrokerModal.open.mockResolvedValue({ message: serverMessage });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        // Verbatim: the "fresh approval is required" warning is the SERVER's sentence.
        expect(toast.message).toBe(serverMessage);
        expect(toast.variant).toBe('warning');
        // Sticky, because it describes a consequence the user must act on.
        expect(toast.mode).toBe('sticky');

        // 🔴 The swap is imperative Apex DML on records this cacheable wire already
        // holds, so LDS has no idea they changed. Asserted with the WIRE RESULT
        // OBJECT, which is what pins the un-destructured `wiredSubmissions(result)`
        // shape — the only thing refreshApex can actually re-provision.
        expect(refreshApex).toHaveBeenCalledTimes(1);
        const passed = refreshApex.mock.calls[0][0];
        expect(passed).toBeDefined();
        expect(passed).toHaveProperty('data');
    });

    it('REPLACE CANCELLED: no toast and no refresh', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('REPLACE: a modal that fails to OPEN toasts a distinct message and does not refresh', async () => {
        BovReplaceBrokerModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        replaceBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the replace dialog'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
