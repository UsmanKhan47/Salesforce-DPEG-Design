/**
 * @wire-to-Apex suite for c-broker-leaderboard.
 *
 * The component is deliberately thin — BrokerLeaderboardService decides rank, win
 * rate and ordering, and the client only formats. These tests therefore assert
 * PASS-THROUGH (server values reach the datatable unmodified and in order) rather
 * than re-deriving the ranking, which is the behaviour a regression here would
 * break.
 */
import { createElement } from 'lwc';
import BrokerLeaderboard from 'c/brokerLeaderboard';
import getLeaderboard from '@salesforce/apex/BrokerLeaderboardController.getLeaderboard';

jest.mock(
    '@salesforce/apex/BrokerLeaderboardController.getLeaderboard',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Matches BrokerLeaderboardService.BrokerRow[].
const ROWS = [
    {
        brokerEmail: 'jane@brokerfirm.example.invalid',
        brokerName: 'Jane Broker',
        rank: 1,
        submissions: 12,
        propertiesWon: 8,
        winRatePct: 66.7,
        firstSubmitted: '2026-01-05T10:00:00.000Z',
        lastSubmitted: '2026-08-01T09:30:00.000Z'
    },
    {
        brokerEmail: 'listings@buildout.example.invalid',
        brokerName: null,
        rank: 2,
        submissions: 9,
        propertiesWon: 2,
        winRatePct: 22.2,
        firstSubmitted: '2026-02-11T08:00:00.000Z',
        lastSubmitted: '2026-07-20T16:45:00.000Z'
    },
    {
        brokerEmail: 'sam@smallshop.example.invalid',
        brokerName: 'Sam Agent',
        rank: 3,
        submissions: 4,
        propertiesWon: 0,
        winRatePct: 0,
        firstSubmitted: '2026-03-02T11:15:00.000Z',
        lastSubmitted: '2026-06-30T12:00:00.000Z'
    }
];

describe('c-broker-leaderboard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function createComponent() {
        const element = createElement('c-broker-leaderboard', {
            is: BrokerLeaderboard
        });
        document.body.appendChild(element);
        return element;
    }

    function title(element) {
        return element.shadowRoot.querySelector('span[slot="title"]').textContent;
    }

    it('shows the empty state, not an error, before the wire emits', async () => {
        const element = createComponent();

        await Promise.resolve();

        expect(title(element)).toBe('Broker Leaderboard (0)');
        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
        expect(element.shadowRoot.querySelector('.bl-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('DATA BRANCH: passes every server row through in server order', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);

        await Promise.resolve();

        expect(title(element)).toBe('Broker Leaderboard (3)');
        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data).toHaveLength(3);
        // Order and rank are the SERVER's decision — assert they survive untouched.
        expect(table.data.map((r) => r.rank)).toEqual([1, 2, 3]);
        expect(table.data.map((r) => r.brokerEmail)).toEqual([
            ROWS[0].brokerEmail,
            ROWS[1].brokerEmail,
            ROWS[2].brokerEmail
        ]);
        expect(table.data[0].submissions).toBe(12);
        expect(table.data[0].propertiesWon).toBe(8);
    });

    it('formats the win rate as a percentage and never recomputes it', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);

        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        // 8/12 is 66.666...; the label must be the server's 66.7, not a client divide.
        expect(table.data[0].winRateLabel).toBe('66.7%');
        expect(table.data[2].winRateLabel).toBe('0%');
    });

    it('renders an em dash for a broker with no name, keeping the email as the key', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);

        await Promise.resolve();

        const table = element.shadowRoot.querySelector('c-list-datatable');
        expect(table.data[1].brokerLabel).toBe('—');
        expect(table.data[1].brokerEmail).toBe('listings@buildout.example.invalid');
    });

    it('surfaces the blast-platform note so a platform row is explicable', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);

        await Promise.resolve();

        const note = element.shadowRoot.querySelector('.bl-note');
        expect(note).not.toBeNull();
        expect(note.textContent).toContain('listing platform');
    });

    it('EMPTY BRANCH: an empty ledger is not an error', async () => {
        const element = createComponent();
        getLeaderboard.emit([]);

        await Promise.resolve();

        expect(title(element)).toBe('Broker Leaderboard (0)');
        expect(element.shadowRoot.querySelector('.bl-empty')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.lv-error')).toBeNull();
    });

    it('ERROR BRANCH: shows the banner and drops the table rather than showing stale rows', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('c-list-datatable')).not.toBeNull();

        // The test adapter's error(body, status) wraps `body` — it is NOT the whole
        // error object, so passing { body: ... } here silently yields "Unknown error".
        getLeaderboard.error({ message: 'Read failed' }, 500);
        await Promise.resolve();

        const banner = element.shadowRoot.querySelector('.lv-error');
        expect(banner).not.toBeNull();
        expect(banner.textContent).toContain('Read failed');
        expect(element.shadowRoot.querySelector('c-list-datatable')).toBeNull();
    });

    it('ERROR BRANCH: falls back to a generic message when the error carries none', async () => {
        const element = createComponent();
        getLeaderboard.error({});

        await Promise.resolve();

        expect(element.shadowRoot.querySelector('.lv-error').textContent).toContain(
            'Unknown error'
        );
    });

    it('is accessible with data', async () => {
        const element = createComponent();
        getLeaderboard.emit(ROWS);

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });

    it('is accessible when empty', async () => {
        const element = createComponent();
        getLeaderboard.emit([]);

        await Promise.resolve();

        await expect(element).toBeAccessible();
    });
});
