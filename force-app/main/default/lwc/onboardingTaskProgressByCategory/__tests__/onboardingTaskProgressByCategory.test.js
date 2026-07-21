/**
 * @wire-to-Apex (parameterised by $recordId) suite for
 * c-onboarding-task-progress-by-category. Emits the OnboardingController
 * checklist groups and asserts one c-onboarding-card-child tile per category.
 */
import { createElement } from 'lwc';
import OnboardingTaskProgressByCategory from 'c/onboardingTaskProgressByCategory';
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

// Matches OnboardingController.ChecklistGroup[]. Group 2 is fully complete.
const GROUPS = [
    { category: 'Property Set up', total: 4, complete: 1, items: [] },
    { category: 'Unit & Tenant Setup', total: 3, complete: 3, items: [] }
];

describe('c-onboarding-task-progress-by-category', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-onboarding-task-progress-by-category', {
            is: OnboardingTaskProgressByCategory
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders no category tiles before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('c-onboarding-card-child').length
        ).toBe(0);
    });

    it('DATA BRANCH: renders one tile per category with count + done flag', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll(
            'c-onboarding-card-child'
        );
        expect(cards.length).toBe(2);

        expect(cards[0].label).toBe('Property Set up');
        expect(cards[0].value).toBe('1 / 4');
        expect(cards[0].done).toBe(false);

        // Fully complete group -> done true, green icon color.
        expect(cards[1].label).toBe('Unit & Tenant Setup');
        expect(cards[1].value).toBe('3 / 3');
        expect(cards[1].done).toBe(true);
        expect(cards[1].iconColor).toBe('#2e7d32');
    });

    it('ERROR BRANCH: renders no tiles and an inline error alert when the wire errors', async () => {
        const element = createComponent();

        getChecklist.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelectorAll('c-onboarding-card-child').length
        ).toBe(0);
        expect(element.shadowRoot.querySelector('[role="alert"]')).not.toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getChecklist.emit(GROUPS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
