/**
 * c/utils — pure-function unit suite.
 *
 * These helpers were extracted from copy-pasted logic across many bundles; the
 * consuming components' own suites already assert the RENDERED strings. This
 * suite pins the helpers' contract directly, exercising boundaries ($0, sub-K,
 * exactly 1e6, negatives, null/undefined fallbacks, malformed dates) so a future
 * edit that changes output is caught here first.
 */
import {
    MONTHS,
    formatMoney,
    formatMillions,
    formatDaysToMarket,
    formatCapRate,
    formatExactCurrency,
    formatShortDate,
    formatLongDate,
    brokerOptionLabel
} from 'c/utils';

describe('c/utils MONTHS', () => {
    it('is the 12 abbreviated month names, Jan first', () => {
        expect(MONTHS).toEqual([
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec'
        ]);
    });

    it('is zero-indexed (index 0 = Jan, 11 = Dec)', () => {
        expect(MONTHS[0]).toBe('Jan');
        expect(MONTHS[11]).toBe('Dec');
    });
});

/**
 * 🔴 TWO COMPONENTS DEPEND ON THIS EXACT STRING — `c/bovComparisonMatrix` (BOV Outreach) and
 * `c/brokerListing` (Active Listing) both compose the Replace Broker modal's radio options with it,
 * and `c/bovComparisonMatrix`'s own suite asserts the full label verbatim. It lives here rather
 * than in either component precisely so the same broker cannot read differently on the two
 * surfaces that can open that modal.
 */
describe('c/utils brokerOptionLabel (broker picker option line)', () => {
    const ROW = {
        id: 'a0X010000000002',
        name: 'BOV-0002',
        brokerFirm: 'JLL',
        contactName: 'John Roe',
        bovAmount: 11000000,
        bovScore: 71
    };

    it('names the firm, the contact, the amount, the score and the auto-number', () => {
        expect(brokerOptionLabel(ROW)).toBe(
            'JLL — John Roe · $11.0M · Score 71 · BOV-0002'
        );
    });

    /**
     * 🔴 A NULL SCORE IS `—`, NEVER `0`. Every score in this org is null today, and 0 is a real,
     * meaningful, terrible score — printing it for "not computed" would say something false about
     * every broker on the list.
     */
    it('renders a null score as an em dash and a genuine zero as 0', () => {
        expect(brokerOptionLabel({ ...ROW, bovScore: null })).toContain(
            'Score —'
        );
        expect(brokerOptionLabel({ ...ROW, bovScore: null })).not.toContain(
            'Score 0'
        );
        expect(brokerOptionLabel({ ...ROW, bovScore: 0 })).toContain('Score 0');
    });

    it('falls back to "Unnamed firm" and omits absent parts rather than printing blanks', () => {
        expect(
            brokerOptionLabel({
                bovAmount: null,
                bovScore: null,
                brokerFirm: null,
                contactName: null,
                name: null
            })
        ).toBe('Unnamed firm · — · Score —');
    });
});

describe('c/utils formatMoney (compact, $0 fallback)', () => {
    it('renders zero as $0', () => {
        expect(formatMoney(0)).toBe('$0');
    });

    it('renders null / undefined / non-finite as $0', () => {
        expect(formatMoney(null)).toBe('$0');
        expect(formatMoney(undefined)).toBe('$0');
        expect(formatMoney(NaN)).toBe('$0');
        expect(formatMoney('not-a-number')).toBe('$0');
        expect(formatMoney(Infinity)).toBe('$0');
    });

    it('renders millions with one decimal', () => {
        expect(formatMoney(2500000)).toBe('$2.5M');
        expect(formatMoney(12500000)).toBe('$12.5M');
    });

    it('renders exactly 1e6 as $1.0M (boundary)', () => {
        expect(formatMoney(1000000)).toBe('$1.0M');
    });

    it('renders thousands as rounded whole K', () => {
        expect(formatMoney(750000)).toBe('$750K');
        expect(formatMoney(1500)).toBe('$2K'); // Math.round(1.5) = 2
    });

    it('renders exactly 1000 as $1K (boundary)', () => {
        expect(formatMoney(1000)).toBe('$1K');
    });

    it('renders sub-thousand raw with a dollar sign', () => {
        expect(formatMoney(500)).toBe('$500');
        expect(formatMoney(999)).toBe('$999');
    });

    it('coerces a decimal-over-the-wire string', () => {
        expect(formatMoney('2500000')).toBe('$2.5M');
    });

    it('handles negatives via absolute-value thresholds', () => {
        expect(formatMoney(-2500000)).toBe('$-2.5M');
        expect(formatMoney(-750000)).toBe('$-750K');
        expect(formatMoney(-500)).toBe('$-500');
    });
});

