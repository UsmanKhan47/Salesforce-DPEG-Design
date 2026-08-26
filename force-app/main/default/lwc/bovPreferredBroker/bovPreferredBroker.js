import { LightningElement, api } from 'lwc';

/**
 * What the panel says when the preferred broker has neither a contact name nor a
 * firm name.
 *
 * 🔴 BOTH SOURCES ARE LEGITIMATELY NULLABLE AND `Broker_Firm__c` WAS NULL ON LIVE
 * DATA THIS WEEK. A preferred broker is a broker DPEG would like to use, recorded
 * ahead of any quoted opinion of value, so the thin row that carries the flag
 * frequently carries little else. Without this fallback the panel renders as a
 * green box containing an icon, a label and an empty bold line — or, if a parent
 * ever hands over `undefined`, the literal string "undefined". Both have shipped
 * in this repo before.
 *
 * ⚠ THE SAME WORDING AS `c/bovBrokerPanel`'s `outgoingPreferredLabel` and as the
 * BOV responses section of `c/dispositionBuyerTimeline`, which solve the same
 * problem for the same broker. Two different placeholders for one missing value
 * on one page read as two different states.
 */
const UNNAMED = 'Unnamed broker';

/**
 * What a STAT COLUMN shows when the parent supplied no string for it.
 *
 * 🔴 THE SAME GLYPH `c/utils.formatMillions` AND `c/bovComparisonMatrix` ALREADY
 * USE FOR A MISSING NUMBER, and that is the whole point — the matrix's Valuation
 * / Days to Mkt / Cap Rate columns and these three read the same `BovRow` fields
 * through the same formatters, so a blank here beside a `—` there would be two
 * renderings of one absent value.
 *
 * ⚠ IT IS A PARTIAL-SUPPLY GUARD, NOT THE NORMAL PATH. `c/bovBrokerPanel` formats
 * all three and hands down `—` itself for a null field. This constant only fires
 * if a caller supplies SOME of the three, which would otherwise render a column
 * with an empty value line above a label.
 */
const NO_VALUE = '—';

