/**
 * c-competing-broker-submissions  (Broker Protection — CHUNK 4)
 * ---------------------------------------------------------------------------
 * Read-only: a single @wire(getSubmissions, { leadId: '$recordId' }) renders a
 * row per Competing_Broker_Submission__c with a Winner / Competing badge; a wire
 * error raises an error ShowToastEvent. No imperative Apex.
 *
 * getSubmissions is mocked as an Apex *wire* adapter via createApexTestWireAdapter
 * (the repo pattern — see brokerAssignmentHistory). sa11y's toBeAccessible() is
 * registered globally by jest.setup.js -> @sa11y/jest setup() (per jest.config.js),
 * so every test opts in with an explicit toBeAccessible() call, no per-file setup().
 */
import { createElement } from 'lwc';
import CompetingBrokerSubmissions from 'c/competingBrokerSubmissions';
import getSubmissions from '@salesforce/apex/CompetingSubmissionController.getSubmissions';

jest.mock(
    '@salesforce/apex/CompetingSubmissionController.getSubmissions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const RECORD_ID = '00Q0000000000001AAA';

const SUBMISSIONS = [
    {
        Id: 'a0X0000000000001AAA',
        Broker_Name__c: 'Dana Reyes',
        Broker_Email__c: 'dana.reyes@colliers.com',
        Forwarded_By_Email__c: 'intake@dpeg.com',
        Property_Address_Raw__c: '400 Congress Ave, Austin, TX 78701',
        Submitted_DateTime__c: '2025-02-10T15:30:00.000Z',
        Is_Winning_Submission__c: true
    },
    {
        Id: 'a0X0000000000002AAA',
        Broker_Name__c: 'Sam Okafor',
        Broker_Email__c: 'sam.okafor@cbre.com',
        Forwarded_By_Email__c: 'intake@dpeg.com',
        Property_Address_Raw__c: '400 Congress Ave, Austin, TX 78701',
        Submitted_DateTime__c: '2025-02-08T09:15:00.000Z',
        Is_Winning_Submission__c: false
    }
];

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('c-competing-broker-submissions', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: RECORD_ID }) {
        const element = createElement('c-competing-broker-submissions', {
            is: CompetingBrokerSubmissions
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('HAPPY PATH: renders a row per submission with Winner and Competing badges', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        // One row per submission.
        const rows = element.shadowRoot.querySelectorAll('tbody tr');
        expect(rows.length).toBe(2);

        // Header count reflects the data.
        expect(element.shadowRoot.querySelector('span[slot="title"]').textContent).toBe(
            'Competing Broker Submissions (2)'
        );

        // Both badges present, one Winner and one Competing.
        const badgeLabels = [
            ...element.shadowRoot.querySelectorAll('lightning-badge')
        ].map((b) => b.label);
        expect(badgeLabels).toContain('Winner');
        expect(badgeLabels).toContain('Competing');

        // Broker + forwarded-by emails render via lightning-formatted-email.
        const emailValues = [
            ...element.shadowRoot.querySelectorAll('lightning-formatted-email')
        ].map((e) => e.value);
        expect(emailValues).toContain('dana.reyes@colliers.com');
        expect(emailValues).toContain('sam.okafor@cbre.com');

        // Submitted date/time renders via lightning-formatted-date-time.
        const dt = element.shadowRoot.querySelector('lightning-formatted-date-time');
        expect(dt).not.toBeNull();
        expect(dt.value).toBe('2025-02-10T15:30:00.000Z');
    });

    it('EMPTY STATE: shows the empty message and no table when there are no submissions', async () => {
        const element = createComponent();

        getSubmissions.emit([]);
        await flushPromises();

        expect(element.shadowRoot.querySelector('.lv-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('tbody')).toBeNull();
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('ERROR PATH: dispatches an error toast and shows no table when the wire errors', async () => {
        const element = createComponent();

        const toastHandler = jest.fn();
        element.addEventListener('lightning__showtoast', toastHandler);

        getSubmissions.error();
        await flushPromises();

        expect(toastHandler).toHaveBeenCalledTimes(1);
        const { detail } = toastHandler.mock.calls[0][0];
        expect(detail.variant).toBe('error');
        expect(detail.title).toBe('Could not load broker submissions');
        expect(typeof detail.message).toBe('string');
        expect(detail.message.length).toBeGreaterThan(0);

        // Inline error banner replaces the table on error.
        expect(element.shadowRoot.querySelector('.lv-error')).not.toBeNull();
        expect(element.shadowRoot.querySelector('tbody')).toBeNull();
    });

    it('is accessible', async () => {
        const element = createComponent();

        getSubmissions.emit(SUBMISSIONS);
        await flushPromises();

        await expect(element).toBeAccessible();
    });
});
