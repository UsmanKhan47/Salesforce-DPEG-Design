/**
 * c-portfolio-deal-siblings — @wire-to-Apex suite WITH NavigationMixin.
 * Pattern: WIRE-MOCK TEMPLATE 1 (Apex @wire) + the lwc-recipes navigation mock, matching
 * c-recent-leads and c-broker-scorecard.
 *
 * Data source: @wire(getSiblingRecords, { recordId: '$recordId' }) from
 * PortfolioDealController.getSiblingRecords. The server does the object dispatch, so THIS SUITE
 * NEVER MOCKS A SCHEMA IMPORT — there is none to mock, which is itself the design under test.
 *
 * ⚠ RENAMED IN PHASE B4 — this suite was `packageSiblings.test.js` against `c/packageSiblings` and
 * `PropertyPackageController.getSiblingRecords`. Both the bundle and the Apex class moved with the
 * object rename `Property_Package__c` -> `Portfolio_Deal__c`. A stale `jest.mock` path would still
 * register as a virtual module and the suite would go green while the component imported something
 * else entirely, so the mock path and the import are edited together, always.
 *
 * lightning/navigation is mocked at the MODULE level so [Navigate] dispatches a catchable
 * 'navigate' event carrying the PageReference. An instance spy cannot work here: the sfdx-lwc-jest
 * stub's Navigate is a no-op, and the host element and the component instance are different
 * objects, so an override on the element never sees the call.
 *
 * 🔴 THE MOST IMPORTANT TEST IN THIS FILE IS THE FIRST ONE — "renders nothing". Every other state
 * is visible to a human the moment they open a record page; the invisible state is the one that
 * regresses silently, and it is the state MOST records in the org are in.
 */
import { createElement } from 'lwc';
import PortfolioDealSiblings from 'c/portfolioDealSiblings';
import getSiblingRecords from '@salesforce/apex/PortfolioDealController.getSiblingRecords';

