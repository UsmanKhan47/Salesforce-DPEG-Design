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
 * 🔴 THE LOAD-BEARING TEST IN THIS SUITE IS J6, AND IT IS A NEGATIVE
 * ═════════════════════════════════════════════════════════════════════════════
 * `getRecordNotifyChange` must NEVER be called. `updateRecord` writes THROUGH the LDS cache, so the
 * record page re-renders on its own (the c/leadStatusChange rule). That is the EXACT OPPOSITE of the
 * c/dealActionGuard / c/recordStageGuard rule, which applies only to imperative Apex DML.
 *
 * The failure this pins is a plausible one, which is why it is written as its own test rather than
 * left as an incidental assertion: this repo has four bundles that MUST call it, and someone reading
 * them will reasonably "fix" this component by analogy. J6 is the permanent falsifier. DO NOT DELETE
 * IT. When a real callout lands and the write moves to Apex, J6 INVERTS (assert it IS called) — it
 * does not disappear.
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
 * - `getObjectInfo`'s fixture only needs the `fields` map entries the component reads, each with an
 *   `updateable` flag. Both stamp fields are supplied on every emit so a single helper serves both
 *   source configurations.
 * - The component FAILS CLOSED on access: until `getObjectInfo` emits, the button is disabled. Every
 *   test that clicks Sync therefore emits object info first. That is not test scaffolding working
 *   around the component — it is the fail-closed behaviour, and `renders the button DISABLED before
 *   the object info arrives` asserts it directly.
 */
import { createElement } from 'lwc';
import MarketDataSync from 'c/marketDataSync';
import {
    getRecord,
    updateRecord,
    getRecordNotifyChange
} from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import OPPORTUNITY_OBJECT from '@salesforce/schema/Opportunity';

const RECORD_ID = '006iw000004GtLmAAK';

const PLACER_STAMP = 'Placer_Last_Synced_DateTime__c';
const COSTAR_STAMP = 'CoStar_Last_Synced_DateTime__c';

const OLD_STAMP = '2026-07-01T09:14:00.000Z';
const NEW_STAMP = '2026-08-16T11:30:00.000Z';

const GENERIC_ERROR =
    'The sync timestamp could not be saved. Please try again or contact your administrator.';
const NO_EDIT_ACCESS =
    'You do not have edit access to this field, so it cannot be stamped.';

/** Object info carrying the two stamp fields, both editable unless told otherwise. */
function objectInfoWith(updateable = true) {
    return {
        apiName: 'Opportunity',
        fields: {
            [PLACER_STAMP]: { apiName: PLACER_STAMP, updateable },
            [COSTAR_STAMP]: { apiName: COSTAR_STAMP, updateable }
        }
    };
}

