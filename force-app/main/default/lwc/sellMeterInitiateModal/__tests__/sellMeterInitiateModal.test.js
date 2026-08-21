/**
 * c-sell-meter-initiate-modal — LightningModal + IMPERATIVE Apex suite.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 sfdx-lwc-jest SHIPS NO `lightning/modal` STUB — READ jest-mocks/lightning/modal.js
 * ─────────────────────────────────────────────────────────────────────────────
 * Verified against @salesforce/sfdx-lwc-jest 7.9.0: `src/lightning-stubs/` has
 * modalHeader / modalBody / modalFooter but NOT `modal`. A repo-local stub is
 * mapped in via `jest.config.js` -> moduleNameMapper. Without it this whole file
 * dies with "Cannot find module 'lightning/modal'" — a resolution error that
 * reads like a typo rather than like a missing stub.
 *
 * Because the stub extends LightningElement, the modal is mounted DIRECTLY with
 * createElement here and driven like any other component; `close(result)` is
 * observed through the stub's `close` CustomEvent. There is no promise to await,
 * because there is no platform `open()` in play — that path is exercised from
 * the OPENER's suite (`c-sell-meter-list`), which mocks this module wholesale.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * 🔴 THE LOAD-BEARING ASSERTIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. The record-type radio has NO DEFAULT and the confirm button is DISABLED
 *    until it is answered. A default would silently decide the entire downstream
 *    path (On Market gets BOV Outreach + Active Listing; Off Market gets neither)
 *    for a user who never looked at the control.
 * 2. The values sent to Apex are RECORD TYPE DEVELOPER NAMES ('On_Market' /
 *    'Off_Market'), not labels. The service allow-lists them character-for-
 *    character and masks the resulting exception as a generic write failure, so
 *    a label leaking through here surfaces as an unexplained "could not create".
 * 3. `submitted === false` closes with the OUTCOME, not with an error. It is a
 *    success path — the record exists — and only the caller's toast variant
 *    differs. Turning it into `{ error }` would tell a user nothing was created
 *    about a record that is sitting there.
 * 4. A THROW closes with `{ error }` rather than keeping the form open. Every
 *    refusal reachable here is a property of the ASSET (RED band, already-open
 *    disposition), so re-picking the other record type and retrying produces the
 *    identical refusal.
 */
import { createElement } from 'lwc';
import SellMeterInitiateModal from 'c/sellMeterInitiateModal';
import initiateAndSubmit from '@salesforce/apex/DispositionController.initiateAndSubmit';