/**
 * c-bov-preferred-broker — the highlighted preferred-broker panel.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS A BUNDLE AND NOT A `preferredOnly` MODE (2026-08-24).
 * ══════════════════════════════════════════════════════════════════════════════
 * `c/bovComparisonMatrix` carried `@api preferredOnly`, and that flag selected
 * FOUR things: the row filter, the card title, the column set, and whether the
 * card rendered at all. Three of those four are statements about a TABLE. Once
 * the user's design turned the preferred view into a hero panel, the flag no
 * longer selected between two configurations of one rendering; it selected
 * between two unrelated renderings inside one template, which is strictly worse
 * than two components.
 *
 * DELETED FROM `c/bovComparisonMatrix` IN THAT SAME CHANGE, and none of it should
 * come back: `@api preferredOnly` itself; `PREFERRED_COLUMNS` and the `columns`
 * branch that chose between them; the `cardTitle` branch; and
 * `hasPreferredBroker` / `isVisible` with the `lwc:if` wrapper around the card.
 * WHAT STAYED THERE: the row filter, unconditional now — the matrix must still
 * exclude the preferred row, and that is a fact about the MATRIX rather than a
 * mode of it.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 2026-08-25 — TWO PROPS NOW, AND THE NEW ONE IS THE PRIMARY LINE.
 * ══════════════════════════════════════════════════════════════════════════════
 * User instruction: *"show broker contacts, not accounts"*. `contactName` is the
 * person and is what the panel leads with; `firmName` demotes to a muted second
 * line. Both come off ONE `BovController.BovRow` (`contactName` / `brokerFirm`),
 * which is the same object backing the BOV Comparison Matrix's "Contact" column —
 * so the two surfaces cannot disagree about who the broker is.
 *
 * 🔴 `firmName` KEPT ITS NAME AND ITS POSITION IN THE API. Renaming it would have
 * broken `c/bovBrokerPanel`'s existing mount for no gain, and the panel still
 * needs the firm — it just no longer leads with it.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 2026-08-25 (3) — FIVE PROPS NOW. THE THREE NEW ONES ARE PRE-FORMATTED.
 * ══════════════════════════════════════════════════════════════════════════════
 * User instruction: the row shows Valuation, Days to Market and Cap Rate on its
 * right-hand side. All three arrive as FINISHED STRINGS — this component does no
 * number formatting at all, and must not start.
 *
 * 🔴 WHY THE FORMATTING IS THE PARENT'S. The same three fields are already
 * rendered by `c/bovComparisonMatrix` inches below this row, from the SAME
 * `BovController.BovRow` payload, through `c/utils.formatMillions` and the two
 * inline expressions beside it. Formatting them a second time here — even
 * "identically" — is how `$12.5M` up here becomes `$12.50M` down there after
 * someone edits one of the two copies. The parent formats once, with the shared
 * helper, and hands the result to both surfaces. Same argument, and the same
 * `c/utils` helper, that put `brokerOptionLabel` in a shared module.
 *
 * 🔴 `''` MEANS "THIS PARENT DOES NOT SHOW STATS" — IT IS NOT A MISSING VALUE.
 * The distinction is load-bearing and is the reverse of `contactName`/`firmName`,
 * where `''` means the row's field is null:
 *   · all three `''`  -> the stats block is NOT RENDERED AT ALL (`hasStats`).
 *   · any non-empty   -> the block renders, and a missing NUMBER is the `—` the
 *                        parent already put in the string.
 * That is what keeps this addition invisible to the OTHER parent below: the
 * ~276px sidebar has no room for three columns, `c/dispositionBuyerTimeline`
 * passes none of them, and its rendering is unchanged BY CONSTRUCTION rather
 * than by a mode flag. A component that always rendered the block — three em
 * dashes wide — would have forced that parent to opt out of something it never
 * asked for.
 *
 * ⚠ THE `''`-NEVER-`undefined` CONTRACT APPLIES TO ALL FIVE. A getter bound to
 * an attribute on a custom element is written UNCONDITIONALLY, so `undefined`
 * reaches the DOM as the literal string "undefined" — measured in this repo. The
 * normalisation is HERE (see the getters) rather than in each caller.
 *
 * ── TWO PARENTS SINCE 2026-08-25 ────────────────────────────────────────────
 *   · `c/bovBrokerPanel` — the "Brokers" card at BOV Outreach;
 *   · `c/dispositionBuyerTimeline` — SECTION 1 of the record-page card.
 * Both hold every BOV row already (their own rules read them) and both find the
 * flagged one themselves, so neither makes this component wire another copy of
 * the same `cacheable=true` query. That also makes the refresh path free: after a
 * write the parent re-provisions its own wire, the props change, and this panel
 * re-renders — there is nothing here for a `refreshApex` to call.
 */
export default class BovPreferredBroker extends LightningElement {
    /**
     * The preferred broker's CONTACT name — the person. Straight off
     * `BovController.BovRow.contactName`.
     *
     * ⚠ MAY BE `''`, `null`, `undefined` OR WHITESPACE, AND ALL FOUR ARE
     * NORMALISED BY THE GETTERS BELOW rather than by the caller. Owning the
     * fallback here is what makes this bundle safe to mount from anywhere; a
     * caller-side fallback is one every future caller has to remember, and there
     * are two callers now.
     */
    @api contactName;

    /** The preferred broker's firm name, straight off `BovController.BovRow.brokerFirm`. */
    @api firmName;

    /**
     * The quoted valuation, ALREADY FORMATTED — e.g. `'$12.5M'`, or `'—'`.
     *
     * ⚠ A STRING, NOT A NUMBER, AND NOT BY ACCIDENT. `c/bovBrokerPanel` runs
     * `c/utils.formatMillions` over `BovRow.bovAmount` — the same call
     * `c/bovComparisonMatrix` makes for its Valuation column — so the two
     * surfaces cannot render one broker's number two ways. Do not add a
     * `Number()` path here to "make the API nicer": that is the second copy.
     */
    @api valuationLabel;

    /** Days to market, already formatted — e.g. `'45d'`, or `'—'`. Same contract as `valuationLabel`. */
    @api daysToMarketLabel;

    /** Cap rate, already formatted — e.g. `'6.25%'`, or `'—'`. Same contract as `valuationLabel`. */
    @api capRateLabel;

