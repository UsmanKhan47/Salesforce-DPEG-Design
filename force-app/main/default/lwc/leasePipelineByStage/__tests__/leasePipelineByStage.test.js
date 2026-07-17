/**
 * leasePipelineByStage — @wire to Apex (no-parameter), presentational widget.
 * ---------------------------------------------------------------------------
 * Follows WIRE-MOCK TEMPLATE 1 (see brokerFirmCard.test.js): the imported Apex
 * method `LeaseInquiryController.getPipelineByStage` is registered as a shared
 * test wire adapter via createApexTestWireAdapter, then driven with .emit(data)
 * and .error(). This is a Lease Activity Tracker DASHBOARD component — the
 * LeaseInquiryController.cls itself is intentionally NOT opened; the DTO shape
 * ({ stage, count }[]) is derived solely from this component's own .js.
 */
import { createElement } from 'lwc';
import LeasePipelineByStage from 'c/leasePipelineByStage';
import getPipelineByStage from '@salesforce/apex/LeaseInquiryController.getPipelineByStage';

jest.mock(
    '@salesforce/apex/LeaseInquiryController.getPipelineByStage',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Two of the five stages are past "Inquiry Received", so reachedLoi = 5 of 10.
const PIPELINE = [
    { stage: 'Inquiry Received', count: 5 },
    { stage: 'LOI Received', count: 3 },
    { stage: 'LOI Signed', count: 2 }
];

describe('c-lease-pipeline-by-stage', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-lease-pipeline-by-stage', {
            is: LeasePipelineByStage
        });
        document.body.appendChild(element);
        return element;
    }

    it('EMPTY: shows 0% reached-LOI and no legend rows before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ps-pct').textContent).toBe(
            '0%'
        );
        expect(
            element.shadowRoot.querySelector('.ps-rd-active').textContent
        ).toBe('0');
        expect(
            element.shadowRoot.querySelectorAll('.ps-leg-row').length
        ).toBe(0);
    });

    it('DATA BRANCH: computes the reached-LOI percentage from the emitted stages', async () => {
        const element = createComponent();

        getPipelineByStage.emit(PIPELINE);
        await Promise.resolve();

        // total 10, reachedLoi 5 -> 50%
        expect(element.shadowRoot.querySelector('.ps-pct').textContent).toBe(
            '50%'
        );
        expect(
            element.shadowRoot.querySelector('.ps-rd-active').textContent
        ).toBe('10');
    });

    it('DATA BRANCH: renders one legend row + one bar segment per stage', async () => {
        const element = createComponent();

        getPipelineByStage.emit(PIPELINE);
        await Promise.resolve();

        const labels = [
            ...element.shadowRoot.querySelectorAll('.ps-leg-lbl')
        ].map((el) => el.textContent);
        expect(labels).toEqual([
            'Inquiry Received',
            'LOI Received',
            'LOI Signed'
        ]);

        const counts = [
            ...element.shadowRoot.querySelectorAll('.ps-leg-cnt')
        ].map((el) => el.textContent);
        expect(counts).toEqual(['5', '3', '2']);

        // One filled <div> per stage inside the stacked bar.
        expect(
            element.shadowRoot.querySelectorAll('.ps-bar > div').length
        ).toBe(3);
    });

    it('ERROR BRANCH: degrades to the empty readout when the wire errors', async () => {
        const element = createComponent();

        getPipelineByStage.error();
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.ps-pct').textContent).toBe(
            '0%'
        );
        expect(
            element.shadowRoot.querySelectorAll('.ps-leg-row').length
        ).toBe(0);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getPipelineByStage.emit(PIPELINE);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
