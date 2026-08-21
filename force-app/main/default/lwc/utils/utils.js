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
 * EXACT currency, grouped, never abbreviated — `$1,850,000`. Cents are shown
 * only when non-zero (`$1,850,000.50`). Null / empty / non-numeric render as an
 * em dash (`—`).
 *
 * ── 🔴 WHY THIS EXISTS BESIDE `formatMillions` RATHER THAN REPLACING IT ──────
 * ADDED 2026-08-21 from live UAT. `c/dispositionOfferSelect` — the screen where
 * DPEG picks the WINNING BID — was labelling its radio options with
 * `formatMillions`, and the org's two live offers are:
 *
 *     OFFER-0005   $1,850,000        OFFER-0006   $1,860,000
 *
 * Both rendered `$1.9M`. Two distinct bids reading as the same string on the
 * screen that chooses between them is a wrong-decision defect.
 *
 * ⚠ MORE DECIMAL PLACES WOULD NOT HAVE FIXED IT, IT WOULD HAVE MOVED IT. Any
 * abbreviation has a collision distance: one decimal collides at $100k, two at
 * $10k, three at $1k. DPEG's offers routinely differ by increments smaller than
 * the last kept digit, so every choice of N leaves a pair of real bids that
 * render identically — there is no safe N. An exact figure has a collision
 * distance of ZERO CENTS by construction, which is the only property that makes
 * the label safe to decide on. It is also how the platform itself renders the
 * field (the UI API returns `displayValue: "$1,850,000"` for
 * `Offer_Amount__c`), so the radio label now agrees with the record detail page
 * beside it instead of disagreeing by $50,000.
 *
 * 🔴 `formatMillions` IS DELIBERATELY LEFT EXACTLY AS IT WAS. Its other two
 * callers — `c/backupBrokers` and `c/bovComparisonMatrix` — render BOV
 * VALUATIONS in a dense comparison grid, where `$11.0M` is the right register
 * and where the labels are already disambiguated by score and by the
 * submission's own auto-number (see `brokerOptionLabel` below). Widening
 * `formatMillions` would have changed their rendered output, breaking the
 * byte-compatibility contract stated at the top of this module, to fix a defect
 * neither of them has. One new export, zero behaviour change for existing
 * callers.
 *
 * @param {number|string|null|undefined} n Raw amount (Decimals arrive as
 *   strings over the wire).
 * @returns {string} e.g. `'$1,850,000'`, `'$1,850,000.50'`, `'$0'`, or `'—'`.
 */
export function formatExactCurrency(n) {
    if (n == null || n === '') {
        return '—';
    }
    const v = Number(n);
    if (!isFinite(v)) {
        return '—';
    }
    // `toFixed(2)` then split, rather than arithmetic on the fractional part:
    // it has no floating-point edge where the cents round up to `100`.
    const [whole, cents] = Math.abs(v).toFixed(2).split('.');
    const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (v < 0 ? '-$' : '$') + grouped + (cents === '00' ? '' : '.' + cents);
}

/**
 * One radio-option label for the Select / Replace Broker picker, from a
 * `BovController.BovRow`.
 *
 * ── 🔴 IT IS DELIBERATELY LONG, BECAUSE THIS ORG'S DATA IS AMBIGUOUS ─────────
 * Two data realities are visible on this surface and NEITHER is filtered or
 * de-duplicated here — that is the user's decision to make, not this helper's:
 *   - SIX broker Contacts exist TWICE with an identical name AND an identical
 *     firm (Derek Simmons, Priya Nair, Marcus Whitfield, Katie Osborne, Ryan
 *     O'Connell, Sofia Delgado). Firm alone — which is all this label carried
 *     until 2026-08-21 — renders two options as the same string, so the user is
 *     choosing at random between them.
 *   - SEVEN Contacts on the Broker record type are not brokers at all (Acme x3,
 *     Global Media x2, salesforce.com, "Unknown - Via Email"). They are shown,
 *     because hiding a bad row is how it survives.
 * The BOV amount and the submission's own auto-number are what actually
 * separate two otherwise identical lines, so both are in the label. Do not
 * shorten this back to the firm.
 *
 * ⚠ A NULL SCORE RENDERS `—`, NEVER `0`. Every score in the org is null today
 * (`BOV_Score__c` is a formula returning null until the disposition has an
 * asking price), and `0` is a real, meaningful, terrible score — printing it
 * for "not computed" would tell the user something false about every broker on
 * the list. `== null` rather than a falsy test, so a genuine zero still prints.
 *
 * ── 🔴 WHY IT LIVES HERE RATHER THAN IN A COMPONENT (2026-08-21) ─────────────
 * TWO components now open `c/bovReplaceBrokerModal` and must supply
 * `backupOptions`: `c/bovComparisonMatrix` (BOV Outreach stage) and
 * `c/brokerListing` (Active Listing stage — the two are mutually exclusive on
 * the page, which is why the second entry point exists at all). The modal's own
 * header records that it does NO formatting *"so the modal and the matrix
 * behind it cannot disagree about the same broker's numbers"* — a second copy
 * of this function in the second component would reintroduce exactly the
 * disagreement that contract prevents. One function, two callers, no drift.
 *
 * @param {object} r A `BovController.BovRow`-shaped object.
 * @returns {string} e.g. `'JLL — John Roe · $11.0M · Score 71 · BOV-0002'`.
 */
export function brokerOptionLabel(r) {
    const who = [r.brokerFirm || 'Unnamed firm', r.contactName]
        .filter(Boolean)
        .join(' — ');
    const facts = [
        formatMillions(r.bovAmount),
        `Score ${r.bovScore == null ? '—' : r.bovScore}`
    ];
    if (r.name) {
        facts.push(r.name);
    }
    return `${who} · ${facts.join(' · ')}`;
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
