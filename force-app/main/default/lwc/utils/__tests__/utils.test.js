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
