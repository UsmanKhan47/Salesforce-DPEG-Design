/**
 * c-broker-listing — the listing card on the Active Listing stage of the Disposition record page.
 *
 * The traction badge and every offer-derived number come from ONE server computation
 * (`DispositionTractionService`, via `BrokerListingController.getListing`), shared with
 * `c-listing-alerts` on the same screen so the badge and the panel cannot contradict each other.
 *
 * ── ⚠ RESIDUAL: TWO VALUES ON THIS CARD CAN LAG A JUST-LOGGED OFFER (review W1, 2026-08-10) ──
 * `getListing` is `@AuraEnabled(cacheable=true)` and this component holds no wire result and calls
 * no `refreshApex`, so after a user logs an offer from `c-disposition-offer` in the SIDEBAR, that
 * card's LDS related-list wire refreshes while BOTH the traction badge (`tractionLabel`) and the
 * "Offers Received" stat here may keep showing the payload already held. ⚠ Two places on this card,
 * against one on `c-listing-alerts` — a reader who fixes only the panel has fixed half of it. A page
 * reload always shows the truth; the window itself was not measured, so none is claimed.
 *
 * 🔴 A CustomEvent relay through `c-disposition-main` is NOT buildable, and that is measured rather
 * than assumed: per `flexipages/Disposition_Record_Page.flexipage-meta.xml`, `dispositionMain` is in
 * the `main` region while `dispositionSidebar` — the only renderer of `c-disposition-offer` — is in
 * the `sidebar` region, so the two share no ancestor for an event to travel through. Crossing
 * regions needs Lightning Message Service and this repo has no `messageChannels/` directory. If you
 * build it, use `refreshApex` on a retained wire result, NOT `getRecordNotifyChange` — the band is
 * an Apex computation, not a field on the Disposition record. Full reasoning and the
 * accepted-residual decision live in `DispositionTractionService`'s §3 header block.
 *
 * @see force-app/main/default/classes/BrokerListingController.cls
 * @see force-app/main/default/classes/DispositionTractionService.cls (the band ladder)
 */
import { LightningElement, api, wire } from 'lwc';
import getListing from '@salesforce/apex/BrokerListingController.getListing';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class BrokerListing extends LightningElement {
    @api recordId;
    listing;
    error;

    @wire(getListing, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.listing = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.listing = undefined;
        }
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || 'Unknown error';
    }
    get showEmpty() { return !this.listing && !this.error; }

    get listDateLabel() { return this._fmtDate(this.listing?.listDate); }
    get cfoDateLabel()  { return this._fmtDate(this.listing?.callForOffersDate); }

    get stats() {
        const l = this.listing || {};
        // ⚠ daysOnMarket is now null (not 0) when the marketing clock has not started — the
        // controller computes it from Disposition__c.Listing_Date__c rather than reading the
        // hand-keyed Broker_Listing__c.Days_On_Market__c, so "no listing date" and "listed today"
        // are finally distinguishable. Render the honest dash instead of collapsing back to 0.
        const domValue = l.daysOnMarket == null ? '—' : `${l.daysOnMarket} days`;
        return [
            { key: 'dom',    label: 'Days On Market',       value: domValue,                      iconName: 'utility:clock', iconColor: l.isAtRisk ? '#b45309' : '#5a6b7b' },
            { key: 'list',   label: 'List Date',            value: this.listDateLabel,            iconName: 'utility:event', iconColor: '#1565c0' },
            { key: 'cfo',    label: 'Call For Offers Date', value: this.cfoDateLabel,             iconName: 'utility:event', iconColor: '#1565c0' },
            { key: 'offers', label: 'Offers Received',      value: String(l.offersReceived ?? 0), iconName: 'utility:reply', iconColor: l.offersReceived === 0 ? '#b91c1c' : '#2e7d32' }
        ];
    }

    /**
     * ⚠ RENAMED FROM hasWeekLabel (Tranche 5B). The payload field is `tractionLabel`, not
     * `weekLabel`: the 6-week clock it was named after no longer exists, and a getter asserting
     * "week" over a string reading "Day 34 — Traction checkpoint" is the same stale-signal defect
     * the retired listingAlerts mock was. The badge itself renders `listing.tractionLabel`.
     */
    get hasTractionLabel() { return !!this.listing?.tractionLabel; }

    _fmtDate(d) {
        if (!d) return '—';
        const parts = String(d).split('-');
        return MONTHS[parseInt(parts[1], 10) - 1] + ' ' + parseInt(parts[2], 10) + ', ' + parts[0];
    }
}