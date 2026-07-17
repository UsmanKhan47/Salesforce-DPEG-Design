/**
 * IMPERATIVE APEX pattern (mirrors c-submit-for-approval).
 * c-advance-deal-stage is a headless quick action whose @api invoke() awaits
 *   const message = await advance({ recordId: this.recordId });
 * and then either toasts success + notifies the record, or toasts the error.
 * Drive each branch with mockResolvedValue / mockRejectedValue and assert the
 * dispatched ShowToastEvent + getRecordNotifyChange side effects.
 */
import { createElement } from 'lwc';
import AdvanceDealStage from 'c/advanceDealStage';
import advance from '@salesforce/apex/StageAdvanceController.advance';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

jest.mock(
    '@salesforce/apex/StageAdvanceController.advance',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const RECORD_ID = '0065g00000AbCdEAAV';

describe('c-advance-deal-stage', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-advance-deal-stage', {
            is: AdvanceDealStage
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    function flushPromises() {
        return Promise.resolve();
    }

    it('SUCCESS BRANCH: calls Apex with the recordId, toasts success, notifies the record', async () => {
        advance.mockResolvedValue('Deal advanced to Due Diligence.');

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(advance).toHaveBeenCalledTimes(1);
        expect(advance).toHaveBeenCalledWith({ recordId: RECORD_ID });

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'Deal advanced to Due Diligence.'
        );

        expect(getRecordNotifyChange).toHaveBeenCalledWith([
            { recordId: RECORD_ID }
        ]);
    });

    it('ERROR BRANCH: surfaces the Apex message in an error toast, no record notify', async () => {
        advance.mockRejectedValue({
            body: { message: 'The deal is not in an advanceable stage.' }
        });

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'Cannot advance the deal'
        );
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The deal is not in an advanceable stage.'
        );

        expect(getRecordNotifyChange).not.toHaveBeenCalled();
    });

    it('ERROR BRANCH: falls back to a generic message when the error carries no body', async () => {
        advance.mockRejectedValue(new Error('network'));

        const element = createComponent();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        await element.invoke();
        await flushPromises();

        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'The deal could not be advanced.'
        );
    });

    it('is accessible', async () => {
        advance.mockResolvedValue('ok');

        const element = createComponent();

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
