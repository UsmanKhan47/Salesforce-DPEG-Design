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

/**
 * ⚠ NEITHER ROW IS FLAGGED, ON PURPOSE. This is the DEFAULT-mode fixture and it is what makes
 * the `selected-only` tests below non-vacuous: a fixture where every row happened to be selected
 * would render identically in both modes, so the filter could be deleted outright and every test
 * in this file would stay green.
 */
const OFFERS = {
    records: [
        {
            id: 'a0E01',
            fields: {
                Name: { value: 'OFFER-0001' },
                Offer_Amount__c: { value: 2500000 },
                Offer_Date__c: { value: '2026-03-15' },
                Is_Selected__c: { value: false }
            }
        },
        {
            id: 'a0E02',
            fields: {
                Name: { value: 'OFFER-0002' },
                Offer_Amount__c: { value: 2350000 },
                Offer_Date__c: { value: '2026-03-20' },
                Is_Selected__c: { value: false }
            }
        }
    ]
};

/**
 * THREE offers, exactly ONE of them selected — the real Offer Selection shape.
 *
 * 🔴 THE SELECTED ROW IS THE MIDDLE ONE, DELIBERATELY. With it first, a broken filter that
 * simply took `records[0]` would produce an identical render and pass. With it last, a `slice(-1)`
 * bug would. Being second, neither positional accident can imitate a working filter.
 *
 * ⚠ IT IS ALSO NOT THE HIGHEST OFFER (2.35M against 2.50M). `Is_Selected__c` is a human choice
 * recorded by `DispositionApprovalService.selectOffer`, not "the best number" — a fixture where
 * the selected offer was also the largest would pass for a card that sorted by amount and took
 * the top row.
 */
