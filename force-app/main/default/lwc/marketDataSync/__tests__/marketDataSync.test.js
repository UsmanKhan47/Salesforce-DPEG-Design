/**
 * c-market-data-sync — LDS READ + LDS WRITE, parameterised by a design property.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * HOW THIS SUITE MOCKS, AND WHY THERE IS NO jest.mock() FOR uiRecordApi
 * ═════════════════════════════════════════════════════════════════════════════
 * `lightning/uiRecordApi` and `lightning/uiObjectInfoApi` are ALREADY module-level mocks: the
 * sfdx-lwc-jest preset substitutes its own stub modules for them, in which `getRecord` /
 * `getObjectInfo` are `createLdsTestWireAdapter(jest.fn())`, `updateRecord` is
 * `jest.fn().mockResolvedValue({})` and `getRecordNotifyChange` is assertable. Importing those
 * bindings and asserting on them directly IS module-level mocking, and it is what every LDS suite in
 * this repo does.
 *
 * ⚠ What must NOT be done instead is an INSTANCE SPY — reaching into a created element and replacing
 * a method on it. That binds the assertion to the component's internals rather than to the platform
 * boundary it actually crosses, and it silently stops asserting anything the moment the component is
 * refactored. A repo-recorded gotcha.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 THE COMPONENT HAS **TWO** `getRecord` WIRES, SO EVERY EMIT MUST BE FILTERED
 * ═════════════════════════════════════════════════════════════════════════════
 * Since 2026-08-17 the card reads the OPPORTUNITY (one field: `Property__c`, the lookup Id) and then
 * reads the PROPERTY (one field: the stamp). Both use the same `getRecord` adapter, and
 * `TestWireAdapter.emit(value)` with no second argument emits to **every registered instance** — so a
 * bare `getRecord.emit(...)` feeds one record to both wires and produces a state the org can never
 * be in.
 *
 * Every emit in this suite therefore passes the adapter's `filterFn`, which receives each wire
 * instance's own config, and discriminates on `config.recordId`: the deal wire is configured with
 * `RECORD_ID` and the property wire with whatever `Property__c` resolved to. `emitDeal` /
 * `emitProperty` below are the only places that knowledge lives.
 *
 * ⚠ `getRecord.error(...)` — the convenience used by the pre-2026-08-17 version of this suite —
 * takes NO filter and hits both wires. Use `getRecord.emitError(options, filterFn)` instead, which
 * does. That is why J15 (a refused DEAL read) and the "Not available" case (a refused PROPERTY read)
 * can be told apart at all: they are genuinely different states and the component renders them
 * differently.
 *
 * ⚠ Both helpers `await` a macrotask, because the property wire cannot even be CONFIGURED until the
 * deal wire's emit has propagated through a render cycle.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 TWO LOAD-BEARING NEGATIVES IN THIS SUITE: J6 AND THE NO-SPINNER PIN
 * ═════════════════════════════════════════════════════════════════════════════
 * `getRecordNotifyChange` must NEVER be called. `updateRecord` writes THROUGH the LDS cache, so the
 * record page re-renders on its own (the c/leadStatusChange rule). That is the EXACT OPPOSITE of the
 * c/dealActionGuard / c/recordStageGuard rule, which applies only to imperative Apex DML. ⚠ The move
 * of the write from Opportunity to Property__c did NOT change this: the target record moved, the
 * mechanism did not.
 *
 * The failure this pins is a plausible one, which is why it is written as its own test rather than
 * left as an incidental assertion: this repo has four bundles that MUST call it, and someone reading
 * them will reasonably "fix" this component by analogy. J6 is the permanent falsifier. DO NOT DELETE
 * IT. When a real callout lands and the write moves to Apex, J6 INVERTS (assert it IS called) — it
 * does not disappear.
 *
 * The no-spinner pin (J17) guards mitigation (c) of a CONDITIONAL user decision — the button may be
 * labelled `Sync` only while all three stub mitigations hold. It is deliberately broader than a
 * `lightning-spinner` tag query, and it now also asserts the CLASS exposes no busy member at all.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 THERE ARE ALSO **TWO** `lightning-record-form`s (code review C2, 2026-08-17)
 * ═════════════════════════════════════════════════════════════════════════════
 * ⚠ THAT IS HISTORY, NOT CURRENT STATE — READ ON. A second `mode="readonly"` form held the two
 * provider CONTROL fields for part of 2026-08-17 (code review C2). The user then removed all four
 * control fields from the cards, so that form had nothing left to render and went with them.
 *
 * ⇒ THERE IS **ONE** `lightning-record-form` PER CARD TODAY, at `mode="view"`. `formOf` is it.
 * `formsOf` survives deliberately: the "is a form mounted?" assertions must count ALL forms (a
 * `formOf(...).toBeNull()` would pass while a second one rendered), and it is the assertion that
 * catches a control field being restored. `controlFormOf` is gone with the form itself.
 *
 * Two consequences worth stating, because each is its own failure:
 *   - "the form is not mounted" assertions use `formsOf(...).toHaveLength(0)`. A `formOf(...)
 *     .toBeNull()` would pass while the control form was still rendering with a null record-id.
 *   - the field-list tests assert BOTH `fieldApiNamesOn` (the concatenation — COVERAGE, i.e. that
 *     nothing was silently dropped) and the per-form lists. Neither catches the other's
 *     regression.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * ⚠ THE 251-RECORD BULK MANDATE DOES NOT APPLY HERE
 * ═════════════════════════════════════════════════════════════════════════════
 * `.claude/rules/bulk-test-rule.md` requires 251+ records for triggers, batch jobs, DML-performing
 * SERVICES and queueables, because 200 is the trigger chunk size and 251 forces a second firing.
 * This feature has none of those: it is one LWC bundle with zero Apex, zero SOQL, zero server-side
 * DML and no async context. There is no loop to force a second chunk of and nothing whose governor
 * budget could move. Recorded here, and in the design document's test plan, so the point is settled
 * rather than argued at review.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * FIXTURE NOTES
 * ═════════════════════════════════════════════════════════════════════════════
 * - The LDS record fixture shape is `{ apiName, id, fields: { Field__c: { value } } }` using REAL
 *   field API names — that is what the stub's real `getFieldValue` walks.
 * - `getObjectInfo`'s fixture is for **`Property__c`**, not `Opportunity`. 🔴 That is not cosmetic: a
 *   suite still emitting an `Opportunity` object info would go green while the component gated the
 *   button on the wrong object's field entirely. The `apiName` is asserted nowhere by the component,
 *   so the fixture's own `apiName` is documentation — the discriminating fact is that the FIELD
 *   entries are the Property stamp fields.
 * - The component FAILS CLOSED on access, now on TWO grounds: until `getObjectInfo` emits the button
 *   is disabled, and until a Property Id is in hand it is disabled too. Every test that clicks Sync
 *   therefore emits object info AND a deal carrying a property first. That is not scaffolding around
 *   the component — it is the fail-closed behaviour, and three tests assert it directly.
 */
import { createElement } from 'lwc';
import MarketDataSync from 'c/marketDataSync';
import {
    getRecord,
    updateRecord,
    getRecordNotifyChange
} from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import PROPERTY_OBJECT from '@salesforce/schema/Property__c';

