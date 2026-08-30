import { LightningElement, api, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import getFormMetadata from '@salesforce/apex/BrokerPortalController.getFormMetadata';
import submitDeal from '@salesforce/apex/BrokerPortalController.submitDeal';
import DPEG_LOGO from '@salesforce/resourceUrl/DPEG_Logo';

/**
 * THIRD-PARTY SCRIPT, LOADED FROM CLOUDFLARE'S CDN BY ABSOLUTE URL. Three options were available
 * and this one was chosen deliberately:
 *
 *  - loadScript(absolute URL)  <- CHOSEN. The dependency stays inside this deployable bundle,
 *    visible to code review and to grep, and scoped to this one component.
 *  - A static resource copy of api.js. REJECTED: Cloudflare does not support self-hosting it.
 *    api.js is a loader that fetches versioned challenge bundles from challenges.cloudflare.com
 *    regardless, so a local copy still needs the identical CSP entry, buys no isolation, and adds
 *    a stale-copy failure mode nobody would notice until the widget silently stopped working.
 *  - The LWR site head markup in Experience Builder. REJECTED: it lives in the force-ignored
 *    networks/ + sites/ trees (.forceignore 509-522), so it cannot be deployed or verified from
 *    source, and it would load Cloudflare's script on EVERY page of the portal rather than on the
 *    one page that needs it.
 *
 * This URL only resolves in the browser if BOTH halves of the CSP work are in place: the
 * deployable Cloudflare_Turnstile CspTrustedSite record AND the manual Experience Builder
 * security-level relaxation (GATE C). Neither a green deploy nor a passing Jest run can detect the
 * second one -- the acceptance test is a browser check on the live guest page.
 *
 * render=explicit is required: without it Turnstile auto-scans the document for its widget div at
 * script load, which races LWC's own rendering and intermittently finds nothing.
 */
const TURNSTILE_SCRIPT_URL = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

const GENERIC_ERROR = 'Something went wrong. Please try again.';

export default class BrokerDealIntakeForm extends LightningElement {
    /**
     * The PUBLIC Cloudflare Turnstile sitekey, set per-environment in Experience Builder.
     *
     * A sitekey is not a secret -- it is published in the page source of every site that uses
     * Turnstile, by design. The SECRET key is its counterpart and lives only in the
     * Turnstile_Credential External Credential, server-side, never here (ARCHITECTURE.md 3.5).
     *
     * It is a design attribute rather than a constant because it differs per environment, and
     * hardcoding it would make rotating or re-pointing the widget a code deploy.
     */
    @api siteKey;

    assetTypeOptions = [];
    submitting = false;
    submitted = false;
    errorMessage = '';
    logoUrl = DPEG_LOGO;

    // form state
    firstName = '';
    lastName = '';
    brokerageFirm = '';
    email = '';
    phone = '';
    propertyAddress = '';
    assetType = '';
    website = ''; // honeypot

    // Turnstile state.
    // 🔴 scriptRequested and scriptLoaded ARE TWO DIFFERENT FACTS AND MUST NOT BE MERGED.
    // scriptRequested means "we have already called loadScript, do not call it again"; scriptLoaded
    // means "Cloudflare's api.js actually executed and window.turnstile now exists". Collapsing
    // them into one flag set before the promise settles makes a FAILED load indistinguishable from
    // a successful one, and the component then tries to render a widget with a script that never
    // arrived. Caught by the CSP-failure Jest test.
    turnstileToken = '';
    turnstileError = '';
    scriptRequested = false;
    scriptLoaded = false;
    widgetId = null;

    @wire(getFormMetadata)
    wiredMeta({ data, error }) {
        if (data) {
            this.assetTypeOptions = data.assetTypes.map((o) => ({ label: o.label, value: o.value }));
        } else if (error) {
            this.errorMessage = 'Could not load the form. Please refresh and try again.';
        }
    }

    /**
     * The widget can only be rendered once its container exists in the DOM, and the container only
     * exists while the form (not the confirmation) is showing. renderedCallback is therefore the
     * right hook -- but it fires on EVERY rerender, so both the script load and the widget render
     * are guarded. Without those guards a single keystroke in any input would mint another widget.
     */
    renderedCallback() {
        if (this.submitted) {
            return;
        }
        if (!this.scriptRequested) {
            this.scriptRequested = true;
            loadScript(this, TURNSTILE_SCRIPT_URL)
                .then(() => {
                    this.scriptLoaded = true;
                    this.renderWidget();
                })
                .catch(() => {
                    // Almost always CSP: the CspTrustedSite record or the manual Experience
                    // Builder relaxation is missing. Say something a broker can act on; the
                    // diagnosis lives in the browser console, not in this message.
                    this.turnstileError =
                        'The human-verification check could not load. Please refresh the page, or contact us if this continues.';
                });
            return;
        }
        this.renderWidget();
    }

    /**
     * Render the Turnstile widget exactly once per form lifetime.
     *
     * Returns early rather than throwing on every "not ready" condition, because renderedCallback
     * calls this speculatively on each rerender and a throw here would surface as an opaque LWC
     * error with no relation to anything the user did.
     */
    renderWidget() {
        if (this.widgetId !== null || !this.scriptLoaded) {
            return;
        }
        const container = this.template.querySelector('[data-id="turnstile"]');
        const turnstile = typeof window === 'undefined' ? undefined : window.turnstile;
        if (!container || !turnstile) {
            return;
        }
        if (!this.siteKey) {
            // Fail visibly, not silently. A blank sitekey renders nothing at all, and the server
            // then refuses every submission with a message about a widget the broker never saw.
            this.turnstileError =
                'The human-verification check is not configured. Please contact us so we can take your submission directly.';
            return;
        }
        this.widgetId = turnstile.render(container, {
            sitekey: this.siteKey,
            callback: (token) => {
                this.turnstileToken = token;
                this.turnstileError = '';
            },
            'expired-callback': () => {
                // Turnstile tokens expire on their own after a few minutes. Clearing the token
                // here is what stops a slow form-filler from submitting a stale one and being told
                // to try again with no visible reason.
                this.turnstileToken = '';
            },
            'error-callback': () => {
                this.turnstileToken = '';
                this.turnstileError = 'Verification failed to load. Please refresh and try again.';
            }
        });
    }

    /**
     * Turnstile tokens are SINGLE-USE. Re-submitting the same one returns timeout-or-duplicate
     * from Cloudflare and is refused, so the widget must be reset after every failed submit or the
     * broker's second attempt is guaranteed to fail for a different reason than their first.
     */
    resetWidget() {
        this.turnstileToken = '';
        const turnstile = typeof window === 'undefined' ? undefined : window.turnstile;
        if (turnstile && this.widgetId !== null) {
            turnstile.reset(this.widgetId);
        }
    }

    /** True while the broker has not solved the widget -- used to disable the submit button. */
    get submitDisabled() {
        return this.submitting || !this.turnstileToken;
    }

    handleChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    handleSubmit() {
        this.errorMessage = '';
        if (!this.validate()) {
            return;
        }
        if (!this.turnstileToken) {
            // The button is disabled in this state, so this is a belt-and-braces guard against
            // programmatic invocation. The SERVER is the real gate -- this check exists to give a
            // human a faster message than a round trip would, never to be the control itself.
            this.errorMessage = 'Please complete the human-verification check below.';
            return;
        }
        this.submitting = true;
        const input = {
            firstName: this.firstName,
            lastName: this.lastName,
            brokerageFirm: this.brokerageFirm,
            email: this.email,
            phone: this.phone,
            propertyAddress: this.propertyAddress,
            assetType: this.assetType,
            website: this.website,
            turnstileToken: this.turnstileToken
        };
        submitDeal({ input })
            .then((result) => {
                this.submitting = false;
                if (result && result.success) {
                    this.submitted = true;
                } else {
                    this.errorMessage = (result && result.message) || GENERIC_ERROR;
                    this.resetWidget();
                }
            })
            .catch((error) => {
                this.submitting = false;
                this.errorMessage = (error && error.body && error.body.message) || GENERIC_ERROR;
                this.resetWidget();
            });
    }

    validate() {
        const inputs = [...this.template.querySelectorAll('.validate')];
        let allValid = true;
        inputs.forEach((input) => {
            if (!input.reportValidity()) {
                allValid = false;
            }
        });
        return allValid;
    }

    handleReset() {
        this.submitted = false;
        this.firstName = '';
        this.lastName = '';
        this.brokerageFirm = '';
        this.email = '';
        this.phone = '';
        this.propertyAddress = '';
        this.assetType = '';
        this.website = '';
        this.errorMessage = '';
        // The confirmation view replaced the form, so the widget's container was destroyed with
        // it. Dropping widgetId lets renderedCallback mint a fresh widget into the new container;
        // calling turnstile.reset() instead would target a node that no longer exists.
        this.turnstileToken = '';
        this.turnstileError = '';
        this.widgetId = null;
    }
}
