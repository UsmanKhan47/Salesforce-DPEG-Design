/**
 * WIRE-MOCK TEMPLATE — @wire to APEX (parameterised)
 * --------------------------------------------------
 * Follows the c-broker-firm-card @wire-Apex template. Single data source:
 *   @wire(getOutreachSummary, { dispositionId: '$recordId' })
 * The whole card is gated behind if:true={summary}, so the pre-emit state
 * renders nothing; getOutreachSummary.emit(summary) drives the data branch.
 *
 * Values are derived in getters (date formatting, "N of M" responses, the NDA
 * pill), so assertions read the child c-onboarding-card-child props + DOM text
 * rather than raw wire output.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE NDA PILL IS NOW REAL DATA (it used to be a hard-coded 'Signed')
 * ─────────────────────────────────────────────────────────────────────────────
 * `_ndaStatus = 'Signed'` reported a COMPLIANCE state as satisfied on every
 * disposition, whether or not an NDA existed. The pill now renders
 * summary.ndaStatus, which BovController populates from the disposition's most
 * recent NDA__c.
 *
 * 🔴 The load-bearing case is the NULL one: Apex returns null both when there is
 * genuinely no NDA and when the NDA read degraded (BovController fails that read
 * soft so a missing FLS grant cannot blank the whole tile). Both must render
 * 'No NDA'. A test that only covered the happy 'Signed' path would have passed
 * against the hard-coded version too, which is exactly how the defect survived.
 */
import { createElement } from 'lwc';
import BovOutreach from 'c/bovOutreach';
import getOutreachSummary from '@salesforce/apex/BovController.getOutreachSummary';

jest.mock(
    '@salesforce/apex/BovController.getOutreachSummary',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const SUMMARY = {
    assetName: 'Oak Plaza',
    matrixGenerated: true,
    packageSent: '2026-02-10',
    submissionDeadline: '2026-03-01',
    responsesReceived: 4,
    brokersContacted: 6,
    selectedBroker: 'Colliers International',
    ndaStatus: 'Signed'
};

describe('c-bov-outreach', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-bov-outreach', { is: BovOutreach });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders nothing until the summary wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card')).toBeNull();
    });

    it('DATA BRANCH: renders the asset title, matrix badge and four stat cards', async () => {
        const element = createComponent();

        getOutreachSummary.emit(SUMMARY);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.card-title').textContent
        ).toBe('BOV Outreach — Oak Plaza');

        expect(element.shadowRoot.querySelector('.matrix-badge')).not.toBeNull();

        const cards = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('Feb 10, 2026'); // Package Sent
        expect(cards[1].value).toBe('Mar 1, 2026'); //  Submission Deadline
        expect(cards[2].value).toBe('4 of 6'); //        Responses Received
        expect(cards[3].value).toBe('Colliers International'); // Selected Broker
    });

    it('DATA BRANCH: hides the matrix badge when the matrix is not generated', async () => {
        const element = createComponent();

        getOutreachSummary.emit({ ...SUMMARY, matrixGenerated: false });
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.matrix-badge')).toBeNull();
    });

    it('NDA PILL: renders the real Signed status from the wire', async () => {
        const element = createComponent();

        getOutreachSummary.emit(SUMMARY);
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('.nda-pill');
        expect(pill.textContent).toContain('Signed');
        expect(pill.className).toContain('nda-signed');
    });

    it('NDA PILL: a Pending NDA renders Pending, not Signed', async () => {
        const element = createComponent();

        getOutreachSummary.emit({ ...SUMMARY, ndaStatus: 'Pending' });
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('.nda-pill');
        expect(pill.textContent).toContain('Pending');
        expect(pill.textContent).not.toContain('Signed');
        expect(pill.className).toContain('nda-pending');
    });

    it('NDA PILL: a Sent NDA renders Sent on the amber style', async () => {
        const element = createComponent();

        getOutreachSummary.emit({ ...SUMMARY, ndaStatus: 'Sent' });
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('.nda-pill');
        expect(pill.textContent).toContain('Sent');
        // The CSS class names predate the picklist; 'Sent' maps to nda-received.
        expect(pill.className).toContain('nda-received');
    });

    /**
     * 🔴 THE DEFECT FENCE. null means "no NDA yet" (or a degraded NDA read) and MUST NOT
     * render 'Signed'. If someone reintroduces a default on the client, this goes red.
     */
    it('NDA PILL: a null status renders "No NDA" and never Signed', async () => {
        const element = createComponent();

        getOutreachSummary.emit({ ...SUMMARY, ndaStatus: null });
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('.nda-pill');
        expect(pill.textContent).toContain('No NDA');
        expect(pill.textContent).not.toContain('Signed');
        expect(pill.className).toContain('nda-pending');
    });

    /**
     * An unrecognised status (a value added to NDA__c.Status__c later, e.g. D7's
     * 'Declined') must still render its own text on the neutral style rather than an
     * unstyled pill or a stale colour.
     */
    it('NDA PILL: an unknown status renders its own text on the neutral style', async () => {
        const element = createComponent();

        getOutreachSummary.emit({ ...SUMMARY, ndaStatus: 'Declined' });
        await Promise.resolve();

        const pill = element.shadowRoot.querySelector('.nda-pill');
        expect(pill.textContent).toContain('Declined');
        expect(pill.className).toContain('nda-pending');
    });

    it('ERROR BRANCH: renders an error card instead of the summary when the wire errors', async () => {
        const element = createComponent();

        getOutreachSummary.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.card-title')).toBeNull();
        const err = element.shadowRoot.querySelector('.error-card');
        expect(err).not.toBeNull();
        expect(err.textContent).toBe("Couldn't load the BOV outreach summary.");
    });

    it('is accessible', async () => {
        const element = createComponent();

        getOutreachSummary.emit(SUMMARY);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
