/**
 * c-broker-listing — @wire-to-Apex suite.
 * Pattern: bovComparisonMatrix template (createApexTestWireAdapter + emit/error, modal mocked
 * wholesale, `@salesforce/apex` mocked so `refreshApex` is a spy).
 *
 * Data sources: TWO wires now.
 *   @wire(getListing,     { dispositionId: '$recordId' }) -> the card's facts and traction badge
 *   @wire(getSubmissions, { dispositionId: '$recordId' }) -> whether Replace Broker may render
 *
 * ── 🔴 WHAT THIS SUITE PROVES ABOUT THE REPLACE BROKER BUTTON ───────────────
 * It is a SECOND ENTRY POINT to one server mechanism, not a second mechanism. The assertions that
 * carry that are:
 *   - the button opens `c/bovReplaceBrokerModal` (the same bundle `c/bovComparisonMatrix` opens),
 *     with `dispositionId` and `backupOptions`;
 *   - `isFirstAppointment` is NOT passed — the modal reads `=== true`, so absent means "replacement";
 *   - both wires are refreshed with the SAME objects the wires handed the component, which is the
 *     only assertion that catches a "tidying" edit back to a destructured wire handler;
 *   - the button is ABSENT when nothing is Selected — which is also the off-market case, since an
 *     off-market disposition has no BOV submissions at all.
 *
 * ⚠ THE FIXTURE MOVED OFF THE 30/40/60 CLOCK (user decision, 2026-08-21). It previously carried
 * `tractionBand: 'HARD_STOP'` / `'Day 71 — Hard Stop: no offers'`. The payload now carries the
 * Week 1/4/6 bands and a paused variant — computed server-side by DispositionTractionService. This
 * suite asserts that the card RENDERS what it is given and deliberately re-derives no threshold of
 * its own.
 *
 * ── ⚠ THREE TILES, AND `offersReceived` IS GONE FROM THE FIXTURE (UAT, 2026-08-21) ──
 * The user asked for the disposition-offer count to be removed, so the fourth "Offers Received"
 * tile went and `BrokerListingController.ListingRow.offersReceived` went with it. The assertions
 * that read `tiles[3]` were DELETED rather than repointed — there is no tile there to assert on —
 * and the member was removed from both fixtures, because a fixture carrying a field the server no
 * longer sends is a suite testing a payload the org cannot produce.
 *
 * 🔴 THE `.risk-badge` ASSERTIONS BELOW ARE NOW LOAD-BEARING FOR THE WHOLE SCREEN, not just for this
 * card. `c/listingAlerts` lost its own copy of the band pill in the same UAT pass, so this is the
 * ONLY place "Week 4 — At Risk" — the one string the user gave verbatim — is rendered anywhere. If
 * these tests are ever deleted as redundant, nothing else fails when the label disappears.
 */
import { createElement } from 'lwc';
import BrokerListing from 'c/brokerListing';
import getListing from '@salesforce/apex/BrokerListingController.getListing';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';
import { refreshApex } from '@salesforce/apex';
import BovReplaceBrokerModal from 'c/bovReplaceBrokerModal';

jest.mock(
    '@salesforce/apex/BrokerListingController.getListing',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

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

// ⚠ `refreshApex` IS NOT AUTO-MOCKED. `@salesforce/apex` resolves to a real module whose
// `refreshApex` is a plain function, so `expect(refreshApex).toHaveBeenCalled()` fails with
// "received value must be a mock or spy function" — which reads like a broken assertion rather
// than a missing mock.
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn() }), {
    virtual: true
});

const LISTING = {
    assetName: 'Sugar Land Town Center',
    brokerFirm: 'CBRE',
    contactName: 'Jane Doe',
    tractionBand: 'WEEK_4',
    tractionLabel: 'Week 4 — At Risk',
    tractionDetail:
        'Four weeks on the market with no offers, and 14 days of the marketing period remain.',
    daysOnMarket: 30,
    isAtRisk: true,
    listDate: '2026-03-15',
    callForOffersDate: '2026-04-10'
};

/** The paused variant — an offer stopped the clock, so the card must show the FROZEN day count. */
const PAUSED_LISTING = {
    ...LISTING,
    tractionBand: 'ON_TRACK',
    tractionLabel: 'Day 12 — Offer received, clock paused',
    tractionDetail:
        '2 offers received, so the marketing clock stopped at day 12 and no week check-in is due.',
    daysOnMarket: 12,
    isAtRisk: false
};

const SUBMISSIONS = [
    {
        id: 'a0X010000000001',
        name: 'BOV-0001',
        isSelected: true,
        bovScore: 88,
        brokerFirm: 'Colliers International',
        contactName: 'Jane Doe',
        bovAmount: 12500000
    },
    {
        id: 'a0X010000000002',
        name: 'BOV-0002',
        isSelected: false,
        bovScore: 71,
        brokerFirm: 'JLL',
        contactName: 'John Roe',
        bovAmount: 11000000
    }
];