jest.mock(
    'lightning/navigation',
    () => {
        const Navigate = Symbol('Navigate');
        const GenerateUrl = Symbol('GenerateUrl');
        const NavigationMixin = (Base) =>
            class extends Base {
                [Navigate](pageReference) {
                    this.dispatchEvent(
                        new CustomEvent('navigate', { detail: { pageReference } })
                    );
                }
                [GenerateUrl]() {
                    return Promise.resolve('https://example.com/record');
                }
            };
        NavigationMixin.Navigate = Navigate;
        NavigationMixin.GenerateUrl = GenerateUrl;
        return { NavigationMixin };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PortfolioDealController.getSiblingRecords',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const LEAD_ID = '00Q000000000001';
const SIBLING_LEAD_ID = '00Q000000000002';
const SIBLING_OPP_ID = '006000000000001';
const DEAL_ID = 'a0Z000000000001';

// 🔴 THE THREE `portfolioDeal*` KEYS BELOW ARE COPIED FROM
// `PortfolioDealController.PortfolioDealSiblings`, NOT CHOSEN HERE, AND THAT IS THE ONE THING IN
// THIS FILE A GREEN RUN CANNOT PROVE. These fixtures DEFINE the payload locally, so a key that
// disagrees with the Apex DTO makes the component read `undefined` — which is its normal, invisible
// "no portfolio deal" state — and every test in this suite still passes while the card is dead in
// the org. They were `packageId` / `packageName` / `packageUrl` before phase B4. Check them against
// the Apex source, not against this suite.
//
// A three-member portfolio deal viewed from one of its Leads: the server has already excluded the
// anchor, so the payload carries the OTHER two.
const WITH_SIBLINGS = {
    portfolioDealId: DEAL_ID,
    portfolioDealName: 'FW: Three-property portfolio',
    portfolioDealUrl: `/lightning/r/Portfolio_Deal__c/${DEAL_ID}/view`,
    siblings: [
        {
            id: SIBLING_LEAD_ID,
            name: '1002 Multi St',
            objectLabel: 'Lead',
            recordUrl: `/lightning/r/Lead/${SIBLING_LEAD_ID}/view`,
            status: 'New'
        },
        {
            id: SIBLING_OPP_ID,
            name: '1003 Multi St',
            objectLabel: 'Opportunity',
            recordUrl: `/lightning/r/Opportunity/${SIBLING_OPP_ID}/view`,
            status: 'Underwriting'
        }
    ]
};

// The overwhelmingly common case: this record came from a single-property email.
const NO_DEAL = {
    portfolioDealId: null,
    portfolioDealName: null,
    portfolioDealUrl: null,
    siblings: []
};

// Design residual R6: a multi-property email whose other properties failed to route.
const DEAL_WITH_NO_SIBLINGS = {
    portfolioDealId: DEAL_ID,
    portfolioDealName: 'FW: only one routed',
    portfolioDealUrl: `/lightning/r/Portfolio_Deal__c/${DEAL_ID}/view`,
    siblings: []
};

function card(element) {
    return element.shadowRoot.querySelector('lightning-card');
}

function siblingLinks(element) {
    return element.shadowRoot.querySelectorAll('.pds-link');
}

describe('c-portfolio-deal-siblings', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-portfolio-deal-siblings', {
            is: PortfolioDealSiblings
        });
        element.recordId = LEAD_ID;
        element.objectApiName = 'Lead';
        document.body.appendChild(element);
        return element;
    }

    it('NO PORTFOLIO DEAL: renders NOTHING AT ALL — not an empty card', async () => {
        // 🔴 THE HEADLINE BEHAVIOUR. This component sits on every Lead and every Opportunity record
        // page, and most records came from a single-property email. An empty card here would be
        // permanent visual noise on the majority of pages in the org — which is why the assertion is
        // on the ABSENCE of the lightning-card, not on its contents being empty.
        const element = createComponent();

        getSiblingRecords.emit(NO_DEAL);
        await Promise.resolve();

        expect(card(element)).toBeNull();
        expect(element.shadowRoot.textContent.trim()).toBe('');
    });

    it('BEFORE THE WIRE EMITS: renders nothing, so no card flashes in and out', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(card(element)).toBeNull();
    });

    it('DATA BRANCH: renders the portfolio deal heading and one row per sibling', async () => {
        const element = createComponent();

        getSiblingRecords.emit(WITH_SIBLINGS);
        await Promise.resolve();

        expect(card(element)).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('span[slot="title"]').textContent
        ).toBe('Portfolio Deal (2)');

        // The heading links to the deal itself, using the SERVER-BUILT url.
        const dealLink = element.shadowRoot.querySelector('.pds-line a');
        expect(dealLink.textContent).toBe('FW: Three-property portfolio');
        expect(dealLink.getAttribute('href')).toBe(
            `/lightning/r/Portfolio_Deal__c/${DEAL_ID}/view`
        );

        const links = siblingLinks(element);
        expect(links.length).toBe(2);
        expect(links[0].textContent).toBe('1002 Multi St');
        expect(links[0].getAttribute('href')).toBe(
            `/lightning/r/Lead/${SIBLING_LEAD_ID}/view`
        );
        expect(links[1].getAttribute('href')).toBe(
            `/lightning/r/Opportunity/${SIBLING_OPP_ID}/view`
        );
    });

    it('DATA BRANCH: shows each row\'s object label and state, both supplied by the server', async () => {
        // The labels come from Apex precisely so this component never derives an object name. A
        // Lead row and an Opportunity row must be distinguishable to a human WITHOUT the client
        // knowing either object exists.
        const element = createComponent();

        getSiblingRecords.emit(WITH_SIBLINGS);
        await Promise.resolve();

        const meta = element.shadowRoot.querySelectorAll('.pds-meta');
        expect(meta.length).toBe(2);
        expect(meta[0].textContent).toContain('Lead');
        expect(meta[0].textContent).toContain('New');
        expect(meta[1].textContent).toContain('Opportunity');
        expect(meta[1].textContent).toContain('Underwriting');
    });

    it('NAVIGATION: clicking a sibling navigates to that record by Id alone', async () => {
        // ⚠ The page reference carries recordId and NO objectApiName — standard__recordPage resolves
        // the object from the Id itself, which is what keeps this component object-agnostic. A
        // pageReference that named an object would mean the client had to know which one.
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSiblingRecords.emit(WITH_SIBLINGS);
        await Promise.resolve();

        siblingLinks(element)[1].click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        const pageRef = navHandler.mock.calls[0][0].detail.pageReference;
        expect(pageRef.type).toBe('standard__recordPage');
        expect(pageRef.attributes.recordId).toBe(SIBLING_OPP_ID);
        expect(pageRef.attributes.actionName).toBe('view');
        expect(pageRef.attributes.objectApiName).toBeUndefined();
    });

    it('NAVIGATION: clicking the deal heading navigates to the portfolio deal record', async () => {
        const element = createComponent();
        const navHandler = jest.fn();
        element.addEventListener('navigate', navHandler);

        getSiblingRecords.emit(WITH_SIBLINGS);
        await Promise.resolve();

        element.shadowRoot.querySelector('.pds-line a').click();

        expect(navHandler).toHaveBeenCalledTimes(1);
        expect(
            navHandler.mock.calls[0][0].detail.pageReference.attributes.recordId
        ).toBe(DEAL_ID);
    });

    it('R6: a deal whose only member is this record still renders, with an explanation', async () => {
        // Deliberately NOT hidden. It is TRUE that this record arrived on a multi-property email,
        // and the deal link is the route to the routing audit that says where the rest went.
        const element = createComponent();

        getSiblingRecords.emit(DEAL_WITH_NO_SIBLINGS);
        await Promise.resolve();

        expect(card(element)).not.toBeNull();
        expect(siblingLinks(element).length).toBe(0);
        expect(element.shadowRoot.textContent).toContain(
            'No other records were created from this email.'
        );
    });

    it('ERROR BRANCH: renders the server message in an alert and hides the list', async () => {
        // ⚠ THIS BRANCH EXISTS BECAUSE SILENCE IS AMBIGUOUS HERE. A blank card would be
        // indistinguishable from the very common "no portfolio deal" state, so a genuine failure
        // would never be noticed. role="alert" is what makes it reach a screen reader too.
        const element = createComponent();

        // ⚠ The test wire adapter's `error(...)` takes the BODY as its first argument and wraps it
        // as `{ body, ok, status, statusText }` itself — the same call shape c-recent-leads' suite
        // uses. Passing a pre-wrapped `{ body: ... }` object silently produces `body.body.message`,
        // so the component reads undefined and falls back, and the test then "passes" against the
        // generic message while proving nothing about the server's own wording.
        getSiblingRecords.error({
            message: 'The related properties could not be loaded.'
        });
        await Promise.resolve();

        expect(card(element)).not.toBeNull();
        const err = element.shadowRoot.querySelector('.lv-error');
        expect(err).not.toBeNull();
        expect(err.getAttribute('role')).toBe('alert');
        expect(err.textContent.trim()).toBe(
            'The related properties could not be loaded.'
        );
        expect(siblingLinks(element).length).toBe(0);
    });

    it('ERROR BRANCH: falls back to a generic message when the error carries no message', async () => {
        // A body with no `message` is the real shape of the case the fallback exists for (a transport
        // failure, or a platform error the adapter shapes differently). ⚠ `error()` with NO argument
        // is deliberately not used: the adapter substitutes its own default body ("An internal server
        // error has occurred"), so that call tests the MOCK's wording, not this component's fallback.
        //
        // ⚠ THIS WORDING IS DELIBERATELY *NOT* IN THE RENAME'S SCOPE. It says "the related
        // properties", not "the portfolio deal", because that is what the card shows the user — the
        // OTHER properties from their email. `PortfolioDealController.READ_FAILURE_MESSAGE` is its
        // server-side twin and is likewise NOT in lockstep with the homepage widget's message.
        const element = createComponent();

        getSiblingRecords.error({});
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent.trim()
        ).toBe('Unable to load the related properties.');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSiblingRecords.emit(WITH_SIBLINGS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible in the error state', async () => {
        const element = createComponent();

        // ⚠ BODY-SHAPED, per the note on the first ERROR BRANCH test above: `error(...)` wraps its
        // argument AS the body. A pre-wrapped `{ body: { message } }` gives `body.body.message`, so
        // the component would fall through to its generic fallback and this would silently assert
        // accessibility of the WRONG branch — the fallback, not the server-message one.
        getSiblingRecords.error({ message: 'Nope.' });
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.lv-error').textContent.trim()
        ).toBe('Nope.');
        await expect(element).toBeAccessible();
    });
});
