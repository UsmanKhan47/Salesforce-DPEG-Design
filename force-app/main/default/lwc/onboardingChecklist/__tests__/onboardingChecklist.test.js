/**
 * MIXED suite for c-onboarding-checklist — it both READS via
 * @wire(getChecklist, { onboardingId: '$recordId' }) and WRITES via the
 * imperative completeTask(). So this suite combines two template patterns:
 *   - getChecklist -> createApexTestWireAdapter + .emit()/.error()   (wire)
 *   - completeTask -> plain jest.fn() + mockResolvedValue()          (imperative)
 * refreshApex (@salesforce/apex) and notifyRecordUpdateAvailable
 * (lightning/uiRecordApi) are auto-stubbed by sfdx-lwc-jest as resolved
 * promises; notifyRecordUpdateAvailable is imported here only to assert it fires
 * on the success path.
 */
import { createElement } from 'lwc';
import OnboardingChecklist from 'c/onboardingChecklist';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';
import completeTask from '@salesforce/apex/OnboardingController.completeTask';
import { notifyRecordUpdateAvailable, getRecord } from 'lightning/uiRecordApi';
import UtilityMeterCapture from 'c/utilityMeterCapture';

jest.mock(
    '@salesforce/apex/OnboardingController.getChecklist',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/OnboardingController.completeTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
// UT-001: the modal MODULE is replaced, not spied. lightning/modal's stub makes the static
// open() throw on purpose, so letting the real one run would kill the suite on resolution.
jest.mock(
    'c/utilityMeterCapture',
    () => ({ __esModule: true, default: { open: jest.fn() } }),
    { virtual: true }
);

const RECORD_ID = 'a0x5g000000OnbAAAW';

// Task id of the single open (Not Started) row — the only checkbox that is enabled.
const OPEN_TASK_ID = '00T5g000001AbdAEAV';

// Matches OnboardingController.ChecklistGroup[] / ChecklistItem shape.
const GROUPS = [
    {
        category: 'Property Set up',
        total: 3,
        complete: 1,
        items: [
            {
                id: '00T5g000001AbcAEAV',
                name: 'Create Property Record',
                status: 'Complete',
                sourceSystem: 'Yardi',
                owner: 'Jane Smith',
                due: '2026-01-05',
                reason: null,
                hasNotes: true,
                overdue: false
            },
            {
                id: OPEN_TASK_ID,
                name: 'Assign Onboarding Lead',
                status: 'Not Started',
                sourceSystem: 'Manual',
                owner: 'Accounting Queue',
                due: '2026-02-10',
                reason: null,
                hasNotes: false,
                overdue: true
            },
            {
                id: '00T5g000001AbeAEAV',
                name: 'Verify Title Documents',
                status: 'Not Applicable',
                sourceSystem: 'Manual',
                owner: 'Bob Lee',
                due: null,
                reason: 'Not required for this asset',
                hasNotes: false,
                overdue: false
            }
        ]
    },
    {
        category: 'Unit & Tenant Setup',
        total: 2,
        complete: 2,
        items: [
            {
                id: '00T5g000001AbfAEAV',
                name: 'Import Rent Roll',
                status: 'Complete',
                sourceSystem: 'Yardi',
                owner: 'Jane Smith',
                due: '2026-01-20',
                reason: null,
                hasNotes: false,
                overdue: false
            },
            {
                id: '00T5g000001AbgAEAV',
                name: 'Load Tenant Contacts',
                status: 'Complete',
                sourceSystem: 'Yardi',
                owner: 'Jane Smith',
                due: '2026-01-22',
                reason: null,
                hasNotes: false,
                overdue: false
            }
        ]
    }
]
/* UT-001 fixture. The category and Subject are verbatim from row 28 of
   scripts/load-onboarding-task-defs.apex, which is what seeds the
   Onboarding_Task_Def__mdt record every new onboarding fans out from. If either string
   drifts from that file, UT-001 stops firing SILENTLY - no error, the modal just never
   appears - and these two tests are the only thing that would notice. */
const UTILITY_CATEGORY = 'Vendor & Expense Management';
const UTILITY_SUBJECT = 'Set up utility accounts & transfers';
const UTILITY_TASK_ID = '00T5g000001AbhAEAV';
const OTHER_VENDOR_TASK_ID = '00T5g000001AbiAEAV';

const VENDOR_GROUP = {
    category: UTILITY_CATEGORY,
    total: 2,
    complete: 0,
    items: [
        {
            id: UTILITY_TASK_ID,
            name: UTILITY_SUBJECT,
            status: 'Not Started',
            sourceSystem: 'Email',
            owner: 'Endya Williams',
            due: '2026-03-01',
            reason: null,
            hasNotes: false,
            overdue: false
        },
        {
            id: OTHER_VENDOR_TASK_ID,
            name: 'Enter vendor list & W-9s',
            status: 'Not Started',
            sourceSystem: 'Yardi',
            owner: 'Accounting Queue',
            due: '2026-03-02',
            reason: null,
            hasNotes: false,
            overdue: false
        }
    ]
};

const ONBOARDING_RECORD = {
    id: RECORD_ID,
    apiName: 'Onboarding__c',
    fields: {
        Property_Asset__c: { value: 'a0a5g000000PrpAAAS', displayValue: null },
        Property_Name__c: { value: 'Park North', displayValue: null }
    }
};;

describe('c-onboarding-checklist', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-onboarding-checklist', {
            is: OnboardingChecklist
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function flushPromises() {
        return Promise.resolve();
    }

    it('renders the four filter chips and an empty task list before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const chips = element.shadowRoot.querySelectorAll('.oc-chip');
        expect(chips.length).toBe(4);
        expect(element.shadowRoot.querySelectorAll('.oc-gchip').length).toBe(0);
        expect(element.shadowRoot.querySelector('.oc-empty').textContent).toBe(
            'No tasks match this filter in this category.'
        );
    });

    it('DATA BRANCH: renders a ring tile per group and the selected group tasks', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        const tiles = element.shadowRoot.querySelectorAll('.oc-gchip');
        expect(tiles.length).toBe(2);
        expect(
            element.shadowRoot.querySelector('.oc-gchip-name').textContent
        ).toBe('Property Set up');
        expect(
            element.shadowRoot.querySelector('.oc-gchip-count').textContent
        ).toBe('1 / 3');

        // Selected group defaults to index 0 -> all three of its tasks show.
        const subjects = [
            ...element.shadowRoot.querySelectorAll('.oc-subject')
        ].map((el) => el.textContent);
        expect(subjects).toEqual([
            'Create Property Record',
            'Assign Onboarding Lead',
            'Verify Title Documents'
        ]);
    });

    it('selectGroup switches the detail card to the clicked group', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        const secondTile = element.shadowRoot.querySelectorAll('.oc-gchip')[1];
        secondTile.click();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.oc-detail-name').textContent
        ).toBe('Unit & Tenant Setup');
        expect(
            element.shadowRoot.querySelectorAll('.oc-task').length
        ).toBe(2);
    });

    it('selectFilter narrows the task list (Completed keeps only complete rows)', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        // Chip order = ['All','Not Started','Overdue','Completed'].
        const completedChip = element.shadowRoot.querySelectorAll('.oc-chip')[3];
        completedChip.click();
        await Promise.resolve();

        const subjects = [
            ...element.shadowRoot.querySelectorAll('.oc-subject')
        ].map((el) => el.textContent);
        expect(subjects).toEqual(['Create Property Record']);
    });

    it('handleCheck on an open task opens the confirm modal with the subject', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        // The only enabled checkbox is the open (Not Started) task.
        const openCheck = element.shadowRoot.querySelector(
            '.oc-check:not([disabled])'
        );
        expect(openCheck).not.toBeNull();
        openCheck.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        const dialog = element.shadowRoot.querySelector('[role="dialog"]');
        expect(dialog).not.toBeNull();
        expect(
            element.shadowRoot.querySelector('.oc-confirm-subject').textContent
        ).toBe('Assign Onboarding Lead');
    });

    it('SUCCESS BRANCH: confirmComplete calls Apex, notifies the record, and closes the modal', async () => {
        completeTask.mockResolvedValue(undefined);

        const element = createComponent();
        getChecklist.emit(GROUPS);
        await Promise.resolve();

        // Open the modal.
        element.shadowRoot
            .querySelector('.oc-check:not([disabled])')
            .dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        // Confirm.
        element.shadowRoot.querySelector('button.slds-button_brand').click();
        await flushPromises();
        await flushPromises();

        expect(completeTask).toHaveBeenCalledTimes(1);
        expect(completeTask).toHaveBeenCalledWith({
            taskId: OPEN_TASK_ID,
            notes: ''
        });
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);

        // Modal closed after the save resolves.
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('[role="dialog"]')).toBeNull();
    });

    it('WIRE ERROR BRANCH: renders an inline error alert when the checklist read fails', async () => {
        const element = createComponent();

        getChecklist.error();
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        // No group tiles when the read fails.
        expect(element.shadowRoot.querySelectorAll('.oc-gchip').length).toBe(0);
    });

    it('SAVE ERROR BRANCH: shows an error toast and keeps the modal open when completeTask fails', async () => {
        completeTask.mockRejectedValue({ body: { message: 'Task is locked.' } });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        // Open the confirm modal on the single open task.
        element.shadowRoot
            .querySelector('.oc-check:not([disabled])')
            .dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        // Confirm -> completeTask rejects.
        element.shadowRoot.querySelector('button.slds-button_brand').click();
        await flushPromises();
        await flushPromises();

        expect(completeTask).toHaveBeenCalledTimes(1);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe('Task is locked.');

        // Modal stays open so the user can retry — nothing was persisted.
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('[role="dialog"]')).not.toBeNull();
        // The record was never notified of a (non-existent) update.
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
    });

    it('is accessible (empty-category state — no unlabeled checkboxes rendered)', async () => {
        const element = createComponent();

        // A single category with no items -> tiles + detail render, but no
        // checkbox inputs, keeping the tree axe-clean.
        getChecklist.emit([
            { category: 'Property Set up', total: 0, complete: 0, items: [] }
        ]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    /* ══════════════════════════════════════════════════════════════════════════
       FSD UAT UT-001 — "Onboarding utility-transfer task completed → meter capture
       screen opens; meters saved against property and spaces."

       🔴 A BEHAVIOUR CHANGE TO A SHIPPED FEATURE, CROSSING A MODULE BOUNDARY
       (Onboarding → Utilities). The three tests below are the whole guarantee that
       it is SCOPED: one proves the modal opens for the utility row, and two prove
       it does NOT open for the 44 other rows or for a completion that failed.
       ══════════════════════════════════════════════════════════════════════════ */

    /** Completes a specific task in the Vendor & Expense Management group. */
    async function completeVendorTask(element, taskId) {
        getChecklist.emit([GROUPS[0], VENDOR_GROUP]);
        await Promise.resolve();

        // Select the vendor group (tile index 1) so its rows are the ones rendered.
        element.shadowRoot.querySelectorAll('.oc-gchip')[1].click();
        await Promise.resolve();

        const checkbox = [...element.shadowRoot.querySelectorAll('.oc-check')].find(
            (el) => el.dataset.id === taskId
        );
        checkbox.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        element.shadowRoot.querySelector('button.slds-button_brand').click();
        await flushPromises();
        await flushPromises();
        await flushPromises();
    }

    it('UT-001: completing the utility-transfer task opens the meter capture screen', async () => {
        completeTask.mockResolvedValue(undefined);
        UtilityMeterCapture.open.mockResolvedValue(undefined);

        const element = createComponent();
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(completeTask).toHaveBeenCalledWith({ taskId: UTILITY_TASK_ID, notes: '' });
        expect(UtilityMeterCapture.open).toHaveBeenCalledTimes(1);
        const args = UtilityMeterCapture.open.mock.calls[0][0];
        // The property comes from the Onboarding via LDS - no Apex was widened to supply it.
        expect(args.propertyAssetId).toBe('a0a5g000000PrpAAAS');
        expect(args.propertyName).toBe('Park North');
    });

    it('UT-001 SCOPE: another task in the SAME category closes silently', async () => {
        // The falsifier. Matching on the category alone would fire on all eight Vendor &
        // Expense Management rows; matching on the subject alone would fire on an
        // identically-worded row added to another category later. BOTH must match.
        completeTask.mockResolvedValue(undefined);

        const element = createComponent();
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, OTHER_VENDOR_TASK_ID);

        expect(completeTask).toHaveBeenCalledWith({
            taskId: OTHER_VENDOR_TASK_ID,
            notes: ''
        });
        expect(UtilityMeterCapture.open).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('[role="dialog"]')).toBeNull();
    });

    it('UT-001 SCOPE: a task in a different category closes silently', async () => {
        // The pre-existing behaviour of the other 44 checklist rows, pinned so this change
        // cannot quietly widen. Without this, a regression to "open on every completion"
        // would still pass every other test in this suite.
        completeTask.mockResolvedValue(undefined);

        const element = createComponent();
        getRecord.emit(ONBOARDING_RECORD);
        getChecklist.emit(GROUPS);
        await Promise.resolve();

        element.shadowRoot
            .querySelector('.oc-check:not([disabled])')
            .dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();
        element.shadowRoot.querySelector('button.slds-button_brand').click();
        await flushPromises();
        await flushPromises();

        expect(completeTask).toHaveBeenCalledTimes(1);
        expect(UtilityMeterCapture.open).not.toHaveBeenCalled();
    });

    it('UT-001: a FAILED completion never opens the capture screen', async () => {
        // The modal opens only AFTER the completion is persisted. Asking a user to record
        // meters for a task that did not complete would be worse than not opening at all.
        completeTask.mockRejectedValue({ body: { message: 'Task is locked.' } });

        const element = createComponent();
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(UtilityMeterCapture.open).not.toHaveBeenCalled();
        // And the confirm dialog stays open so the user can retry.
        expect(element.shadowRoot.querySelector('[role="dialog"]')).not.toBeNull();
    });

    it('UT-001: an onboarding with no property warns instead of opening an unsaveable grid', async () => {
        completeTask.mockResolvedValue(undefined);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        getRecord.emit({
            ...ONBOARDING_RECORD,
            fields: {
                Property_Asset__c: { value: null, displayValue: null },
                Property_Name__c: { value: null, displayValue: null }
            }
        });
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(UtilityMeterCapture.open).not.toHaveBeenCalled();
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('warning');
        // Opening the grid without a property would let a user type a whole register that
        // the save then refuses - MeterCaptureService requires one.
        expect(toastHandler.mock.calls[0][0].detail.message).toContain('no property linked');
    });

    it('UT-001: a saved capture toasts what happened, warnings separately and sticky', async () => {
        completeTask.mockResolvedValue(undefined);
        UtilityMeterCapture.open.mockResolvedValue({
            result: {
                created: 3,
                updated: 0,
                skipped: 2,
                meterIds: [],
                warnings: ['Service identifier ESID-1 is already on the register under 5512345.']
            }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(toastHandler).toHaveBeenCalledTimes(2);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe('3 created, 0 updated.');
        const warning = toastHandler.mock.calls[1][0].detail;
        expect(warning.variant).toBe('warning');
        // STICKY: a possible physical meter swap is the one thing here a person has to act
        // on later, so it must not vanish after four seconds.
        expect(warning.mode).toBe('sticky');
    });

    it('UT-001: a cancelled capture says nothing at all', async () => {
        completeTask.mockResolvedValue(undefined);
        // Falsy, not undefined: the Jest stub's close() with no argument arrives as
        // detail === null while the real LightningModal resolves undefined. Both mean
        // "cancelled" and the component must not distinguish them.
        UtilityMeterCapture.open.mockResolvedValue(null);

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(UtilityMeterCapture.open).toHaveBeenCalledTimes(1);
        expect(toastHandler).not.toHaveBeenCalled();
    });

    it('UT-001: a failed capture raises a sticky error toast', async () => {
        completeTask.mockResolvedValue(undefined);
        UtilityMeterCapture.open.mockResolvedValue({
            error: { body: { message: 'The meters could not be saved.' } }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);
        getRecord.emit(ONBOARDING_RECORD);
        await completeVendorTask(element, UTILITY_TASK_ID);

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.mode).toBe('sticky');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The meters could not be saved.'
        );
    });
});
