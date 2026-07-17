/**
 * WIRE-MOCK TEMPLATE — IMPERATIVE APEX
 * ------------------------------------
 * Follows the c-submit-for-approval imperative-Apex template. This component
 * calls two Apex methods imperatively:
 *   - getClosingTasks({ dispositionId }) in connectedCallback -> renders the list
 *   - setTaskDone({ taskId, done })      on checkbox toggle   -> then reloads
 * Both are mocked as bare jest.fn() and driven with mockResolvedValue /
 * mockRejectedValue. After each imperative call the microtask queue is flushed
 * before asserting on the re-rendered shadow DOM.
 */
import { createElement } from 'lwc';
import DispositionClosingTasks from 'c/dispositionClosingTasks';
import getClosingTasks from '@salesforce/apex/DispositionTaskController.getClosingTasks';
import setTaskDone from '@salesforce/apex/DispositionTaskController.setTaskDone';

jest.mock(
    '@salesforce/apex/DispositionTaskController.getClosingTasks',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/DispositionTaskController.setTaskDone',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const TASKS = [
    {
        id: '00T01',
        subject: 'Order title commitment',
        done: true,
        completedDate: '2026-02-15T18:00:00.000Z'
    },
    { id: '00T02', subject: 'Wire earnest money', done: false }
];

// Flush the microtask queue so the awaited Apex promise + its .then chain settle.
function flushPromises() {
    return Promise.resolve();
}

describe('c-disposition-closing-tasks', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a0D5g000000DispEAG' }) {
        const element = createElement('c-disposition-closing-tasks', {
            is: DispositionClosingTasks
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('loads and renders the checklist rows with a progress badge', async () => {
        getClosingTasks.mockResolvedValue(TASKS);

        const element = createComponent();
        await flushPromises();
        await flushPromises();

        expect(getClosingTasks).toHaveBeenCalledWith({
            dispositionId: 'a0D5g000000DispEAG'
        });

        const rows = element.shadowRoot.querySelectorAll('.task-row');
        expect(rows.length).toBe(2);

        const subjects = [
            ...element.shadowRoot.querySelectorAll('.task-subject')
        ].map((el) => el.textContent);
        expect(subjects).toEqual([
            'Order title commitment',
            'Wire earnest money'
        ]);

        // 1 of 2 done -> amber (incomplete) badge.
        const badge = element.shadowRoot.querySelector('.progress-badge');
        expect(badge.textContent).toContain('1/2 complete');
        expect(badge.getAttribute('style')).toContain('#fef3c7');

        // Completed row carries a "Completed <date>" meta label + done class.
        expect(rows[0].className).toContain('task-row--done');
        expect(
            element.shadowRoot.querySelector('.task-meta').textContent
        ).toMatch(/^Completed /);
    });

    it('shows a green badge when every task is complete', async () => {
        getClosingTasks.mockResolvedValue([
            { id: '00T01', subject: 'A', done: true },
            { id: '00T02', subject: 'B', done: true }
        ]);

        const element = createComponent();
        await flushPromises();
        await flushPromises();

        const badge = element.shadowRoot.querySelector('.progress-badge');
        expect(badge.textContent).toContain('2/2 complete');
        expect(badge.getAttribute('style')).toContain('#e6f4ea');
    });

    it('toggling a checkbox calls setTaskDone with the id + state, then reloads', async () => {
        getClosingTasks.mockResolvedValue(TASKS);
        setTaskDone.mockResolvedValue(undefined);

        const element = createComponent();
        await flushPromises();
        await flushPromises();

        const input = element.shadowRoot.querySelector('lightning-input');
        input.checked = true;
        input.dispatchEvent(new CustomEvent('change'));
        await flushPromises();
        await flushPromises();

        expect(setTaskDone).toHaveBeenCalledTimes(1);
        expect(setTaskDone).toHaveBeenCalledWith({
            taskId: '00T01',
            done: true
        });
        // Initial load + the reload after the toggle.
        expect(getClosingTasks).toHaveBeenCalledTimes(2);
    });

    it('ERROR BRANCH: renders an empty checklist when the load fails', async () => {
        getClosingTasks.mockRejectedValue({
            body: { message: 'No access' }
        });

        const element = createComponent();
        await flushPromises();
        await flushPromises();

        expect(element.shadowRoot.querySelectorAll('.task-row').length).toBe(0);
        expect(
            element.shadowRoot.querySelector('.progress-badge').textContent
        ).toContain('0/0 complete');
    });

    it('is accessible', async () => {
        getClosingTasks.mockResolvedValue(TASKS);

        const element = createComponent();
        await flushPromises();
        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
