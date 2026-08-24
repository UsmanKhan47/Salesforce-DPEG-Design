/**
 * WIRE-MOCK TEMPLATE — @wire to LDS (getRecord), stage + SPANNING record type
 * ---------------------------------------------------------------------------
 * Follows the c-transaction-critical-dates LDS template. c-disposition-sidebar
 * reads TWO things off ONE `getRecord`: `Disposition__c.Disposition_Stage__c`
 * (required) and `Disposition__c.RecordType.DeveloperName` (optional). No
 * jest.mock() for LDS; `getRecord.emit(record)` drives the branch and
 * `getRecord.error()` the fallback. The accessibility check runs on the empty
 * state (guaranteed axe-clean).
 *
 * Note: unlike c-disposition-main, isClosing here is true ONLY for the 'Closing'
 * stage, so the terminal stage ('Sale Closes') renders no child — asserted below.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE OFFER CARD IS RECORD-TYPE AWARE SINCE 2026-08-25 — AND THIS HEADER HAS
 *    NOW BEEN WRONG ABOUT THAT TWICE. READ BOTH CORRECTIONS.
 * ─────────────────────────────────────────────────────────────────────────────
 * CORRECTION 1 (dead). This header once said the two record types' stage value
 * sets "are DISJOINT for every path-specific stage — 'Call for Offers' is
 * On_Market only and 'Disposition Offer' is Off_Market only — so the stage alone
 * identifies the path". Both values were REMOVED from Disposition_Stage__c, and
 * the premise inverted: 'Broker Selection', 'Release Materials', 'Offer
 * Selection' and 'Sale Closes' are on BOTH record types.
 *
 * CORRECTION 2 (dead). Its replacement said there was STILL no record-type wire
 * because "the four offer stages render the SAME card with the SAME meaning on
 * both paths, so a stage alone is all these fixtures need". FALSE for exactly one
 * of them. 'Release Materials' is on both record types but only means "offers
 * arrive here" OFF-market; on the on-market path it merely precedes 'Active
 * Listing'. CONFIRMED LIVE: DISP-0023 is On_Market, sits at Release Materials,
 * and was showing the offers card.
 *
 * 🔴 SO EVERY OFFER-STAGE FIXTURE NOW CARRIES A RECORD TYPE, and 'Release
 * Materials' is asserted BOTH WAYS. A fixture that names only a stage can no
 * longer express what this component does.
 *
 * ⚠ THE SPANNING FIXTURE SHAPE IS MEASURED, NOT INVENTED. Verified against the
 * live org's UI API on 2026-08-25 for DISP-0023:
 *     fields.RecordType.value.fields.DeveloperName.value === 'On_Market'
 * A flatter shape (`fields: { RecordType: { value: 'On_Market' } }`) would make
 * `getFieldValue` return an object and every assertion here green while the
 * production read returns undefined. The stub's getFieldValue walks
 * `r.fields[f].value` per segment exactly like the real one — so the nesting is
 * the test.
 *
 * ⚠ AND THE LABEL IS NOT THE DEVELOPER NAME. The same measurement showed
 * `getRecord`'s free `data.recordTypeInfo.name` is "On Market" (a space), not
 * "On_Market". The component deliberately does not use it — see its constant.
 *
 * 🔴 RETIRED VALUES ARE ASSERTED TO ROUTE NOWHERE rather than simply dropped from
 * the suite. A fixture that stops mentioning a removed value proves nothing; one
 * that asserts the branch does NOT fire is a falsifier for anyone who re-adds it
 * "to be safe". (Passing tests are not evidence a removal sweep was complete —
 * an LWC fixture is the blind spot of a picklist retirement.)
 *
 * 🔴 'PSA' is asserted to render NOTHING, on purpose (Gate 1 Q5 = no placeholder).
 * At PSA the only marker is PSA_Executed__c on the Disposition itself and the
 * record page falls back to its Details section. That is a decision, not a gap.
 */
import { createElement } from 'lwc';
import DispositionSidebar from 'c/dispositionSidebar';
import { getRecord } from 'lightning/uiRecordApi';

const RECORD_ID = 'a0D5g000000DispEAG';
const ON_MARKET = 'On_Market';
const OFF_MARKET = 'Off_Market';

