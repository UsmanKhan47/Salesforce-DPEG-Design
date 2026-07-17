/**
 * c/utils — shared presentational helpers for DPEG LWCs.
 *
 * Pure, stateless formatting utilities extracted from helper logic that was
 * copy-pasted across many bundles (compact currency, $M abbreviation, the
 * `Jan..Dec` month table, and short/long date formatting). Import what you
 * need:
 *
 *     import { formatMoney, formatMillions, MONTHS } from 'c/utils';
 *
 * Every export here reproduces the EXACT string output of the local copies it
 * replaced — the consuming components' Jest suites assert those exact strings,
 * so this module is byte-compatible by construction. Do not "improve" the
 * output (e.g. add thousands separators) without updating every consumer test.
 *
 * NOTE: several bundles carry subtly divergent variants (e.g. lowercase `k`
 * suffix, a `—`/`''`/`$0` fallback, or an always-millions vs. compact scale).
 * Those are intentionally NOT collapsed into one function — each distinct,
 * genuinely-duplicated behaviour gets its own named export so no consumer's
 * rendered output changes.
 *
 * @module c/utils
 */

/**
 * Abbreviated English month names, index 0 = January. Shared table replacing
 * the identical `const MONTHS = ['Jan', ...]` declared in ~18 bundles.
 * @type {string[]}
 */
export const MONTHS = [
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
];

/**
 * Compact currency for KPI tiles. Millions render with one decimal (`$2.5M`),
 * thousands render as rounded whole `K` (`$750K`), sub-thousand renders raw
 * (`$500`), and zero / non-finite input renders `$0`.
 *
 * Extracted from the byte-identical `_money(n)` in `opportunityPipeline` and
 * `sellMeterStats`.
 *
 * @param {number|string|null|undefined} n Raw amount (Decimals arrive as
 *   strings over the wire; `Number()` coerces them).
 * @returns {string} e.g. `'$2.5M'`, `'$750K'`, `'$500'`, `'$0'`.
 */
export function formatMoney(n) {
    const v = Number(n);
    if (!isFinite(v) || v === 0) {
        return '$0';
    }
    if (Math.abs(v) >= 1000000) {
        return '$' + (v / 1000000).toFixed(1) + 'M';
    }
    if (Math.abs(v) >= 1000) {
        return '$' + Math.round(v / 1000) + 'K';
    }
    return '$' + v;
}

/**
 * Always-millions currency with one decimal (`$9.8M`), used for valuation /
 * BOV-amount columns where every value is expected to be in the millions.
 * Null / undefined render as an em dash (`—`).
 *
 * Extracted from the identical `_fmtM(val)` in `sellMeterList` and the inline
 * `bovAmount != null ? '$' + (parseFloat(...) / 1000000).toFixed(1) + 'M' : '—'`
 * expressions in `backupBrokers` and `bovComparisonMatrix`.
 *
 * @param {number|string|null|undefined} n Raw amount (Decimal-over-wire safe
 *   via `parseFloat`).
 * @returns {string} e.g. `'$9.8M'`, or `'—'` when null/undefined.
 */
export function formatMillions(n) {
    if (n == null) {
        return '—';
    }
    return '$' + (parseFloat(n) / 1000000).toFixed(1) + 'M';
}

/**
 * Short date `MON D` (no year, no leading zero) from a Salesforce Date string
 * `'YYYY-MM-DD'`. Parsed by hand (not `new Date`) to avoid timezone shifting a
 * date-only value. Null / malformed input renders as an empty string.
 *
 * Matches the `dateLabel(d)` in `transactionTaskGroups` exactly. The
 * `onboardingChecklist` copy shares the same valid-input formatting but has a
 * different fallback (`'—'` / echoes the raw input), so it is NOT migrated to
 * this helper.
 *
 * @param {string|null|undefined} d Date-only string `'YYYY-MM-DD'`.
 * @returns {string} e.g. `'Sep 5'`, or `''` when null/malformed.
 */
export function formatShortDate(d) {
    if (!d) {
        return '';
    }
    const p = String(d).split('-');
    if (p.length !== 3) {
        return '';
    }
    return MONTHS[parseInt(p[1], 10) - 1] + ' ' + parseInt(p[2], 10);
}

/**
 * Long date `MON D, YYYY` from a Salesforce Date string `'YYYY-MM-DD'`. Parsed
 * by hand to avoid timezone shifting a date-only value. Null / falsy input
 * renders as an em dash (`—`).
 *
 * Extracted from the byte-identical `_fmtDate(d)` in `bovOutreach` and
 * `brokerListing`.
 *
 * @param {string|null|undefined} d Date-only string `'YYYY-MM-DD'`.
 * @returns {string} e.g. `'Feb 10, 2026'`, or `'—'` when falsy.
 */
export function formatLongDate(d) {
    if (!d) {
        return '—';
    }
    const parts = String(d).split('-');
    return (
        MONTHS[parseInt(parts[1], 10) - 1] +
        ' ' +
        parseInt(parts[2], 10) +
        ', ' +
        parts[0]
    );
}
