/**
 * c-portfolio-deal-siblings — "what else arrived on the broker email this record came from?"
 *
 * Placed on the Lead record page AND the Opportunity record page. One inbound broker email that
 * named several properties produces several Leads (and, after conversion, several Opportunities),
 * all grouped by one `Portfolio_Deal__c`. This card is how a human working one of them sees the
 * others.
 *
 * ═══ 🔴 ONE BUNDLE SERVES BOTH RECORD PAGES. DO NOT SPLIT IT. ═══
 * There must never be a `leadPortfolioDealSiblings` and an `opportunityPortfolioDealSiblings`.
 * ARCHITECTURE.md §5 records what happened the last time that was attempted: a
 * `c/transactionAdvanceStage` bundle was created so a module would "own its own component", was
 * byte-identical to `c/advanceRecordStage` below the comments, and was DELETED THE SAME DAY (code
 * review W3, user decision) — *"a copy carrying only a different header is not a split; it is a
 * second file that must now receive every fix this one gets, with nothing but review to notice when
 * it does not."* The same section records the payoff: `Transaction__c` was added as a SEVENTH object
 * to that feature with ZERO changes to any client file.
 *
 * "Its own bundle" is legitimate only for a bundle that genuinely DIFFERS — different wording,
 * different behaviour. A different header comment is not a difference.
 *
 * ═══ 🔴 IT IMPORTS NO OBJECT SCHEMA, AND THAT IS WHAT MAKES THE ABOVE POSSIBLE ═══
 * There is no `@salesforce/schema/Lead.*` and no `@salesforce/schema/Opportunity.*` here, and there
 * must never be. The component sends `recordId` and the SERVER dispatches on
 * `recordId.getSObjectType()` — the same shape as
 * `RecordStageAdvanceController.hasStageActionAccess(recordId)`. Every object-specific value the
 * card displays (each row's URL and its object LABEL) is supplied by Apex for exactly this reason.
 *
 * ⚠ THAT IS ALSO WHY THE `Property_Package__c` -> `Portfolio_Deal__c` RENAME COST THIS FILE NOTHING
 * BUT WORDS. The object's API name appears in no import, no page reference and no composed URL here;
 * only the Apex import path and the display strings moved. A version of this component that read the
 * lookup client-side would have needed a schema import edited in two places and a fixture rebuilt.
 *
 * ⚠ THE OBVIOUS ALTERNATIVE IS THE TRAP. `@wire getRecord` with
 * `@salesforce/schema/Lead.Portfolio_Deal__c` needs a SECOND import plus a branch for Opportunity —
 * object-agnosticism gone. A dynamic `` `${objectApiName}.Portfolio_Deal__c` `` avoids that but
 * still needs a SECOND round trip for the siblings, plus an intermediate "deal known, siblings not
 * yet loaded" state. One Apex call taking only the Id has neither problem.
 *
 * ⚠ `objectApiName` IS DECLARED BUT DELIBERATELY UNUSED FOR DATA ACCESS. The platform injects it on
 * a record page, and declaring it documents that the component knows which object it is on and
 * CHOOSES not to branch on it. Using it to pick a schema import or an Apex method would reintroduce
 * exactly what the server dispatch removes.
 *
 * ═══ INVISIBLE WHEN THERE IS NO PORTFOLIO DEAL ═══
 * Most Leads and most deals came from a single-property email, so `dealId` is null and this
 * component renders NOTHING AT ALL — not an empty card, not a "no related records" message. An
 * always-present empty card on every record page in the org is worse than no feature. A non-null
 * dealId with zero siblings still renders: it is TRUE that the record came off a multi-property
 * email, and the deal link is how a human reaches the routing audit explaining where the other
 * properties went (design residual R6).
 *
 * ⚠ THERE IS NO SPINNER AND NO `isLoaded` GATE, AND THAT IS A DECISION — NOT AN OVERSIGHT. The card
 * is simply absent until the wire emits. A spinner is the right pattern for a component that WILL
 * show something, but this one shows nothing on the overwhelming majority of records (most emails
 * name one property, so most Leads and most deals have no portfolio deal at all) — so a spinner
 * would flash and vanish on almost every record page in the org, advertising a card that is not
 * coming. The wire's own latency is the only thing it would cover, and `cacheable=true` makes a
 * repeat view instant anyway. Do not add one without a reason that outweighs that.
 *
 * ═══ ⚠ CARD TITLE: "Portfolio Deal" — AND THE SCHEMA NOW AGREES WITH IT ═══
 * The displayed title and the App Builder `masterLabel` in `portfolioDealSiblings.js-meta.xml` have
 * carried four names:
 *
 *   1. `Same Email`       — the original. Retired.
 *   2. `Portfolio Deal`   — 2026-08-17, retracted the same day it shipped: it collided with an
 *                           existing `Opportunity` STAGE of exactly that name, belonging to an
 *                           unrelated, MANUAL, dormant feature that answered a DIFFERENT QUESTION —
 *                           "which seller's deal bundle is this part of?" — where this card answers
 *                           "what else arrived on the broker email this record came from?". A card
 *                           title that read as a deal STAGE, on a record page for the very object
 *                           that had that stage, was a permanent misread.
 *   3. `Property Package` — 2026-08-17, the settled display label WHILE the object was still called
 *                           `Property_Package__c`. Superseded by (4).
 *   4. `Portfolio Deal`   — CURRENT. The underlying object's own label (`Portfolio_Deal__c`).
 *
 * 🔴 (2)'s RETRACTION IS SPENT, AND SO IS THE "DISPLAY-ONLY, DO NOT MOVE THE API NAMES" RULE THAT
 * SAT HERE. Both were conditional, and both conditions have now been discharged rather than ignored:
 *   • The colliding `Portfolio Deal` Opportunity stage value, its `Acquisitions_Deal_Path` step,
 *     `OpportunityFunnelController`'s stage list and the FLS grants were retired in phases A1/A2 of
 *     the Portfolio Deal rename, and its three Opportunity fields in phase A3. Nothing is left to
 *     collide with, which is exactly why (4) may be the same words as (2).
 *   • The old header pinned as "unchanged, and to stay unchanged" the bundle name
 *     (`c/packageSiblings`), the Apex method (`PropertyPackageController.getSiblingRecords`) and both
 *     record pages' `<componentName>` / `<identifier>`, adding that *"moving the vocabulary again
 *     belongs to the rename program, not to a passing edit"*. THIS IS THAT PROGRAM — phase B4 of
 *     `agent-output/design-requirements-portfolio-deal-rename.md` (§5, and §6 which supersedes those
 *     statements by name). All four moved together, in one deploy: the bundle is now
 *     `c/portfolioDealSiblings`, the Apex is `PortfolioDealController.getSiblingRecords`, and
 *     `Lead_Record_Page` and `Opportunity_Record_Page` were re-pointed in the same wave. An LWC
 *     bundle rename is a delete-and-create: a flexipage still naming `packageSiblings` renders
 *     nothing, silently.
 *
 * ⚠ WHAT SURVIVES BOTH DISCHARGES is the only part still load-bearing: this card shows a
 * PIPELINE-DERIVED grouping (one inbound email -> many records). A revived seller-bundle requirement
 * ("which seller's bundle is this part of?") is manual data about a different thing and would need
 * its OWN new field and its own card — never this one re-pointed and never this object re-purposed,
 * however closely the words now read.
 *
 * ⚠ THE OLD NAMES ARE STILL QUOTED OUTSIDE THIS BUNDLE, WHICH IS WHY THE CHAIN IS RECORDED RATHER
 * THAN SWAPPED SILENTLY — `DPEG_Acquisition_Edit` and `DPEG_Admin_Access` each still describe their
 * FLS grants as backing *the `c/packageSiblings` "Same Email" card*, and this repo's docs quote
 * "Property Package" throughout. A reader who greps any old name must be able to land here and see
 * that the card was RENAMED, not deleted.
 *
 * ═══ 🔴 THE SINGULAR/PLURAL SPLIT WITH `c/recentPortfolioDeals` IS DELIBERATE, NOT A COLLISION ═══
 * "Portfolio Deal" (singular) HERE, because this card shows the ONE deal the record in front of you
 * belongs to; "Portfolio Deals" (plural) THERE, because that card LISTS deals. Both are
 * `Portfolio_Deal__c`'s own label. A plural difference between two card titles is fine — it was a
 * plural difference from a live PICKLIST VALUE that was the 2026-08-17 defect, and that value no
 * longer exists.
 *
 * ⚠ Do NOT "deduplicate" the two titles into one wording, and do NOT rename either back. They remain
 * two separate features — that card lists the deals, this one shows the deal-mates of the record in
 * front of you — so read the bundle name before editing either title.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSiblingRecords from '@salesforce/apex/PortfolioDealController.getSiblingRecords';

const GENERIC_ERROR = 'Unable to load the related properties.';

export default class PortfolioDealSiblings extends NavigationMixin(LightningElement) {
    /** Injected by the record page. The ONLY thing sent to the server. */
    @api recordId;

    /**
     * Injected by the record page. Held for context only — see the class header: this component
     * deliberately never branches on it.
     */
    @api objectApiName;

    dealId;
    dealName;
    dealUrl;
    siblings = [];
    error;

    /**
     * ⚠ THE THREE `data.portfolioDeal*` MEMBERS ARE THE SERVER'S NAMES, NOT THIS COMPONENT'S —
     * `PortfolioDealController.PortfolioDealSiblings` declares `portfolioDealId` /
     * `portfolioDealName` / `portfolioDealUrl` (they were `packageId` / `packageName` / `packageUrl`
     * before phase B4 of the Portfolio Deal rename). This mapping is the ONLY place the two
     * vocabularies meet, deliberately: a mistyped member here does not throw, it silently yields
     * `undefined`, which this component renders as its perfectly normal "no portfolio deal" state —
     * an invisible card on every record page and nothing red anywhere, including in Jest, whose
     * fixtures define the payload locally. Verify a rename of either side against the OTHER side's
     * source, never against a green suite.
     */
    @wire(getSiblingRecords, { recordId: '$recordId' })
    wiredSiblings({ data, error }) {
        if (data) {
            this.dealId = data.portfolioDealId;
            this.dealName = data.portfolioDealName;
            this.dealUrl = data.portfolioDealUrl;
            // The server always sends a list, but defaulting here keeps the template's `for:each`
            // safe if that contract is ever loosened.
            this.siblings = data.siblings || [];
            this.error = undefined;
        } else if (error) {
            // ⚠ The error branch is handled EXPLICITLY rather than ignored. An unhandled wire error
            // would leave the card silently blank, which on this component is indistinguishable
            // from the (very common) "this record has no portfolio deal" state — so a real failure
            // would never be noticed by anyone.
            this.error = error;
            this.dealId = undefined;
            this.dealName = undefined;
            this.dealUrl = undefined;
            this.siblings = [];
        }
    }

    /**
     * Render nothing unless there is something true to say. Deliberately NOT
     * `siblings.length > 0`: a one-member deal is still a fact about this record (see the class
     * header), and its link leads to the audit that explains the rest.
     */
    get hasDeal() {
        return !!this.dealId;
    }

    get hasError() {
        return !!this.error;
    }

    /** Show the card at all only for a real deal or a real failure — never for "nothing here". */
    get isVisible() {
        return this.hasDeal || this.hasError;
    }

    get hasSiblings() {
        return this.siblings.length > 0;
    }

    get count() {
        return this.siblings.length;
    }

    /** The repo-standard shape: the server's user-safe message, with a fixed fallback. */
    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || GENERIC_ERROR;
    }

    /**
     * Navigate to one sibling record.
     *
     * ⚠ The Id comes from the clicked element's `data-id`, never from an object-typed page
     * reference this component composed: `standard__recordPage` resolves an Id on its own, which is
     * precisely why no `objectApiName` is passed here.
     */
    handleSiblingClick(event) {
        event.preventDefault();
        const recordId = event.currentTarget.dataset.id;
        if (!recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
        });
    }

    /** Navigate to the portfolio deal record itself. */
    handleDealClick(event) {
        event.preventDefault();
        if (!this.dealId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.dealId, actionName: 'view' }
        });
    }
}
