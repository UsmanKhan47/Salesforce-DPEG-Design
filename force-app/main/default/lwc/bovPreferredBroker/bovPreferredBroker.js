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
}