const OFFERS_WITH_SELECTION = {
    records: [
        {
            id: 'a0E01',
            fields: {
                Name: { value: 'OFFER-0001' },
                Offer_Amount__c: { value: 2500000 },
                Offer_Date__c: { value: '2026-03-15' },
                Is_Selected__c: { value: false }
            }
        },
        {
            id: 'a0E02',
            fields: {
                Name: { value: 'OFFER-0002' },
                Offer_Amount__c: { value: 2350000 },
                Offer_Date__c: { value: '2026-03-20' },
                Is_Selected__c: { value: true }
            }
        },
        {
            id: 'a0E03',
            fields: {
                Name: { value: 'OFFER-0003' },
                Offer_Amount__c: { value: 2100000 },
                Offer_Date__c: { value: '2026-03-22' },
                Is_Selected__c: { value: false }
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

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 selected-only MODE (2026-08-24) — "at Offer Selection show only the
    //    offer going for approval, and disable Log Offer"
    //
    // Set by c/dispositionSidebar at the Offer Selection stage; the WIRING is
    // pinned in that bundle's tests, the BEHAVIOUR is pinned here.
    //
    // ⚠ EVERY TEST BELOW RUNS AGAINST `OFFERS_WITH_SELECTION` — three rows, one
    // flagged, the flagged one neither first nor largest. A fixture where the
    // filter's answer coincided with "the first row" or "all rows" would let the
    // filter be deleted with the suite still green.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 SELECTED-ONLY: renders ONLY the flagged offer, out of three', async () => {
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });

        getRelatedListRecords.emit(OFFERS_WITH_SELECTION);
        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.offer-row');
        expect(rows.length).toBe(1);

        // 🔴 WHICH row, not just how many. A filter that kept the wrong single row
        // (`records[0]`, a sort-and-take-top, an inverted predicate) renders exactly
        // one row too, and a count-only assertion cannot tell the difference.
        expect(
            element.shadowRoot.querySelector('.offer-name').textContent
        ).toBe('OFFER-0002');
        expect(
            element.shadowRoot.querySelector('.offer-amount').textContent
        ).toBe('$2.35M');

        // The unselected rows are gone from the RENDERED output, not merely
        // deprioritised.
        const rendered = element.shadowRoot.textContent;
        expect(rendered).not.toContain('OFFER-0001');
        expect(rendered).not.toContain('OFFER-0003');

        expect(element.shadowRoot.querySelector('.empty-msg')).toBeNull();
    });

    it('🔴 CONTROL: the SAME fixture in default mode still lists all three', async () => {
        // The other half of the falsifier. Without this, deleting the filter
        // entirely would red only the test above; with it, the pair pins that the
        // difference is caused by the MODE and not by the fixture.
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS_WITH_SELECTION);
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(3);
        expect(element.shadowRoot.textContent).toContain('OFFER-0001');
        expect(element.shadowRoot.textContent).toContain('OFFER-0003');
    });

    it('🔴 SELECTED-ONLY: the LOG OFFER BUTTON IS DISABLED, and says why', async () => {
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });

        getRelatedListRecords.emit(OFFERS_WITH_SELECTION);
        await Promise.resolve();

        const btn = element.shadowRoot.querySelector('.log-btn');
        // 🔴 DISABLED, NOT ABSENT — the user asked for a greyed control, because a
        // vanished one reads as a permission problem. Both halves are asserted:
        // a "hide it" implementation would fail the first line, not the second.
        expect(btn).not.toBeNull();
        expect(btn.disabled).toBe(true);

        // A greyed button with no explanation is the thing "disable, don't hide"
        // was chosen to avoid, so the tooltip is part of the requirement.
        expect(btn.getAttribute('title')).toContain('Select Offer');
    });

    it('🔴 DEFAULT MODE: the button is enabled and carries a REAL title, not "undefined"', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        const btn = element.shadowRoot.querySelector('.log-btn');
        expect(btn.disabled).toBe(false);

        // ⚠ THE LWC COMPILER WRITES A BOUND ATTRIBUTE UNCONDITIONALLY. A `logTitle`
        // that returned `undefined` in this branch would render the literal string
        // `title="undefined"` on the page — measured in this repo on another
        // bundle, and invisible to every other assertion in this file.
        expect(btn.getAttribute('title')).not.toBe('undefined');
        expect(btn.getAttribute('title')).toContain('Log an offer');
    });

    it('🔴 SELECTED-ONLY: the HANDLER refuses too, even with the button force-enabled', async () => {
        // The second, independent guard. `disabled` is what stops the click in a
        // browser; this is what stops the SAVE if that binding is ever dropped in a
        // template edit. Re-enabling the button in the DOM is the only way to reach
        // the handler, and it is precisely the state a broken template would leave
        // the page in.
        DispositionLogOfferModal.open.mockResolvedValue(undefined);
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });
        await Promise.resolve();

        const btn = element.shadowRoot.querySelector('.log-btn');
        btn.disabled = false;
        btn.click();
        await flushPromises();

        expect(DispositionLogOfferModal.open).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('🔴 SELECTED-ONLY: the card is titled for the ONE offer it shows', async () => {
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });

        getRelatedListRecords.emit(OFFERS_WITH_SELECTION);
        await Promise.resolve();

        // ⚠ "Selected Offer", NOT "Offer Sent for Approval": the flag survives a
        // REJECTION, which parks the disposition back at Offer Selection, so a
        // title claiming the offer is out for approval would be false in exactly
        // the state the user most needs this card in.
        expect(
            element.shadowRoot.querySelector('.section-header').textContent.trim()
        ).toBe('Selected Offer');
    });

    it('the default card keeps its original title, which another component names in its copy', async () => {
        // `c/dispositionOfferSelect` tells the user to "Log an offer from the
        // **Disposition Offers** card first". This is the pin that stops the two
        // drifting apart.
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.section-header').textContent.trim()
        ).toBe('Disposition Offers');
    });

    it('🔴 SELECTED-ONLY with nothing flagged says so — it does not claim there are no offers', async () => {
        // Not reachable through the authored path (selectOffer sets the flag and
        // moves the stage in one savepointed transaction), but reachable by data
        // load or direct API write. "No offers yet." here would be a LIE that sends
        // the user to log another offer — the one thing the disabled button exists
        // to prevent.
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });

        getRelatedListRecords.emit(OFFERS); // two rows, neither flagged
        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.offer-row').length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.empty-msg').textContent.trim()
        ).toBe('No offer is currently selected for approval.');
    });

    it('🔴 THE DISABLED BUTTON IS ACTUALLY STYLED AS DISABLED — pinned on the STYLESHEET SOURCE', () => {
        // 🔴 jsdom PERFORMS NO LAYOUT AND APPLIES NO STYLESHEET, so `btn.disabled === true`
        // above is true whether or not anything on the page LOOKS different. A user
        // staring at an unchanged blue button that silently ignores clicks is worse
        // than no change at all, and not one DOM assertion in this file can see it.
        // The stylesheet source is the only observable.
        const css = require('fs')
            .readFileSync(
                require('path').join(__dirname, '..', 'dispositionOffer.css'),
                'utf8'
            )
            .replace(/\/\*[\s\S]*?\*\//g, ''); // comments NAME the banned hooks

        const disabled = css.match(/\.log-btn\[disabled\]\s*\{([^}]*)\}/);
        expect(disabled).not.toBeNull();
        const body = disabled[1];

        // Tokenised, per SLDS 2 — a raw hex here is unthemeable and looks identical
        // on the light theme, so only a source assertion catches it.
        expect(body).toMatch(/background:\s*var\(\s*--slds-g-/);
        expect(body).toMatch(/color:\s*var\(\s*--slds-g-/);
        // Colour is not the only affordance the pointer gets.
        expect(body).toMatch(/cursor:\s*not-allowed/);

        // 🔴 THE BANNED PAIR. Measured against the linter's own metadata:
        // --slds-g-color-disabled-container-1 is WHITE and --slds-g-color-on-disabled-1
        // is pale grey, which on this white card is near-invisible. The linter passes
        // them; nothing but this line objects.
        expect(body).not.toMatch(/--slds-g-color-disabled-container-1/);
        expect(body).not.toMatch(/--slds-g-color-on-disabled-1/);

        // 🔴 AND THE HOVER MUST NOT PAINT OVER IT. `.log-btn:hover` unscoped would
        // repaint the disabled button on mouse-over, undoing the whole affordance.
        expect(css).toMatch(/\.log-btn:not\(\[disabled\]\):hover/);
        expect(css).not.toMatch(/(^|[^)])\.log-btn:hover/);
    });

    it('🔴 THE FILTER KEY IS ACTUALLY REQUESTED FROM LDS', async () => {
        // 🔴 THE SILENT-FAILURE PIN. Drop `Is_Selected__c` from the wire's field
        // list and `fields.Is_Selected__c` is `undefined` on every row, so the
        // selected-only card filters EVERYTHING out and renders its empty state
        // forever. Nothing throws, nothing logs, and the default mode is unaffected
        // — so this is the only assertion in the suite that would move.
        createComponent();
        await Promise.resolve();

        const config = getRelatedListRecords.getLastConfig();
        expect(config.fields).toContain('Disposition_Offer__c.Is_Selected__c');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRelatedListRecords.emit(OFFERS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible in selected-only mode (a disabled button is still announced)', async () => {
        const element = createComponent({
            recordId: 'a0D5g000000DispEAG',
            selectedOnly: true
        });

        getRelatedListRecords.emit(OFFERS_WITH_SELECTION);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
