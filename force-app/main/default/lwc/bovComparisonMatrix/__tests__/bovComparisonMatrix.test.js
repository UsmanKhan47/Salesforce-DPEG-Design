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
 * THREE HEADER ACTIONS, TWO OF WHICH ARE MUTUALLY EXCLUSIVE (DEV-15; Select
 * Broker added 2026-08-21)
 * ─────────────────────────────────────────────────────────────────────────────
 * "Add Broker Response" opens c/bovAddResponseModal and is always available.
 * "Select Broker" and "Replace Broker" BOTH open c/bovReplaceBrokerModal — one
 * bundle, one Apex method — and exactly one of the two ever renders. NONE OF
 * THE THREE NAVIGATES.
 *
 * 🔴 THE MUTUAL EXCLUSION IS ASSERTED IN BOTH DIRECTIONS, AS ABSENCE. A suite
 * that only checked "Replace renders when something is Selected" and "Select
 * renders when nothing is" would stay green if BOTH rendered at once — which
 * would put two routes to the same server method on screen, one of which sends
 * `Initial Appointment` on a replacement and is refused by the server.
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
 * 🔴 THE REAL SHAPE OF THIS ORG'S DATA, NOT A CONVENIENT ONE. Six broker Contacts exist TWICE
 * with an identical name AND an identical firm, and seven Contacts on the Broker record type are
 * not brokers at all. Neither is filtered or de-duplicated — that is the user's decision — so the
 * PICKER has to be legible anyway. These two rows are the duplicate case: same firm, same contact,
 * different submission. Scores are null because every score in the org is null until
 * `BOV_Score__c` becomes a formula AND the disposition gets an asking price.
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
    const selectBtn = (el) => el.shadowRoot.querySelector('.matrix-select');

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

    it('REPLACE BROKER is HIDDEN until a submission is Selected — SELECT BROKER takes its place', async () => {
        const element = createComponent();

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        // Nothing to replace yet — but the add button is always available.
        expect(replaceBtn(element)).toBeNull();
        expect(selectBtn(element)).not.toBeNull();
        expect(addBtn(element)).not.toBeNull();
    });

    it('REPLACE BROKER appears once a submission is Selected — and SELECT BROKER disappears', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await Promise.resolve();

        expect(replaceBtn(element)).not.toBeNull();
        // 🔴 EXACTLY ONE OF THE TWO, ALWAYS. Two live broker buttons would be two
        // routes to the same server method offering different reason semantics —
        // and the "Select" one would send `Initial Appointment` on a replacement,
        // which the server refuses. Asserted as ABSENCE, deliberately: a test that
        // only checked "Replace renders" stays green if Select renders beside it.
        expect(selectBtn(element)).toBeNull();
    });

    it('🔴 NEITHER broker button renders on an EMPTY matrix — there is nothing to appoint', async () => {
        const element = createComponent();

        getSubmissions.emit([]);
        await Promise.resolve();

        // `_selected` is undefined here too, so a bare negation of `canReplaceBroker`
        // would render "Select Broker" over a modal whose only content is its own
        // empty state. The `count > 0` term is what stops that.
        expect(selectBtn(element)).toBeNull();
        expect(replaceBtn(element)).toBeNull();
        expect(addBtn(element)).not.toBeNull();
    });

    it('🔴 NEITHER broker button renders on the wire ERROR branch', async () => {
        const element = createComponent();

        getSubmissions.error();
        await Promise.resolve();

        // The error branch sets `_data = []`. Offering to appoint a broker from a
        // list that failed to load is offering to choose blind.
        expect(selectBtn(element)).toBeNull();
        expect(replaceBtn(element)).toBeNull();
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
    // SELECT BROKER — the first appointment (2026-08-21)
    // ─────────────────────────────────────────────────────────────────────────

    it('SELECT: opens the SAME modal bundle in first-appointment mode with EVERY submission', async () => {
        const element = createComponent();

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        // 🔴 THE SAME BUNDLE, NOT A SECOND ONE. One modal, one Apex method, one set
        // of invariants. If this ever becomes `BovSelectBrokerModal.open`, the
        // exclusivity swap / approval revocation / savepoint / history row exist
        // twice and can disagree.
        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        const args = BovReplaceBrokerModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe(RECORD_ID);
        expect(args.isFirstAppointment).toBe(true);
        // No incumbent exists, so none is named. `undefined`, not a placeholder
        // string the modal would then have to recognise.
        expect(args.currentBroker).toBeUndefined();
        expect(args.label).toBe('Select Broker');
        expect(typeof args.description).toBe('string');
        expect(args.description.length).toBeGreaterThan(0);
        // Nothing is Selected, so the `isSelected !== true` filter excludes nothing
        // and EVERY response is appointable.
        expect(args.backupOptions.map((o) => o.value)).toEqual([
            'a0X010000000001',
            'a0X010000000002'
        ]);
    });

    it('🔴 SELECT: a null score renders an EM DASH, never 0', async () => {
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        const labels = BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions.map(
            (o) => o.label
        );
        // Every score in the org is null today. `0` is a real and terrible score;
        // printing it for "not computed" would tell the user something false about
        // every broker on the list.
        expect(labels[0]).toContain('Score —');
        expect(labels[0]).not.toContain('Score 0');
    });

    it('🔴 SELECT: two brokers with an IDENTICAL name and firm are still distinguishable', async () => {
        const element = createComponent();

        getSubmissions.emit(DUPLICATE_BROKERS);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        const labels = BovReplaceBrokerModal.open.mock.calls[0][0].backupOptions.map(
            (o) => o.label
        );
        // The falsifier for "firm alone is enough". These two rows share the firm,
        // the contact, the amount and the cap rate — this org really does hold six
        // such Contact pairs. The submission's own auto-number is what separates
        // them, and without it the user picks at random between two identical lines.
        expect(labels[0]).not.toBe(labels[1]);
        expect(labels[0]).toContain('BOV-0011');
        expect(labels[1]).toContain('BOV-0012');
    });

    it('🔴 SELECT SUCCESS: toasts the SERVER message STICKY, then refreshes THIS wire', async () => {
        const serverMessage =
            'Broker appointed. The broker must be approved before the sale can proceed.';
        BovReplaceBrokerModal.open.mockResolvedValue({ message: serverMessage });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const toast = toastHandler.mock.calls[0][0].detail;
        expect(toast.title).toBe('Broker appointed');
        // Verbatim. The appoint-vs-replace wording is the SERVER's choice, made from
        // what it actually did inside the transaction — not from the stale wire that
        // decided which button to render.
        expect(toast.message).toBe(serverMessage);
        expect(toast.variant).toBe('success');
        // 🔴 STICKY DESPITE THE `success` VARIANT. `_toast`'s variant-derived default
        // would make this dismissable, and the sentence it carries ("must be approved
        // before the sale can proceed") is a consequence the user has to act on. This
        // assertion is the reason `_toast` gained an explicit `mode` argument.
        expect(toast.mode).toBe('sticky');

        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(refreshApex.mock.calls[0][0]).toHaveProperty('data');
    });

    it('SELECT CANCELLED: no toast and no refresh', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('SELECT: a modal that fails to OPEN toasts its OWN message and does not refresh', async () => {
        BovReplaceBrokerModal.open.mockRejectedValue(
            new Error('modal layer unavailable')
        );

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        // Distinct from the replace path's title — the two entry points share one
        // implementation, so a title collision here would mean the config object
        // is not actually reaching the shared method.
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Could not open the select dialog'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('SELECT: never navigates', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSubmissions.emit(NONE_SELECTED);
        await Promise.resolve();

        selectBtn(element).click();
        await flushPromises();

        expect(navHandler).not.toHaveBeenCalled();
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
