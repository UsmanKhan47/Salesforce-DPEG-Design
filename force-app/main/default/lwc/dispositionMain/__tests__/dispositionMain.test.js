/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord)
 * ---------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-main is a
 * single-field router: it reads Disposition__c.Disposition_Stage__c via
 * getRecord + getFieldValue and swaps which feature child renders. So there is
 * NO jest.mock() for LDS — just getRecord.emit(record) with a UI-API record whose
 * fields use the REAL Disposition__c field API name.
 *
 * ⚠ THE TERMINAL STAGE IS 'Sale Closes', NOT 'Completed'. The disposition flow
 * redesign RETIRED 'Completed' (along with 'Call for Offers' and 'Disposition
 * Offer'), so this suite no longer emits it. A fixture that kept emitting a
 * retired value would keep PASSING while proving nothing — the branch simply
 * never fires for a value the org can no longer produce.
 *
 * The child feature components (bov matrix, broker listing, wire verification,
 * closing tasks, ...) render idle: their un-mocked Apex resolves to the
 * transformer's default Promise.resolve() stub, so they mount in an empty state
 * rather than throwing. Assertions check WHICH child slot appears per stage.
 * The accessibility assertion runs against the empty (no-stage) state, which is a
 * guaranteed axe-clean target (matches the headless c-submit-for-approval
 * precedent) and does not depend on grandchild markup.
 */
import { createElement } from 'lwc';
import DispositionMain from 'c/dispositionMain';
import { getRecord } from 'lightning/uiRecordApi';

const RECORD_ID = 'a0D5g000000DispEAG';

function recordForStage(stage) {
    return {
        apiName: 'Disposition__c',
        id: RECORD_ID,
        fields: { Disposition_Stage__c: { value: stage } }
    };
}

describe('c-disposition-main', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-main', {
            is: DispositionMain
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders no feature child before the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
    });

    it('BOV Outreach stage renders the comparison matrix only', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).toBeNull();
    });

    it('🔴 BOV Outreach renders the matrix bundle TWICE — preferred card FIRST, then the matrix', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('BOV Outreach'));
        await Promise.resolve();

        const matrices = [
            ...element.shadowRoot.querySelectorAll('c-bov-comparison-matrix')
        ];

        // 🔴 TWO, AND THE ORDER IS THE REQUIREMENT. The preferred-broker card
        // renders ABOVE the comparison matrix. `querySelectorAll` returns
        // document order, so index 0 IS the top card — the test that used
        // `querySelector` above would pass with the tags in either order, or
        // with only one of them present.
        expect(matrices).toHaveLength(2);

        // ⚠ ASSERTED ON THE RENDERED ELEMENT'S PROPERTIES. `preferred-only` and
        // `hide-actions` are written as BARE attributes in the template; this is
        // the assertion that proves LWC resolves a valueless attribute on a
        // custom element to boolean `true` and not to the empty string — which
        // is FALSY, and would have silently turned the top card back into a
        // second copy of the matrix, buttons and all.
        expect(matrices[0].preferredOnly).toBe(true);
        expect(matrices[0].hideActions).toBe(true);
        expect(matrices[0].recordId).toBe(RECORD_ID);

        // The existing tag is untouched: both flags fall back to their `false`
        // defaults, which is what makes the second instance provably unchanged.
        expect(matrices[1].preferredOnly).toBe(false);
        expect(matrices[1].hideActions).toBe(false);
        expect(matrices[1].recordId).toBe(RECORD_ID);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 RELEASE MATERIALS (2026-08-24) — the response logger
    //
    // This tag is the ONLY route to creating a `Release_Materials_Response__c`:
    // the object ships with no tab and no list view. Removing the line does not
    // hide a feature, it deletes the only way in.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 Release Materials stage renders the response logger, and only it', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Release Materials'));
        await Promise.resolve();

        const logger = element.shadowRoot.querySelector(
            'c-release-materials-response-log'
        );
        expect(logger).not.toBeNull();
        // ⚠ THE CHILD HAS NO OTHER ROUTE TO THE DISPOSITION. Without record-id
        // it wires `undefined`, its Apex returns a fully-populated EMPTY context
        // rather than throwing, and the card renders a permanent, confident
        // "No responses yet" that nothing on the page contradicts.
        expect(logger.recordId).toBe(RECORD_ID);

        // No other stage's children leak into this branch.
        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-broker-listing')).toBeNull();
        expect(element.shadowRoot.querySelector('c-wire-verification')).toBeNull();
    });

    it('🔴 the response logger appears at NO other stage', async () => {
        // ⚠ EXHAUSTIVE OVER EVERY OTHER VALUE OF Disposition_Stage__c, not a
        // sample. A near-miss in the getter's string comparison ('Release
        // materials', an underscore, a trailing space) fails SILENTLY — the
        // branch simply never fires — so the falsifier that matters is the
        // POSITIVE test above. This one catches the opposite mistake: a getter
        // widened to a `includes`/truthiness test that fires everywhere.
        const otherStages = [
            'Disposition Readiness',
            'BOV Outreach',
            'Broker Selection',
            'NDA',
            'Active Listing',
            'Offer Selection',
            'LOI',
            'PSA',
            'Closing',
            'Sale Closes'
        ];

        for (const stage of otherStages) {
            const element = createComponent();
            getRecord.emit(recordForStage(stage));
            // eslint-disable-next-line no-await-in-loop
            await Promise.resolve();

            expect(
                element.shadowRoot.querySelector('c-release-materials-response-log')
            ).toBeNull();
            document.body.removeChild(element);
        }
    });

    it('Active Listing stage renders the broker-listing cluster', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-backup-brokers')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
    });

    it('🔴 renders NO call-for-offers card at Active Listing — the UAT removal must not come back', async () => {
        // DELIBERATE ABSENCE PIN (UAT 2026-08-21: "also remove call for offers lwc, we
        // don't need to show"). The positive assertion that used to prove
        // c-disposition-call-for-offers rendered here was DELETED, not weakened — this
        // replaces it, and it is the only thing standing between a one-line re-add of the
        // tag in dispositionMain.html and it silently shipping. The bundle still exists in
        // lwc/, so the re-add is genuinely one line.
        //
        // ⚠ THE FIXTURE IS THE POPULATED ONE ON PURPOSE. 'Active Listing' is the exact
        // stage the card used to render at; an absence assertion against the pre-wire
        // empty state would pass for the wrong reason. The two not-toBeNull() checks below
        // exist to PROVE the block actually rendered, so the absence below means "the card
        // is gone" and not "nothing rendered at all".
        //
        // ⚠ SUBSTRING MATCH ON TAG NAMES, NOT A SINGLE querySelector, AND NOT textContent.
        // textContent would be VACUOUS here: c-disposition-main is a router whose children
        // are custom elements with their own shadow roots, so the host's textContent never
        // contains their copy whether they render or not. Tag names are what this component
        // actually controls. The substring also catches the OPPORTUNITY-scoped
        // c-call-for-offers-list / c-call-for-offers-panel, which are out of scope for the
        // disposition module and are the likeliest wrong thing for someone to reach for.
        const element = createComponent();

        getRecord.emit(recordForStage('Active Listing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-broker-listing')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-backup-brokers')
        ).not.toBeNull();

        const renderedTags = Array.from(
            element.shadowRoot.querySelectorAll('*')
        ).map((el) => el.tagName.toLowerCase());

        expect(renderedTags.length).toBeGreaterThan(0);
        expect(
            renderedTags.filter((tag) => tag.includes('call-for-offers'))
        ).toEqual([]);
    });

    it('Closing stage renders wire verification + the closing checklist', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Closing'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).not.toBeNull();
    });

    it('Sale Closes stage still shows the closing cards (finished-deal view)', async () => {
        const element = createComponent();

        getRecord.emit(recordForStage('Sale Closes'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).not.toBeNull();
    });

    it('RETIRED VALUE: the old terminal stage routes NOWHERE', async () => {
        // 'Completed' was removed from Disposition_Stage__c and existing rows
        // migrated off it. This is the falsifier for the isClosing rewrite: if
        // someone re-adds it to the getter "to be safe", this test reds. A test
        // that merely stopped mentioning it would not.
        const element = createComponent();

        getRecord.emit(recordForStage('Completed'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing-tasks')
        ).toBeNull();
    });

    it('ERROR BRANCH: renders an inline error state and no feature child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-bov-comparison-matrix')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-wire-verification')
        ).toBeNull();
        expect(
            element.shadowRoot.querySelector('.wire-error')
        ).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
