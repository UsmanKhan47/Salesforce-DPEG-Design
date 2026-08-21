/**
 * c-disposition-call-for-offers — ONE LDS related-list wire.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS SUITE LOST TWELVE ASSERTIONS AT UAT ON 2026-08-21, BY DELETION
 * ═════════════════════════════════════════════════════════════════════════════
 * The user asked for the disposition-offer COUNT and the "+ Log Offer" BUTTON to be removed from
 * this card. Both are gone from the component, so every assertion that rendered them is gone from
 * here — the six `LOG OFFER: …` tests, the offer-count halves of the render tests, and the
 * `ERROR BRANCH (offers wire)` test, which no longer describes a state the component can enter
 * because it no longer holds that wire.
 *
 * 🔴 THEY WERE DELETED, NOT WEAKENED. Turning `expect(values(el)).toEqual(['Sep 15, 2026', '3'])`
 * into a one-element check would have kept a test whose NAME still promised a count; turning the
 * modal assertions into `toBeNull()` on `.cfo-log` inside a test called "opens the in-place dialog"
 * would have been worse. The ONE absence pin that survives is grouped and named as such below.
 *
 * ── ⚠ THREE MOCKS WERE REMOVED WITH THEM, AND THAT IS DELIBERATE ────────────
 * `lightning/navigation`, `c/dispositionLogOfferModal` and `@salesforce/apex` (for `refreshApex`)
 * are all gone from this file. The component imports none of them any more, and this file's own
 * retired comment about the `encodeDefaultFieldValues` stub said why that matters: a mock of a
 * module nothing under test uses is *"the kind of leftover that makes a suite look like it covers
 * more than it does."* The `never navigates` pin went with the navigation mock — there is no longer
 * a button to click, so nothing could observe a re-added `Navigate` call anyway; the pin that
 * replaces it asserts the BUTTON's absence, which is upstream of navigation.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 emit() BROADCASTS TO EVERY WIRE INSTANCE OF THE ADAPTER — THE FILTER IS KEPT
 * ─────────────────────────────────────────────────────────────────────────────
 * This component now holds ONE `@wire(getRelatedListRecords, ...)`, so a bare
 * `getRelatedListRecords.emit(payload)` would reach it. The `relatedListId` filter and the
 * `await mount()` are kept anyway, because the trap they document is real and is one edit away from
 * mattering again:
 *
 * `@salesforce/wire-service-jest-util`'s adapters take an optional SECOND argument —
 * `emit(value, filterFn)` / `emitError(errorOptions, filterFn)` — where `filterFn` receives that
 * instance's CONFIG. ⚠ `.error()` (no arguments) DOES NOT ACCEPT A FILTER — it errors every
 * instance; `emitError(opts, filterFn)` is the one to use for a single wire.
 *
 * 🔴 A FILTERED EMIT MUST BE PRECEDED BY ONE MICROTASK, AND THIS FAILS SILENTLY. Measured here:
 * immediately after `document.body.appendChild(element)` the wire instance EXISTS but its config is
 * still `{}`, so `config.relatedListId` is `undefined`, the filter matches NOTHING, and `emit`
 * reaches nobody — with no error and no warning. The component then renders its empty state, which
 * looks exactly like "the component ignored the payload". Every test below therefore mounts through
 * `await mount()`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. ZERO APEX, end to end again now that the dialog button has gone (ARCHITECTURE.md §5
 *    LDS-first). The existing `BrokerListingController.getListing` returns this same date but is
 *    `cacheable=true` with nothing invalidating it, so it is still deliberately not reused.
 * 2. "No listing yet" is NOT an error. A disposition that has just entered Active Listing has no
 *    Broker_Listing__c, and the card must render a dash rather than an error banner.
 * 3. NOTHING renders the literal string "undefined". The displayed getter returns a string,
 *    asserted on the RENDERED markup rather than on the getter.
 */
import { createElement } from 'lwc';
import DispositionCallForOffers from 'c/dispositionCallForOffers';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';

const RECORD_ID = 'a0D5g000000DispEAG';

const isListing = (config) => config.relatedListId === 'Broker_Listings__r';

const LISTING = {
    records: [
        {
            id: 'a0L0000000000001',
            fields: { Call_For_Offers_Date__c: { value: '2026-09-15' } }
        }
    ]
};

describe('c-disposition-call-for-offers', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    /**
     * Mounts the component AND waits one microtask, so the wire config is populated before any
     * filtered emit runs. See the header: a filtered emit against an unprovisioned config matches
     * nothing and fails silently.
     */
    async function mount(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-call-for-offers', {
            is: DispositionCallForOffers
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        await Promise.resolve();
        return element;
    }

    const values = (el) =>
        [...el.shadowRoot.querySelectorAll('.cfo-value')].map(
            (n) => n.textContent
        );

    it('EMPTY: a dash, not "undefined", before the wire answers', async () => {
        const element = await mount();

        await Promise.resolve();

        expect(values(element)).toEqual(['—']);
        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('DATA: renders the call-for-offers date', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        await Promise.resolve();

        expect(values(element)).toEqual(['Sep 15, 2026']);
    });

    it('NO LISTING YET is not an error — a dash, and no error banner', async () => {
        const element = await mount();

        // A disposition that has just entered Active Listing has no Broker_Listing__c.
        getRelatedListRecords.emit({ records: [] }, isListing);
        await Promise.resolve();

        expect(values(element)).toEqual(['—']);
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('LISTING WITH NO DATE SET renders a dash, not "undefined"', async () => {
        const element = await mount();

        getRelatedListRecords.emit(
            { records: [{ id: 'a0L0000000000001', fields: {} }] },
            isListing
        );
        await Promise.resolve();

        expect(values(element)).toEqual(['—']);
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('ERROR BRANCH: the banner appears and the card still renders', async () => {
        const element = await mount();

        // emitError takes the filter; the bare .error() does NOT.
        getRelatedListRecords.emitError(undefined, isListing);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.lv-error')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.lv-error').getAttribute('role')
        ).toBe('alert');
        expect(values(element)).toEqual(['—']);
    });

    /**
     * 🔴 THE UAT REMOVAL, PINNED AS AN ASSERTION ABOUT ABSENCE — the only one in this file. Every
     * POSITIVE assertion about the count and the button was deleted, which leaves nothing to fail
     * if either comes back. This is that falsifier.
     *
     * ⚠ IT CHECKS THE RENDERED TEXT AS WELL AS THE SELECTORS, because a re-added row would arrive
     * as a new `.cfo-label`/`.cfo-value` pair and a re-added button might not carry `.cfo-log`.
     * The listing payload is emitted first so the card is in its fully-loaded state — an assertion
     * about absence on an EMPTY card would pass for the wrong reason.
     */
    it('🔴 renders no offer count and no Log Offer button — the UAT removal must not come back', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.cfo-log')).toBeNull();
        expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
        // Exactly one dt/dd pair survives: the date.
        expect(
            element.shadowRoot.querySelectorAll('.cfo-label').length
        ).toBe(1);
        expect(values(element)).toEqual(['Sep 15, 2026']);

        const rendered = element.shadowRoot.textContent.toLowerCase();
        expect(rendered).not.toContain('offers received');
        expect(rendered).not.toContain('log offer');
    });

    it('is accessible', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
