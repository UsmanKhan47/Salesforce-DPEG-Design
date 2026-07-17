/**
 * c-transaction-task-groups — @wire-to-Apex READ + two IMPERATIVE Apex WRITES.
 * Combines wire-mock template 1 (Apex @wire, parameterised on '$recordId') with
 * template 2 (imperative Apex) for the two completion flows:
 *   - @wire(getTaskGroups, { transactionId: '$recordId' }) -> TransactionTaskController
 *   - confirmComplete() -> completeTask({ taskId, notes })
 *   - submitWire()      -> completeWireVerification({ taskId, verifiedBy, phone, comments })
 *
 * getTaskGroups is an Apex test wire adapter (emit/error). completeTask and
 * completeWireVerification are plain jest.fns whose call args are asserted.
 * refreshApex ('@salesforce/apex') is toolchain-stubbed to a resolved Promise, so
 * the post-write refresh settles without a throw (not asserted).
 *
 * The wire returns task GROUPS: { key, letter, name, total, complete, pct,
 * conditional, ownerLabel, tasks: [{ id, subject, done, verifyComplete, verifiedBy,
 * notes, ownerLabel, completedDate, phone, verifiedAt }] }. Letters map to the four
 * phases (A/B -> Open Contract, C..H2 -> Due Diligence, I -> Closing, J -> Post).
 * Subjects ending "(anti-fraud)" are wire-verification tasks (WIRE_RE) that open the
 * anti-fraud dialog instead of the plain confirm dialog.
 *
 * Completion-date text runs `new Date()` math (timezone-drifting), so it is not
 * asserted; structural DOM (subjects, letters, counts, phase state) is stable.
 * toBeAccessible() runs on the empty state — the data branch renders bare
 * checkboxes with no <label>, which axe would (correctly) flag.
 */
import { createElement } from 'lwc';
import TransactionTaskGroups from 'c/transactionTaskGroups';
import getTaskGroups from '@salesforce/apex/TransactionTaskController.getTaskGroups';
import completeTask from '@salesforce/apex/TransactionTaskController.completeTask';
import completeWireVerification from '@salesforce/apex/TransactionTaskController.completeWireVerification';