/** The OPPORTUNITY the card sits on. */
const RECORD_ID = '006iw000004GtLmAAK';
/** The PROPERTY it renders and writes — a DIFFERENT record. */
const PROPERTY_ID = 'a04iw000001PrpQAAS';
/** A second property, for the "the lookup changed" case (J16). */
const OTHER_PROPERTY_ID = 'a04iw000001PrpRAAS';

const PLACER_STAMP = 'Placer_Last_Synced_DateTime__c';
const COSTAR_STAMP = 'CoStar_Last_Synced_DateTime__c';

const OLD_STAMP = '2026-07-01T09:14:00.000Z';
const NEW_STAMP = '2026-08-16T11:30:00.000Z';

/**
 * 🔴 THE EXACT FIELD LISTS, IN ORDER, SPLIT ACROSS THE TWO FORMS (code review C2).
 *
 * Asserted as exact arrays rather than by containment: an EXTRA field on this card is a real defect,
 * because the Sync button and the Last Synced row are an assertion ABOUT the fields beside them.
 * A MISSING one is equally a defect — `Market_Rent_PSF__c` in particular has no `CoStar_` prefix, so
 * it is the field a prefix-based edit is most likely to drop silently.
 *
 * ⚠ `*_FIELDS` is the CONCATENATION, and the tests assert BOTH the split and the whole. The split
 * pins editability; the concatenation pins COVERAGE. Those are different failures and neither
 * assertion catches the other.
 *
 * 🔴 THESE ARE API NAMES, NEVER LABELS, AND THAT MATTERS RIGHT NOW. A parallel admin change is
 * dropping the provider prefix from eight of these fields' LABELS (`Placer_State_Rank__c` →
 * "State Rank", `CoStar_Pct_Leased__c` → "% Leased", and six more) while leaving every API name
 * alone. Nothing in this suite asserts a field label, so none of it moves — verified by grep, not by
 * assumption. If a future test ever does assert a rendered label, it takes on that churn and should
 * say so at the assertion.
 *
 * ⚠ `<source>_Data_Source__c` IS ABSENT FROM BOTH LISTS ON PURPOSE (user decision, 2026-08-17). It
 * was rendered in the control form for part of that day and removed from the card; the FIELD still
 * exists on `Property__c`, untouched. `notOnTheCard` below pins the absence directly, because an
 * exact-array assertion would go red for the wrong reason if someone re-added it and would not
 * SAY why.
 */
const PLACER_METRIC_FIELDS = [
    'Placer_URL__c',
    'Placer_State_Rank__c',
    'Placer_State_Percentile__c',
    'Placer_MSA_Rank__c',
    'Placer_National_Rank__c',
    'Monthly_Visits__c'
];
const PLACER_FIELDS = [...PLACER_METRIC_FIELDS];

const COSTAR_METRIC_FIELDS = [
    'CoStar_URL__c',
    'CoStar_Pct_Leased__c',
    'CoStar_Location_Score__c',
    'CoStar_Asking_Rent_PSF__c',
    'Market_Rent_PSF__c',
    'CoStar_Exit_Cap_Rate__c',
    'Market_Cap_Rate__c'
];
const COSTAR_FIELDS = [...COSTAR_METRIC_FIELDS];

/**
 * The four PROVIDER CONTROL fields, rendered nowhere on either card since 2026-08-17 — see the note
 * above. `notRenderedAnywhere` pins all four together, because they were removed for one reason in
 * two steps and a partial re-add is as much a reversal as a full one.
 */
const CONTROL_FIELDS_NOT_ON_CARD = [
    'Placer_Data_Source__c',
    'CoStar_Data_Source__c',
    'Placer_Fetch_Status__c',
    'CoStar_Fetch_Status__c'
];

const GENERIC_ERROR =
    'The sync timestamp could not be saved. Please try again or contact your administrator.';
const NO_EDIT_ACCESS =
    'You do not have edit access to this field, so it cannot be stamped.';
const NO_PROPERTY_NOTE =
    'No property is linked to this deal, so there is no market data to show. Link a property to the deal to see its Placer and CoStar data.';
const NO_PROPERTY_REASON = 'There is no linked property to stamp.';

/**
 * `Property__c` object info carrying the two stamp fields, both editable unless told otherwise.
 *
 * 🔴 Property__c, NOT Opportunity — the FLS gate moved objects with the write.
 */
function objectInfoWith(updateable = true) {
    return {
        apiName: 'Property__c',
        fields: {
            [PLACER_STAMP]: { apiName: PLACER_STAMP, updateable },
            [COSTAR_STAMP]: { apiName: COSTAR_STAMP, updateable }
        }
    };
}

/** The OPPORTUNITY record: one field, the Property lookup. Pass `null` for a deal with no property. */
function dealWith(propertyId) {
    return {
        apiName: 'Opportunity',
        id: RECORD_ID,
        fields: {
            Property__c: { value: propertyId === undefined ? null : propertyId }
        }
    };
}

/** The PROPERTY record, carrying one stamp value. Pass `undefined` for a never-synced property. */
function propertyWith(stampField, value, propertyId = PROPERTY_ID) {
    return {
        apiName: 'Property__c',
        id: propertyId,
        fields: {
            [stampField]: { value: value === undefined ? null : value }
        }
    };
}

