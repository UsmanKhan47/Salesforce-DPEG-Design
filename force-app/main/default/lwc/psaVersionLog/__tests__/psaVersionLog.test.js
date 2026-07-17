/**
 * c-psa-version-log — HYBRID suite.
 * ---------------------------------
 * The PSA Version Log records the full contract negotiation history. It works in
 * two placements:
 *   - On an Opportunity page: reads the Opp's Primary_Contract__c (+ the Contract
 *     Review's Ball_In_Court__c spanning field) via LDS getRecord, then tracks
 *     that Contract Review.
 *   - On a Contract Review record page: tracks the record directly.
 * The version history comes from an @wire Apex read (getVersions), and a new
 * version is committed through an imperative Apex write (saveVersion).
 *
 * Combines THREE mocking techniques (mirrors c-broker-replace-quick-action):
 *   - LDS getRecord  -> sfdx-lwc-jest uiRecordApi stub, driven with .emit
 *     (Primary_Contract__c + nested Primary_Contract__r.Ball_In_Court__c spanning
 *     field — getFieldValue traverses record.fields.Primary_Contract__r.value...).
 *   - @wire Apex     -> getVersions via createApexTestWireAdapter.emit/.error.
 *   - imperative Apex-> saveVersion via jest.fn + mockResolvedValue/Rejected.
 *
 * notifyRecordUpdateAvailable (lightning/uiRecordApi) is a jest.fn in the stub and
 * is asserted. refreshApex (@salesforce/apex) is a plain resolved-promise fallback
 * in the transform — NOT a jest.fn — so it is exercised but never asserted on.
 */
import { createElement } from 'lwc';
import PsaVersionLog from 'c/psaVersionLog';
import { getRecord, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getVersions from '@salesforce/apex/PsaVersionController.getVersions';
import saveVersion from '@salesforce/apex/PsaVersionController.saveVersion';

jest.mock(
    '@salesforce/apex/PsaVersionController.getVersions',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PsaVersionController.saveVersion',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const OPP_ID = '0065g00000AbCdEAAV';
const CONTRACT_ID = 'a035g00000CtrXyAAK';

function oppRecord({ contractId = CONTRACT_ID, ball } = {}) {
    return {
        apiName: 'Opportunity',
        id: OPP_ID,
        fields: {
            Primary_Contract__c: { value: contractId },
            Primary_Contract__r: ball
                ? { value: { fields: { Ball_In_Court__c: { value: ball } } } }
                : { value: null }
        }
    };
}

function version(i, overrides = {}) {
    return {
        Id: `a045g0000000${i}AAA`,
        Name: `PSA-v${i}`,
        Direction__c: i % 2 === 0 ? 'Ours' : 'Seller',
        Summary__c: `Redlined section ${i}`,
        Document_URL__c: `https://files.example.com/psa-v${i}.pdf`,
        Version_Date__c: '2026-07-01',
        CreatedDate: '2026-07-01T00:00:00.000Z',
        ...overrides
    };
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-psa-version-log', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createOnOpportunity() {
        const element = createElement('c-psa-version-log', {
            is: PsaVersionLog
        });
        Object.assign(element, {
            recordId: OPP_ID,
            objectApiName: 'Opportunity'
        });
        document.body.appendChild(element);
        return element;
    }

    function createOnContractPage() {
        const element = createElement('c-psa-version-log', {
            is: PsaVersionLog
        });
        Object.assign(element, {
            recordId: CONTRACT_ID,
            objectApiName: 'Contract_Review__c'
        });
        document.body.appendChild(element);
        return element;
    }

    it('NO CONTRACT: explains the Contract Review opens automatically and hides Log Version', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ contractId: null }));
        await Promise.resolve();

        expect(element.shadowRoot.textContent).toContain(
            'Contract Review opens automatically'
        );

        const logBtn = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ].find((b) => b.label === 'Log Version');
        expect(logBtn).toBeUndefined();
    });

    it('DATA BRANCH (Opportunity): renders the datatable, the count, and the ball badge', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID, ball: 'Us' }));
        getVersions.emit([version(1), version(2)]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).not.toBeNull();

        const title = element.shadowRoot.querySelector('[slot="title"]');
        expect(title.textContent).toContain('2');

        const badge = element.shadowRoot.querySelector('.slds-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toContain('our court');
        expect(badge.className).toContain('slds-theme_warning');
    });

    it('DATA BRANCH (Contract Review page): tracks the record directly with no ball badge', async () => {
        const element = createOnContractPage();

        getVersions.emit([version(1)]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).not.toBeNull();
        expect(element.shadowRoot.querySelector('.slds-badge')).toBeNull();
    });

    it('EMPTY BRANCH: shows the no-versions message when the Apex wire returns []', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID }));
        getVersions.emit([]);
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).toBeNull();
        expect(element.shadowRoot.textContent).toContain(
            'No PSA versions logged yet'
        );
    });

    it('ERROR BRANCH: keeps the empty state when the Apex wire errors', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID }));
        getVersions.error();
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('c-list-datatable')
        ).toBeNull();
        expect(element.shadowRoot.textContent).toContain(
            'No PSA versions logged yet'
        );
    });

    it('SAVE SUCCESS: submits the entered version, refreshes the record, and toasts', async () => {
        saveVersion.mockResolvedValue();

        const element = createOnOpportunity();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID }));
        await Promise.resolve();

        // Open the entry form.
        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Log Version')
            .click();
        await Promise.resolve();

        element.shadowRoot
            .querySelector('lightning-radio-group')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Ours' } }));

        const inputs = element.shadowRoot.querySelectorAll('lightning-input');
        const setInput = (idx, value) => {
            inputs[idx].value = value;
            inputs[idx].dispatchEvent(new CustomEvent('change'));
        };
        setInput(0, '2026-08-01'); // Version Date
        setInput(1, 'https://files.example.com/psa-v5.pdf'); // Document URL

        const summary = element.shadowRoot.querySelector('lightning-textarea');
        summary.value = 'Revised indemnification clause.';
        summary.dispatchEvent(new CustomEvent('change'));

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Save')
            .click();
        await flushPromises();

        expect(saveVersion).toHaveBeenCalledTimes(1);
        expect(saveVersion).toHaveBeenCalledWith({
            contractReviewId: CONTRACT_ID,
            direction: 'Ours',
            versionDate: '2026-08-01',
            summary: 'Revised indemnification clause.',
            documentUrl: 'https://files.example.com/psa-v5.pdf'
        });

        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
            { recordId: OPP_ID }
        ]);
        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('success');
        expect(toastHandler.mock.calls[0][0].detail.title).toBe(
            'PSA version logged'
        );
    });

    it('SAVE ERROR: surfaces the Apex error, keeps the form open, and does not refresh', async () => {
        saveVersion.mockRejectedValue({
            body: { message: 'A summary of the change is required.' }
        });

        const element = createOnOpportunity();
        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID }));
        await Promise.resolve();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Log Version')
            .click();
        await Promise.resolve();

        [...element.shadowRoot.querySelectorAll('lightning-button')]
            .find((b) => b.label === 'Save')
            .click();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        expect(toastHandler.mock.calls[0][0].detail.variant).toBe('error');
        expect(toastHandler.mock.calls[0][0].detail.message).toBe(
            'A summary of the change is required.'
        );
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();

        expect(
            [...element.shadowRoot.querySelectorAll('lightning-button')].some(
                (b) => b.label === 'Save'
            )
        ).toBe(true);
    });

    it('is accessible', async () => {
        const element = createOnOpportunity();

        getRecord.emit(oppRecord({ contractId: CONTRACT_ID }));
        getVersions.emit([]);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
