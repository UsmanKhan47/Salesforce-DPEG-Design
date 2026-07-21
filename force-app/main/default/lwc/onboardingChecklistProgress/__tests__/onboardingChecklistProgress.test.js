/**
 * @wire-to-Apex (parameterised by $recordId) suite for
 * c-onboarding-checklist-progress. Emits the OnboardingController.getChecklist
 * group list and asserts the overall roll-up percent + label.
 */
import { createElement } from 'lwc';
import OnboardingChecklistProgress from 'c/onboardingChecklistProgress';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

jest.mock(
    '@salesforce/apex/OnboardingController.getChecklist',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = 'a0x5g000000OnbAAAW';

// Matches OnboardingController.ChecklistGroup[]. 6 of 10 -> 60%.
const GROUPS = [
    { category: 'Property Set up', total: 4, complete: 2, items: [] },
    { category: 'Unit & Tenant Setup', total: 6, complete: 4, items: [] }
];

describe('c-onboarding-checklist-progress', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-onboarding-checklist-progress', {
            is: OnboardingChecklistProgress
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows the no-checklist empty state before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe('—');
        expect(element.shadowRoot.querySelector('.cs-count').textContent).toBe(
            'No checklist generated yet'
        );
    });

    it('DATA BRANCH: rolls all groups up into one overall percent + count', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe('60%');
        expect(element.shadowRoot.querySelector('.cs-count').textContent).toBe(
            '6 of 10 complete'
        );
    });

    it('ERROR BRANCH: renders an inline error alert when the wire errors', async () => {
        const element = createComponent();

        getChecklist.error();
        await Promise.resolve();

        // Roll-up falls back to the empty state, plus an explicit error alert.
        expect(element.shadowRoot.querySelector('.cs-pct').textContent).toBe('—');
        expect(element.shadowRoot.querySelector('[role="alert"]')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