jest.mock(
    '@salesforce/apex/DispositionController.initiateAndSubmit',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const ASSET_ID = 'a0P000000000GRN';
const DISPOSITION_ID = 'a0D0000000000001';

const PROPS = {
    assetId: ASSET_ID,
    propertyName: 'Gateway Plaza',
    noiLabel: '$2.0M',
    capRateLabel: '6.5%',
    targetLabel: '$30.0M',
    peakDateLabel: 'Aug 12, 2027'
};

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-sell-meter-initiate-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = PROPS) {
        const element = createElement('c-sell-meter-initiate-modal', {
            is: SellMeterInitiateModal
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    const radio = (el) => el.shadowRoot.querySelector('lightning-radio-group');
    const confirmBtn = (el) => el.shadowRoot.querySelector('.smi-confirm');
    const cancelBtn = (el) => el.shadowRoot.querySelector('.smi-cancel');

    function chooseRecordType(element, value) {
        radio(element).dispatchEvent(
            new CustomEvent('change', { detail: { value } })
        );
        return Promise.resolve();
    }

    it('renders the caller-supplied property summary verbatim — it formats nothing itself', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.smi-value')
        ].map((n) => n.textContent);
        expect(values).toEqual([
            '$2.0M',
            '6.5%',
            '$30.0M',
            'Aug 12, 2027'
        ]);
        // ⚠ THE ASSERTION THAT `.smi-intro` NAMED THE PROPERTY WAS DELETED ON
        // 2026-08-21, NOT SOFTENED. The intro paragraph went with the UAT prose
        // removal and it was the only surface rendering `propertyName`, so there is
        // no weaker version of that assertion to keep — the value is not displayed
        // at all now. See T-NO-PROSE below, which records the consequence.
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 T-NO-PROSE — THE DELIBERATE ABSENCE PIN (2026-08-21 UAT prose removal)
    //
    // `.smi-intro` — "Initiating a disposition for <property> creates the record
    // and sends it straight into the Sale Decision approval." — was removed at
    // the user's request. It is the same shape as the string they quoted: a
    // sentence restating what the button below does.
    //
    // ⚠ IT WAS ALSO THE ONLY PLACE THIS DIALOG NAMED THE PROPERTY. That is a real
    // cost, recorded here rather than hidden: the modal is only ever opened from
    // a row the user just clicked in c/sellMeterList, and `@api propertyName` is
    // still accepted. If the name is wanted back it belongs as a fifth
    // `summaryRows` entry — a label/value pair — NOT as a restored sentence, and
    // the row-count assertion below is what would then need updating.
    // ─────────────────────────────────────────────────────────────────────────

    it('🔴 T-NO-PROSE: no intro paragraph — the removal must not come back', async () => {
        const element = createComponent();

        await Promise.resolve();

        // Guard the guard: the summary genuinely rendered, so the absences below
        // are real absences and not an unrendered component.
        expect(element.shadowRoot.querySelectorAll('.smi-value').length).toBe(4);
        expect(radio(element)).not.toBeNull();

        // 1. THE OLD SELECTOR.
        expect(element.shadowRoot.querySelector('.smi-intro')).toBeNull();

        // 2. 🔴 THE RENDERED WORDS — a re-added paragraph usually arrives under a
        //    new class name, so the selector alone would stay green.
        const text = element.shadowRoot.textContent.toLowerCase();
        expect(text).not.toContain('initiating a disposition for');
        expect(text).not.toContain('creates the record');
        expect(text).not.toContain('straight into the sale decision approval');

        // 3. 🔴 WHAT MUST SURVIVE. The behaviour the sentence described is now
        //    stated ONLY by the button label, so this half of the pin is what
        //    stops a later edit renaming it to something that says nothing.
        expect(confirmBtn(element).label).toBe('Send for Approval');
    });

    it('renders an em dash — NOT "undefined" — for a summary value the caller omitted', async () => {
        const element = createComponent({ assetId: ASSET_ID });

        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.smi-value')
        ].map((n) => n.textContent);
        expect(values).toEqual(['—', '—', '—', '—']);
        // Asserted on the RENDERED text, not on the getter: a getter bound into
        // the DOM is written unconditionally, and `undefined` renders as the
        // literal string "undefined".
        expect(element.shadowRoot.textContent).not.toContain('undefined');
    });

    it('offers exactly two options, and their VALUES are record type developer names', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(radio(element).options).toEqual([
            { label: 'On Market', value: 'On_Market' },
            { label: 'Off Market', value: 'Off_Market' }
        ]);
        // No default. The choice is mandatory and the platform must not pick.
        expect(radio(element).value).toBeUndefined();
        expect(radio(element).required).toBe(true);
    });

    it('GATE: "Send for Approval" is disabled until a record type is chosen', async () => {
        const element = createComponent();

        await Promise.resolve();
        expect(confirmBtn(element).disabled).toBe(true);

        await chooseRecordType(element, 'Off_Market');
        expect(confirmBtn(element).disabled).toBe(false);
    });

    it('GATE: clicking the disabled confirm button calls no Apex', async () => {
        const element = createComponent();

        await Promise.resolve();
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).not.toHaveBeenCalled();
    });

    it('SUCCESS: sends the chosen developer name to Apex and closes with the outcome', async () => {
        const outcome = {
            dispositionId: DISPOSITION_ID,
            submitted: true,
            message: 'Disposition created and submitted for approval.'
        };
        initiateAndSubmit.mockResolvedValue(outcome);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).toHaveBeenCalledTimes(1);
        // Parameter names ARE the Apex signature — an imperative call binds by name.
        expect(initiateAndSubmit).toHaveBeenCalledWith({
            assetId: ASSET_ID,
            recordTypeDeveloperName: 'On_Market'
        });

        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ outcome });
    });

    it('OFF MARKET: the other radio choice reaches Apex unchanged', async () => {
        initiateAndSubmit.mockResolvedValue({
            dispositionId: DISPOSITION_ID,
            submitted: true,
            message: 'ok'
        });

        const element = createComponent();

        await chooseRecordType(element, 'Off_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).toHaveBeenCalledWith({
            assetId: ASSET_ID,
            recordTypeDeveloperName: 'Off_Market'
        });
    });

    it('NOT-SUBMITTED IS A SUCCESS PATH: closes with the outcome, not with an error', async () => {
        const outcome = {
            dispositionId: DISPOSITION_ID,
            submitted: false,
            message: 'Created, but the approval could not be submitted.'
        };
        initiateAndSubmit.mockResolvedValue(outcome);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        const detail = closeHandler.mock.calls[0][0].detail;
        expect(detail.outcome).toBe(outcome);
        expect(detail.error).toBeUndefined();
        // The Id is populated, which is the whole reason the caller still navigates.
        expect(detail.outcome.dispositionId).toBe(DISPOSITION_ID);
    });

    it('FAILURE: a thrown Apex error CLOSES the modal carrying the error', async () => {
        const error = {
            body: {
                message:
                    'This property is not ready to sell - its peak sell date is more than 90 days away.'
            }
        };
        initiateAndSubmit.mockRejectedValue(error);

        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await chooseRecordType(element, 'On_Market');
        confirmBtn(element).click();
        await flushPromises();

        expect(closeHandler).toHaveBeenCalledTimes(1);
        expect(closeHandler.mock.calls[0][0].detail).toEqual({ error });
    });

    it('CANCEL: closes with undefined and calls no Apex', async () => {
        const element = createComponent();
        const closeHandler = jest.fn();
        element.addEventListener('close', closeHandler);

        await Promise.resolve();
        cancelBtn(element).click();
        await flushPromises();

        expect(initiateAndSubmit).not.toHaveBeenCalled();
        expect(closeHandler).toHaveBeenCalledTimes(1);
        // ⚠ `null`, not `undefined`, and that is a STUB ARTEFACT: CustomEvent's
        // own spec defaults an omitted `detail` to null. The real LightningModal
        // resolves `undefined` on a dismiss. Asserted as falsy so the test states
        // the contract the caller actually relies on (`if (!result) return;`)
        // rather than pinning the stub's coercion.
        expect(closeHandler.mock.calls[0][0].detail).toBeFalsy();
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
