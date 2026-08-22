/**
 * Suite for c-utility-bill-variance — a purely PRESENTATIONAL component: props in, nothing
 * out, no wire and no Apex. There is therefore no adapter to mock and no promise to flush;
 * every test sets properties and asserts on RENDERED output.
 *
 * ⚠ ASSERTIONS ARE ON RENDERED TEXT, NEVER ON A GETTER. A getter bound to an element's
 * attribute is written UNCONDITIONALLY, so a getter returning `undefined` renders the literal
 * string "undefined" on screen while the getter itself looks perfectly fine to a unit test
 * that calls it directly. This repo has shipped that defect before.
 */
import { createElement } from 'lwc';
import UtilityBillVariance from 'c/utilityBillVariance';

describe('c-utility-bill-variance', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = {}) {
        const element = createElement('c-utility-bill-variance', { is: UtilityBillVariance });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    /** The canonical FSD 5.10.5 worked example: $200 -> $345 on 100 -> 150 units. */
    const RECONCILING = {
        usageVariance: 100,
        rateVariance: 45,
        totalVariance: 145,
        totalVariancePct: 72.5,
        priorBillLabel: 'UB-00001 (read 2026-01-01)',
        hasPrior: true
    };

    it('renders the usage and rate decomposition, not just the total', async () => {
        const element = createComponent(RECONCILING);
        await Promise.resolve();

        const labels = [...element.shadowRoot.querySelectorAll('.ubv-row-name')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual(['Usage variance', 'Rate variance']);

        // The split is the entire point of FSD 5.10.2: "we used more" and "they charged more"
        // are two different problems with two different owners.
        const values = element.shadowRoot.querySelectorAll(
            '.ubv-row-value lightning-formatted-number'
        );
        expect(values.length).toBe(2);
        expect(values[0].value).toBe(100);
        expect(values[1].value).toBe(45);
    });

    it('renders the total change and the percentage on the human scale', async () => {
        const element = createComponent(RECONCILING);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.ubv-total-amount').value
        ).toBe(145);
        // +72.5%, on the human scale Total_Variance_Pct__c carries. The component must not
        // rescale it: it renders the number it is handed.
        expect(element.shadowRoot.querySelector('.ubv-pct').textContent).toBe('+72.5%');
    });

    it('names the bill the variance was measured against', async () => {
        const element = createComponent(RECONCILING);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubv-prior').textContent).toBe(
            'Measured against UB-00001 (read 2026-01-01)'
        );
    });

    it('renders no "undefined" anywhere when the optional props are absent', async () => {
        const element = createComponent({
            usageVariance: 10,
            rateVariance: -4,
            totalVariance: 6,
            hasPrior: true
            // totalVariancePct and priorBillLabel deliberately omitted
        });
        await Promise.resolve();

        // The whole rendered subtree, not the getters: the failure mode being guarded is a
        // getter returning undefined and the ATTRIBUTE binding writing it out as text.
        expect(element.shadowRoot.textContent).not.toContain('undefined');
        expect(element.shadowRoot.querySelector('.ubv-pct').textContent).toBe('');
        // The prior-bill caption is suppressed entirely rather than rendered empty.
        expect(element.shadowRoot.querySelector('.ubv-prior')).toBeNull();
    });

    it('EMPTY BRANCH: a first bill explains itself instead of showing zeros', async () => {
        const element = createComponent({ hasPrior: false });
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubv-rows')).toBeNull();
        expect(element.shadowRoot.querySelector('.ubv-empty').textContent).toContain(
            'first bill recorded for this meter'
        );
        // Zeros would be a CLAIM that nothing changed; there is simply nothing to compare.
        expect(element.shadowRoot.querySelector('.ubv-total-amount')).toBeNull();
    });

    it('colours by DIRECTION, so a fall is not styled as good news', async () => {
        const element = createComponent({
            usageVariance: -80,
            rateVariance: 5,
            totalVariance: -75,
            totalVariancePct: -30,
            hasPrior: true
        });
        await Promise.resolve();

        const values = element.shadowRoot.querySelectorAll(
            '.ubv-row-value lightning-formatted-number'
        );
        // A fall in consumption often means a VACANCY, which is not good news - the panel
        // states the direction and leaves the judgement to the reader.
        expect(values[0].className).toContain('ubv-amount_down');
        expect(values[1].className).toContain('ubv-amount_up');
        expect(element.shadowRoot.querySelector('.ubv-pct').textContent).toBe('-30%');
    });

    it('a flat month is styled neutrally rather than as a fall', async () => {
        const element = createComponent({
            usageVariance: 0,
            rateVariance: 0,
            totalVariance: 0,
            totalVariancePct: 0,
            hasPrior: true
        });
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.ubv-total-amount').className
        ).toContain('ubv-amount_flat');
        // 0 is a real answer and is rendered; only a MISSING percentage renders as ''.
        expect(element.shadowRoot.querySelector('.ubv-pct').textContent).toBe('0%');
    });

    it('hides the reconciliation warning while the components add up', async () => {
        const element = createComponent(RECONCILING);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubv-error')).toBeNull();
    });

    it('RAISES the reconciliation warning when the components stop adding up', async () => {
        // The live check. 100 + 45 = 145, so 200 is a total that no longer reconciles - the
        // exact symptom a sign error in either variance formula would produce, and otherwise
        // the ONLY symptom, since all three figures would still render happily.
        const element = createComponent({
            ...RECONCILING,
            totalVariance: 200
        });
        await Promise.resolve();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toContain('do not act on these figures');
    });

    it('absorbs sub-cent rounding without crying wolf', async () => {
        // The currency fields round to 2 decimals, so the components can differ from the
        // total by a fraction of a cent. A sign error is off by TWICE the component, never
        // by a rounding tick - the tolerance separates the two.
        const element = createComponent({
            usageVariance: 100.001,
            rateVariance: 45,
            totalVariance: 145,
            hasPrior: true
        });
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ubv-error')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent(RECONCILING);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible in its empty state', async () => {
        const element = createComponent({ hasPrior: false });
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