/**
 * Builds the record the wire emits.
 *
 * ⚠ `recordType` DEFAULTS TO undefined AND THAT CASE OMITS THE RecordType KEY
 * ENTIRELY — it is not a convenience, it is the third state the component has to
 * survive: an `optionalFields` entry the running user cannot read comes back
 * ABSENT, not null. See the "record type unreadable" test.
 */
function recordFor(stage, recordType) {
    const fields = { Disposition_Stage__c: { value: stage } };
    if (recordType !== undefined) {
        fields.RecordType = {
            value: { fields: { DeveloperName: { value: recordType } } }
        };
    }
    return { apiName: 'Disposition__c', id: RECORD_ID, fields };
}

/**
 * The record type's `.recordType-meta.xml` source.
 *
 * ⚠ `require`, NEVER an ESM `import { readFileSync } from 'fs'` — the LWC compiler
 * rejects that with LWC1702, surfaced in the editor as an error with an EMPTY
 * message. Every source-text pin in this repo uses this form.
 */
function recordTypeXml(recordType) {
    return require('fs').readFileSync(
        require('path').join(
            __dirname, '..', '..', '..', 'objects', 'Disposition__c',
            'recordTypes', `${recordType}.recordType-meta.xml`
        ),
        'utf8'
    );
}

/**
 * The stage values that record type can actually hold, read from the metadata.
 *
 * 🔴 DERIVED, NOT HAND-LISTED, AND THAT IS LOAD-BEARING FOR THE SWEEP BELOW. A
 * hand-written grid would enumerate combinations the platform forbids —
 * `Disposition_Stage__c` is `<restricted>true</restricted>` and record-type
 * value-set scoping is enforced by DML in this org, so 'Active Listing' on
 * Off_Market is not a state to assert about, it is a state that cannot exist. My
 * first draft asserted it and failed, which is the trap this helper closes.
 *
 * ⚠ SCOPED TO THE Disposition_Stage__c BLOCK. `Disposition__c` has a second
 * picklist (`Sell_Decision_Trigger__c`) in the same file, so an unscoped
 * `<fullName>` scrape would return 'Fund Maturity' as a stage.
 */
function stageValuesFor(recordType) {
    const xml = recordTypeXml(recordType);
    const start = xml.indexOf('<picklist>Disposition_Stage__c</picklist>');
    expect(start).toBeGreaterThan(-1);
    const block = xml.slice(start, xml.indexOf('</picklistValues>', start));
    return [...block.matchAll(/<fullName>([^<]+)<\/fullName>/g)].map((m) => m[1]);
}

