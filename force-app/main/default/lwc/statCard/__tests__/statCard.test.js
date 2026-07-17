/**
 * CANONICAL LWC JEST TEMPLATE (P8 proof batch)
 * ---------------------------------------------
 * Copy this shape for every stateless, presentational (`@api` props in -> markup
 * out) component. Conventions enforced here:
 *   - createElement + document.body.appendChild to mount.
 *   - Set @api props on the element BEFORE appendChild (they are reactive after,
 *     but setting first mirrors real usage and avoids an extra microtask).
 *   - `await Promise.resolve()` (or return the promise) to flush the async
 *     rendering microtask before asserting on the shadow DOM.
 *   - afterEach removes the component from the DOM and clears mocks so suites
 *     stay isolated (jest.clearAllMocks() is the template default even when a
 *     component has no mocks yet — later Apex/LDS batches will).
 *   - Every component gets at least one @sa11y/jest `toBeAccessible()` assertion.
 */
import { createElement } from 'lwc';
import StatCard from 'c/statCard';

describe('c-stat-card', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = {}) {
        const element = createElement('c-stat-card', { is: StatCard });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('renders the value and label from @api inputs', async () => {
        const element = createComponent({
            value: '42',
            label: 'Total Deals',
            iconName: 'utility:summary'
        });

        await Promise.resolve();

        const valueEl = element.shadowRoot.querySelector('.stat-value');
        const labelEl = element.shadowRoot.querySelector('.stat-label');
        expect(valueEl.textContent).toBe('42');
        expect(labelEl.textContent).toBe('Total Deals');
    });

    it('passes the icon-name through to lightning-icon', async () => {
        const element = createComponent({
            value: '7',
            label: 'Won',
            iconName: 'utility:check'
        });

        await Promise.resolve();

        const icon = element.shadowRoot.querySelector('lightning-icon');
        expect(icon).not.toBeNull();
        expect(icon.iconName).toBe('utility:check');
    });

    it('applies an icon tint style when iconColor is supplied', async () => {
        const element = createComponent({
            value: '3',
            label: 'Lost',
            iconName: 'utility:close',
            iconColor: '#E0463F'
        });

        await Promise.resolve();

        const icon = element.shadowRoot.querySelector('lightning-icon');
        expect(icon.getAttribute('style')).toContain('#E0463F');
    });

    it('applies no icon tint style when iconColor is omitted', async () => {
        const element = createComponent({
            value: '0',
            label: 'None',
            iconName: 'utility:summary'
        });

        await Promise.resolve();

        const icon = element.shadowRoot.querySelector('lightning-icon');
        // getter returns '' -> no meaningful inline style set
        expect(icon.getAttribute('style') || '').not.toContain('--slds-c-icon-color-foreground-default');
    });

    it('is accessible', async () => {
        const element = createComponent({
            value: '42',
            label: 'Total Deals',
            iconName: 'utility:summary'
        });

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