/** No broker appointed yet — and, identically in shape, the off-market case of NO submissions. */
const NONE_SELECTED = SUBMISSIONS.map((s) => ({ ...s, isSelected: false }));

describe('c-broker-listing', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-broker-listing', {
            is: BrokerListing
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /** Emit both wires and settle. */
    async function emitAll(listing, submissions) {
        getListing.emit(listing);
        getSubmissions.emit(submissions);
        await Promise.resolve();
        await Promise.resolve();
    }

    function replaceButton(element) {
        return element.shadowRoot.querySelector('.replace-btn');
    }

    it('shows the empty card until the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        expect(
            element.shadowRoot.querySelector('.empty-card').textContent
        ).toBe('No broker listing on record.');
    });

    it('DATA BRANCH: renders the listing header and three stat tiles', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.card-title').textContent
        ).toBe('Sugar Land Town Center');
        expect(
            element.shadowRoot.querySelector('.card-sub').textContent
        ).toBe('CBRE · Jane Doe');

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles.length).toBe(3);
        expect(tiles[0].value).toBe('30 days'); // Days On Market
        expect(tiles[1].value).toBe('Mar 15, 2026'); // List Date
        expect(tiles[2].value).toBe('Apr 10, 2026'); // Call For Offers Date
    });

    /**
     * 🔴 THE UAT REMOVAL, PINNED AS AN ASSERTION ABOUT ABSENCE. The count assertions were deleted,
     * which leaves nothing to fail if a fourth tile comes back. `PAUSED_LISTING` is used because it
     * is the fixture with a non-zero count in the underlying data — a re-added tile would render
     * "2" and be caught by the text check as well as by the tile count.
     */
    it('🔴 renders no offer count — the UAT removal must not come back', async () => {
        const element = createComponent();

        getListing.emit(PAUSED_LISTING);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('c-onboarding-card-child').length
        ).toBe(3);
        expect(
            element.shadowRoot.textContent.toLowerCase()
        ).not.toContain('offers received');
    });

    /**
     * 🔴 THE ESCALATION LABEL, WHERE THE USER ASKED FOR IT: beside the listing facts, as TEXT. The
     * exact string is the one the user gave verbatim, and it is produced entirely server-side.
     */
    it('DATA BRANCH: renders the escalation label beside the listing facts', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();

        const badge = element.shadowRoot.querySelector('.risk-badge');
        expect(badge.textContent).toContain('Week 4 — At Risk');
        expect(badge.getAttribute('title')).toBe(LISTING.tractionDetail);
    });

    it('DATA BRANCH: shows the risk badge only when a traction label is present', async () => {
        const element = createComponent();

        getListing.emit(LISTING);
        await Promise.resolve();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Week 4 — At Risk');

        // Re-emit the same listing without a traction label.
        getListing.emit({ ...LISTING, tractionLabel: null });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('.risk-badge')).toBeNull();
    });

    /**
     * 🔴 THE PAUSE, ON THIS CARD. The Days On Market tile shows the FROZEN number, not the elapsed
     * one, because the server computed it that way — and the badge says why in words.
     */
    it('DATA BRANCH: a paused clock shows the frozen day count and says so', async () => {
        const element = createComponent();

        getListing.emit(PAUSED_LISTING);
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles[0].value).toBe('12 days');
        // ⚠ THE `tiles[3].value === '2'` ASSERTION THAT SAT HERE WAS DELETED, NOT MOVED. The offer
        // count tile is gone (UAT, 2026-08-21); the pause is still proven by the FROZEN day count
        // above and by the badge below, which are what the pause actually changes on this card.
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('clock paused');
    });

    /**
     * 🔴 THE CLOCK-NEVER-TICKED REGRESSION, PINNED. The retired controller read the hand-keyed
     * Broker_Listing__c.Days_On_Market__c and defaulted a null to 0, so a listing with no
     * marketing clock rendered "0 days" — indistinguishable from "listed today" and the reason
     * a dead clock looked healthy. A null must now render as a dash.
     */
    it('DATA BRANCH: a null days-on-market renders a dash, never "0 days"', async () => {
        const element = createComponent();

        getListing.emit({
            ...LISTING,
            daysOnMarket: null,
            tractionBand: 'NOT_LISTED',
            tractionLabel: 'Not listed yet',
            isAtRisk: false
        });
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(tiles[0].value).toBe('—');
    });

    it('ERROR BRANCH: renders an inline error state (not the data card) when the wire errors', async () => {
        const element = createComponent();

        getListing.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
        const err = element.shadowRoot.querySelector('.bl-error');
        expect(err).not.toBeNull();
        expect(err.textContent).toContain('could not be loaded');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // REPLACE BROKER
    // ─────────────────────────────────────────────────────────────────────────

    it('REPLACE: the button renders beside the label when a broker is Selected', async () => {
        const element = createComponent();

        await emitAll(LISTING, SUBMISSIONS);

        const btn = replaceButton(element);
        expect(btn).not.toBeNull();
        expect(btn.textContent).toBe('Replace Broker');
        // Beside the label, not somewhere else on the card.
        expect(
            element.shadowRoot.querySelector('.header-right .replace-btn')
        ).not.toBeNull();
    });

    /**
     * 🔴 ABSENCE, ASSERTED IN THREE WAYS — because "the button appears when it should" would stay
     * green if it ALSO appeared when it should not, offering a replacement the server would refuse.
     */
    it('REPLACE: the button is absent with no Selected broker, no submissions, or a failed read', async () => {
        const element = createComponent();

        await emitAll(LISTING, NONE_SELECTED);
        expect(replaceButton(element)).toBeNull();

        // 🔴 THE OFF-MARKET CASE. An off-market disposition has NO BOV submissions — its broker is
        // Disposition__c.Broker__c, which replaceSelectedBroker does not touch — so the button
        // hides by construction, with no record-type check to keep in step with the schema.
        getSubmissions.emit([]);
        await Promise.resolve();
        expect(replaceButton(element)).toBeNull();

        // A failed submissions read hides the button and takes nothing else down with it.
        getSubmissions.error();
        await Promise.resolve();
        expect(replaceButton(element)).toBeNull();
        expect(element.shadowRoot.querySelector('.card')).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.risk-badge').textContent
        ).toContain('Week 4 — At Risk');
    });

    /**
     * 🔴 CONVERGENCE. The button opens the SAME modal bundle `c/bovComparisonMatrix` opens, which
     * reaches the SAME `BovSubmissionService.replaceSelectedBroker`. The incumbent is excluded from
     * the options (promoting a broker to itself is not an operation) and the labels come from
     * `c/utils`'s shared `brokerOptionLabel`, so the same broker cannot read differently on the two
     * surfaces that can open this modal.
     */
    it('REPLACE: opens the shared modal with the incumbent excluded and no first-appointment flag', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(undefined);
        const element = createComponent();
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();

        expect(BovReplaceBrokerModal.open).toHaveBeenCalledTimes(1);
        const args = BovReplaceBrokerModal.open.mock.calls[0][0];
        expect(args.dispositionId).toBe('a0D5g000000DispEAG');
        expect(args.currentBroker).toBe('Colliers International');
        expect(args.backupOptions).toEqual([
            {
                value: 'a0X010000000002',
                label: 'JLL — John Roe · $11.0M · Score 71 · BOV-0002'
            }
        ]);
        // ⚠ ABSENT, not false: the modal's getter reads `=== true`, so absent means "replacement".
        expect(args.isFirstAppointment).toBeUndefined();
    });

    /**
     * 🔴 THE REFRESH ASSERTION IS ON THE WIRE RESULT OBJECTS THEMSELVES. That is what catches a
     * "tidying" edit back to `wired({ data, error })`, which compiles, passes every render test
     * above, and silently turns these refreshes into no-ops.
     */
    it('REPLACE: on success raises a sticky toast carrying the SERVER text and refreshes BOTH wires', async () => {
        const message =
            'Broker replaced. JLL must be approved before the sale can proceed.';
        BovReplaceBrokerModal.open.mockResolvedValue({ message });
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[0][0].detail.title).toBe('Broker replaced');
        expect(toast.mock.calls[0][0].detail.message).toBe(message);
        expect(toast.mock.calls[0][0].detail.mode).toBe('sticky');
        expect(refreshApex).toHaveBeenCalledTimes(2);
    });

    it('REPLACE: a dismissed modal changes nothing — no toast and no refresh', async () => {
        BovReplaceBrokerModal.open.mockResolvedValue(null);
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).not.toHaveBeenCalled();
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('REPLACE: a modal that fails to open raises an error toast and refreshes nothing', async () => {
        BovReplaceBrokerModal.open.mockRejectedValue({
            body: { message: 'boom' }
        });
        const element = createComponent();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await emitAll(LISTING, SUBMISSIONS);

        replaceButton(element).click();
        await Promise.resolve();
        await Promise.resolve();

        expect(toast).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[0][0].detail.variant).toBe('error');
        expect(toast.mock.calls[0][0].detail.message).toBe('boom');
        expect(refreshApex).not.toHaveBeenCalled();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await emitAll(LISTING, SUBMISSIONS);

        await expect(element).toBeAccessible();
    });
});
