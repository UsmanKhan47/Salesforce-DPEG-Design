import { LightningElement, api, wire } from 'lwc';

/**
 * 🔴 A REUSED APEX METHOD, NOT A NEW ONE. `BovController.getSubmissions` is
 * already `cacheable=true`, already granted on `DPEG_Apex_Access`, already read
 * by `c/bovBrokerPanel` — and, as of today, also by `c/bovResponsesCard`, the
 * "BOV (n)" card that sits two places below this one on the same page.
 *
 * ⚠ TWO CARDS WIRING THE SAME ADAPTER WITH THE SAME CONFIG IS ONE SERVER READ,
 * NOT TWO. Lightning Data Service keys its cache on (adapter, config), and both
 * cards pass `{ dispositionId: '$recordId' }` for the same record — so the
 * second subscriber is served from the same cache entry and re-provisions from
 * it whenever the first one's data changes. This is the reason the three cards
 * are three components rather than one: no Apex, no selector and no permission
 * set changed for the split, and the two cards cannot disagree about the same
 * broker because they are reading the identical payload.
 */
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

/**
 * c-bov-preferred-broker-card — "Preferred Broker", the first of three stacked
 * broker cards on the Disposition record page.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS BUNDLE EXISTS AT ALL (2026-08-25)
 * ══════════════════════════════════════════════════════════════════════════════
 * `c/bovBrokerPanel` — the matrix, the three buttons and the preferred-broker
 * panel — renders ONLY at BOV Outreach. The moment a deal moves on, the
 * appointed broker disappears from the record page entirely (confirmed live on
 * DISP-0023, sitting at Release Materials with JLL preferred and none of it
 * visible). The user's design answers that with THREE SEPARATE STACKED CARDS:
 *
 *   1. Preferred Broker        -> THIS BUNDLE
 *   2. Broker Replace History  -> `c/bovBrokerChangeHistory`, ALREADY PLACED
 *                                 standalone on the FlexiPage. Nothing to build.
 *   3. BOV (n)                 -> `c/bovResponsesCard`, built alongside this one
 *
 * ⚠ EARLIER TODAY THESE WERE NESTED AS SECTIONS INSIDE
 * `c/dispositionBuyerTimeline`. The user clarified the design: they are separate
 * cards. That nesting has been reverted in full — the timeline is a single feed
 * again, with its entry count back in its own card title. Do not re-nest them.
 *
 * ── THE THREE STATES, AND WHY ONLY TWO OF THEM ARE VISIBLE ──────────────────
 *   PREFERRED BROKER EXISTS -> the card, with the green panel.
 *   NO PREFERRED BROKER     -> NOTHING. Not an empty card, not a "none yet" line.
 *   THE READ FAILED         -> also NOTHING. See `wiredSubmissions`.
 *
 * ── DATA ACCESS ─────────────────────────────────────────────────────────────
 * ARCHITECTURE.md §5 puts LDS first and Apex last. Apex is correct here: the
 * value shown is derived from a CHILD-OBJECT collection (`BOV_Submission__c`
 * rows filtered on `Is_Preferred_Broker__c`), the query already exists behind a
 * cacheable controller, and `getRelatedListRecords` would need the related list
 * to be on the page layout — which, for BOV Submissions on `Disposition__c`, it
 * is not.
 */
export default class BovPreferredBrokerCard extends LightningElement {
    /** The `Disposition__c` Id. Supplied by the record page. */
    @api recordId;

    /**
     * Every BOV submission on this sale.
     *
     * ⚠ THERE IS NO `_loaded` AND NO `_failed` FIELD, AND BOTH WERE CONSIDERED
     * AND REJECTED RATHER THAN FORGOTTEN. This card renders nothing in the
     * pre-wire state, nothing on an empty sale and nothing on a failed read —
     * three states, ONE rendering — so a flag distinguishing them could not
     * change any answer this component gives. Dead defensive code encodes a
     * premise that a future reader will trust. `c/bovResponsesCard` DOES carry a
     * `_failed` flag, because it genuinely renders a different thing on a failed
     * read; the difference is deliberate, not an inconsistency.
     */
    _rows = [];

    /**
     * ⚠ THE FAILED READ IS SILENT HERE, AND THAT IS A DECISION ABOUT THE PAGE,
     * NOT A SHORTCUT. `c/bovResponsesCard` — same wire, same config, same LDS
     * cache entry, a few inches below on the same page — renders an honest
     * `role="status"` line when this read fails. Two cards announcing one failed
     * read is noise, and a hero panel's honest form of "we could not read the
     * brokers" is not to claim a broker. Same call, same reasoning, as
     * `c/bovBrokerPanel`, which also stays silent and leaves the message to the
     * card beside it.
     *
     * 🔴 CLEARING `_rows` IS LOAD-BEARING, NOT TIDYING. Without it a failed
     * REFRESH leaves the previous green panel on screen, still naming a broker,
     * with nothing anywhere on the page saying the data is stale. The test that
     * pins this has to emit data, assert the panel rendered, and THEN error — an
     * error-only test passes on a mutant that deletes the clear, because the
     * array was already empty when the error arrived.
     */
    @wire(getSubmissions, { dispositionId: '$recordId' })
    wiredSubmissions({ data, error }) {
        if (data) {
            this._rows = data;
        } else if (error) {
            this._rows = [];
        }
    }

    /**
     * The submission flagged preferred, or `undefined`.
     *
     * ⚠ `=== true`, NOT TRUTHINESS. `isPreferred` is a `Boolean` on
     * `BovController.BovRow`, so an Apex null arrives as JS `null` rather than
     * `false`. Under `=== true` a null can never be read as "flagged", which is
     * the safe side for a flag whose entire meaning is that somebody set it.
     * Copied verbatim from `c/bovBrokerPanel` — the same rows, the same rule.
     */
    get _preferredRow() {
        return this._rows.find((r) => r.isPreferred === true);
    }

    /** The card's own visibility gate. See the template header. */
    get hasPreferredBroker() {
        return this._preferredRow !== undefined;
    }

    /**
     * The firm name handed down to `c/bovPreferredBroker`.
     *
     * 🔴 RETURNS `''`, NEVER `undefined` — see the template. The user-facing
     * placeholder is the CHILD's, deliberately: owning it there is what makes
     * that bundle safe to mount from anywhere instead of making every caller
     * remember the wording.
     */
    get preferredBrokerFirm() {
        const row = this._preferredRow;
        return (row && row.brokerFirm) || '';
    }
}
