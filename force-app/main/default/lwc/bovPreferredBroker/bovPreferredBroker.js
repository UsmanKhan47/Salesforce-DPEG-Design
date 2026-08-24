import { LightningElement, api } from 'lwc';

/**
 * What the panel says when the preferred broker's firm name is blank.
 *
 * 🔴 `Broker_Firm__c` IS LEGITIMATELY NULLABLE AND WAS NULL ON LIVE DATA THIS
 * WEEK. A preferred broker is a firm DPEG would like to use, recorded ahead of
 * any quoted opinion of value, so the thin row that carries the flag frequently
 * carries nothing else. Without this fallback the panel renders as a green box
 * containing an icon, a label and an empty bold line — or, if the parent ever
 * hands over `undefined`, the literal string "undefined". Both have shipped in
 * this repo before.
 *
 * ⚠ THE SAME WORDING AS `c/bovBrokerPanel`'s `outgoingPreferredLabel`, which
 * solves the same problem for the replacement dialog's read-only identity field.
 * Two different placeholders for the same missing value on the same page would
 * read as two different states.
 */
const UNNAMED = 'Unnamed broker';

/**
 * c-bov-preferred-broker — the highlighted preferred-broker panel.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS A BUNDLE AND NOT A `preferredOnly` MODE (2026-08-24).
 * ══════════════════════════════════════════════════════════════════════════════
 * `c/bovComparisonMatrix` carried `@api preferredOnly`, and that flag selected
 * FOUR things: the row filter, the card title, the column set, and whether the
 * card rendered at all. Three of those four are statements about a TABLE. Once
 * the user's design turned the preferred view into a hero panel — an icon, a
 * label, a firm name, a pill — the flag no longer selected between two
 * configurations of one rendering; it selected between two unrelated renderings
 * inside one template, which is strictly worse than two components.
 *
 * DELETED FROM `c/bovComparisonMatrix` IN THE SAME CHANGE, and none of it should
 * come back:
 *   - `@api preferredOnly` itself;
 *   - `PREFERRED_COLUMNS` (the COLUMNS-minus-Status derivation) and the
 *     `columns` branch that chose between them — there is no table here to have
 *     columns, so "which columns does the preferred card show" has no answer;
 *   - the `cardTitle` branch — the "Preferred Broker" title is now the eyebrow
 *     label inside this panel, so the matrix's title is unconditional again;
 *   - `hasPreferredBroker` and `isVisible`, and the `lwc:if={isVisible}` wrapper
 *     around the whole card. Those existed ONLY so the preferred instance could
 *     withhold itself; the matrix instance's `isVisible` was `true` in every
 *     state, so deleting them is behaviour-preserving for the surviving card.
 * WHAT STAYED THERE: the row filter, unconditional now — the matrix must still
 * exclude the preferred row, and that is a fact about the MATRIX rather than a
 * mode of it.
 *
 * ── THE PUBLIC API IS ONE STRING ────────────────────────────────────────────
 * `c/bovBrokerPanel` already holds every BOV row (its three buttons' visibility
 * rules read them) and already finds the flagged one, so it hands the firm name
 * down rather than making this component wire a fourth copy of the same
 * `cacheable=true` query. That also makes the refresh path free: after a write
 * the panel re-provisions its own wire, `firmName` changes, and this panel
 * re-renders — there is nothing here for `_refreshAll` to call.
 */
export default class BovPreferredBroker extends LightningElement {
    /**
     * The preferred broker's firm name, straight off `BovController.BovRow`.
     *
     * ⚠ MAY BE `''`, `null`, `undefined` OR WHITESPACE, AND ALL FOUR ARE
     * NORMALISED BY `displayName` BELOW rather than by the caller. Owning the
     * fallback here is what makes this bundle safe to mount from anywhere; a
     * caller-side fallback is one every future caller has to remember.
     */
    @api firmName;

    /**
     * The name actually rendered — never empty, never the string "undefined".
     *
     * 🔴 `.trim()` IS PART OF THE CHECK, NOT TIDYING. A firm name of `'   '` is
     * falsy nowhere in JavaScript, so a bare `this.firmName || UNNAMED` renders
     * a blank bold line for it — visually identical to the null case this getter
     * exists to prevent, and reachable from a hand-typed record.
     */
    get displayName() {
        const name = typeof this.firmName === 'string' ? this.firmName.trim() : '';
        return name || UNNAMED;
    }
}
