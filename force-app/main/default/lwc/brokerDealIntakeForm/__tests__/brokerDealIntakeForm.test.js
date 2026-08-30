/**
 * c-broker-deal-intake-form — HYBRID suite (@wire metadata + IMPERATIVE submit + Turnstile).
 * Combines two templates:
 *   - brokerFirmCard: @wire(getFormMetadata) via createApexTestWireAdapter.emit
 *   - submitForApproval: imperative submitDeal() via jest.fn + resolve/reject.
 *
 * The public guest form loads its asset-type options from getFormMetadata, then
 * POSTs the captured fields through submitDeal. On success it swaps to a
 * confirmation panel; a business failure ({success:false}) or a thrown Apex error
 * surfaces an inline error message.
 *
 * Note: the sfdx-lwc-jest lightning-input/combobox stubs' reportValidity()
 * returns undefined (falsy), so the submit tests shadow it with a truthy stub to
 * clear the component's client-side validate() gate.
 *
 * ═══ EXTENDED 2026-08-30 (WS4): CLOUDFLARE TURNSTILE ═══
 * Two things about this suite are worth understanding before adding to it:
 *
 * 1. window.turnstile IS STUBBED, NOT LOADED. Cloudflare's api.js is a real third-party script
 *    fetched from their CDN at runtime; jsdom neither fetches nor executes it. `mockTurnstile()`
 *    installs a stand-in whose `render()` captures the options object, which is how a test
 *    "solves" the widget: by invoking the captured `callback(token)` exactly as the real widget
 *    would. Everything these tests prove about Turnstile is therefore about OUR wiring — the token
 *    reaching the payload, the reset-after-failure, the disabled gate — and nothing at all about
 *    Cloudflare's script or the CSP that has to allow it.
 *
 * 2. 🔴 THESE TESTS CANNOT SEE THE FEATURE'S TWO MOST LIKELY FAILURES. A missing CspTrustedSite
 *    record, or the un-relaxed LWR site security level in Experience Builder (GATE C — the
 *    networks/ and sites/ trees are force-ignored, so neither is deployable or verifiable from
 *    source), both leave this suite green and the live guest page broken. The acceptance test for
 *    those is a browser check on the real public form; see the WS4 runbook. Do not read a green
 *    Jest run as "Turnstile works".
 */
import { createElement } from 'lwc';
import BrokerDealIntakeForm from 'c/brokerDealIntakeForm';
import { loadScript } from 'lightning/platformResourceLoader';
import getFormMetadata from '@salesforce/apex/BrokerPortalController.getFormMetadata';
import submitDeal from '@salesforce/apex/BrokerPortalController.submitDeal';

