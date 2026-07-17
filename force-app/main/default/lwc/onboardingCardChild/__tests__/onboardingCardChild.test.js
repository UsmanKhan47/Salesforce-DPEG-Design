import { createElement } from 'lwc';
import OnboardingCardChild from 'c/onboardingCardChild';

describe('c-onboarding-card-child', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = {}) {
        const element = createElement('c-onboarding-card-child', {
            is: OnboardingCardChild
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders the value and label from @api inputs', async () => {
        const element = createComponent({
            value: '12',
            label: 'Deals Submitted',
            iconName: 'utility:upload'
        });

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.stat-value').textContent
        ).toBe('12');
        expect(
            element.shadowRoot.querySelector('.stat-label').textContent
        ).toBe('Deals Submitted');
    });

    it('uses the default (grey) card class when done is false', async () => {
        const element = createComponent({ value: '1', label: 'Alpha' });

        await Promise.resolve();

        const article = element.shadowRoot.querySelector('article');
        expect(article.classList.contains('stat-card')).toBe(true);
        expect(article.classList.contains('stat-card--done')).toBe(false);
    });

    it('adds the done modifier class when done is true', async () => {
        const element = createComponent({
            value: '9',
            label: 'Complete',
            done: true
        });

        await Promise.resolve();

        const article = element.shadowRoot.querySelector('article');
        expect(article.classList.contains('stat-card--done')).toBe(true);
    });

    it('applies an icon tint style when iconColor is supplied', async () => {
        const element = createComponent({
            value: '4',
            label: 'Tinted',
            iconName: 'utility:check',
            iconColor: '#3BA755'
        });

        await Promise.resolve();

        const icon = element.shadowRoot.querySelector('lightning-icon');
        expect(icon.getAttribute('style')).toContain('#3BA755');
    });

    it('is accessible', async () => {
        const element = createComponent({
            value: '12',
            label: 'Deals Submitted',
            iconName: 'utility:upload'
        });

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
