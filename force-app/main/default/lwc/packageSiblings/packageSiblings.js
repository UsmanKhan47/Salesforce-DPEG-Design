/**
 * c-package-siblings — "what else arrived on the broker email this record came from?"
 *
 * Placed on the Lead record page AND the Opportunity record page. One inbound broker email that
 * named several properties produces several Leads (and, after conversion, several Opportunities),
 * all grouped by one Property_Package__c. This card is how a human working one of them sees the
 * others.
 *
 * ═══ 🔴 ONE BUNDLE SERVES BOTH RECORD PAGES. DO NOT SPLIT IT. ═══
 * There must never be a `leadPackageSiblings` and an `opportunityPackageSiblings`.
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
 * ⚠ THE OBVIOUS ALTERNATIVE IS THE TRAP. `@wire getRecord` with
 * `@salesforce/schema/Lead.Property_Package__c` needs a SECOND import plus a branch for Opportunity
 * — object-agnosticism gone. A dynamic `` `${objectApiName}.Property_Package__c` `` avoids that but
 * still needs a SECOND round trip for the siblings, plus an intermediate "package known, siblings
 * not yet loaded" state. One Apex call taking only the Id has neither problem.
 *
 * ⚠ `objectApiName` IS DECLARED BUT DELIBERATELY UNUSED FOR DATA ACCESS. The platform injects it on
 * a record page, and declaring it documents that the component knows which object it is on and
 * CHOOSES not to branch on it. Using it to pick a schema import or an Apex method would reintroduce
 * exactly what the server dispatch removes.
 *
 * ═══ INVISIBLE WHEN THERE IS NO PACKAGE ═══
 * Most Leads and most deals came from a single-property email, so `packageId` is null and this
 * component renders NOTHING AT ALL — not an empty card, not a "no related records" message. An
 * always-present empty card on every record page in the org is worse than no feature. A non-null
 * packageId with zero siblings still renders: it is TRUE that the record came off a multi-property
 * email, and the package link is how a human reaches the routing audit explaining where the other
 * properties went (design residual R6).
 *
 * ⚠ THERE IS NO SPINNER AND NO `isLoaded` GATE, AND THAT IS A DECISION — NOT AN OVERSIGHT. The card
 * is simply absent until the wire emits. A spinner is the right pattern for a component that WILL
 * show something, but this one shows nothing on the overwhelming majority of records (most emails
 * name one property, so most Leads and most deals have no package at all) — so a spinner would
 * flash and vanish on almost every record page in the org, advertising a card that is not coming.
 * The wire's own latency is the only thing it would cover, and `cacheable=true` makes a repeat view
 * instant anyway. Do not add one without a reason that outweighs that.
 *
 * ═══ ⚠ CARD TITLE: "Property Package" — SETTLED 2026-08-17. THIRD NAME, READ THE CHAIN ═══
 * The displayed title and the App Builder `masterLabel` in `packageSiblings.js-meta.xml` have
 * carried three names, all on 2026-08-17:
 *
 *   1. `Same Email`       — the original. Retired.
 *   2. `Portfolio Deal`   — RETRACTED THE SAME DAY IT SHIPPED. 🔴 DO NOT RESTORE IT ON A LOCAL
 *                           EDIT: it collided with an existing `Opportunity` STAGE of exactly that
 *                           name, belonging to an unrelated, MANUAL, dormant feature that answered a
 *                           DIFFERENT QUESTION — "which seller's deal bundle is this part of?" —
 *                           where this card answers "what else arrived on the broker email this
 *                           record came from?". A card title that read as a deal STAGE, on a record
 *                           page for the very object that had that stage, was a permanent misread.
 *                           ⚠ THE COLLIDING FEATURE IS NOW GONE: the stage value, its
 *                           `Acquisitions_Deal_Path` step, `OpportunityFunnelController`'s stage
 *                           list and the FLS grants were retired in phases A1/A2 of the Portfolio
 *                           Deal rename, and its Opportunity fields in phase A3. This entry
 *                           therefore survives as HISTORY — it explains how the settled name (3) was
 *                           reached, NOT that (2) is forbidden forever. What outlasts the collision
 *                           is the split between the two QUESTIONS: this card shows a
 *                           PIPELINE-DERIVED grouping (one email -> many records), and a revived
 *                           seller-bundle requirement would need its own new field and its own card
 *                           rather than this one re-pointed. Moving the vocabulary again belongs to
 *                           the rename program, not to a passing edit.
 *   3. `Property Package` — the CURRENT, settled name. It is the underlying object's own label
 *                           (`Property_Package__c` = "Property Package" / "Property Packages"), so
 *                           it collides with nothing in this org, and it needs no parenthetical
 *                           gloss: the retired `masterLabel` was "Portfolio Deal (Property
 *                           Package)" precisely because the name did not say what the card showed.
 *                           This one does.
 *
 * The chain is recorded rather than silently swapped because BOTH retired names are still quoted in
 * prose OUTSIDE this bundle — `DPEG_Acquisition_Edit` and `DPEG_Admin_Access` each describe their
 * FLS grants as backing *the `c/packageSiblings` "Same Email" card* — so a reader who greps either
 * old name must be able to land here and see that the card was RENAMED, not deleted.
 *
 * ⚠ DISPLAY-ONLY, and deliberately so. Unchanged, and to stay unchanged: the bundle folder and
 * component API name (`c/packageSiblings`), the Apex method
 * (`PropertyPackageController.getSiblingRecords`), and both record pages' `<componentName>` /
 * `<identifier>` (`packageSiblings`, in `Lead_Record_Page` and `Opportunity_Record_Page`). The
 * flexipages bind by component NAME and never by `masterLabel`, which is the only reason the label
 * could move on its own without touching either page.
 *
 * ⚠ SUPERSEDED 2026-08-17 by the rename above, on the same day it was written. RETRACTED, verbatim:
 * *"Do not 'fix' the near-collision with `c/recentPackages`, whose card on the `Lead_Funnel` app
 * page is titled 'Portfolio Deal**s**' (plural). Shared vocabulary is the point … they are two
 * separate bundles whose titles now differ only by a plural."* That held only while THIS card was
 * titled "Portfolio Deal". It is now "Property Package" while `c/recentPackages` is still "Portfolio
 * Deals", so the two cards no longer share vocabulary at all and there is no plural near-collision
 * left to preserve.
 *
 * ⚠ AND THE OPEN ITEM THAT REPLACED IT IS NOW CLOSED — 2026-08-17, later the same day. It read:
 * *"the stage-value collision that retracted this card's name applies to `c/recentPackages`'s title
 * too — 'Portfolio Deals' is one letter from the `Portfolio Deal` Opportunity stage … the two cards
 * are knowingly inconsistent for now … If they are ever harmonised, `c/recentPackages` is the one that
 * moves, to 'Property Packages'."* That is exactly what happened: `c/recentPackages` moved to
 * "Property Packages" (its FOURTH name), so the inconsistency is gone and nothing here is pending.
 *
 * 🔴 THE TWO CARDS NOW SHARE THE OBJECT'S VOCABULARY ON PURPOSE, AND THE SINGULAR/PLURAL SPLIT IS THE
 * HARMONIZATION RATHER THAN A NEW COLLISION: "Property Package" (singular) HERE, because this card
 * shows the ONE package the record in front of you belongs to; "Property Packages" (plural) THERE,
 * because that card LISTS packages. Both are `Property_Package__c`'s own label. A plural difference
 * between two card titles is fine — it was a plural difference from a live PICKLIST VALUE that was the
 * defect, and neither title has one now.
 *
 * ⚠ Do NOT "deduplicate" the two titles into one wording, and do NOT rename either back. They remain
 * two separate features — that card lists the packages, this one shows the package-mates of the record
 * in front of you — so read the bundle name before editing either title.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSiblingRecords from '@salesforce/apex/PropertyPackageController.getSiblingRecords';

const GENERIC_ERROR = 'Unable to load the related properties.';

export default class PackageSiblings extends NavigationMixin(LightningElement) {
    /** Injected by the record page. The ONLY thing sent to the server. */
    @api recordId;

    /**
     * Injected by the record page. Held for context only — see the class header: this component
     * deliberately never branches on it.
     */
    @api objectApiName;

    packageId;
    packageName;
    packageUrl;
    siblings = [];
    error;

    @wire(getSiblingRecords, { recordId: '$recordId' })
    wiredSiblings({ data, error }) {
        if (data) {
            this.packageId = data.packageId;
            this.packageName = data.packageName;
            this.packageUrl = data.packageUrl;
            // The server always sends a list, but defaulting here keeps the template's `for:each`
            // safe if that contract is ever loosened.
            this.siblings = data.siblings || [];
            this.error = undefined;
        } else if (error) {
            // ⚠ The error branch is handled EXPLICITLY rather than ignored. An unhandled wire error
            // would leave the card silently blank, which on this component is indistinguishable
            // from the (very common) "this record has no package" state — so a real failure would
            // never be noticed by anyone.
            this.error = error;
            this.packageId = undefined;
            this.packageName = undefined;
            this.packageUrl = undefined;
            this.siblings = [];
        }
    }

    /**
     * Render nothing unless there is something true to say. Deliberately NOT
     * `siblings.length > 0`: a one-member package is still a fact about this record (see the class
     * header), and its link leads to the audit that explains the rest.
     */
    get hasPackage() {
        return !!this.packageId;
    }

    get hasError() {
        return !!this.error;
    }

    /** Show the card at all only for a real package or a real failure — never for "nothing here". */
    get isVisible() {
        return this.hasPackage || this.hasError;
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

    /** Navigate to the package record itself. */
    handlePackageClick(event) {
        event.preventDefault();
        if (!this.packageId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.packageId, actionName: 'view' }
        });
    }
}
