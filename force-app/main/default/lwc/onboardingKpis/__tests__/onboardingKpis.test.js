/**
 * @wire-to-Apex (no-parameter) suite for c-onboarding-kpis.
 * Pattern per brokerFirmCard template: register getKpis as an Apex test wire
 * adapter, emit the OnboardingController.Kpis wrapper, assert the four
 * c-stat-card children receive the mapped values. The @wire takes no reactive
 * param, so no recordId is set.
 */
import { createElement } from 'lwc';
import OnboardingKpis from 'c/onboardingKpis';
import getKpis from '@salesforce/apex/OnboardingController.getKpis';

jest.mock(
    '@salesforce/apex/OnboardingController.getKpis',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches OnboardingController.Kpis (@AuraEnabled Integer fields).
const KPIS = {
    propertiesInOnboarding: 7,
    avgCompletionPct: 64,
    overdueTasks: 12,
    avgDaysToOnboard: 38
};

describe('c-onboarding-kpis', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-onboarding-kpis', { is: OnboardingKpis });
        document.body.appendChild(element);
        return element;
    }

    it('renders four stat cards with default zeroes before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('0'); //   properties
        expect(cards[1].value).toBe('0%'); //  avg % complete
        expect(cards[2].value).toBe('0'); //   overdue
        expect(cards[3].value).toBe('0d'); //  avg days
    });

    it('DATA BRANCH: maps the Kpis wrapper onto the four stat cards', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('7');
        expect(cards[0].label).toBe('Properties in Onboarding');
        expect(cards[1].value).toBe('64%');
        expect(cards[2].value).toBe('12');
        expect(cards[3].value).toBe('38d');
    });

    it('ERROR BRANCH: keeps default zeroes when the wire errors', async () => {
        const element = createComponent();

        getKpis.error();
        await Promise.resolve();

        const cards = element.shadowRoot.querySelectorAll('c-stat-card');
        expect(cards.length).toBe(4);
        expect(cards[0].value).toBe('0');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getKpis.emit(KPIS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