jest.mock(
    'lightning/platformResourceLoader',
    () => ({ loadScript: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerPortalController.getFormMetadata',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/BrokerPortalController.submitDeal',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const METADATA = {
    assetTypes: [
        { label: 'Office', value: 'Office' },
        { label: 'Retail', value: 'Retail' },
        { label: 'Industrial', value: 'Industrial' }
    ]
};

const FORM_VALUES = {
    firstName: 'Ava',
    lastName: 'Broker',
    brokerageFirm: 'CBRE',
    email: 'ava@cbre.com',
    propertyAddress: '123 Main St, Sugar Land TX',
    assetType: 'Office'
};

const SITE_KEY = '1x00000000000000000000AA';
const TOKEN = 'cf-turnstile-token-abc123';

// Flush the microtask + macrotask queue so an awaited Apex promise, its .then/
// .catch chain, and the follow-up re-render all settle before asserting.
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-broker-deal-intake-form', () => {
    let renderOptions;

    beforeEach(() => {
        renderOptions = null;
        loadScript.mockImplementation(() => Promise.resolve());
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        delete window.turnstile;
        jest.clearAllMocks();
    });

    /**
     * Stand in for Cloudflare's api.js. `render` captures the options so a test can drive the
     * widget's callbacks, and returns an opaque widget id exactly as the real one does.
     */
    function mockTurnstile() {
        window.turnstile = {
            render: jest.fn((container, options) => {
                renderOptions = options;
                return 'widget-0';
            }),
            reset: jest.fn()
        };
    }

    function createComponent({ siteKey = SITE_KEY } = {}) {
        const element = createElement('c-broker-deal-intake-form', {
            is: BrokerDealIntakeForm
        });
        element.siteKey = siteKey;
        document.body.appendChild(element);
        return element;
    }

    /** Simulate the broker solving the challenge — the widget invokes `callback(token)`. */
    async function solveWidget(token = TOKEN) {
        renderOptions.callback(token);
        await Promise.resolve();
    }

    /** Bring a component up with the script loaded, the widget rendered, and metadata emitted. */
    async function readyComponent(options) {
        mockTurnstile();
        const element = createComponent(options);
        getFormMetadata.emit(METADATA);
        await flushPromises();
        return element;
    }

    // Populate every field the component reads and clear the validity gate.
    function fillForm(element, values = FORM_VALUES) {
        element.shadowRoot
            .querySelectorAll('.validate')
            .forEach((el) => {
                el.reportValidity = () => true;
            });
        Object.entries(values).forEach(([field, val]) => {
            const el = element.shadowRoot.querySelector(
                `[data-field="${field}"]`
            );
            el.value = val;
            el.dispatchEvent(new CustomEvent('change'));
        });
    }

    function clickSubmit(element) {
        element.shadowRoot.querySelector('lightning-button').click();
    }

    it('WIRE BRANCH: populates the asset-type combobox from getFormMetadata', async () => {
        const element = await readyComponent();

        const combobox = element.shadowRoot.querySelector(
            '[data-field="assetType"]'
        );
        expect(combobox.options).toEqual([
            { label: 'Office', value: 'Office' },
            { label: 'Retail', value: 'Retail' },
            { label: 'Industrial', value: 'Industrial' }
        ]);
    });

    it('WIRE ERROR BRANCH: shows a load error when getFormMetadata errors', async () => {
        mockTurnstile();
        const element = createComponent();

        getFormMetadata.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('Could not load the form. Please refresh and try again.');
    });

    it('SUCCESS BRANCH: submits captured fields and shows the confirmation panel', async () => {
        submitDeal.mockResolvedValue({ success: true });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        expect(submitDeal).toHaveBeenCalledTimes(1);
        const passedInput = submitDeal.mock.calls[0][0].input;
        expect(passedInput.firstName).toBe('Ava');
        expect(passedInput.lastName).toBe('Broker');
        expect(passedInput.brokerageFirm).toBe('CBRE');
        expect(passedInput.email).toBe('ava@cbre.com');
        expect(passedInput.propertyAddress).toBe(
            '123 Main St, Sugar Land TX'
        );
        expect(passedInput.assetType).toBe('Office');

        // Confirmation panel replaces the form.
        expect(element.shadowRoot.querySelector('.confirmation')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.form')).toBeNull();
    });

    it('BUSINESS-FAILURE BRANCH: shows the returned message when success is false', async () => {
        submitDeal.mockResolvedValue({
            success: false,
            message: 'A deal with this address was already submitted.'
        });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('A deal with this address was already submitted.');
        // Stays on the form (no confirmation).
        expect(element.shadowRoot.querySelector('.confirmation')).toBeNull();
    });

    it('THROWN-ERROR BRANCH: surfaces the Apex error body message', async () => {
        submitDeal.mockRejectedValue({
            body: { message: 'Portal is temporarily unavailable.' }
        });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('Portal is temporarily unavailable.');
    });

    it('does NOT call Apex when client-side validation fails', async () => {
        const element = await readyComponent();
        await solveWidget();

        // reportValidity stays falsy (stub default) -> validate() returns false.
        clickSubmit(element);
        await flushPromises();

        expect(submitDeal).not.toHaveBeenCalled();
    });

    // ---- Turnstile ----

    it('TURNSTILE: renders the widget with the configured sitekey', async () => {
        const element = await readyComponent();

        expect(window.turnstile.render).toHaveBeenCalledTimes(1);
        const [container, options] = window.turnstile.render.mock.calls[0];
        expect(container).toBe(
            element.shadowRoot.querySelector('[data-id="turnstile"]')
        );
        expect(options.sitekey).toBe(SITE_KEY);
    });

    it('TURNSTILE: keeps the submit button disabled until the widget is solved', async () => {
        const element = await readyComponent();

        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.disabled).toBe(true);

        await solveWidget();
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(false);
    });

    it('TURNSTILE: refuses to call Apex before the widget is solved', async () => {
        const element = await readyComponent();
        fillForm(element);

        clickSubmit(element);
        await flushPromises();

        expect(submitDeal).not.toHaveBeenCalled();
        expect(
            element.shadowRoot.querySelector('.form__error').textContent
        ).toBe('Please complete the human-verification check below.');
    });

    it('TURNSTILE: sends the solved token in the submitDeal payload', async () => {
        submitDeal.mockResolvedValue({ success: true });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        expect(submitDeal.mock.calls[0][0].input.turnstileToken).toBe(TOKEN);
    });

    /**
     * Tokens are SINGLE-USE. Without this reset, a broker whose first submit was refused would
     * resubmit the same spent token and be refused a second time as `timeout-or-duplicate` — a
     * different failure than the one they were shown, and one they could never clear.
     */
    it('TURNSTILE: resets the widget and clears the token after a failed submit', async () => {
        submitDeal.mockRejectedValue({ body: { message: 'Refused.' } });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        expect(window.turnstile.reset).toHaveBeenCalledWith('widget-0');
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
    });

    it('TURNSTILE: clears the token when the challenge expires', async () => {
        const element = await readyComponent();
        await solveWidget();
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(false);

        renderOptions['expired-callback']();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
    });

    it('TURNSTILE: shows an actionable message when the widget errors', async () => {
        const element = await readyComponent();

        renderOptions['error-callback']();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.turnstile .form__error').textContent
        ).toBe('Verification failed to load. Please refresh and try again.');
    });

    /**
     * The most likely real-world failure this suite CAN see: the CSP blocks Cloudflare's script,
     * loadScript rejects, and the broker must be told something rather than shown an empty gap
     * above a permanently disabled button.
     */
    it('TURNSTILE: shows a load failure when the script is blocked (CSP)', async () => {
        loadScript.mockImplementation(() => Promise.reject(new Error('CSP')));
        mockTurnstile();

        const element = createComponent();
        getFormMetadata.emit(METADATA);
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.turnstile .form__error').textContent
        ).toBe(
            'The human-verification check could not load. Please refresh the page, or contact us if this continues.'
        );
        expect(window.turnstile.render).not.toHaveBeenCalled();
    });

    it('TURNSTILE: fails visibly when no sitekey is configured', async () => {
        const element = await readyComponent({ siteKey: '' });

        expect(window.turnstile.render).not.toHaveBeenCalled();
        expect(
            element.shadowRoot.querySelector('.turnstile .form__error').textContent
        ).toBe(
            'The human-verification check is not configured. Please contact us so we can take your submission directly.'
        );
    });

    it('TURNSTILE: renders exactly one widget across many rerenders', async () => {
        const element = await readyComponent();

        // Every keystroke rerenders; an unguarded renderedCallback would mint a widget per change.
        fillForm(element);
        await flushPromises();

        expect(window.turnstile.render).toHaveBeenCalledTimes(1);
    });

    it('RESET: returns to a blank form and a fresh widget after a successful submission', async () => {
        submitDeal.mockResolvedValue({ success: true });

        const element = await readyComponent();
        fillForm(element);
        await solveWidget();
        clickSubmit(element);
        await flushPromises();

        // "Submit another deal" lives in the confirmation panel.
        element.shadowRoot
            .querySelector('.confirmation lightning-button')
            .click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('.form')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.confirmation')).toBeNull();
        // The confirmation panel destroyed the old container, so a NEW widget is rendered rather
        // than the old id being reset against a node that no longer exists.
        expect(window.turnstile.render).toHaveBeenCalledTimes(2);
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
    });

    it('is accessible', async () => {
        const element = await readyComponent();

        await expect(element).toBeAccessible();
    });
});
