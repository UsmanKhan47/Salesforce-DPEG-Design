/**
 * c-broker-listing-activity — @wire-to-LDS (getRecord) suite.
 * Pattern: transactionCriticalDates template (getRecord.emit / .error, no
 * jest.mock — the sfdx-lwc-jest uiRecordApi stub already exports getRecord as an
 * LDS test wire adapter and a real getFieldValue).
 *
 * Data source: @wire(getRecord, { recordId, fields: [ACTIVE_DAYS, LAST_CHECKIN,
 * DAYS_IDLE, LISTING_START] }) on Broker_Assignment__c. Four tiles are always
 * rendered; the health pill + idle-tile colour derive from Days_Since_Check_In__c
 * (>=30 very stale, >=7 stale, else on track, null = no check-in).
 *
 * MOCK-DATA SHAPE — a UI-API record whose `fields` keys are the REAL
 * Broker_Assignment__c field API names getFieldValue reads.
 */
import { createElement } from 'lwc';
import BrokerListingActivity from 'c/brokerListingActivity';
import { getRecord } from 'lightning/uiRecordApi';

function makeRecord({ active, start, checkin, idle }) {
    return {
        apiName: 'Broker_Assignment__c',
        id: 'a075g000000BAsgAAG',
        fields: {
            Listing_Active_Days__c: { value: active },
            Listing_Start_Date__c: { value: start },
            Last_Check_In_Date__c: { value: checkin },
            Days_Since_Check_In__c: { value: idle }
        }
    };
}

describe('c-broker-listing-activity', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent(props = { recordId: 'a075g000000BAsgAAG' }) {
        const element = createElement('c-broker-listing-activity', {
            is: BrokerListingActivity
        });
        Object.assign(element, props);
        document.body.appendChild(element);
        return element;
    }

    it('shows four em-dash tiles + "No check-in" before the record emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.la-tile-val')
        ].map((el) => el.textContent);
        expect(values).toEqual(['—', '—', '—', '—']);
        expect(
            element.shadowRoot.querySelector('.la-pill-txt').textContent
        ).toBe('No check-in');
    });

    it('DATA BRANCH: formats dates + counts and shows "Stale" for 7-29 idle days', async () => {
        const element = createComponent();

        getRecord.emit(
            makeRecord({
                active: 45,
                start: '2026-05-01',
                checkin: '2026-07-05',
                idle: 12
            })
        );
        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.la-tile-val')
        ].map((el) => el.textContent);
        // active, listing start, last check-in, days-since-check-in
        expect(values).toEqual(['45', 'May 1, 2026', 'Jul 5, 2026', '12']);
        expect(
            element.shadowRoot.querySelector('.la-pill-txt').textContent
        ).toBe('Stale');
    });

    it('DATA BRANCH: shows "Very stale" for 30+ idle days', async () => {
        const element = createComponent();

        getRecord.emit(
            makeRecord({
                active: 90,
                start: '2026-04-01',
                checkin: '2026-05-20',
                idle: 40
            })
        );
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.la-pill-txt').textContent
        ).toBe('Very stale');
    });

    it('DATA BRANCH: shows "On track" for fewer than 7 idle days', async () => {
        const element = createComponent();

        getRecord.emit(
            makeRecord({
                active: 10,
                start: '2026-07-01',
                checkin: '2026-07-14',
                idle: 2
            })
        );
        await Promise.resolve();

        expect(
            element.shadowRoot.querySelector('.la-pill-txt').textContent
        ).toBe('On track');
    });

    it('ERROR BRANCH: keeps the em-dash tiles when the record wire errors', async () => {
        const element = createComponent();

        getRecord.error();
        await Promise.resolve();

        const values = [
            ...element.shadowRoot.querySelectorAll('.la-tile-val')
        ].map((el) => el.textContent);
        expect(values).toEqual(['—', '—', '—', '—']);
    });

    it('is accessible', async () => {
        const element = createComponent();

        getRecord.emit(
            makeRecord({
                active: 45,
                start: '2026-05-01',
                checkin: '2026-07-05',
                idle: 12
            })
        );
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
