/**
 * @wire-to-Apex (no-parameter) suite for c-onboarding-portfolio-progress.
 * Emits the OnboardingController.Portfolio wrapper and asserts the donut %,
 * completed/total counts, and the two-segment legend.
 */
import { createElement } from 'lwc';
import OnboardingPortfolioProgress from 'c/onboardingPortfolioProgress';
import getPortfolio from '@salesforce/apex/OnboardingController.getPortfolio';

jest.mock(
    '@salesforce/apex/OnboardingController.getPortfolio',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches OnboardingController.Portfolio. 12 of 20 complete -> 60%.
const PORTFOLIO = {
    tasksTotal: 20,
    complete: 12,
    inProgress: 3,
    notStarted: 5,
    blocked: 0,
    na: 0
};

describe('c-onboarding-portfolio-progress', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-onboarding-portfolio-progress', {
            is: OnboardingPortfolioProgress
        });
        document.body.appendChild(element);
        return element;
    }

    it('shows 0% / 0 totals before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dpct').textContent).toBe('0%');
        expect(element.shadowRoot.querySelector('.comp').textContent).toBe('0');
        expect(element.shadowRoot.querySelector('.tot').textContent).toBe('/ 0');
    });

    it('DATA BRANCH: computes the completion percent and counts', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dpct').textContent).toBe('60%');
        expect(element.shadowRoot.querySelector('.comp').textContent).toBe('12');
        expect(element.shadowRoot.querySelector('.tot').textContent).toBe('/ 20');
    });

    it('DATA BRANCH: renders the completed + not-started legend segments', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        const labels = [...element.shadowRoot.querySelectorAll('.llabel')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual(['Completed', 'Not Started']);

        const counts = [...element.shadowRoot.querySelectorAll('.lcount')].map(
            (el) => el.textContent
        );
        expect(counts).toEqual(['12', '5']);
    });

    it('ERROR BRANCH: stays on the 0% empty state when the wire errors', async () => {
        const element = createComponent();

        getPortfolio.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.dpct').textContent).toBe('0%');
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPortfolio.emit(PORTFOLIO);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
