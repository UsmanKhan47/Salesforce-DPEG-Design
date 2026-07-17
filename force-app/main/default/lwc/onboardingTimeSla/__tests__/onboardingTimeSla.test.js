/**
 * @wire-to-Apex (no-parameter) suite for c-onboarding-time-sla.
 * Emits the OnboardingController.TimeSla wrapper and asserts the four SLA
 * tiles render the mapped values.
 */
import { createElement } from 'lwc';
import OnboardingTimeSla from 'c/onboardingTimeSla';
import getTimeSla from '@salesforce/apex/OnboardingController.getTimeSla';

jest.mock(
    '@salesforce/apex/OnboardingController.getTimeSla',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches OnboardingController.TimeSla.
const SLA = { avgDaysToOnboard: 41, avgAge: 27, pastTarget: 4, oldestOpen: 96 };

describe('c-onboarding-time-sla', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-onboarding-time-sla', {
            is: OnboardingTimeSla
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders four tiles with zeroes before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [...element.shadowRoot.querySelectorAll('.val')].map(
            (el) => el.textContent
        );
        expect(values).toEqual(['0', '0', '0', '0']);
    });

    it('DATA BRANCH: maps the TimeSla wrapper onto the tiles in order', async () => {
        const element = createComponent();

        getTimeSla.emit(SLA);
        await Promise.resolve();

        const values = [...element.shadowRoot.querySelectorAll('.val')].map(
            (el) => el.textContent
        );
        // TILES order: avgDaysToOnboard, avgAge, pastTarget, oldestOpen
        expect(values).toEqual(['41', '27', '4', '96']);

        const labels = [...element.shadowRoot.querySelectorAll('.lbl')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual([
            'Avg Days to Onboard',
            'Avg Age of Active',
            'Past Target Duration',
            'Oldest Open (Days)'
        ]);
    });

    it('ERROR BRANCH: stays on zeroes when the wire errors', async () => {
        const element = createComponent();

        getTimeSla.error();
        await Promise.resolve();

        const values = [...element.shadowRoot.querySelectorAll('.val')].map(
            (el) => el.textContent
        );
        expect(values).toEqual(['0', '0', '0', '0']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getTimeSla.emit(SLA);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