describe('c-disposition-sidebar', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-disposition-sidebar', {
            is: DispositionSidebar
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const offerCard = (element) =>
        element.shadowRoot.querySelector('c-disposition-offer');

    /** Mounts, emits one record, and returns after the re-render. */
    async function renderAt(stage, recordType) {
        const element = createComponent();
        getRecord.emit(recordFor(stage, recordType));
        await Promise.resolve();
        return element;
    }

    it('renders no sidebar child before the record wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(offerCard(element)).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE WIRE CONFIG ITSELF
    //
    // ⚠ THIS PIN CANNOT BE FOLDED INTO THE RENDER TESTS, AND DELETING IT AS
    // "redundant" IS THE MISTAKE IT EXISTS TO PREVENT. `getRecord.emit(fixture)`
    // hands the component the WHOLE fixture regardless of what the @wire config
    // asked for, so removing `optionalFields: [RECORD_TYPE_FIELD]` from the
    // component leaves every render test below green — while in production the
    // record type comes back undefined, `isOnMarket` is false forever, and the
    // On-Market bug this change fixes silently returns.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 WIRE CONFIG: the stage is required and the record type rides along as an OPTIONAL field', async () => {
        createComponent();

        await Promise.resolve();

        const config = getRecord.getLastConfig();
        // ⚠ A SCHEMA IMPORT RESOLVES TO AN OBJECT IN JEST, NOT TO THE DOTTED
        // STRING — `{ objectApiName, fieldApiName }`. Asserting the string form
        // fails for the wrong reason and reads like a missing field.
        expect(config.fields).toEqual([
            { objectApiName: 'Disposition__c', fieldApiName: 'Disposition_Stage__c' }
        ]);
        // 🔴 optionalFields, NOT fields. An unreadable field in `fields` throws
        // the WHOLE wire into its error branch and would replace every stage's
        // sidebar with the error banner; in optionalFields it simply comes back
        // absent and the card degrades to its pre-2026-08-25 behaviour.
        // 🔴 AND THE SPANNING PATH IS PART OF THE CLAIM. `RecordType.Name` or a
        // bare `RecordTypeId` here would both be readable and both wrong: the
        // first is the renameable LABEL, the second an org-specific Id.
        expect(config.optionalFields).toEqual([
            {
                objectApiName: 'Disposition__c',
                fieldApiName: 'RecordType.DeveloperName'
            }
        ]);
        // ⚠ AND IT IS ONE WIRE. The brief for this change was explicit: no second
        // wire and no Apex call for one field.
        expect(getRecord.getLastConfig().recordId).toBe(RECORD_ID);
    });

    it('BOV Outreach stage renders the outreach panel only', async () => {
        const element = await renderAt('BOV Outreach', ON_MARKET);

        expect(
            element.shadowRoot.querySelector('c-bov-outreach')
        ).not.toBeNull();
        expect(offerCard(element)).toBeNull();
    });

    it('Active Listing stage renders the disposition-offer panel only', async () => {
        const element = await renderAt('Active Listing', ON_MARKET);

        expect(offerCard(element)).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 RELEASE MATERIALS IS THE WHOLE POINT OF THE 2026-08-25 CHANGE
    //
    // The stage exists on BOTH record types and means something different on
    // each. Asserted both ways, each on its own, so a failure names the path.
    // ═════════════════════════════════════════════════════════════════════════

    it('🔴 Release Materials + OFF_MARKET renders the offers card — off-market offers arrive here', async () => {
        const element = await renderAt('Release Materials', OFF_MARKET);

        expect(offerCard(element)).not.toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('🔴 Release Materials + ON_MARKET renders NO offers card — nothing is listed yet (DISP-0023)', async () => {
        const element = await renderAt('Release Materials', ON_MARKET);

        // The reported defect, stated as a falsifier. On the on-market path this
        // stage precedes 'Active Listing'; no offer can have arrived, so the card
        // was showing an empty list that read as "no offers" rather than as "not
        // yet". Deleting the record-type test in `isOfferStage` reds HERE.
        expect(offerCard(element)).toBeNull();
        // ⚠ AND NOTHING ELSE TAKES ITS PLACE. On-market Release Materials is a
        // deliberate no-sidebar stage, not a stage that swapped one card for
        // another — the response log lives in the MAIN region (c/dispositionMain).
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
    });

    it('🔴 Release Materials with the record type UNREADABLE falls back to SHOWING the card', async () => {
        // An `optionalFields` entry the running user cannot read comes back
        // absent, so `_recordType` is undefined and `isOnMarket` is false.
        const element = await renderAt('Release Materials', undefined);

        // 🔴 THIS IS THE DELIBERATE FAIL-SAFE DIRECTION, NOT AN ACCIDENT OF THE
        // COMPARISON. Of the two ways to be wrong, showing an on-market card one
        // stage early is recoverable; hiding the off-market card removes the only
        // route to the offers that genuinely arrive at this stage. Inverting
        // `isOnMarket` to a `=== 'Off_Market'` test reds here.
        expect(offerCard(element)).not.toBeNull();
    });

    it('Offer Selection renders the disposition-offer panel on BOTH paths — a rejected offer parks here for a RE-PICK', async () => {
        const onMarket = await renderAt('Offer Selection', ON_MARKET);
        expect(offerCard(onMarket)).not.toBeNull();

        const offMarket = await renderAt('Offer Selection', OFF_MARKET);
        expect(offerCard(offMarket)).not.toBeNull();
    });

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE selected-only MODE FLAG (2026-08-24)
    //
    // At Offer Selection the card must render ONLY the offer that went for
    // approval, with "+ Log Offer" disabled. This component owns that decision —
    // see `isOfferSelection` in the JS for why it is not made in the card or on
    // the server — so these are the falsifiers for the WIRING. The card's own
    // behaviour under the flag is proved in lwc/dispositionOffer/__tests__.
    //
    // 🔴 ASSERTED ON THE RENDERED CHILD ELEMENT, NOT ON THE GETTER. Reading
    // `element.isOfferSelection` would prove the getter computes and prove nothing
    // about the template: deleting `selected-only={isOfferSelection}` from the tag
    // leaves the getter perfectly correct and the feature completely dead.
    //
    // 🔴 `toBe(true)` / `toBe(false)`, NEVER TRUTHINESS. `selected-only=""` — one
    // character from the correct markup — passes the EMPTY STRING, which is falsy
    // and silently restores the old behaviour. A truthiness assertion would also
    // pass on the string "true", which works only by accident.
    // ═════════════════════════════════════════════════════════════════════════

    it.each([ON_MARKET, OFF_MARKET])(
        '🔴 Offer Selection on %s puts the offers card in SELECTED-ONLY mode',
        async (recordType) => {
            const element = await renderAt('Offer Selection', recordType);

            const card = offerCard(element);
            expect(card).not.toBeNull();
            expect(card.selectedOnly).toBe(true);
        }
    );

    it.each([
        ['Active Listing', ON_MARKET],
        ['Release Materials', OFF_MARKET],
        ['LOI', ON_MARKET],
        ['LOI', OFF_MARKET]
    ])(
        '🔴 %s on %s leaves the offers card in its DEFAULT mode — every offer, Log Offer enabled',
        async (stage, recordType) => {
            const element = await renderAt(stage, recordType);

            const card = offerCard(element);
            expect(card).not.toBeNull();
            // The whole scoping claim of this change, per stage. `toBe(false)` and
            // not `toBeFalsy()`: `undefined` would ALSO be falsy and would also
            // behave correctly today, but it is not what the binding promises, and
            // accepting it here would hide a getter that stopped returning a
            // boolean.
            expect(card.selectedOnly).toBe(false);
        }
    );

    /**
     * 🔴 THE NARROWING INVARIANT, SWEPT ACROSS THE WHOLE STAGE × RECORD-TYPE
     * GRID — the pin the two `it.each` blocks above cannot express between them.
     *
     * `isOfferSelection` is documented as "a NARROWING of `isOfferStage`, NOT a
     * parallel list". Sharing the stage CONSTANT only protects that claim against
     * a rename; it does nothing about a SCOPE change, which is exactly what the
     * 2026-08-25 record-type work introduced. This sweep asserts the invariant
     * itself: selected-only mode is on for EXACTLY the two Offer Selection combos
     * and nowhere else, and there is no combination anywhere in the grid where
     * the flag is true — which, since the flag can only be read off a rendered
     * card, is also the statement that it never outruns the list.
     */
    it('🔴 NARROWING: selected-only is true for EXACTLY Offer Selection, on both paths, and nowhere else', async () => {
        const selectedOnlyCombos = [];
        const renderedCombos = [];

        for (const recordType of [ON_MARKET, OFF_MARKET]) {
            // 🔴 THE GRID IS READ FROM THE RECORD TYPE'S OWN VALUE SET, so it
            // covers every stage that path can REACH and none that it cannot.
            for (const stage of stageValuesFor(recordType)) {
                const element = await renderAt(stage, recordType);
                const card = offerCard(element);
                if (card) {
                    renderedCombos.push(`${stage} / ${recordType}`);
                    if (card.selectedOnly === true) {
                        selectedOnlyCombos.push(`${stage} / ${recordType}`);
                    }
                }
            }
        }

        expect(selectedOnlyCombos).toEqual([
            `Offer Selection / ${ON_MARKET}`,
            `Offer Selection / ${OFF_MARKET}`
        ]);
        // ⚠ THE GUARD-THE-GUARD. Without this the assertion above also passes on
        // a component that renders no card at all, anywhere — an empty array
        // equals an empty array. This is also the single place the whole scoped
        // stage list is stated as one set.
        expect(renderedCombos).toEqual([
            `Active Listing / ${ON_MARKET}`,
            `Offer Selection / ${ON_MARKET}`,
            `LOI / ${ON_MARKET}`,
            `Release Materials / ${OFF_MARKET}`,
            `Offer Selection / ${OFF_MARKET}`,
            `LOI / ${OFF_MARKET}`
        ]);
    });

    it('LOI renders the disposition-offer panel on both paths — the LOI came from one of these offers', async () => {
        const onMarket = await renderAt('LOI', ON_MARKET);
        expect(offerCard(onMarket)).not.toBeNull();

        const offMarket = await renderAt('LOI', OFF_MARKET);
        expect(offerCard(offMarket)).not.toBeNull();
    });

    /**
     * 🔴 THE PREMISE BEHIND 'Active Listing' CARRYING **NO** RECORD-TYPE TEST,
     * PINNED AGAINST THE METADATA ITSELF.
     *
     * `isOfferStage` scopes 'Release Materials' but deliberately leaves 'Active
     * Listing' unscoped, because that value is not in the Off_Market record
     * type's `Disposition_Stage__c` value set at all — the field is
     * `<restricted>true</restricted>` and record-type value-set scoping is
     * enforced by DML in this org, so an off-market disposition cannot hold it.
     * `&& isOnMarket` there would be a condition that can never be false.
     *
     * ⚠ A JEST FIXTURE CANNOT FALSIFY THAT — it would happily emit an impossible
     * record. So the falsifier is a source-text pin on the record type metadata:
     * the day somebody adds 'Active Listing' to the off-market path, THIS reds
     * and points at the guard that then has to be written.
     */
    it('🔴 PREMISE: Active Listing is not an Off_Market stage value, which is why it carries no guard', () => {
        expect(stageValuesFor(ON_MARKET)).toContain('Active Listing');
        expect(stageValuesFor(OFF_MARKET)).not.toContain('Active Listing');
        // ⚠ AND THE CONTRAST THAT MAKES THE POINT: 'Release Materials' IS on both
        // record types, which is precisely why it needed a guard when 'Active
        // Listing' did not. Without this line the assertion above reads as
        // "off-market has fewer stages" rather than as the asymmetry it is.
        expect(stageValuesFor(ON_MARKET)).toContain('Release Materials');
        expect(stageValuesFor(OFF_MARKET)).toContain('Release Materials');
        // ⚠ AND 'Offer Selection' TOO — the stage `isOfferSelection` narrows to.
        // If it ever became path-exclusive, the narrowing sweep's expected set
        // would have to change with it.
        expect(stageValuesFor(ON_MARKET)).toContain('Offer Selection');
        expect(stageValuesFor(OFF_MARKET)).toContain('Offer Selection');
    });

    it.each([ON_MARKET, OFF_MARKET])(
        'PSA on %s renders NO sidebar child — deliberately no placeholder (Gate 1 Q5)',
        async (recordType) => {
            const element = await renderAt('PSA', recordType);

            expect(offerCard(element)).toBeNull();
            expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
            expect(
                element.shadowRoot.querySelector('c-disposition-closing')
            ).toBeNull();
        }
    );

    it('Disposition Readiness renders NO sidebar child (the record page shows Details)', async () => {
        const element = await renderAt('Disposition Readiness', ON_MARKET);

        expect(offerCard(element)).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
    });

    // ⚠ NDA IS NO LONGER OFF-MARKET-ONLY. The disposition flow redesign moved it
    // into the On-Market path too, so the "NDA is off-market only" doctrine that
    // this test title used to assert is dead. What survives is the real point: at
    // NDA there is no offer yet, on EITHER path.
    it.each([ON_MARKET, OFF_MARKET])(
        'NDA on %s renders NO sidebar child — there is no offer yet',
        async (recordType) => {
            const element = await renderAt('NDA', recordType);

            expect(offerCard(element)).toBeNull();
            expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        }
    );

    it('Closing stage renders the closing panel only', async () => {
        const element = await renderAt('Closing', ON_MARKET);

        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).not.toBeNull();
    });

    it('Sale Closes renders no sidebar child (the closing gate is Closing-only here)', async () => {
        const element = await renderAt('Sale Closes', OFF_MARKET);

        expect(
            element.shadowRoot.querySelector('c-disposition-closing')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('c-bov-outreach')).toBeNull();
        expect(offerCard(element)).toBeNull();
    });

    // ── 🔴 RETIRED VALUES. These are FALSIFIERS, not leftovers: they red the ──
    // ── moment someone re-adds a removed value to isOfferStage.             ──

    it.each(['Call for Offers', 'Disposition Offer', 'Completed'])(
        'RETIRED VALUE %p routes NOWHERE — it was removed from Disposition_Stage__c',
        async (stage) => {
            const element = await renderAt(stage, ON_MARKET);

            expect(offerCard(element)).toBeNull();
            expect(
                element.shadowRoot.querySelector('c-bov-outreach')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('c-disposition-closing')
            ).toBeNull();
        }
    );

    it('ERROR BRANCH: renders an inline error state and no sidebar child when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        expect(offerCard(element)).toBeNull();
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
