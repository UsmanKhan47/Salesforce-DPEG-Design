/**
 * c-broker-check-in-alerts
 * ---------------------------------------------------------------------------
 * Single no-param @wire(getAlerts). Maps the Alerts wrapper (stale7/stale30)
 * onto two tiles. The getter falls back to zeros before the wire emits and on
 * error, so the tiles always render.
 */
import { createElement } from 'lwc';
import BrokerCheckInAlerts from 'c/brokerCheckInAlerts';
import getAlerts from '@salesforce/apex/BrokerAssignmentController.getAlerts';

jest.mock(
    '@salesforce/apex/BrokerAssignmentController.getAlerts',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

const ALERTS = { stale7: 5, stale30: 2 };

describe('c-broker-check-in-alerts', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-check-in-alerts', {
            is: BrokerCheckInAlerts
        });
        document.body.appendChild(element);
        return element;
    }

    function tileValues(element) {
        return [...element.shadowRoot.querySelectorAll('.ca-val')].map(
            (el) => el.textContent
        );
    }

    it('renders two zero tiles before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(element.shadowRoot.querySelectorAll('.ca-grid > div').length).toBe(2);
        expect(tileValues(element)).toEqual(['0', '0']);
    });

    it('DATA BRANCH: renders the stale-7 and stale-30 counts with labels', async () => {
        const element = createComponent();

        getAlerts.emit(ALERTS);
        await Promise.resolve();

        expect(tileValues(element)).toEqual(['5', '2']);

        const labels = [...element.shadowRoot.querySelectorAll('.ca-lbl')].map(
            (el) => el.textContent
        );
        expect(labels).toEqual(['7 Days Stale', '30 Days Stale']);
    });

    it('ERROR BRANCH: keeps zero tiles and shows an error banner when the wire errors', async () => {
        const element = createComponent();

        getAlerts.error();
        await Promise.resolve();

        expect(tileValues(element)).toEqual(['0', '0']);
        const banner = element.shadowRoot.querySelector('.ca-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toBe("Couldn't load check-in alerts.");
    });

    it('is accessible', async () => {
        const element = createComponent();

        getAlerts.emit(ALERTS);
        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
