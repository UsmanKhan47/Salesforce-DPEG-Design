import { createElement } from 'lwc';
import ListingAlerts from 'c/listingAlerts';

describe('c-listing-alerts', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-listing-alerts', {
            is: ListingAlerts
        });
        document.body.appendChild(element);
        return element;
    }

    it('renders the section header', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.section-header').textContent
        ).toBe('Automated Alerts');
    });

    it('renders every configured alert row', async () => {
        const element = createComponent();

        await Promise.resolve();

        const rows = element.shadowRoot.querySelectorAll('.alert-row');
        expect(rows.length).toBe(4);

        const triggers = Array.from(
            element.shadowRoot.querySelectorAll('.alert-trigger')
        ).map((el) => el.textContent);
        expect(triggers).toEqual(['Day 21', 'Week 4', 'Week 6', 'Offer in']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