describe('c-market-data-sync', () => {
    beforeEach(() => {
        // The preset stub sets this, but re-assert it so a previous test's mockRejectedValueOnce or
        // a future clearAllMocks change cannot silently turn the happy path red.
        updateRecord.mockResolvedValue({});
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = {}) {
        const element = createElement('c-market-data-sync', {
            is: MarketDataSync
        });
        Object.assign(element, { recordId: RECORD_ID, ...props });
        document.body.appendChild(element);
        return element;
    }

    /** One MACROTASK: drains the whole microtask queue plus the re-render that follows it. */
    const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

    // ─────────────────────────────────────────────────────────────────────────
    // Filtered emits — see the "TWO getRecord WIRES" note in the file header
    //
    // 🔴 EVERY HELPER FLUSHES **BEFORE** IT EMITS, AND THAT LEADING FLUSH IS NOT
    // DEFENSIVE PADDING — IT IS THE WHOLE REASON THE FILTER WORKS.
    //
    // MEASURED 2026-08-17, and it cost a full debugging pass to find:
    // `TestWireAdapterTemplate`'s constructor sets `this.config = {}` and only
    // populates it when LWC calls `update(config)` — which happens on the
    // component's first REACTIVE PASS, not at `appendChild`. So a filtered emit
    // issued in the same synchronous block as the element's creation (or as any
    // other emit) sees `getConfig() === {}` for EVERY instance, `config.recordId`
    // is `undefined`, the filter matches NOTHING, and the emit silently does
    // nothing at all.
    //
    // It fails as SILENCE, not as an error, and it fails only for SOME callers —
    // whichever happened not to flush first — which is exactly why it presented as
    // "20 unrelated tests fail while 24 pass". Putting the flush inside the helpers
    // makes every call site correct by construction rather than by remembering.
    // ─────────────────────────────────────────────────────────────────────────

    /** Answers the OPPORTUNITY wire. `null` means a deal with no linked property. */
    async function emitDeal(propertyId = PROPERTY_ID) {
        await flushPromises();
        getRecord.emit(
            dealWith(propertyId),
            (config) => config.recordId === RECORD_ID
        );
        await flushPromises();
    }

    /** Refuses the OPPORTUNITY read — "we do not know", NOT "there is no property". */
    async function emitDealError() {
        await flushPromises();
        getRecord.emitError(
            { body: { message: 'no access to the deal' } },
            (config) => config.recordId === RECORD_ID
        );
        await flushPromises();
    }

    /** Answers the PROPERTY wire. Targets by Id, so J16 can answer one property and not the other. */
    async function emitProperty(stampField, value, propertyId = PROPERTY_ID) {
        await flushPromises();
        getRecord.emit(
            propertyWith(stampField, value, propertyId),
            (config) => config.recordId === propertyId
        );
        await flushPromises();
    }

    /** Refuses the PROPERTY read — e.g. no FLS on the stamp field. */
    async function emitPropertyError(propertyId = PROPERTY_ID) {
        await flushPromises();
        getRecord.emitError(
            { body: { message: 'no FLS' } },
            (config) => config.recordId === propertyId
        );
        await flushPromises();
    }

    /** The ordinary fully-loaded state: object info, a deal with a property, and that property. */
    async function loadFully(element, stampField, value = OLD_STAMP) {
        getObjectInfo.emit(objectInfoWith(true));
        await emitDeal(PROPERTY_ID);
        await emitProperty(stampField, value);
        return element;
    }

    /**
     * ⚠ TWO forms since code review C2. `formOf` is the METRICS form and is what the "is the form
     * mounted?" assertions mean; `formsOf` is used wherever the answer must cover both — the
     * no-property / in-flight / errored states must mount NEITHER, and a `record-id` regression on
     * the second form would be invisible to a `querySelector` that only ever returns the first.
     */
    function formOf(element) {
        return element.shadowRoot.querySelector('lightning-record-form.mds-metrics');
    }

    function formsOf(element) {
        return Array.from(
            element.shadowRoot.querySelectorAll('lightning-record-form')
        );
    }

    function namesOn(form) {
        return form ? form.fields.map((field) => field.fieldApiName) : null;
    }

    function metricFieldApiNamesOn(element) {
        return namesOn(formOf(element));
    }

    /** Every field the card renders, in render order, across both forms. */
    function fieldApiNamesOn(element) {
        const forms = formsOf(element);
        if (forms.length === 0) {
            return null;
        }
        return forms.reduce((all, form) => all.concat(namesOn(form)), []);
    }

    function clickSync(element) {
        element.shadowRoot.querySelector('lightning-button').click();
    }

    function sectionTitleOf(element) {
        return element.shadowRoot
            .querySelector('.mds-section-title')
            .textContent.trim();
    }

    /** Every lightning-icon inside the section header, by icon-name. */
    function iconNamesInHeader(element) {
        return Array.from(
            element.shadowRoot.querySelectorAll(
                '.slds-section__title lightning-icon'
            )
        ).map((icon) => icon.iconName);
    }

    function toggleButtonOf(element) {
        return element.shadowRoot.querySelector('.slds-section__title-action');
    }

    function sectionContentOf(element) {
        return element.shadowRoot.querySelector('.slds-section__content');
    }

    function noPropertyNoteOf(element) {
        return element.shadowRoot.querySelector('.mds-empty');
    }

    /**
     * Asserts the Sync button carries no tooltip.
     *
     * 🔴 It is NOT enough to assert `toBeFalsy()`. A dynamic attribute bound on a CUSTOM ELEMENT is
     * written unconditionally with the STRINGIFIED value, so a getter returning `undefined` or
     * `null` renders `title="undefined"` / `title="null"` — truthy strings that a user would
     * actually see on hover. Both were measured during the S3 fix. These assertions name the two
     * failed attempts explicitly so a future "cleanup" that reinstates either one goes red with an
     * obvious cause rather than a bare falsy-check failure.
     */
    function expectNoTooltip(element) {
        const title = element.shadowRoot.querySelector('lightning-button').title;
        expect(title).toBeFalsy();
        expect(title).not.toBe('undefined');
        expect(title).not.toBe('null');
        expect(title).not.toBe('Sync');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // J1 / J2 — the CONFIG_BY_SOURCE parameterisation, now against Property__c
    // ─────────────────────────────────────────────────────────────────────────

    it('J1 PLACER: renders the Placer title and the 6 Property fields, and no CoStar field', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        // SENTENCE case, exactly as a native field section renders it. The first version used
        // `slds-text-title_caps` (the utility-bar treatment), which rendered "PLACER".
        expect(sectionTitleOf(element)).toBe('Placer');
        // 🔴 No source icon: the only lightning-icon in the header is the collapse chevron. Dropped
        // by user decision so the card matches the native "Broker" section, which has none.
        expect(iconNamesInHeader(element)).toEqual(['utility:switch']);

        // The exact list, in the FSD §18.2 order, with the incumbent Monthly_Visits__c in place.
        expect(fieldApiNamesOn(element)).toEqual(PLACER_FIELDS);
        expect(fieldApiNamesOn(element)).not.toContain('CoStar_URL__c');
        expect(fieldApiNamesOn(element)).not.toContain('Market_Cap_Rate__c');

        // ⚠ ONE form since 2026-08-17 — the readonly control form went with the fields it held — so
        // `metricFieldApiNamesOn` and `fieldApiNamesOn` now agree. Both are asserted deliberately:
        // if a control field ever comes back it returns in a SECOND form, and only the second of
        // these two would notice.
        expect(metricFieldApiNamesOn(element)).toEqual(PLACER_METRIC_FIELDS);
        expect(formsOf(element)).toHaveLength(1);

        // The stamp field is NOT in the form — this component renders it itself as the bespoke
        // `Last Synced` row, so that it can carry the helptext and the three-state rendering.
        expect(fieldApiNamesOn(element)).not.toContain(PLACER_STAMP);
    });

    it('J2 COSTAR: renders the CoStar title and the 7 Property fields, and no Placer field', async () => {
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        expect(sectionTitleOf(element)).toBe('CoStar');
        expect(iconNamesInHeader(element)).toEqual(['utility:switch']);

        expect(fieldApiNamesOn(element)).toEqual(COSTAR_FIELDS);
        expect(fieldApiNamesOn(element)).not.toContain('Monthly_Visits__c');
        expect(fieldApiNamesOn(element)).not.toContain('Placer_URL__c');
        expect(fieldApiNamesOn(element)).not.toContain(COSTAR_STAMP);

        expect(metricFieldApiNamesOn(element)).toEqual(COSTAR_METRIC_FIELDS);
        expect(formsOf(element)).toHaveLength(1);
    });

    it('J2 (cont): Market_Rent_PSF__c is on the CoStar card DESPITE having no CoStar_ prefix', async () => {
        // 🔴 A standalone pin, because this is the one field a prefix-based edit or audit drops
        // silently. It is the FSD's CoStar "Market Rent (PSF)"; the name is ARCHITECTURE §1 rule 5
        // compliant (a per-unit rate suffixes the unit) and predates the CoStar block, and a rename
        // would be delete-and-recreate against a field with Apex, permission-set and report readers.
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        const fields = fieldApiNamesOn(element);
        expect(fields).toContain('Market_Rent_PSF__c');

        // 🔴 THE POINT, STATED AS AN ASSERTION: a prefix-based audit of "the CoStar block" finds
        // only FIVE of the seven fields on this card. The two it misses are named here, so the
        // residual is auditable rather than merely described in a comment — and so that anyone who
        // later adds a CoStar field has to decide, deliberately, which list it belongs to.
        //
        // ⚠ The counts moved twice on 2026-08-17 as the control fields left the card (7 of 9 → 6 of
        // 8 → 5 of 7). Neither the ratio nor the arithmetic is the point: the point is that exactly
        // two fields on this card are invisible to a `CoStar_` grep, permanently, and that the
        // number of them has never changed.
        expect(fields.filter((f) => f.startsWith('CoStar_'))).toHaveLength(5);
        expect(fields.filter((f) => !f.startsWith('CoStar_'))).toEqual([
            'Market_Rent_PSF__c',
            'Market_Cap_Rate__c'
        ]);

        // And it sits INSIDE the CoStar card, which is the whole mitigation: the UI carries the
        // grouping the name does not.
        expect(fields.indexOf('Market_Rent_PSF__c')).toBeGreaterThan(-1);
    });

    it('J1/J2 (cont): the two cards render two cap rates and one visit count, never crossed over', async () => {
        // The CoStar card shows BOTH CoStar_Exit_Cap_Rate__c and the incumbent Market_Cap_Rate__c —
        // different facts (the exit assumption vs the prevailing market rate), which is why both
        // fields' <description> must distinguish them. Pinned here so a future "de-duplication" of
        // the two cap rates goes red rather than silently dropping one.
        const costar = createComponent({ source: 'CoStar' });
        await loadFully(costar, COSTAR_STAMP);
        const costarFields = fieldApiNamesOn(costar);
        expect(costarFields).toContain('CoStar_Exit_Cap_Rate__c');
        expect(costarFields).toContain('Market_Cap_Rate__c');
        expect(costarFields).not.toContain('Monthly_Visits__c');
    });

    it('defaults to Placer when no source is supplied, matching the js-meta default', async () => {
        const element = createComponent();
        await loadFully(element, PLACER_STAMP);

        expect(fieldApiNamesOn(element)).toEqual(PLACER_FIELDS);
    });

    it('LOADING: the Last Synced row says NOTHING before the record wires answer — never "Never"', async () => {
        // 🔴 REGRESSION PIN (code review W2). Before any emit the component does not know whether
        // this property has ever been synced, and "Never" is an ASSERTION. It is the same
        // confident-wrong-answer class as reporting "Not available" as "Never" on the error branch,
        // as accusing a user of lacking edit access while the object info is still in flight, and as
        // claiming "no property linked" before the deal wire has answered. All four are one rule:
        // say nothing until you know.
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();

        const placeholder = element.shadowRoot.querySelector('.mds-muted');
        expect(placeholder.textContent).not.toBe('Never');
        expect(placeholder.textContent).not.toBe('Not available');
        expect(placeholder.textContent).toBe('—');
        // Told to a screen reader as nothing at all, rather than as a dash.
        expect(placeholder.getAttribute('aria-hidden')).toBe('true');

        // Still the em-dash once the DEAL has answered but the PROPERTY has not — the second wire is
        // a second unknown, and the row must not resolve until it too has answered.
        await emitDeal(PROPERTY_ID);
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            '—'
        );

        // ...and it becomes "Never" only once the PROPERTY has answered with a null stamp.
        await emitProperty(PLACER_STAMP, null);
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Never'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // The collapsible field-section header (SLDS Expandable Section blueprint)
    // ─────────────────────────────────────────────────────────────────────────

    it('SECTION: defaults to EXPANDED, matching a native Dynamic Forms field section', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        expect(
            element.shadowRoot.querySelector('.slds-section').className
        ).toContain('slds-is-open');
        expect(toggleButtonOf(element).getAttribute('aria-expanded')).toBe('true');
        expect(sectionContentOf(element).getAttribute('aria-hidden')).toBe(
            'false'
        );
        expect(formOf(element)).not.toBeNull();
    });

    it('SECTION: the WHOLE BAR is the toggle, and clicking it collapses the section', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        // The click target is a button carrying `slds-section__title-action` — the full-width bar, as
        // it is natively, not a chevron with a label sitting beside it.
        const toggle = toggleButtonOf(element);
        expect(toggle.tagName).toBe('BUTTON');
        expect(toggle.className).toContain('slds-button');

        toggle.click();
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.slds-section').className
        ).not.toContain('slds-is-open');
        expect(toggleButtonOf(element).getAttribute('aria-expanded')).toBe(
            'false'
        );

        // ...and back again: the control is a toggle, not a one-way close.
        toggleButtonOf(element).click();
        await flushPromises();

        expect(toggleButtonOf(element).getAttribute('aria-expanded')).toBe('true');
    });

    it('SECTION A11Y: aria-controls resolves to the content container that is actually rendered', async () => {
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        // LWC mangles template ids at runtime and rewrites idref attributes to match, so this asserts
        // the RESOLVED pair rather than the literal authored string — a dangling aria-controls is
        // invisible to a reader of the template but is a real defect for assistive technology.
        const controls = toggleButtonOf(element).getAttribute('aria-controls');
        expect(controls).toBeTruthy();
        expect(sectionContentOf(element).getAttribute('id')).toBe(controls);
        expect(
            element.shadowRoot.querySelector(`[id="${controls}"]`)
        ).not.toBeNull();
    });

    it('SECTION A11Y: collapsed content is hidden from AT and holds no focusable control', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        toggleButtonOf(element).click();
        await flushPromises();

        const content = sectionContentOf(element);
        // The container survives so aria-controls still resolves...
        expect(content).not.toBeNull();
        expect(content.getAttribute('aria-hidden')).toBe('true');
        expect(content.className).toContain('slds-hide');

        // ...but the body is UNMOUNTED, not merely styled away. That distinction is the point: hiding
        // by stylesheet alone is not "hidden from assistive technology", and leaving focusable
        // controls inside an aria-hidden container is itself an accessibility defect (and the reason
        // the collapsed sa11y assertion below can pass at all).
        expect(formsOf(element)).toHaveLength(0);
        expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J3 — a misconfigured instance must SAY SO
    // ─────────────────────────────────────────────────────────────────────────

    it.each([
        ['an unknown vendor', 'Yardi', '"Yardi"'],
        ['an empty string', '', 'a blank value'],
        ['a case typo', 'placer', '"placer"']
    ])(
        'J3 INVALID SOURCE (%s): renders a role="alert" naming the accepted values, and no card',
        async (label, source, expectedFragment) => {
            const element = createComponent({ source });
            getObjectInfo.emit(objectInfoWith(true));
            await flushPromises();

            const alert = element.shadowRoot.querySelector('[role="alert"]');
            // 🔴 The whole point: NOT an empty card. An empty card is indistinguishable from "this
            // deal has no market data", so the misconfiguration would never be reported by anything.
            expect(alert).not.toBeNull();
            expect(alert.textContent).toContain(expectedFragment);
            // The message must enumerate what IS accepted, or it is not actionable.
            expect(alert.textContent).toContain('Placer, CoStar');
            expect(alert.textContent).toContain('Data source');

            expect(formsOf(element)).toHaveLength(0);
            expect(
                element.shadowRoot.querySelector('lightning-button')
            ).toBeNull();
            // 🔴 And it is an ALERT, not the no-property STATUS note. The two states are different
            // and their roles are not interchangeable.
            expect(noPropertyNoteOf(element)).toBeNull();
        }
    );

    it('J3 (cont): an invalid source never throws and never writes, even if the wires emit', async () => {
        const element = createComponent({ source: 'Yardi' });
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getObjectInfo.emit(objectInfoWith(true));
        await emitDeal(PROPERTY_ID);

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J4 / J5 — the write targets exactly one field, on exactly the right RECORD
    // ─────────────────────────────────────────────────────────────────────────

    it('J4 SYNC (Placer): writes the PROPERTY Id + Placer_Last_Synced_DateTime__c and nothing else', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP, null);

        clickSync(element);
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        const payload = updateRecord.mock.calls[0][0];

        // Exactly two keys. A third would mean this card silently writes something the user did not
        // ask it to, which is the failure mode a Sync button is most likely to grow.
        expect(Object.keys(payload.fields).sort()).toEqual(['Id', PLACER_STAMP]);

        // 🔴 THE HIGHEST-VALUE ASSERTION IN THIS SUITE. The freshness marker must live with the data
        // it claims freshness for. Stamping the Opportunity twin instead would show ONE dataset under
        // TWO different "Last Synced" values for two deals on one property, and would permanently
        // desynchronise this card from MarketDataSnapshotService, which freezes the PROPERTY
        // timestamp into the approval evidence. Both Ids are asserted, so a regression cannot pass by
        // coincidence.
        expect(payload.fields.Id).toBe(PROPERTY_ID);
        expect(payload.fields.Id).not.toBe(RECORD_ID);

        expect(typeof payload.fields[PLACER_STAMP]).toBe('string');
        // An ISO 8601 instant, which is what LDS accepts for a DateTime.
        expect(Number.isNaN(Date.parse(payload.fields[PLACER_STAMP]))).toBe(false);
        expect(payload.fields[COSTAR_STAMP]).toBeUndefined();
    });

    it('J5 SYNC (CoStar): the same write targets CoStar_Last_Synced_DateTime__c on the PROPERTY', async () => {
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP, null);

        clickSync(element);
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        const payload = updateRecord.mock.calls[0][0];
        // Sorted, so the stamp field sorts ahead of `Id` here and behind it in J4. The assertion is
        // about the SET of keys being exactly two, not about their order.
        expect(Object.keys(payload.fields).sort()).toEqual([COSTAR_STAMP, 'Id']);
        expect(payload.fields.Id).toBe(PROPERTY_ID);
        expect(payload.fields.Id).not.toBe(RECORD_ID);
        expect(payload.fields[PLACER_STAMP]).toBeUndefined();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J6 — 🔴 PERMANENT FALSIFIER. DO NOT DELETE.
    // ─────────────────────────────────────────────────────────────────────────

    it('J6 🔴 getRecordNotifyChange is NEVER called — updateRecord writes THROUGH the LDS cache', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        clickSync(element);
        await flushPromises();

        // Sanity: the write really did happen, so this is not vacuously green.
        expect(updateRecord).toHaveBeenCalledTimes(1);

        // 🔴 THE ASSERTION. c/advanceRecordStage and c/advanceDealStage MUST call this because their
        // writes are imperative Apex and bypass the LDS cache. This component MUST NOT, because
        // updateRecord writes through it. ARCHITECTURE.md §5's guard-util table records that the two
        // requirements are opposite and must not be harmonised. ⚠ Moving the write from Opportunity
        // to Property__c changed the TARGET RECORD, not the mechanism — so this rule is untouched.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('J6 (cont): it is not called on the ERROR path either', async () => {
        updateRecord.mockRejectedValueOnce({ body: { message: 'nope' } });

        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        clickSync(element);
        await flushPromises();

        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J7 — success toast, and the row re-renders from the RECORD, not local state
    // ─────────────────────────────────────────────────────────────────────────

    it('J7 SUCCESS: toasts, and the Last Synced row follows the refreshed record, not local state', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP, OLD_STAMP);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(OLD_STAMP);

        clickSync(element);
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Placer marked as synced.'
        );

        // 🔴 THE DISCRIMINATING ASSERTION. The component wrote a timestamp and was told the write
        // succeeded, yet the row STILL shows the old value — because it renders what the RECORD
        // holds, never what the client believes it sent. If someone "improves" this by assigning the
        // written value to a tracked property, this line goes red. That matters: a locally-assigned
        // value would display a timestamp even where the server altered or rejected the value, and
        // would hide the very failure the error toast reports.
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(OLD_STAMP);

        // Now the LDS cache re-emits the PROPERTY, exactly as it does in the org because
        // updateRecord writes through it. 🔴 This is also why the stamp is read by a second
        // getRecord wire on the Property rather than through an Opportunity.Property__r.* spanning
        // field: the guarantee relied on here is "a getRecord on record X re-emits after an
        // updateRecord on record X", which is the same record in both halves.
        await emitProperty(PLACER_STAMP, NEW_STAMP);

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(NEW_STAMP);
    });

    it('J7 (cont): a never-synced property reads "Never", and a refused PROPERTY read reads "Not available"', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP, null);

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Never'
        );

        // A property the running user cannot read must NOT read as "never synced" — that is a
        // confident wrong answer where "not available" is a true one.
        await emitPropertyError();

        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Not available'
        );
        // ...and it must NOT be mistaken for "no property linked": the deal HAS one, we simply could
        // not read it. The form stays mounted because the Id is still in hand.
        expect(noPropertyNoteOf(element)).toBeNull();

        // 🔴 THIS IS ALSO THE PIN FOR "WHY TWO getRecord WIRES" — the BLAST-RADIUS argument, and the
        // reason that argument is preferable to any claim about LDS cache invalidation: it is
        // observable right here. The Property read was just REFUSED, and the cost is exactly one
        // row. BOTH forms are still mounted and every metric still renders, because the Property Id
        // came from a separate, one-field read that was not refused with it.
        //
        // Fold the stamp onto the deal wire and this test cannot pass: `getRecord` refusal is
        // all-or-nothing across the fields it selects, so the same FLS gap would take the Property
        // Id with it and the whole card would collapse — including the ability to tell this state
        // apart from "no property linked", which the assertion above depends on.
        expect(formsOf(element)).toHaveLength(1);
        expect(formOf(element)).not.toBeNull();
        expect(metricFieldApiNamesOn(element)).toEqual(PLACER_METRIC_FIELDS);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J8 / J9 / J10 — the LDS error shape, NOT the Apex one
    // ─────────────────────────────────────────────────────────────────────────

    it('J8 ERROR (validation rule): surfaces body.output.errors[0].message VERBATIM', async () => {
        // 🔴 The regression pin for a body.message-only read. LDS puts its own useless summary in
        // body.message and the RULE'S OWN TEXT in body.output — so reading body.message first tells
        // the user to retry a problem retrying can never fix. c/dealActionGuard's reducer is correct
        // for ITS Apex path and would be wrong here.
        updateRecord.mockRejectedValueOnce({
            body: {
                message:
                    'An error occurred while trying to update the record. Please try again.',
                output: {
                    errors: [
                        {
                            message:
                                'A CoStar URL is required before this property can be marked as synced.'
                        }
                    ],
                    fieldErrors: {}
                }
            }
        });

        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'A CoStar URL is required before this property can be marked as synced.'
        );
        expect(toastHandler.mock.calls[0][0].detail.message).not.toBe(
            GENERIC_ERROR
        );
    });

    it('J9 ERROR (field error): extracts body.output.fieldErrors rather than swallowing it', async () => {
        updateRecord.mockRejectedValueOnce({
            body: {
                message: '',
                output: {
                    errors: [],
                    fieldErrors: {
                        [PLACER_STAMP]: [
                            {
                                message:
                                    'You do not have permission to edit Placer Last Synced.',
                                fieldLabel: 'Placer Last Synced'
                            }
                        ]
                    }
                }
            }
        });

        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'You do not have permission to edit Placer Last Synced.'
        );
    });

    it('J10 ERROR (nothing usable): falls back to the module constant, never undefined', async () => {
        updateRecord.mockRejectedValueOnce(new Error('network'));

        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        const message = toastHandler.mock.calls[0][0].detail.message;
        expect(message).toBe(GENERIC_ERROR);
        expect(message).not.toBeUndefined();
        expect(message).not.toContain('undefined');
        expect(message).not.toContain('[object Object]');
    });

    it('J10 (cont): an error body that is an ARRAY still yields a real message', async () => {
        // LDS's own createLdsTestWireAdapter defaults an error body to an ARRAY, and real LDS write
        // errors are sometimes shaped that way too — so the reducer walks both forms.
        updateRecord.mockRejectedValueOnce({
            body: [{ errorCode: 'INVALID_FIELD', message: 'Bad field.' }]
        });

        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe('Bad field.');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J11 — FLS edit on the PROPERTY stamp field IS the gate. No custom permission.
    // ─────────────────────────────────────────────────────────────────────────

    it('J11 NOT UPDATEABLE: the button is disabled WITH A REASON and a click writes nothing', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(false));
        await emitDeal(PROPERTY_ID);
        await emitProperty(PLACER_STAMP, OLD_STAMP);

        const button = element.shadowRoot.querySelector('lightning-button');
        // Present, not hidden: a missing button is indistinguishable from "this feature is not for
        // me". That is the same silent-denial defect that retired the User.*_Driver__c model.
        expect(button).not.toBeNull();
        expect(button.disabled).toBe(true);

        const reason = element.shadowRoot.querySelector('.mds-reason');
        expect(reason).not.toBeNull();
        expect(reason.textContent).toBe(NO_EDIT_ACCESS);
        // 🔴 The deal HAS a property, so the reason must be the FLS one and not the no-property one.
        // The two causes are distinct and the message must not name the wrong one.
        expect(reason.textContent).not.toBe(NO_PROPERTY_REASON);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        // `disabled` is a UI affordance; a click can still reach the handler (it does here). The
        // refusal must therefore also be expressed in code, which is what this asserts.
        clickSync(element);
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).not.toHaveBeenCalled();
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('J11 (cont): the button is disabled BEFORE the object info arrives, with no accusatory reason', async () => {
        // FAIL CLOSED on an unknown answer — but do not tell a user they lack access while the
        // answer is still in flight.
        const element = createComponent({ source: 'Placer' });
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
        expect(element.shadowRoot.querySelector('.mds-reason')).toBeNull();

        clickSync(element);
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
    });

    it('J11 (cont): a failed object-info read fails closed WITHOUT claiming an FLS denial', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.error({ message: 'no object access' });
        await emitDeal(PROPERTY_ID);

        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);

        // 🔴 REGRESSION PIN (code review W3). This test previously asserted only `disabled`, which is
        // exactly why the wrong message went unnoticed: the component rendered "You do not have edit
        // access to this field" for a failure that is not evidence of a field-level denial at all —
        // more plausibly an object-access problem or a transient fault. Refusing to act on an answer
        // you do not have is correct; naming a cause you have not established is not, and it sends
        // the user after the wrong fix. Disabled and SILENT is the only defensible pair here.
        expect(element.shadowRoot.querySelector('.mds-reason')).toBeNull();
        expectNoTooltip(element);

        clickSync(element);
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J13 / J14 / J15 / J16 — the linked Property, and every way it can be absent
    // ─────────────────────────────────────────────────────────────────────────

    it('J13 🔴 NO PROPERTY: an honest role="status" note, no form, and a disabled button with a reason', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await emitDeal(null);

        // A visible, honest note — NOT a blank card, which would be indistinguishable from "this org
        // has no market data feature".
        const note = noPropertyNoteOf(element);
        expect(note).not.toBeNull();
        expect(note.textContent.trim()).toBe(NO_PROPERTY_NOTE);

        // 🔴 role="status", NOT role="alert". role="alert" is reserved for configError — an
        // ADMINISTRATOR MISCONFIGURATION nothing else in the org would report. A deal with no
        // property is an ordinary state the user can fix by filling in the lookup. Collapsing the
        // two would train users to ignore the alert that actually matters.
        expect(note.getAttribute('role')).toBe('status');
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();

        // 🔴 The form is NOT MOUNTED. lightning-record-form with a null record-id renders a broken
        // or empty form rather than nothing.
        expect(formsOf(element)).toHaveLength(0);

        // The Last Synced row is gone too — there is no field to read, and "Never" would be an
        // assertion about a record that does not exist.
        expect(element.shadowRoot.querySelector('.mds-muted')).toBeNull();
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();

        // The button is RENDERED and DISABLED with a reason — never hidden. Hiding a control from a
        // user who is genuinely authorized is the defect that retired the User.*_Driver__c model.
        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button).not.toBeNull();
        expect(button.disabled).toBe(true);
        expect(button.title).toBe(NO_PROPERTY_REASON);

        const reason = element.shadowRoot.querySelector('.mds-reason');
        expect(reason).not.toBeNull();
        expect(reason.textContent).toBe(NO_PROPERTY_REASON);
        expect(reason.textContent).not.toBe(NO_EDIT_ACCESS);
    });

    it('J13 (cont): the button is disabled even where FLS WOULD allow the stamp, and writes nothing', async () => {
        // The object info says the field is updateable — the refusal is entirely about there being
        // no record to write to, which is the second, independent fail-closed ground.
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        await emitDeal(null);

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('J14 🔴 DEAL WIRE IN FLIGHT: neither the form NOR the no-property note is rendered', async () => {
        // 🔴 The falsifier for a `!propertyId` check written without a loaded flag. Such a check
        // would flash "No property is linked to this deal" on EVERY page load of EVERY deal — a
        // confident wrong answer stated before the fact is in hand, which is the same defect
        // LOADING_LABEL and the three-state access gate each exist to prevent.
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        expect(noPropertyNoteOf(element)).toBeNull();
        expect(formsOf(element)).toHaveLength(0);

        // The Last Synced row IS rendered, showing the em-dash: "we do not know yet" is the honest
        // answer there, and suppressing the row entirely would be a second, different assertion.
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            '—'
        );

        // Disabled — there is nothing to write to — and SILENT, because no cause is established.
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
        expect(element.shadowRoot.querySelector('.mds-reason')).toBeNull();
    });

    it('J15 🔴 DEAL WIRE ERRORS: degrades to "Not available" and does NOT claim "no property linked"', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await emitDealError();

        // A refused read is not evidence that the deal has no property. Saying so would send the
        // user to fill in a lookup that is probably already populated.
        expect(noPropertyNoteOf(element)).toBeNull();
        expect(element.shadowRoot.textContent).not.toContain(
            'No property is linked'
        );

        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Not available'
        );

        // No form (there is no Id), button disabled, and NO reason text — the cause is unknown.
        expect(formsOf(element)).toHaveLength(0);
        expect(
            element.shadowRoot.querySelector('lightning-button').disabled
        ).toBe(true);
        expect(element.shadowRoot.querySelector('.mds-reason')).toBeNull();
    });

    it('J16 🔴 THE LOOKUP CHANGES: the form follows it, and the stale stamp is cleared first', async () => {
        // Guards against a one-shot read cached in connectedCallback, and against the subtler bug of
        // showing property A's Last Synced beside property B's data during the refetch window.
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP, OLD_STAMP);

        expect(formOf(element).recordId).toBe(PROPERTY_ID);
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(OLD_STAMP);

        await emitDeal(OTHER_PROPERTY_ID);

        // BOTH forms follow — the control form binds the same {propertyId}, and a copy-paste that
        // hard-coded or dropped that binding on the second one would leave the two forms showing two
        // different properties side by side.
        formsOf(element).forEach((form) => {
            expect(form.recordId).toBe(OTHER_PROPERTY_ID);
        });
        // 🔴 Back to the em-dash, NOT still showing OLD_STAMP. The second wire has not answered for
        // the new property yet, so the only true statement is "we do not know".
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            '—'
        );

        await emitProperty(PLACER_STAMP, NEW_STAMP, OTHER_PROPERTY_ID);
        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(NEW_STAMP);

        // ...and a Sync now stamps the NEW property.
        clickSync(element);
        await flushPromises();
        expect(updateRecord.mock.calls[0][0].fields.Id).toBe(OTHER_PROPERTY_ID);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // The stub warning. 🔴 THE CONTRACT CHANGED ON 2026-08-17: mitigation (a) — the
    // `Last Synced (manual)` label — was RETIRED by user decision and the `Sync`
    // button label was deliberately KEPT, so (b) the helptext now carries the whole
    // disclosure alone and (c) the no-spinner rule is unchanged. These tests pin the
    // NEW contract; do not "restore" (manual) on the strength of the old one.
    // ─────────────────────────────────────────────────────────────────────────

    it('STUB WARNING: the row is labelled `Last Synced` — bare, and (manual) is NOT restored', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const label = element.shadowRoot.querySelector(
            '.slds-form-element__label'
        );

        // 🔴 ASSERT THE LABEL IS PRESENT, NOT MERELY THAT "(manual)" IS ABSENT. A card that rendered
        // nothing at all would satisfy a bare `not.toContain` and this test would go green on a
        // completely broken component — the vacuous-assertion trap. The positive assertion first,
        // then the negative.
        expect(label).not.toBeNull();
        expect(label.textContent).toContain('Last Synced');
        expect(label.textContent).not.toContain('(manual)');
        expect(label.textContent).not.toContain('manual');

        const helptext = element.shadowRoot.querySelector('lightning-helptext');
        expect(helptext).not.toBeNull();

        // 🔴 MITIGATION (b), AND IT IS NOW THE ENTIRE DISCLOSURE. With `(manual)` retired and both
        // provider control fields off the card, this tooltip is the ONLY place on screen that says
        // any of this. Asserted as SUBSTANCE — four required facts — rather than as an exact string,
        // so the wording can be improved without the test becoming a spelling checker, while
        // deleting a fact still goes red.
        expect(helptext.content).toContain('no connection to Placer.ai'); // 1. no integration
        expect(helptext.content).toContain('entered by hand'); // 2. hand-entered
        expect(helptext.content).toContain('fetches nothing'); // 3. Sync fetches nothing
        // 4. the values live on a SHARED Property record — editing here changes what every other
        // deal on that property sees. The stated cost of rendering the parent record, and words are
        // the only mitigation available for it.
        expect(helptext.content).toContain('Property record');
        expect(helptext.content).toContain('every deal on that property');

        // 🔴 AND IT NAMES ONLY WHAT THE READER CAN SEE. It named `Sync Status` until that field left
        // the card, and `Data Source` before that. Help text describing an invisible field is the
        // stale-text defect this bundle has been bitten by twice, and it is worse than no help text:
        // it sends the reader looking for a row that is not there.
        expect(helptext.content).not.toContain('Data Source');
        expect(helptext.content).not.toContain('Sync Status');
    });

    it('STUB WARNING: the CoStar card names CoStar in its helptext, not Placer', async () => {
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP);

        const helptext = element.shadowRoot.querySelector('lightning-helptext');
        expect(helptext.content).toContain('no connection to CoStar');
        expect(helptext.content).not.toContain('Placer');
        expect(helptext.content).toContain('entered by hand');
        expect(helptext.content).toContain('fetches nothing');
        expect(helptext.content).toContain('Property record');
        expect(helptext.content).not.toContain('Data Source');
        expect(helptext.content).not.toContain('Sync Status');

        // The bare label is per-source config too, not a Placer special case.
        expect(
            element.shadowRoot.querySelector('.slds-form-element__label')
                .textContent
        ).toContain('Last Synced');
    });

    it('J17 🔴 STUB WARNING: there is NO spinner and NO busy state, in markup or on the class', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        // 🔴 Animating a fetch that does not happen is how a stub becomes a lie. Asserted BEFORE,
        // DURING (between the click and the awaited resolution) and AFTER, because a spinner added
        // by a later "polish" pass would live exactly in that middle window.
        //
        // The pin is deliberately BROADER than `lightning-spinner` (code review S1). This test
        // protects mitigation (c) of a CONDITIONAL user decision — the button may be labelled `Sync`
        // only while all three stub mitigations hold — so it must be as broad as the condition it
        // guards. A hand-rolled <div class="slds-spinner">, an slds-is-relative overlay and a
        // "Syncing..." label swap are the three most likely forms, and only the first would have
        // been caught by a tag-name query.
        const noBusyIndicator = () => {
            expect(
                element.shadowRoot.querySelector('lightning-spinner')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('[class*="spinner"]')
            ).toBeNull();
            const button = element.shadowRoot.querySelector('lightning-button');
            expect(button.label).toBe('Sync');
            // The cheapest discriminator of all: ANY busy flag would have to disable the button to
            // suppress a double click, so this reds for a busy state that renders no markup at all.
            expect(button.disabled).toBe(false);
        };

        noBusyIndicator();

        clickSync(element);
        noBusyIndicator();

        await flushPromises();
        noBusyIndicator();

        // 🔴 AND THE CLASS ITSELF EXPOSES NO BUSY MEMBER. The header states there is deliberately no
        // isBusy / isSyncing property "so there is nothing for a spinner to bind to"; this asserts
        // that claim rather than trusting it. A busy state has to be reachable from the template, so
        // it would have to be a getter (on the prototype) or a public property (on the element) —
        // both are covered here.
        const members = Object.getOwnPropertyNames(MarketDataSync.prototype);
        expect(members.filter((name) => /busy|syncing|spinner/i.test(name))).toEqual(
            []
        );
        expect(element.isBusy).toBeUndefined();
        expect(element.isSyncing).toBeUndefined();
    });

    it('the Sync button is variant="neutral" — a brand button would assert an unearned primacy', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.label).toBe('Sync');
        expect(button.variant).toBe('neutral');
    });

    it('🔴 the record form renders the PROPERTY: two columns, Property__c, propertyId', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        const forms = formsOf(element);
        // ONE form since 2026-08-17 (the readonly control form went with the fields it held). The
        // assertions below still iterate rather than reaching for `formOf` directly: if a second
        // form is ever reintroduced, its bindings get checked automatically instead of silently
        // escaping a `querySelector` that only ever returns the first.
        expect(forms).toHaveLength(1);

        forms.forEach((form) => {
            expect(form.columns).toBe('2');

            // 🔴 THE RECORD IS THE PROPERTY, NOT THE OPPORTUNITY THE CARD SITS ON.
            expect(form.recordId).toBe(PROPERTY_ID);
            expect(form.recordId).not.toBe(RECORD_ID);

            // The @salesforce/schema IMPORT, not a "Property__c" string literal in the template
            // (code review S5) — the same reference the getObjectInfo wire uses, so the two cannot
            // silently disagree. The schema transform resolves it to { objectApiName: 'Property__c' }.
            expect(form.objectApiName).toEqual(PROPERTY_OBJECT);
            expect(form.objectApiName.objectApiName).toBe('Property__c');
        });

        // mode="view" preserves the per-field inline-edit pencils. A read-only card
        // (lightning-output-field, or spanning Property__r.* fields rendered with
        // lightning-formatted-*) would be a FUNCTIONAL regression — the argument this bundle already
        // made against four fields.
        expect(formOf(element).mode).toBe('view');
    });

    it('🔴 NO provider CONTROL field is rendered on EITHER card, and there is ONE form', async () => {
        // 🔴 THE ABSENCE PIN. All four control fields — both `*_Data_Source__c` and both
        // `*_Fetch_Status__c` — were on these cards earlier on 2026-08-17, in a second
        // `mode="readonly"` form added by code review C2, and the user removed them after seeing the
        // rendered result. Data Source first ("there is no need to add datasource field"), Fetch
        // Status shortly after.
        //
        // 🔴 They are pinned TOGETHER, in one test, because they left for one reason in two steps: a
        // partial re-add is as much a reversal as a full one, and a reader who restores just Fetch
        // Status "because it is the honest one" has undone the same decision.
        //
        // 🔴 This is its own test rather than a line inside J1/J2 because it pins an ABSENCE that a
        // future reader has an obvious, well-meaning reason to undo: ARCHITECTURE §1 describes these
        // as part of the same provider block as the metrics, so "the card is missing the control
        // fields" reads like an oversight. It is not. An exact-array assertion would catch the
        // re-add but would report it as a list mismatch; this one reports the DECISION.
        //
        // ⚠ IT ASSERTS THE CARD ONLY. All four fields still exist on Property__c with their FLS
        // intact and are still seeded — nothing in this change touched their metadata, and nothing
        // here should be read as saying it did.
        const placer = createComponent({ source: 'Placer' });
        await loadFully(placer, PLACER_STAMP);
        const costar = createComponent({ source: 'CoStar' });
        await loadFully(costar, COSTAR_STAMP);

        CONTROL_FIELDS_NOT_ON_CARD.forEach((field) => {
            expect(fieldApiNamesOn(placer)).not.toContain(field);
            expect(fieldApiNamesOn(costar)).not.toContain(field);
        });

        // 🔴 AND THE READ-ONLY FORM WENT WITH THEM. Exactly ONE `lightning-record-form` per card.
        // This is the half that catches a re-add done "properly" — someone restoring a control field
        // AND its readonly form would still trip the field assertions above, but someone restoring
        // the form alone (or a future control field slipped into `metricFields`) is caught here.
        expect(formsOf(placer)).toHaveLength(1);
        expect(formsOf(costar)).toHaveLength(1);
        expect(
            placer.shadowRoot.querySelector('lightning-record-form.mds-controls')
        ).toBeNull();
        expect(
            costar.shadowRoot.querySelector('lightning-record-form.mds-controls')
        ).toBeNull();

        // ⚠ And the surviving form is the EDITABLE one — the metrics keep their inline-edit pencils.
        // Removing the control fields must not have quietly turned the whole card read-only.
        expect(formOf(placer).mode).toBe('view');
        expect(formOf(costar).mode).toBe('view');
    });

    it('🔴 pressing Sync writes no control field — the card cannot move its own status', async () => {
        // The component must not quietly do what the removed read-only form stopped a human doing.
        // A "helpful" future edit that stamps `Fetch_Status__c = 'Success'` alongside the timestamp
        // would make the card assert a fetch that never happened — the exact lie the whole mitigation
        // set exists to prevent — and it would look like a bug fix in review.
        //
        // ⚠ This survives the field's removal from the CARD and is if anything more necessary now:
        // with `Sync Status` no longer displayed, a component that wrote it would do so invisibly.
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP, null);

        clickSync(element);
        await flushPromises();

        const written = Object.keys(updateRecord.mock.calls[0][0].fields);
        expect(written).toEqual(expect.arrayContaining(['Id', PLACER_STAMP]));
        expect(written).toHaveLength(2);
        expect(written).not.toContain('Placer_Fetch_Status__c');
        expect(written).not.toContain('Placer_Data_Source__c');
    });

    it('S3: the button carries a tooltip ONLY when it is refusing, never a copy of its own label', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        // Enabled: a tooltip repeating the visible label is noise.
        expectNoTooltip(element);

        // Disabled for a KNOWN reason: the tooltip carries it, so the refusal survives a narrow
        // layout where the note beside the button has wrapped away.
        getObjectInfo.emit(objectInfoWith(false));
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-button').title).toBe(
            NO_EDIT_ACCESS
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J12 — accessibility, in every rendered state
    // ─────────────────────────────────────────────────────────────────────────

    it('J12 A11Y: the Placer card is accessible', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the CoStar card is accessible', async () => {
        const element = createComponent({ source: 'CoStar' });
        await loadFully(element, COSTAR_STAMP, NEW_STAMP);

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the COLLAPSED section is accessible', async () => {
        const element = createComponent({ source: 'Placer' });
        await loadFully(element, PLACER_STAMP);

        toggleButtonOf(element).click();
        await flushPromises();

        // The header is now an interactive control, so both of its states have to be checked — a
        // toggle that is accessible only when open is not accessible.
        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the misconfigured-source alert state is accessible', async () => {
        const element = createComponent({ source: 'Yardi' });
        await flushPromises();

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the disabled/no-edit-access state is accessible', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(false));
        await emitDeal(PROPERTY_ID);
        await emitProperty(PLACER_STAMP, null);

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the NO-PROPERTY state is accessible', async () => {
        // The newest rendered state, and the only one carrying role="status".
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        await emitDeal(null);

        await expect(element).toBeAccessible();
    });
});
