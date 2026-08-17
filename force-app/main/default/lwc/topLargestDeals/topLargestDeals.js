import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTopDeals from '@salesforce/apex/TopDealsController.getTopDeals';

/**
 * topLargestDeals — the "Top 5 Largest Deals" home-page card (FSD §24.2: *the five biggest
 * active deals, any stage except Closed*).
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 RE-RANKED ONTO `Asking_Price__c` AND CUT TO TWO COLUMNS (user decision, 2026-08-17)
 * ═════════════════════════════════════════════════════════════════════════════
 * This card ranks on **`Asking_Price__c`** and shows exactly two columns — Property Name and
 * Asking Price. It is a DELIBERATE change of the question the card answers, taken by the user
 * with the alternatives on the table: it is now "the five highest ASKING PRICES among active
 * deals", not "the five biggest deal Amounts". Different deals appear.
 *
 * ⚠ SUPERSEDED, 2026-08-16, kept verbatim so nobody restores it from the retired argument:
 *
 *     "c/recentOpportunities   ranks by `Asking_Price__c`  — what the SELLER wants.
 *      c/topLargestDeals (this) ranks by `Amount`          — what the DEAL is worth to DPEG.
 *      ⇒ Do NOT re-point this component's wire ... Either change makes this a second copy of
 *      a card the page already carries."
 *
 * 🔴 THAT SEPARATION ARGUMENT IS NOW MOSTLY SPENT, AND SAYING SO IS THE HONEST POSITION.
 * Both cards now rank on the same field. What still distinguishes them is narrower than it
 * was and is worth knowing before anyone merges them:
 *
 *   c/recentOpportunities  every stage, incl. Closed Won / Dead/Pass; Asking Price + NOI.
 *   c/topLargestDeals      ACTIVE deals only (`OpportunitySelector.CLOSED_STAGES` excluded,
 *                          which is the FSD §24.2 requirement); Property Name + Asking Price.
 *
 * ⇒ Adding the stage filter to `selectTopByAskingPrice` — the tranche-2 proposal the user
 *   OVERRULED on 2026-08-16 — would collapse the last real difference. `recentOpportunities`,
 *   `OpportunityFunnelController.getRecentOpportunities` and
 *   `OpportunitySelector.selectTopByAskingPrice` remain UNTOUCHED.
 *   `TopDealsControllerTest.excludesClosedAndDeadDeals` is the server-side falsifier.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * "PROPERTY NAME" IS `Opportunity.Name`, RELABELLED — NOT `Property__r.Name`
 * ═════════════════════════════════════════════════════════════════════════════
 * User decision, 2026-08-17, and it is the same reasoning `OpportunitySelector`'s
 * call-for-offers block comment already records for that surface: `LeadConvertService` names
 * the deal after the property (marketing name, else the address), so `Name` already IS the
 * property name on every lead-converted deal. Traversing `Property__r.Name` instead would
 * add a cross-object CRUD/FLS dependency under `WITH USER_MODE` — which throws for the WHOLE
 * ROW rather than blanking one column — and would render an empty cell on any deal with a
 * null `Property__c` (a manually built deal has none). Zero traversal, zero new FLS surface,
 * zero blank rows.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * ERROR HANDLING — an inline banner, not a toast
 * ═════════════════════════════════════════════════════════════════════════════
 * `TopDealsController` throws `AuraHandledException` with a fixed, user-safe message
 * (ARCHITECTURE.md §5), so `error.body.message` is the actionable text and the Apex-path
 * reader is the correct one here. It is rendered INLINE with `role="alert"` rather than as
 * a toast: this card is passive page furniture the user did not click, so a toast would
 * appear unprompted and then vanish, leaving a permanently empty card with no explanation.
 *
 * 🔴 THE MOST LIKELY REAL-WORLD ERROR IS AN FLS GAP ON `Opportunity.Asking_Price__c`. The
 * selector is `WITH USER_MODE` on purpose (this backs a read a human asked for), and
 * USER_MODE throws on the WHOLE ROW for ONE inaccessible field — so the whole card fails
 * rather than showing a blank column. That is the intended, LOUD posture; the fix is a
 * permission-set grant. ⚠ The read's FLS surface SHRANK with this change: it no longer
 * selects `Amount`, `Deal_Type__c` or `Asset_Type__c`, so three of the four ways it could
 * throw are gone.
 *
 * ⚠ THE ERROR BRANCH KEEPS THE COUNT AT ZERO AND HIDES THE TABLE. An error state that still
 * rendered the last-known rows would assert a ranking the server just refused to confirm.
 *
 * ⚠ THE STAGE / DEAL-TYPE PILL MAPS ARE GONE, NOT MISPLACED. This card had `STAGE` /
 * `DEAL_TYPE` colour maps and `pillWrap` / `pillDot` builders serving its Stage and Deal Type
 * columns; with those columns removed they had no reader, so they were deleted rather than
 * left as unreferenced constants. `c/recentOpportunities` keeps its own copies for its own
 * pills, and `c/listDatatable`'s `pill` cell type is unchanged and still used there.
 */

const COLUMNS = [
    // ⚠ STILL A `url` COLUMN. Only the LABEL and the removal of its five siblings changed —
    // losing the link to the record would be a regression, so the type and typeAttributes are
    // exactly what they were under the old "Deal Name" heading.
    {
        label: 'Deal Name',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    { label: 'Asking Price', fieldName: 'askingPriceLabel', type: 'text', initialWidth: 140 }
];

/**
 * $1.2M / $850K / $0 — compact currency, matching the sibling deal cards on this page.
 *
 * ⚠ A null renders as an em dash, NOT as `$0`. A price-less deal is one nobody has quoted
 * yet; `$0` would assert the seller wants nothing for it, which is a different and wrong
 * claim. The server sorts nulls last for the same reason.
 *
 * ⚠ It is the SAME helper the removed `Amount` column used, deliberately unchanged: the ask
 * and the deal value are both money and must not render in two different formats on one page.
 */
const money = (n) => {
    if (n === null || n === undefined) {
        return '—';
    }
    if (Math.abs(n) >= 1000000) {
        return '$' + (n / 1000000).toFixed(1) + 'M';
    }
    if (Math.abs(n) >= 1000) {
        return '$' + Math.round(n / 1000) + 'K';
    }
    return '$' + n;
};

export default class TopLargestDeals extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getTopDeals)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (
            (e && e.body && e.body.message) ||
            'Unable to load the largest deals.'
        );
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Opportunity', actionName: 'list' },
            state: { filterName: 'All_Deals' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    /**
     * ⚠ NO CLIENT-SIDE `slice` AND NO CLIENT-SIDE SORT. The server already applies
     * `ORDER BY Asking_Price__c DESC NULLS LAST` and `LIMIT 5`, so re-imposing either here
     * would put a second, drifting copy of the ranking rule in JS — and a client sort would
     * silently reorder rows the server deliberately ordered by a tiebreak (`CreatedDate
     * DESC`) this component cannot see.
     */
    get rows() {
        if (!this.data) {
            return [];
        }
        return this.data.map((r) => ({
            id: r.id,
            recordUrl: `/lightning/r/Opportunity/${r.id}/view`,
            name: r.name,
            askingPriceLabel: money(r.askingPrice)
        }));
    }

    get count() {
        return this.rows.length;
    }
}
