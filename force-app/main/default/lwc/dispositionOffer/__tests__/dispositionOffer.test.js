/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRelatedListRecords) + LightningModal
 * --------------------------------------------------------------------------
 * Variant of the LDS template for RELATED-LIST reads. The sfdx-lwc-jest
 * `lightning/uiRelatedListApi` stub already exports getRelatedListRecords as an
 * LDS test wire adapter, so — as with getRecord — there is NO jest.mock() for
 * it. Drive it with getRelatedListRecords.emit({ records: [...] }); each record
 * is a UI-API record: { id, fields: { Field__c: { value } } } using the REAL
 * Disposition_Offer__c field API names the component reads.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 🔴 "+ LOG OFFER" USED TO NAVIGATE, AND THAT WAS TWO DEFECTS (fixed 2026-08-21)
 * ═══════════════════════════════════════════════════════════════════════════
 * It called `NavigationMixin.Navigate` with `actionName: 'new'` on
 * `Disposition_Offer__c`. The platform's post-save behaviour for a record created
 * that way is to NAVIGATE TO THE NEW RECORD, so logging an offer threw the user
 * off the Disposition page; and that create screen renders from the PAGE LAYOUT,
 * which cannot express a narrow field set or a read-only, server-resolved broker.
 * ⚠ THE SECOND DEFECT USED TO BE DESCRIBED AS "the layout offers `Buyer__c` as an
 * UNFILTERED Contact lookup". That sentence was retired on 2026-08-21 with buyer
 * identity itself — DPEG communicates only with the appointed listing broker.
 *
 * 🔴 `LOG OFFER: never navigates` BELOW IS THE ANTI-REGRESSION PIN, AND IT IS
 * DELIBERATELY AN ASSERTION ABOUT **ABSENCE**. Asserting only that the modal
 * opened would stay green if a `Navigate` call were added back beside it. The
 * `lightning/navigation` mock is therefore KEPT even though the component no
 * longer imports the module — it is what makes a re-added Navigate observable
 * rather than silently inert.
 *
 * 🔴 `LightningModal.open()` IS A STATIC ON A CLASS and cannot be driven like a
 * wire adapter, so the modal is mocked wholesale here. Its own behaviour is
 * proved in lwc/dispositionLogOfferModal/__tests__ (33 tests).
 */
import { createElement } from 'lwc';
import DispositionOffer from 'c/dispositionOffer';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';
import { refreshApex } from '@salesforce/apex';
import DispositionLogOfferModal from 'c/dispositionLogOfferModal';

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
                return Promise.resolve('/');
            }
        };
    NavigationMixin.Navigate = Navigate;
    NavigationMixin.GenerateUrl = GenerateUrl;
    return { NavigationMixin, CurrentPageReference: jest.fn() };
});

jest.mock('c/dispositionLogOfferModal', () => ({
    __esModule: true,
    default: { open: jest.fn() }
}));

// ⚠ `refreshApex` IS NOT AUTO-MOCKED. `@salesforce/apex` resolves to a real module whose
// `refreshApex` is a plain function, so `expect(refreshApex).toHaveBeenCalled()` fails with
// "received value must be a mock or spy function" — which reads like a broken assertion rather
// than a missing mock.
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), {
    virtual: true
});

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));
const NEW_OFFER_ID = 'a0Biw000000009AAA';

const OFFERS = {
    records: [
        {
            id: 'a0E01',
            fields: {
                Name: { value: 'OFFER-0001' },
                Offer_Amount__c: { value: 2500000 },
                Offer_Date__c: { value: '2026-03-15' }
            }
        },
        {
            id: 'a0E02',
            fields: {
                Name: { value: 'OFFER-0002' },
                Offer_Amount__c: { value: 2350000 },
                Offer_Date__c: { value: '2026-03-20' }
            }
        }
    ]
};

