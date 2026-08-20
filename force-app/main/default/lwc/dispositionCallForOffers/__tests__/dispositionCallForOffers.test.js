/**
 * c-disposition-call-for-offers — TWO LDS related-list wires on the SAME adapter.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 emit() BROADCASTS TO EVERY WIRE INSTANCE OF THE ADAPTER — USE THE FILTER
 * ─────────────────────────────────────────────────────────────────────────────
 * This component holds TWO `@wire(getRelatedListRecords, ...)` — one for
 * `Broker_Listings__r`, one for `Disposition_Offers__r`. A bare
 * `getRelatedListRecords.emit(payload)` feeds BOTH of them, so the listing
 * payload would also arrive at the offers handler (and vice versa) and the test
 * would be asserting against a state the org can never produce.
 *
 * `@salesforce/wire-service-jest-util`'s adapters take an optional SECOND
 * argument — `emit(value, filterFn)` / `emitError(errorOptions, filterFn)` —
 * where `filterFn` receives that instance's CONFIG. Every emit below routes on
 * `config.relatedListId`, which is what keeps the two wires independent.
 *
 * ⚠ `.error()` (no arguments) DOES NOT ACCEPT A FILTER — it errors every
 * instance. `emitError(opts, filterFn)` is the one to use for a single wire.
 *
 * 🔴 A FILTERED EMIT MUST BE PRECEDED BY ONE MICROTASK, AND THIS FAILS SILENTLY.
 * Measured here: immediately after `document.body.appendChild(element)` the wire
 * instances EXIST but their configs are still `{}`, so `config.relatedListId` is
 * `undefined`, the filter matches NOTHING, and `emit` reaches nobody — with no
 * error and no warning. The component then renders its empty state, which looks
 * exactly like "the component ignored the payload". Every test below therefore
 * mounts through `await mount()`. An UNFILTERED `emit(payload)` does not need the
 * wait (it broadcasts to every instance regardless of config), which is why
 * sibling suites like c-disposition-offer-select get away without one — do not
 * copy that pattern into a multi-wire suite.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING FACTS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. ZERO APEX. Both reads are LDS (ARCHITECTURE.md §5 LDS-first), which is what
 *    makes the offer count refresh itself when an offer is logged. The existing
 *    `BrokerListingController.getListing` returns both values but is
 *    `cacheable=true` with nothing invalidating it — its own class header records
 *    that its `offersReceived` can be stale — so reusing it would have imported
 *    that staleness into a card whose whole job is a live count.
 * 2. "No listing yet" is NOT an error. A disposition that has just entered Active
 *    Listing has no Broker_Listing__c, and the card must render a dash rather than
 *    an error banner.
 * 3. NOTHING renders the literal string "undefined". Every displayed getter
 *    returns a string, asserted on the RENDERED markup rather than on the getter.
 */
import { createElement } from 'lwc';
import DispositionCallForOffers from 'c/dispositionCallForOffers';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';

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
                return Promise.resolve('/lightning/o/Disposition_Offer__c/list');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

const RECORD_ID = 'a0D5g000000DispEAG';

const isListing = (config) => config.relatedListId === 'Broker_Listings__r';
const isOffers = (config) => config.relatedListId === 'Disposition_Offers__r';

const LISTING = {
    records: [
        {
            id: 'a0L0000000000001',
            fields: { Call_For_Offers_Date__c: { value: '2026-09-15' } }
        }
    ]
};

const offerPage = (n) => ({
    records: Array.from({ length: n }, (_, i) => ({
        id: `a0O000000000${String(i).padStart(3, '0')}`,
        fields: {}
    }))
});

describe('c-disposition-call-for-offers', () => {
    beforeEach(() => {
        encodeDefaultFieldValues.mockImplementation((fields) =>
            Object.entries(fields)
                .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
                .join(',')
        );
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    /**
     * Mounts the component AND waits one microtask, so the two wire configs are
     * populated before any filtered emit runs. See the header: a filtered emit
     * against an unprovisioned config matches nothing and fails silently.
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

    it('EMPTY: dashes, not zeros or "undefined", before either wire answers', async () => {
        const element = await mount();

        await Promise.resolve();

        // '—' for BOTH: "0 offers" would be a claim about data nobody has read yet.
        expect(values(element)).toEqual(['—', '—']);
        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('DATA: renders the call-for-offers date and the offer count', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        getRelatedListRecords.emit(offerPage(3), isOffers);
        await Promise.resolve();

        expect(values(element)).toEqual(['Sep 15, 2026', '3']);
    });

    it('DATA: zero offers renders "0" once the wire has actually answered', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        getRelatedListRecords.emit(offerPage(0), isOffers);
        await Promise.resolve();

        // Now '0' IS the truth — the read happened and found nothing.
        expect(values(element)).toEqual(['Sep 15, 2026', '0']);
    });

    it('NO LISTING YET is not an error — a dash, and no error banner', async () => {
        const element = await mount();

        // A disposition that has just entered Active Listing has no Broker_Listing__c.
        getRelatedListRecords.emit({ records: [] }, isListing);
        getRelatedListRecords.emit(offerPage(1), isOffers);
        await Promise.resolve();

        expect(values(element)).toEqual(['—', '1']);
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('LISTING WITH NO DATE SET renders a dash, not "undefined"', async () => {
        const element = await mount();

        getRelatedListRecords.emit(
            { records: [{ id: 'a0L0000000000001', fields: {} }] },
            isListing
        );
        getRelatedListRecords.emit(offerPage(2), isOffers);
        await Promise.resolve();

        expect(values(element)).toEqual(['—', '2']);
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('ERROR BRANCH (listing wire): banner appears, the offer count still renders', async () => {
        const element = await mount();

        // emitError takes the filter; the bare .error() does NOT and would error
        // BOTH wires, which is a state the org cannot produce independently.
        getRelatedListRecords.emitError(undefined, isListing);
        getRelatedListRecords.emit(offerPage(4), isOffers);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.lv-error')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.lv-error').getAttribute('role')
        ).toBe('alert');
        // The working half keeps working.
        expect(values(element)).toEqual(['—', '4']);
    });

    it('ERROR BRANCH (offers wire): banner appears, the date still renders', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        getRelatedListRecords.emitError(undefined, isOffers);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.lv-error')).not.toBeNull();
        expect(values(element)).toEqual(['Sep 15, 2026', '—']);
    });

    it('LOG OFFER: navigates to the create screen with Disposition__c defaulted', async () => {
        const element = await mount();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getRelatedListRecords.emit(LISTING, isListing);
        getRelatedListRecords.emit(offerPage(1), isOffers);
        await Promise.resolve();

        element.shadowRoot.querySelector('.cfo-log').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail;
        expect(pageRef.type).toBe('standard__objectPage');
        expect(pageRef.attributes.objectApiName).toBe('Disposition_Offer__c');
        expect(pageRef.attributes.actionName).toBe('new');
        // Built with encodeDefaultFieldValues, not string concatenation.
        expect(encodeDefaultFieldValues).toHaveBeenCalledWith({
            Disposition__c: RECORD_ID
        });
        expect(pageRef.state.defaultFieldValues).toContain(RECORD_ID);
    });

    it('is accessible', async () => {
        const element = await mount();

        getRelatedListRecords.emit(LISTING, isListing);
        getRelatedListRecords.emit(offerPage(3), isOffers);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
