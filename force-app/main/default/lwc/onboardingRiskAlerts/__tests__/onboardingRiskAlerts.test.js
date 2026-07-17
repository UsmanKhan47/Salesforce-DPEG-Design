/**
 * @wire-to-Apex (no-parameter) suite for c-onboarding-risk-alerts.
 * Emits the OnboardingController.RiskAlerts wrapper and asserts the four
 * risk tiles render the mapped counts.
 */
import { createElement } from 'lwc';
import OnboardingRiskAlerts from 'c/onboardingRiskAlerts';
import getRiskAlerts from '@salesforce/apex/OnboardingController.getRiskAlerts';

jest.mock(
    '@salesforce/apex/OnboardingController.getRiskAlerts',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches OnboardingController.RiskAlerts.
const ALERTS = { overdue: 9, pastTarget: 3, stalled: 5, due7d: 14 };

describe('c-onboarding-risk-alerts', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-onboarding-risk-alerts', {
            is: OnboardingRiskAlerts
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

    it('DATA BRANCH: maps the RiskAlerts wrapper onto the tiles in order', async () => {
        const element = createComponent();

        getRiskAlerts.emit(ALERTS);
        await Promise.resolve();

        const values = [...element.shadowRoot.querySelectorAll('.val')].map(
            (el) => el.textContent
        );
        // TILES order: overdue, pastTarget, stalled, due7d
        expect(values).toEqual(['9', '3', '5', '14']);

        const labels = [...element.shadowRoot.querySelectorAll('.lbl')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual([
            'Overdue Tasks',
            'Past Target Date',
            'Stalled Over 7 Days',
            'Due Next 7 Days'
        ]);
    });

    it('ERROR BRANCH: stays on zeroes when the wire errors', async () => {
        const element = createComponent();

        getRiskAlerts.error();
        await Promise.resolve();

        const values = [...element.shadowRoot.querySelectorAll('.val')].map(
            (el) => el.textContent
        );
        expect(values).toEqual(['0', '0', '0', '0']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRiskAlerts.emit(ALERTS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