/** A record carrying one stamp value. Pass `undefined` for a never-synced deal. */
function recordWith(stampField, value) {
    return {
        apiName: 'Opportunity',
        id: RECORD_ID,
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

    function fieldApiNamesOn(element) {
        const form = element.shadowRoot.querySelector('lightning-record-form');
        return form ? form.fields.map((field) => field.fieldApiName) : null;
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
    // J1 / J2 — the CONFIG_BY_SOURCE parameterisation
    // ─────────────────────────────────────────────────────────────────────────

    it('J1 PLACER: renders the Placer title and field set, and no CoStar field', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));

        await flushPromises();

        // SENTENCE case, exactly as a native field section renders it. The first version used
        // `slds-text-title_caps` (the utility-bar treatment), which rendered "PLACER".
        expect(sectionTitleOf(element)).toBe('Placer');
        // 🔴 No source icon: the only lightning-icon in the header is the collapse chevron. Dropped
        // by user decision so the card matches the native "Broker" section, which has none.
        expect(iconNamesInHeader(element)).toEqual(['utility:switch']);

        const fields = fieldApiNamesOn(element);
        // The exact list, not a containment check: an extra field on this card is a real defect —
        // the Sync button and the Last Synced row are an assertion ABOUT the fields beside them.
        expect(fields).toEqual(['Placer_URL__c', 'Monthly_Visits__c']);
        expect(fields).not.toContain('CoStar_URL__c');
        expect(fields).not.toContain('Market_Cap_Rate__c');

        // The stamp field is NOT in the form — this component renders it itself as the
        // "Last Synced (manual)" row, so that it can carry the label and the helptext.
        expect(fields).not.toContain(PLACER_STAMP);
    });

    it('J2 COSTAR: renders the CoStar title and field set, and no Placer field', async () => {
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(COSTAR_STAMP, OLD_STAMP));

        await flushPromises();

        expect(sectionTitleOf(element)).toBe('CoStar');
        expect(iconNamesInHeader(element)).toEqual(['utility:switch']);

        const fields = fieldApiNamesOn(element);
        expect(fields).toEqual(['CoStar_URL__c', 'Market_Cap_Rate__c']);
        expect(fields).not.toContain('Monthly_Visits__c');
        expect(fields).not.toContain('Placer_URL__c');
        expect(fields).not.toContain(COSTAR_STAMP);
    });

    it('defaults to Placer when no source is supplied, matching the js-meta default', async () => {
        const element = createComponent();
        getObjectInfo.emit(objectInfoWith(true));

        await flushPromises();

        expect(fieldApiNamesOn(element)).toEqual([
            'Placer_URL__c',
            'Monthly_Visits__c'
        ]);
    });

    it('LOADING: the Last Synced row says NOTHING before the record wire answers — never "Never"', async () => {
        // 🔴 REGRESSION PIN (code review W2). Before any emit the component does not know whether
        // this deal has ever been synced, and "Never" is an ASSERTION. It is the same
        // confident-wrong-answer class as reporting "Not available" as "Never" on the error branch,
        // and as accusing a user of lacking edit access while the object info is still in flight.
        // All three are one rule: say nothing until you know. This is the only one of the three that
        // shipped wrong, precisely because no test covered the pre-emit window.
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

        // ...and it becomes "Never" only once the record has actually answered with a null stamp.
        getRecord.emit(recordWith(PLACER_STAMP, null));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Never'
        );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // The collapsible field-section header (SLDS Expandable Section blueprint)
    // ─────────────────────────────────────────────────────────────────────────

    it('SECTION: defaults to EXPANDED, matching a native Dynamic Forms field section', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('.slds-section').className
        ).toContain('slds-is-open');
        expect(toggleButtonOf(element).getAttribute('aria-expanded')).toBe('true');
        expect(sectionContentOf(element).getAttribute('aria-hidden')).toBe(
            'false'
        );
        expect(
            element.shadowRoot.querySelector('lightning-record-form')
        ).not.toBeNull();
    });

    it('SECTION: the WHOLE BAR is the toggle, and clicking it collapses the section', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

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
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        // LWC mangles template ids at runtime and rewrites idref attributes to match, so this asserts
        // the RESOLVED pair rather than the literal authored string — a dangling aria-controls is
        // invisible to a reader of the template but is a real defect for assistive technology.
        const controls = toggleButtonOf(element).getAttribute('aria-controls');
        expect(controls).toBeTruthy();
        expect(sectionContentOf(element).getAttribute('id')).toBe(controls);
        expect(element.shadowRoot.querySelector(`[id="${controls}"]`)).not.toBeNull();
    });

    it('SECTION A11Y: collapsed content is hidden from AT and holds no focusable control', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

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
        expect(
            element.shadowRoot.querySelector('lightning-record-form')
        ).toBeNull();
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

            expect(
                element.shadowRoot.querySelector('lightning-record-form')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('lightning-button')
            ).toBeNull();
        }
    );

    it('J3 (cont): an invalid source never throws and never writes, even if a wire emits', async () => {
        const element = createComponent({ source: 'Yardi' });
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));

        await flushPromises();

        expect(updateRecord).not.toHaveBeenCalled();
        expect(toastHandler).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J4 / J5 — the write targets exactly one field, and the right one
    // ─────────────────────────────────────────────────────────────────────────

    it('J4 SYNC (Placer): writes Id + Placer_Last_Synced_DateTime__c and NO other field', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, null));
        await flushPromises();

        clickSync(element);
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        const payload = updateRecord.mock.calls[0][0];

        // Exactly two keys. A third would mean this card silently writes something the user did not
        // ask it to, which is the failure mode a Sync button is most likely to grow.
        expect(Object.keys(payload.fields).sort()).toEqual(['Id', PLACER_STAMP]);
        expect(payload.fields.Id).toBe(RECORD_ID);
        expect(typeof payload.fields[PLACER_STAMP]).toBe('string');
        // An ISO 8601 instant, which is what LDS accepts for a DateTime.
        expect(Number.isNaN(Date.parse(payload.fields[PLACER_STAMP]))).toBe(false);
        expect(payload.fields[COSTAR_STAMP]).toBeUndefined();
    });

    it('J5 SYNC (CoStar): the same write targets CoStar_Last_Synced_DateTime__c', async () => {
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(COSTAR_STAMP, null));
        await flushPromises();

        clickSync(element);
        await flushPromises();

        expect(updateRecord).toHaveBeenCalledTimes(1);
        const payload = updateRecord.mock.calls[0][0];
        // Sorted, so the stamp field sorts ahead of `Id` here and behind it in J4. The assertion is
        // about the SET of keys being exactly two, not about their order.
        expect(Object.keys(payload.fields).sort()).toEqual([COSTAR_STAMP, 'Id']);
        expect(payload.fields[PLACER_STAMP]).toBeUndefined();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J6 — 🔴 PERMANENT FALSIFIER. DO NOT DELETE.
    // ─────────────────────────────────────────────────────────────────────────

    it('J6 🔴 getRecordNotifyChange is NEVER called — updateRecord writes THROUGH the LDS cache', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

        clickSync(element);
        await flushPromises();

        // Sanity: the write really did happen, so this is not vacuously green.
        expect(updateRecord).toHaveBeenCalledTimes(1);

        // 🔴 THE ASSERTION. c/advanceRecordStage and c/advanceDealStage MUST call this because their
        // writes are imperative Apex and bypass the LDS cache. This component MUST NOT, because
        // updateRecord writes through it. ARCHITECTURE.md §5's guard-util table records that the two
        // requirements are opposite and must not be harmonised.
        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('J6 (cont): it is not called on the ERROR path either', async () => {
        updateRecord.mockRejectedValueOnce({ body: { message: 'nope' } });

        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        clickSync(element);
        await flushPromises();

        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J7 — success toast, and the row re-renders from the RECORD, not local state
    // ─────────────────────────────────────────────────────────────────────────

    it('J7 SUCCESS: toasts, and the Last Synced row follows the refreshed record, not local state', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

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

        // Now the LDS cache re-emits, exactly as it does in the org because updateRecord writes
        // through it.
        getRecord.emit(recordWith(PLACER_STAMP, NEW_STAMP));
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time').value
        ).toBe(NEW_STAMP);
    });

    it('J7 (cont): a never-synced deal reads "Never", and a refused record read reads "Not available"', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, null));
        await flushPromises();

        expect(
            element.shadowRoot.querySelector('lightning-formatted-date-time')
        ).toBeNull();
        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Never'
        );

        // A record the running user cannot read must NOT read as "never synced" — that is a
        // confident wrong answer where "not available" is a true one.
        getRecord.error({ message: 'no FLS' });
        await flushPromises();

        expect(element.shadowRoot.querySelector('.mds-muted').textContent).toBe(
            'Not available'
        );
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
                                'A CoStar URL is required before this deal can be marked as synced.'
                        }
                    ],
                    fieldErrors: {}
                }
            }
        });

        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'A CoStar URL is required before this deal can be marked as synced.'
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
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

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
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

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
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        clickSync(element);
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe('Bad field.');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // J11 — FLS edit on the stamp field IS the gate. No custom permission exists.
    // ─────────────────────────────────────────────────────────────────────────

    it('J11 NOT UPDATEABLE: the button is disabled WITH A REASON and a click writes nothing', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(false));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

        const button = element.shadowRoot.querySelector('lightning-button');
        // Present, not hidden: a missing button is indistinguishable from "this feature is not for
        // me". That is the same silent-denial defect that retired the User.*_Driver__c model.
        expect(button).not.toBeNull();
        expect(button.disabled).toBe(true);

        const reason = element.shadowRoot.querySelector('.mds-reason');
        expect(reason).not.toBeNull();
        expect(reason.textContent).toBe(NO_EDIT_ACCESS);

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
        await flushPromises();

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
    // The stub warning — mitigations (a) and (b) of the header. These are the
    // conditions on which the user's choice of the label `Sync` depends.
    // ─────────────────────────────────────────────────────────────────────────

    it('STUB WARNING: the row is labelled "Last Synced (manual)" and carries the hand-entered helptext', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

        const label = element.shadowRoot.querySelector(
            '.slds-form-element__label'
        );
        // 🔴 "(manual)" is a REQUIREMENT, not wording. Without it the row asserts a freshness the
        // data does not have. The button label `Sync` was accepted by the user only WITH this
        // mitigation, the helptext below, and the absence of any spinner.
        expect(label.textContent).toContain('Last Synced (manual)');

        const helptext = element.shadowRoot.querySelector('lightning-helptext');
        expect(helptext).not.toBeNull();
        expect(helptext.content).toContain('no connection to Placer.ai');
        expect(helptext.content).toContain('entered by hand');
    });

    it('STUB WARNING: the CoStar card names CoStar in its helptext, not Placer', async () => {
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        const helptext = element.shadowRoot.querySelector('lightning-helptext');
        expect(helptext.content).toContain('no connection to CoStar');
        expect(helptext.content).not.toContain('Placer');
    });

    it('STUB WARNING: there is NO spinner and NO busy state at any point in the click', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        // 🔴 Animating a fetch that does not happen is how a stub becomes a lie. Asserted BEFORE,
        // DURING (between the click and the awaited resolution) and AFTER, because a spinner added
        // by a later "polish" pass would live exactly in that middle window.
        //
        // The pin is deliberately BROADER than `lightning-spinner` (code review S1). This test
        // protects mitigation (c) of a CONDITIONAL user decision — the button may be labelled `Sync`
        // only while all three R1 mitigations hold — so it must be as broad as the condition it
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
    });

    it('the Sync button is variant="neutral" — a brand button would assert an unearned primacy', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.label).toBe('Sync');
        expect(button.variant).toBe('neutral');
    });

    it('the record form is view mode, two columns — the nearest reproduction of a field section', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

        const form = element.shadowRoot.querySelector('lightning-record-form');
        // mode="view" preserves the per-field inline-edit pencils. A read-only card
        // (lightning-output-field) would be a FUNCTIONAL regression: every field here is
        // behavior=Edit on the layout today.
        expect(form.mode).toBe('view');
        expect(form.columns).toBe('2');
        expect(form.recordId).toBe(RECORD_ID);

        // The @salesforce/schema IMPORT, not a "Opportunity" string literal in the template (code
        // review S5) — the same reference the getObjectInfo wire uses, so the two cannot silently
        // disagree. The schema transform resolves it to { objectApiName: 'Opportunity' }.
        expect(form.objectApiName).toEqual(OPPORTUNITY_OBJECT);
        expect(form.objectApiName.objectApiName).toBe('Opportunity');
    });

    it('S3: the button carries a tooltip ONLY when it is refusing, never a copy of its own label', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        await flushPromises();

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
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the CoStar card is accessible', async () => {
        const element = createComponent({ source: 'CoStar' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(COSTAR_STAMP, NEW_STAMP));
        await flushPromises();

        await expect(element).toBeAccessible();
    });

    it('J12 A11Y: the COLLAPSED section is accessible', async () => {
        const element = createComponent({ source: 'Placer' });
        getObjectInfo.emit(objectInfoWith(true));
        getRecord.emit(recordWith(PLACER_STAMP, OLD_STAMP));
        await flushPromises();

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
        getRecord.emit(recordWith(PLACER_STAMP, null));
        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
