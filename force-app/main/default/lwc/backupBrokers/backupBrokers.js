import { LightningElement, api, wire } from 'lwc';
import { formatMillions } from 'c/utils';
import getSubmissions from '@salesforce/apex/BovController.getSubmissions';

/**
 * c-backup-brokers — the BOV Outreach brokers who were NOT appointed.
 *
 * Mounted by c/dispositionMain at the Active Listing stage.
 */
export default class BackupBrokers extends LightningElement {
    @api recordId;
    _data;
    loadError;

    @wire(getSubmissions, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this._data = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = 'Couldn\'t load backup brokers.';
            this._data = [];
        }
    }

    /**
     * The ONE broker actually working the listing, or null when it cannot be
     * determined. Everything else is a backup.
     *
     * ── 🔴 WHY THIS IS NOT `filter(r => !r.isSelected)` ──────────────────────
     * Under the dual-slot model TWO rows can carry Submission_Status__c =
     * 'Selected' at once: the system-scored winner AND the manually appointed
     * preferred broker (BOV_Submission__c.Is_Preferred_Broker__c). The old
     * predicate excluded BOTH, so on a disposition with exactly two BOVs — both
     * Selected, e.g. DISP-0023 — this card rendered "No backup brokers." while
     * a perfectly good runner-up sat in the data.
     *
     * The preferred flag WINS over the system flag, because a preferred broker
     * is a human overriding the score: once one exists, the system-selected row
     * is a runner-up and belongs in this list like any other.
     *
     * Returns null rather than guessing when neither flag is set. `rows` then
     * lists EVERYTHING — a card showing one row too many is a display quirk, a
     * card that hides the whole list because the winner is ambiguous is the
     * defect being fixed here.
     *
     * @returns {object|null} the effective broker's submission row, or null
     */
    get effectiveBroker() {
        const data = this._data;
        if (!Array.isArray(data) || data.length === 0) {
            return null;
        }
        return (
            data.find((r) => r.isPreferred === true) ||
            data.find((r) => r.isSelected === true) ||
            null
        );
    }

    get rows() {
        const data = this._data;
        if (!Array.isArray(data) || data.length === 0) {
            return [];
        }
        const effective = this.effectiveBroker;

        // Reference identity, not `r.id !== effective.id`: `effective` is an
        // element OF this same array, so identity is exact and cannot be
        // defeated by a null/duplicate id.
        return data
            .filter((r) => r !== effective)
            .map((r) => {
                // BROKER CONTACT FIRST, FIRM SECONDARY (standing instruction).
                // Both fields are legitimately nullable on BOV_Submission__c,
                // so the firm is PROMOTED to the primary line when there is no
                // contact name — rather than rendering an em dash as the whole
                // identity while the firm sits muted underneath it. The
                // secondary line is emitted only when it would say something
                // the primary line does not, which is what keeps a null from
                // rendering as "null" or as a dangling separator.
                const contact = (r.contactName || '').trim();
                const firm = (r.brokerFirm || '').trim();
                return {
                    id: r.id,
                    primaryName: contact || firm || 'Unnamed broker',
                    firmLabel: contact && firm ? firm : '',
                    bovScore: r.bovScore != null ? r.bovScore : '—',
                    bovAmountLabel: formatMillions(r.bovAmount)
                };
            });
    }

    get isEmpty() {
        return !this.loadError && this.rows.length === 0;
    }
}