describe('c-disposition-offer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-disposition-offer', {
            is: DispositionOffer
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /**
     * ⚠ THE CLOCK NOTE THIS TEST USED TO PIN IS GONE (UAT, 2026-08-21). The assertion read
     * `'No offers yet. 60-day marketing clock, traction check at day 30.'` — it was DELETED and
     * replaced with the shorter true string rather than relaxed to a `toContain('No offers yet')`,
     * which would have passed with the stale ladder still rendered. The extra clause was removed
     * both because the user asked for the listing-traction display to go AND because it was by then
     * FALSE: the service had moved to a 42-day period with rungs at 7/28/42.
     */
    it('shows the empty message before any offers load, with no clock note', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.empty-msg').textContent.trim()
        ).toBe('No offers yet.');
        // 🔴 THE FALSIFIER FOR A REINSTATED LADDER. No number and no traction language may return
        // to this card: the schedule renders once, on c/listingAlerts, from the server.
        const rendered = element.shadowRoot.textContent.toLowerCase();
        expect(rendered).not.toContain('clock');
        expect(rendered).not.toContain('traction');
    });

    it('DATA BRANCH: renders one row per related offer with formatted money + date', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.offer-row');
        expect(rows.length).toBe(2);

        // 🔴 THE OFFER'S OWN NUMBER, NOT A BUYER NAME (2026-08-21). With the buyer
        // gone the amount and the date are otherwise the only things telling two
        // offers apart, and two offers can legitimately share both.
        expect(
            element.shadowRoot.querySelector('.offer-name').textContent
        ).toBe('OFFER-0001');
        expect(
            element.shadowRoot.querySelector('.offer-amount').textContent
        ).toBe('$2.50M');
        expect(
            element.shadowRoot.querySelector('.offer-date').textContent
        ).toBe('Mar 15, 2026');

        expect(element.shadowRoot.querySelector('.empty-msg')).toBeNull();
    });

    it('LOG OFFER: opens the in-place dialog for THIS disposition', async () => {
        DispositionLogOfferModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();
        await flushPromises();

        expect(DispositionLogOfferModal.open).toHaveBeenCalledTimes(1);
        const args = DispositionLogOfferModal.open.mock.calls[0][0];
        // The dialog is scoped to the sale it was opened from, and nothing else.
        expect(args.dispositionId).toBe('a0D5g000000DispEAG');
        // A label and a description are what LightningModal exposes to assistive
        // tech; a dialog with neither announces as an unnamed region.
        expect(args.label).toBe('Log Offer');
        expect(typeof args.description).toBe('string');
        expect(args.description.length).toBeGreaterThan(0);
    });

    it('🔴 LOG OFFER: NEVER NAVIGATES — the original bug must not come back', async () => {
        DispositionLogOfferModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);
        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();
        await flushPromises();

        // 🔴 AN ASSERTION ABOUT ABSENCE, ON PURPOSE. The test above would stay
        // green if a `NavigationMixin.Navigate` call were added back BESIDE the
        // modal — which is exactly the shape a well-meaning "also open the record
        // afterwards" edit would take, and it would reinstate the UAT complaint.
        // The `lightning/navigation` mock above stays in this file solely so this
        // assertion can observe a re-added call.
        expect(navHandler).not.toHaveBeenCalled();
    });

    it('🔴 LOG OFFER: a saved offer toasts and REFRESHES THE WIRE IN PLACE', async () => {
        DispositionLogOfferModal.open.mockResolvedValue({
            recordId: NEW_OFFER_ID,
            name: 'OFFER-0007'
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toContain('OFFER-0007');
        // 🔴 CALLED WITH THE **WHOLE WIRE RESULT**, which is the only assertion
        // that catches a "tidying" edit back to `wired({ data, error })`. That
        // shape compiles, passes every render test in this file, and silently
        // turns this refresh into a no-op — leaving the card showing the old set
        // after every save.
        expect(refreshApex).toHaveBeenCalledTimes(1);
        expect(refreshApex.mock.calls[0][0]).toEqual(
            expect.objectContaining({ data: OFFERS })
        );
    });

    it('LOG OFFER: a dismissed dialog says nothing and refreshes nothing', async () => {
        // ⚠ The real LightningModal resolves `undefined` on a dismiss; this repo's
        // own Jest stub for it resolves `null` (CustomEvent coerces an absent
        // `detail` to null). Both are falsy and both must take the quiet branch.
        DispositionLogOfferModal.open.mockResolvedValue(null);
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();
        await flushPromises();

        expect(toastHandler).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('LOG OFFER: a dialog that fails to open reports it instead of failing silently', async () => {
        DispositionLogOfferModal.open.mockRejectedValue({
            body: { message: 'You do not have access to the broker information.' }
        });
        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        await Promise.resolve();

        element.shadowRoot.querySelector('.log-btn').click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        // The AUTHORED server message survives — a generic "something went wrong"
        // here would hide a provisioning gap the administrator can actually fix.
        expect(toastHandler.mock.calls[0][0].detail.message).toContain(
            'do not have access'
        );
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: shows an inline error (not the empty note) when the related-list wire errors', async () => {
        const element = createComponent();

        getRelatedListRecords.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(0);
        expect(element.shadowRoot.querySelector('.empty-msg')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.wire-error')
        ).not.toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-BUYER — THE DELIBERATE ABSENCE PIN (2026-08-21)
    //
    // The buyer-name assertion above was RETARGETED, not deleted, so this card
    // kept a first-column test. What it did NOT keep is anything that fails if a
    // buyer column is added BACK beside the offer number. This is that pin, and
    // it runs against the two-row fixture so it cannot pass on an empty card.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-BUYER: the card names no buyer and requests no buyer field', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        // Guard the guard: two rows genuinely rendered.
        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(2);

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.offer-buyer')).toBeNull();

        // 2. 🔴 THE RENDERED WORD. A re-added column arrives under a new class
        //    name, so the selector assertion alone would stay green.
        expect(element.shadowRoot.textContent.toLowerCase()).not.toContain('buyer');

        // 3. 🔴 THE WIRE REQUEST ITSELF. This is the assertion that catches the
        //    field coming back into the LDS `fields` list — which would re-add the
        //    FLS gate on `Buyer_Name__c` for every user of this card even if
        //    nothing rendered it. `getConfig()` is the sfdx-lwc-jest adapter's
        //    view of the last config the component asked for.
        const config = getRelatedListRecords.getLastConfig();
        expect(config.fields).not.toContain('Disposition_Offer__c.Buyer_Name__c');
        expect(config.fields).toContain('Disposition_Offer__c.Name');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
