/**
 * @wire-to-Apex (no-parameter) suite for c-onboarding-property-list.
 * Emits OnboardingController.getOnboardings rows and asserts the card count
 * and the c-list-datatable data. The component mixes in NavigationMixin; the
 * lightning/navigation stub resolves GenerateUrl to a URL, so View All renders.
 */
import { createElement } from 'lwc';
import OnboardingPropertyList from 'c/onboardingPropertyList';
import getOnboardings from '@salesforce/apex/OnboardingController.getOnboardings';

jest.mock(
    '@salesforce/apex/OnboardingController.getOnboardings',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches OnboardingController.Row[].
const ROWS = [
    {
        id: 'a0x5g000000Onb1AAF',
        name: 'ONB-0001',
        propertyName: 'Westgate Plaza',
        startDate: '2026-01-05',
        targetDate: '2026-03-01',
        stage: 'Unit & Tenant Setup',
        completionPct: 72,
        openTasks: 6,
        status: 'In Progress',
        owner: 'Jane Smith'
    },
    {
        id: 'a0x5g000000Onb2AAF',
        name: 'ONB-0002',
        propertyName: 'Harbor Point Center',
        startDate: '2026-02-10',
        targetDate: '2026-04-15',
        stage: 'Property Set up',
        completionPct: 30,
        openTasks: 14,
        status: 'In Progress',
        owner: 'Bob Lee'
    }
];

describe('c-onboarding-property-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-onboarding-property-list', {
            is: OnboardingPropertyList
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders an empty datatable and (0) count before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Properties In Onboarding (0)'
        );
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toEqual([]);
    });

    it('DATA BRANCH: passes mapped rows to the datatable and updates the count', async () => {
        const element = createComponent();

        getOnboardings.emit(ROWS);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Properties In Onboarding (2)'
        );

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data.length).toBe(2);
        expect(table.data[0].propertyName).toBe('Westgate Plaza');
        expect(table.data[0].pctText).toBe('72%');
        expect(table.data[0].recordUrl).toBe(
            '/lightning/r/Onboarding__c/a0x5g000000Onb1AAF/view'
        );
        expect(table.data[1].openTasks).toBe(14);
    });

    it('ERROR BRANCH: keeps the empty datatable when the wire errors', async () => {
        const element = createComponent();

        getOnboardings.error();
        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toEqual([]);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getOnboardings.emit(ROWS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
