import { createElement } from 'lwc';
import SellMeterLegend from 'c/sellMeterLegend';

describe('c-sell-meter-legend', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-sell-meter-legend', {
            is: SellMeterLegend
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders the legend title', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.legend__title').textContent
        ).toBe('Readiness Indicator');
    });

    it('renders the three readiness bands with their labels', async () => {
        const element = createComponent();

        await Promise.resolve();

        const bands = element.shadowRoot.querySelectorAll('.band');
        expect(bands.length).toBe(3);

        const labels = Array.from(
            element.shadowRoot.querySelectorAll('.band__label')
        ).map((el) => el.textContent);
        expect(labels).toEqual(['GREEN', 'YELLOW', 'RED']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