jest.mock(
    '@salesforce/apex/TransactionTaskController.getTaskGroups',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/TransactionTaskController.completeTask',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/TransactionTaskController.completeWireVerification',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = 'a0V5g00000Txn99AAB';

// Two groups, both in the "Open Contract" phase (letters A + B). Group A holds a
// done task (with notes -> View button), an open regular task, and an open
// anti-fraud wire task. B is a conditional group in the same phase.
const GROUPS = [
    {
        key: 'A',
        letter: 'A',
        name: 'Contract & Signatures',
        total: 3,
        complete: 1,
        pct: 33,
        conditional: false,
        ownerLabel: 'Acquisitions',
        tasks: [
            {
                id: 't1',
                subject: 'Fully execute PSA',
                done: true,
                verifyComplete: false,
                verifiedBy: null,
                notes: 'Executed via DocuSign',
                ownerLabel: 'Alice Adams',
                completedDate: '2026-05-08',
                phone: null,
                verifiedAt: null
            },
            {
                id: 't2',
                subject: 'Open escrow account',
                done: false,
                verifyComplete: false,
                verifiedBy: null,
                notes: '',
                ownerLabel: 'Alice Adams',
                completedDate: null,
                phone: null,
                verifiedAt: null
            },
            {
                id: 't3',
                subject: 'Confirm wire instructions (anti-fraud)',
                done: false,
                verifyComplete: false,
                verifiedBy: null,
                notes: '',
                ownerLabel: 'Bob Brown',
                completedDate: null,
                phone: null,
                verifiedAt: null
            }
        ]
    },
    {
        key: 'B',
        letter: 'B',
        name: 'Title & Survey',
        total: 2,
        complete: 0,
        pct: 0,
        conditional: true,
        ownerLabel: 'Legal',
        tasks: [
            {
                id: 't4',
                subject: 'Order title commitment',
                done: false,
                verifyComplete: false,
                verifiedBy: null,
                notes: '',
                ownerLabel: 'Legal',
                completedDate: null,
                phone: null,
                verifiedAt: null
            },
            {
                id: 't5',
                subject: 'Review survey',
                done: false,
                verifyComplete: false,
                verifiedBy: null,
                notes: '',
                ownerLabel: 'Legal',
                completedDate: null,
                phone: null,
                verifiedAt: null
            }
        ]
    }
];

describe('c-transaction-task-groups', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-transaction-task-groups', {
            is: TransactionTaskGroups
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function flushPromises() {
        return Promise.resolve();
    }

    function textList(element, selector) {
        return [...element.shadowRoot.querySelectorAll(selector)].map((el) =>
            el.textContent.trim()
        );
    }

    function brandFooterButton(element) {
        return element.shadowRoot.querySelector(
            '.slds-modal__footer .slds-button_brand'
        );
    }

    it('shows the "no tasks yet" empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const empty = element.shadowRoot.querySelector('.tg-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toContain('No tasks yet.');
        expect(
            element.shadowRoot.querySelectorAll('.tg-task').length
        ).toBe(0);
    });

    it('DATA BRANCH: renders four phases with Open Contract active + its group chips', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        // Four phase buttons; the one holding the first open group is active.
        expect(element.shadowRoot.querySelectorAll('.tg-phase').length).toBe(4);
        const active = element.shadowRoot.querySelector('.tg-phase--active');
        expect(active.querySelector('.tg-phase-name').textContent).toBe(
            'Open Contract'
        );

        // Two group chips (A + B) in the selected phase, in order.
        expect(textList(element, '.tg-ring-inner')).toEqual(['A', 'B']);

        // Selected group defaults to the first not-complete group (A).
        expect(
            element.shadowRoot.querySelector('.tg-badge').textContent
        ).toBe('A');
        expect(
            element.shadowRoot.querySelector('.tg-detail-name span').textContent
        ).toBe('Contract & Signatures');
    });

    it('DATA BRANCH: lists the selected group tasks with the "(anti-fraud)" tag stripped', async () => {
        const element = createComponent();

        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        expect(textList(element, '.tg-subject')).toEqual([
            'Fully execute PSA',
            'Open escrow account',
            'Confirm wire instructions'
        ]);

        // The done task with notes exposes a View button.
        expect(
            element.shadowRoot.querySelectorAll('.tg-view-btn').length
        ).toBe(1);
    });

    it('CONFIRM FLOW: checking a regular task opens the dialog and completeTask is called', async () => {
        completeTask.mockResolvedValue(undefined);

        const element = createComponent();
        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        // Check the open regular task (t2) -> confirmation dialog opens.
        const checkbox = element.shadowRoot.querySelector(
            'input.tg-check[data-id="t2"]'
        );
        checkbox.checked = true;
        checkbox.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.tg-confirm-subject').textContent
        ).toBe('Open escrow account');

        // Click "Confirm" (the confirm dialog's brand footer button).
        brandFooterButton(element).click();
        await flushPromises();
        await flushPromises();

        expect(completeTask).toHaveBeenCalledTimes(1);
        expect(completeTask).toHaveBeenCalledWith({ taskId: 't2', notes: '' });
        expect(completeWireVerification).not.toHaveBeenCalled();
    });

    it('WIRE FLOW: checking an anti-fraud task opens the verification dialog and validates', async () => {
        const element = createComponent();
        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        // Check the anti-fraud wire task (t3) -> wire-verification dialog opens.
        const checkbox = element.shadowRoot.querySelector(
            'input.tg-check[data-id="t3"]'
        );
        checkbox.checked = true;
        checkbox.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.tg-modal-sub').textContent
        ).toBe('Confirm wire instructions');

        // Submit with empty name/phone -> validation error, no Apex call.
        brandFooterButton(element).click();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.tg-modal-error').textContent
        ).toContain('required');
        expect(completeWireVerification).not.toHaveBeenCalled();
    });

    it('WIRE FLOW: a filled verification calls completeWireVerification with trimmed values', async () => {
        completeWireVerification.mockResolvedValue(undefined);

        const element = createComponent();
        getTaskGroups.emit(GROUPS);
        await Promise.resolve();

        const checkbox = element.shadowRoot.querySelector(
            'input.tg-check[data-id="t3"]'
        );
        checkbox.checked = true;
        checkbox.dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        // Fill the two required inputs (Confirmed by, Phone number used).
        const inputs = element.shadowRoot.querySelectorAll('lightning-input');
        inputs[0].value = 'Nora Ng';
        inputs[0].dispatchEvent(new CustomEvent('change'));
        inputs[1].value = '555-9000';
        inputs[1].dispatchEvent(new CustomEvent('change'));
        await Promise.resolve();

        brandFooterButton(element).click();
        await flushPromises();
        await flushPromises();

        expect(completeWireVerification).toHaveBeenCalledTimes(1);
        expect(completeWireVerification).toHaveBeenCalledWith({
            taskId: 't3',
            verifiedBy: 'Nora Ng',
            phone: '555-9000',
            comments: ''
        });
    });

    it('ERROR BRANCH: keeps the empty state when the wire errors', async () => {
        const element = createComponent();

        getTaskGroups.error();
        await Promise.resolve();

        const empty = element.shadowRoot.querySelector('.tg-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toContain('No tasks yet.');
    });

    it('is accessible (empty state)', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