    /**
     * The name on the PRIMARY line — never empty, never the string "undefined".
     *
     * 🔴 THE FIRM IS THE FALLBACK, AND `UNNAMED` IS THE FALLBACK'S FALLBACK. A
     * BOV submission recorded against a firm with no named contact is ordinary
     * data, and a green panel headed "Unnamed broker" while the row plainly
     * carries a firm name would be withholding what is known.
     *
     * 🔴 `.trim()` IS PART OF THE CHECK, NOT TIDYING. A name of `'   '` is falsy
     * nowhere in JavaScript, so a bare `||` chain renders a blank bold line for
     * it — visually identical to the null case these fallbacks exist to prevent,
     * and reachable from a hand-typed record.
     */
    get displayName() {
        return this.trimmedContact || this.trimmedFirm || UNNAMED;
    }

    /** The firm, trimmed. Rendered only when `hasFirm` says so. */
    get displayFirm() {
        return this.trimmedFirm;
    }

    /**
     * Whether the muted firm line renders at all.
     *
     * 🔴 IT IS NOT "IS THE FIRM NON-EMPTY". With no contact name the firm has
     * ALREADY been promoted to the primary line by `displayName`, so rendering it
     * again underneath itself in grey would read as two different brokers on one
     * panel. The condition is therefore "there is a firm AND it is not what the
     * primary line is already showing".
     */
    get hasFirm() {
        return !!this.trimmedFirm && this.trimmedFirm !== this.displayName;
    }

    get trimmedContact() {
        return typeof this.contactName === 'string' ? this.contactName.trim() : '';
    }

    get trimmedFirm() {
        return typeof this.firmName === 'string' ? this.firmName.trim() : '';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE THREE STAT COLUMNS (2026-08-25)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Whether the right-hand stats block renders at all.
     *
     * 🔴 "DID A PARENT ASK FOR STATS", NOT "ARE THERE NUMBERS". A preferred
     * broker is typically a THIN row — flagged before anyone has quoted — so
     * `'—' / '—' / '—'` is the ordinary state of this block on the Brokers card
     * and must still render: three labelled em dashes say the facts are not
     * recorded yet, which is information. Withholding the block on all-dashes
     * would make the row silently change shape the moment a broker responds.
     *
     * ⚠ WHICH IS EXACTLY WHY THE TEST IS ON THE UNFORMATTED `''`. Only a parent
     * that supplies NOTHING gets no block — see the header for why that is what
     * keeps `c/dispositionBuyerTimeline` unchanged.
     */
    get hasStats() {
        return !!(
            this.trimmedValuation ||
            this.trimmedDaysToMarket ||
            this.trimmedCapRate
        );
    }

    /**
     * The three columns, in the user's order: Valuation, Days to Market, Cap Rate.
     *
     * 🔴 ONE ARRAY RENDERED BY A `for:each`, NOT THREE HAND-WRITTEN BLOCKS. The
     * three columns are identical in every respect but their two strings, and
     * three copies of the same two-span markup is three places for one of them
     * to drift out of the shared typography — which is the defect the whole
     * `.pref-stat-value` / `.pref-stat-label` pair exists to prevent.
     *
     * ⚠ `key` IS THE LABEL because it is fixed, unique and stable — these are
     * three constant columns, not data rows.
     */
    get stats() {
        return [
            { key: 'Valuation', label: 'Valuation', value: this.trimmedValuation || NO_VALUE },
            { key: 'Days to Market', label: 'Days to Market', value: this.trimmedDaysToMarket || NO_VALUE },
            { key: 'Cap Rate', label: 'Cap Rate', value: this.trimmedCapRate || NO_VALUE }
        ];
    }

    get trimmedValuation() {
        return typeof this.valuationLabel === 'string' ? this.valuationLabel.trim() : '';
    }

    get trimmedDaysToMarket() {
        return typeof this.daysToMarketLabel === 'string'
            ? this.daysToMarketLabel.trim()
            : '';
    }

    get trimmedCapRate() {
        return typeof this.capRateLabel === 'string' ? this.capRateLabel.trim() : '';
    }
}