describe('c/utils formatMillions (always $M, em-dash fallback)', () => {
    it('renders null / undefined as an em dash', () => {
        expect(formatMillions(null)).toBe('—');
        expect(formatMillions(undefined)).toBe('—');
    });

    it('renders a value in millions with one decimal', () => {
        expect(formatMillions(9800000)).toBe('$9.8M');
        expect(formatMillions(12500000)).toBe('$12.5M');
    });

    it('keeps the millions scale even for zero and sub-million input', () => {
        expect(formatMillions(0)).toBe('$0.0M');
        expect(formatMillions(500000)).toBe('$0.5M');
    });

    it('coerces a decimal-over-the-wire string', () => {
        expect(formatMillions('11000000')).toBe('$11.0M');
    });

    it('renders negatives in millions', () => {
        expect(formatMillions(-9800000)).toBe('$-9.8M');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE CONTRACT ABOVE IS UNCHANGED BY THE 2026-08-21 EXACT-CURRENCY WORK.
    //    `c/dispositionOfferSelect` stopped CALLING this function; it was not
    //    widened, because `c/backupBrokers` and `c/bovComparisonMatrix` render
    //    BOV valuations where `$11.0M` is the right register and their suites
    //    assert those exact strings. The test below is the pin on that decision.
    // ─────────────────────────────────────────────────────────────────────────
    it('🔴 STILL ROUNDS — this is why the offer-select label had to stop using it', () => {
        // The org's two real offers. One string for two different bids; that is
        // the defect, and it is CORRECT behaviour for a $M abbreviation. Anyone
        // tempted to "fix" it here should read formatExactCurrency's header.
        expect(formatMillions(1850000)).toBe('$1.9M');
        expect(formatMillions(1860000)).toBe('$1.9M');
        expect(formatMillions(1850000)).toBe(formatMillions(1860000));
    });
});

/*
 * ═══════════════════════════════════════════════════════════════════════════
 * THE TWO BOV COLUMN FORMATTERS (extracted 2026-08-25)
 * ═══════════════════════════════════════════════════════════════════════════
 * Both were inline ternaries inside `c/bovComparisonMatrix.rows` with one caller
 * each. They now have two: that table, and the three stat columns on
 * `c/bovPreferredBroker`'s row, which `c/bovBrokerPanel` renders DIRECTLY ABOVE
 * the table from the SAME payload. The strings below are the exact strings both
 * of those suites assert — this file is where their contract is pinned directly.
 */
describe('c/utils formatDaysToMarket (day count + d, em-dash fallback)', () => {
    it('renders null / undefined as an em dash', () => {
        expect(formatDaysToMarket(null)).toBe('—');
        expect(formatDaysToMarket(undefined)).toBe('—');
    });

    it('suffixes a day count with d', () => {
        expect(formatDaysToMarket(45)).toBe('45d');
        expect(formatDaysToMarket(60)).toBe('60d');
    });

    /**
     * 🔴 ZERO IS A REAL VALUE AND MUST NOT PRINT AS `—`. "0 days to market"
     * means the asset is already listed; a falsy null-check would replace that
     * with the same glyph used for "we don't know", which says something false
     * about the broker's quote. `!= null` is what keeps them apart.
     */
    it('🔴 renders a genuine ZERO, never the em dash', () => {
        expect(formatDaysToMarket(0)).toBe('0d');
        expect(formatDaysToMarket(0)).not.toBe('—');
    });

    it('coerces a number-over-the-wire string', () => {
        expect(formatDaysToMarket('45')).toBe('45d');
    });
});

describe('c/utils formatCapRate (BOV cap rate, 2dp, em-dash fallback)', () => {
    it('renders null / undefined as an em dash', () => {
        expect(formatCapRate(null)).toBe('—');
        expect(formatCapRate(undefined)).toBe('—');
    });

    it('renders a percentage to two decimals', () => {
        expect(formatCapRate(6.25)).toBe('6.25%');
        expect(formatCapRate(6.8)).toBe('6.80%');
    });

    it('renders a genuine zero rather than the em dash', () => {
        expect(formatCapRate(0)).toBe('0.00%');
    });

    it('coerces a Decimal-over-the-wire string', () => {
        expect(formatCapRate('6.1')).toBe('6.10%');
    });

    /**
     * 🔴 TWO DECIMALS IS THE **BOV** VARIANT. `c/sellMeterList` formats its
     * `mktCapRate` with `toFixed(1)` and is deliberately NOT migrated to this
     * helper — its output would change from `6.5%` to `6.50%` and its suite
     * asserts the exact string. This assertion is the pin on that decision: if
     * someone "unifies" the precision, this fails here rather than silently
     * re-rendering another module's table.
     */
    it('🔴 keeps TWO decimals — sellMeterList uses ONE and is not a caller', () => {
        expect(formatCapRate(6.5)).toBe('6.50%');
        expect(formatCapRate(6.5)).not.toBe('6.5%');
    });
});

describe('c/utils formatExactCurrency (exact, grouped, never abbreviated)', () => {
    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE DEFECT THIS EXPORT EXISTS FOR (live UAT, 2026-08-21): the two offers
    //    in `usman-dpeg` both rendered `$1.9M` on the screen that picks the
    //    winning bid. These two lines are the whole point of the change.
    // ─────────────────────────────────────────────────────────────────────────
    it('🔴 renders the org’s two real offers as two DISTINCT strings', () => {
        expect(formatExactCurrency(1850000)).toBe('$1,850,000');
        expect(formatExactCurrency(1860000)).toBe('$1,860,000');
        expect(formatExactCurrency(1850000)).not.toBe(
            formatExactCurrency(1860000)
        );
    });

    it('🔴 has a collision distance of zero cents — $10 apart still reads apart', () => {
        // Two decimals would have rendered both of these `$1.85M`. There is no
        // choice of decimal places that survives this; only an exact figure does.
        expect(formatExactCurrency(1850000)).not.toBe(
            formatExactCurrency(1850010)
        );
        expect(formatExactCurrency(1850000.5)).toBe('$1,850,000.50');
    });

    it('groups thousands at every scale', () => {
        expect(formatExactCurrency(0)).toBe('$0');
        expect(formatExactCurrency(999)).toBe('$999');
        expect(formatExactCurrency(1000)).toBe('$1,000');
        expect(formatExactCurrency(12500000)).toBe('$12,500,000');
        expect(formatExactCurrency(1234567890)).toBe('$1,234,567,890');
    });

    it('shows cents only when they are non-zero', () => {
        expect(formatExactCurrency(2500000.0)).toBe('$2,500,000');
        expect(formatExactCurrency(2500000.4)).toBe('$2,500,000.40');
        expect(formatExactCurrency(2500000.456)).toBe('$2,500,000.46');
    });

    it('coerces a decimal-over-the-wire string', () => {
        expect(formatExactCurrency('1850000')).toBe('$1,850,000');
        expect(formatExactCurrency('1850000.25')).toBe('$1,850,000.25');
    });

    it('renders negatives with the sign OUTSIDE the currency symbol', () => {
        expect(formatExactCurrency(-1850000)).toBe('-$1,850,000');
    });

    it('renders null / undefined / empty / non-numeric as an em dash', () => {
        // ⚠ Stricter than formatMillions, which returns '$NaNM' for a non-numeric
        // input. An amount is the deciding value on this screen — "—" says "not
        // stated", where "$NaNM" says nothing at all.
        expect(formatExactCurrency(null)).toBe('—');
        expect(formatExactCurrency(undefined)).toBe('—');
        expect(formatExactCurrency('')).toBe('—');
        expect(formatExactCurrency('not a number')).toBe('—');
    });
});

describe('c/utils formatShortDate (MON D, empty fallback)', () => {
    it('formats a YYYY-MM-DD string as MON D with no leading zero', () => {
        expect(formatShortDate('2026-09-05')).toBe('Sep 5');
        expect(formatShortDate('2026-01-15')).toBe('Jan 15');
        expect(formatShortDate('2026-12-31')).toBe('Dec 31');
    });

    it('returns empty string for null / undefined / empty', () => {
        expect(formatShortDate(null)).toBe('');
        expect(formatShortDate(undefined)).toBe('');
        expect(formatShortDate('')).toBe('');
    });

    it('returns empty string for a malformed (non 3-part) date', () => {
        expect(formatShortDate('2026-09')).toBe('');
        expect(formatShortDate('garbage')).toBe('');
    });
});

describe('c/utils formatLongDate (MON D, YYYY, em-dash fallback)', () => {
    it('formats a YYYY-MM-DD string as MON D, YYYY with no leading zero', () => {
        expect(formatLongDate('2026-02-10')).toBe('Feb 10, 2026');
        expect(formatLongDate('2026-03-01')).toBe('Mar 1, 2026');
        expect(formatLongDate('2025-12-25')).toBe('Dec 25, 2025');
    });

    it('returns an em dash for null / undefined / empty', () => {
        expect(formatLongDate(null)).toBe('—');
        expect(formatLongDate(undefined)).toBe('—');
        expect(formatLongDate('')).toBe('—');
    });
});
