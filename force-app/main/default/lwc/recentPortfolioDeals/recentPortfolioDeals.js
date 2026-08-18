/**
 * c-recent-portfolio-deals — "which multi-property broker emails arrived most recently?"
 *
 * A Lead Funnel homepage widget listing the newest `Portfolio_Deal__c` records: one row per inbound
 * broker email that named two or more properties, with the property count, the broker and when it
 * arrived.
 *
 * ⚠ HISTORY — this sentence used to end *"with how many live Leads and Opportunities came off it"*.
 * The 'Linked Records' column that showed those counts was removed at the user's request on
 * 2026-08-17; the SERVER still sends them (see the COLUMNS note below for why they were not retired
 * with it), so that was a change to what the card PAINTS, not to the DTO.
 *
 * ═══ 🔴 WHY THIS BUNDLE EXISTS — AND WHY IT IS THE ONLY SURFACE FOR THIS FACT ═══
 * `recentLeads` once carried a 'Deal'/'Package' column answering the same question. It was REMOVED on
 * 2026-08-17 once this card shipped, because the two were redundant and this one is strictly better —
 * so this bundle is not the second of two views, it is the only one.
 *
 * That column was structurally unable to guarantee a deal is VISIBLE. `recentLeads` reads
 * `LeadFunnelController.getFunnel()`, which priority-partitions `LeadSelector.selectRecent(50)` into
 * high/standard and concatenates them, and the client then shows the first 5 rows. A deal's member
 * Leads have no priority of their own, so three unrelated `Broker_Priority__c = 'High'` Leads can
 * permanently occupy 3 of the 5 visible rows and a deal's own Leads fall silently past the cutoff —
 * observed with a direct server call, not a permission, FLS or deploy defect.
 *
 * This widget reads `Portfolio_Deal__c` DIRECTLY through its own Apex method, with its own sort and
 * its own cutoff, so it inherits none of that partitioning. **Do not "simplify" it back into a
 * `recentLeads` column** — the whole point is that it is NOT downstream of the Lead feed, and that
 * column has already been tried and retired. Restoring it would also mean re-adding `dealId` /
 * `dealName` to `LeadFunnelController.LeadRow` and `Portfolio_Deal__c` + the spanning
 * `Portfolio_Deal__r.Name` to `LeadSelector.selectRecent`, whose `WITH USER_MODE` SELECT is the whole
 * Lead Funnel homepage's single point of FLS failure.
 *
 * ⚠ The per-record question "what deal is THIS Lead part of?" is still answered, by
 * `c/portfolioDealSiblings` on the Lead record page — which is a record-page card, not a homepage
 * feed, and is untouched by the column's removal. This card answers "what deals arrived?". Both are
 * wanted; the retired column was a third, weaker answer to the first one.
 *
 * ═══ ⚠ USER-FACING LABEL: "Portfolio Deals" — AND THE SCHEMA NOW AGREES WITH IT ═══
 * Renamed five times. The chain is kept because the earlier names are still quoted in this repo's
 * docs, in the design requirements and in the deploy-verification notes — a reader who finds one of
 * those and assumes it is current will "fix" the card back:
 *
 *   1. `Recent Packages`   — the original build. Named after `Property_Package__c`.
 *   2. `Recent Portfolios` — 2026-08-17, superseded later the same day.
 *   3. `Portfolio Deals`   — 2026-08-17, retracted the same day: it collided with a live
 *                            `Opportunity` STAGE of exactly that name (singular), belonging to an
 *                            unrelated, MANUAL, dormant feature that answered a DIFFERENT QUESTION —
 *                            "which seller's deal bundle is this part of?" — where this card answers
 *                            "which inbound broker emails arrived?". A card titled as a deal STAGE,
 *                            listing rows that are not deals, was a permanent misread.
 *   4. `Property Packages` — 2026-08-17, the settled display label WHILE the object was still called
 *                            `Property_Package__c`. Superseded by (5).
 *   5. `Portfolio Deals`   — CURRENT. The plural of the underlying object's own label
 *                            (`Portfolio_Deal__c` = "Portfolio Deal" / "Portfolio Deals").
 *
 * 🔴 (3)'s RETRACTION IS SPENT, AND SO IS THE "DO NOT FINISH THE RENAME" BAN THAT SAT HERE.
 * Both were conditional on facts that no longer hold, and both are now DISCHARGED rather than
 * violated:
 *   • The colliding `Portfolio Deal` Opportunity stage value, its `Acquisitions_Deal_Path` step,
 *     `OpportunityFunnelController`'s stage list, `recentOpportunities`' colour map, the FLS grants
 *     and finally the three Opportunity fields themselves were all retired in phases A1-A3 of the
 *     Portfolio Deal rename. There is nothing left to collide with, which is precisely why (5) is
 *     allowed to be the same words as (3).
 *   • The old header's rule — *"every API name behind the card keeps 'Package' … do not 'finish' the
 *     rename into the schema … re-pointing those API names is the rename program's job, not a
 *     passing edit's"* — named the exact condition under which it lifts. THIS IS THAT PROGRAM
 *     (Phase B4, `agent-output/design-requirements-portfolio-deal-rename.md` §5 and §6, which
 *     supersedes those statements explicitly). The bundle, the Apex, the object and the labels all
 *     moved together in one authorised phase, which is what that rule was protecting.
 *
 * ⚠ WHAT SURVIVES BOTH DISCHARGES, and is the only part still load-bearing: the two QUESTIONS are
 * separate facts. This card is fed by the PIPELINE-DERIVED grouping "which inbound email routed this
 * record". A revived seller-bundle requirement ("which seller's bundle is this part of?") is manual
 * data about a different thing, and would need its OWN new field and its own surface — never this one
 * re-pointed, and never this object re-purposed, however close the words now read.
 *
 * ⚠ THE RENAME COVERS EVERY STRING A USER CAN READ, NOT JUST THE TITLE — `GENERIC_ERROR` below and
 * the spinner's `alternative-text` moved WITH it, and so did the SERVER's own message
 * (`PortfolioDealController.RECENT_READ_FAILURE_MESSAGE`). That last one is the reason to check both
 * sides together: this component prefers `error.body.message` and only falls back to `GENERIC_ERROR`,
 * so re-wording one side alone leaves the card saying "portfolio deals" on a client-side failure and
 * something else on a server-side one — two different words for one thing, decided by which layer
 * broke. The Jest suite and `PortfolioDealControllerTest` each pin their own side's exact wording.
 *
 * ⚠ THE FIRST COLUMN'S HEADER IS 'Deal Name', AND IT IS NOT A FREE CHOICE. It is the object's own
 * Name-field label (`Portfolio_Deal__c.object-meta.xml` → `<nameField><label>Deal Name</label>`), so
 * the column, the card title and the record page all read as one vocabulary. It has tracked that
 * label through every rename ('Package Name' → 'Portfolio Name' → 'Package Name' → 'Deal Name') and
 * must keep tracking it; a column header that disagrees with the record page is the defect this
 * pattern exists to prevent. `fieldName: 'recordUrl'`, `type: 'url'` and the DTO member `name` are
 * API-side and were never touched by any of it.
 *
 * ═══ 🔴 THERE IS NO CLIENT-SIDE `.slice()` HERE, AND ADDING ONE WOULD REINSTATE THE BUG ═══
 * `recentLeads` and `recentOpportunities` both `.slice(0, 5)` because their Apex returns a wider set
 * (50 Leads, the whole pipeline) that several components share. This component's Apex method returns
 * EXACTLY what should display — `PortfolioDealController.RECENT_LIMIT` is applied as a SOQL `LIMIT` —
 * so the server cutoff is the only cutoff. A second truncation layer on top of a server cutoff is
 * precisely the shape that hid deals in the Lead feed; do not copy that half of the peer components'
 * pattern along with the rest.
 *
 * ═══ ⚠ ROW ORDER IS FIXED SERVER-SIDE, ON `CreatedDate`, AND MUST NOT BE RE-DERIVED HERE ═══
 * The selector orders on `CreatedDate DESC`, not on the `Received` value this table DISPLAYS, because
 * `receivedDateTime` is parsed out of the email headers and is null whenever that parse fails (see
 * `PortfolioDealSelector.selectRecent`). The `receivedLabel` fallback below — a relative age off
 * `createdDate` — is therefore DISPLAY-ONLY: it exists so a null cell still says something useful,
 * and it must never become a sort key. Rows are rendered in arrival order.
 */
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import TIME_ZONE from '@salesforce/i18n/timeZone';
import getRecentPortfolioDeals from '@salesforce/apex/PortfolioDealController.getRecentPortfolioDeals';

const GENERIC_ERROR = 'Unable to load portfolio deals.';
const EMPTY = '—';

/**
 * The `Received` cell's date format — the SALESFORCE USER's locale and time zone, not the browser's.
 *
 * ⚠ `timeZone` is explicit on purpose. A `Datetime` arrives from Apex as an absolute instant, so
 * formatting it without a zone renders it in whatever zone the machine happens to be in — which for a
 * homepage widget means two users in one company disagreeing about when an email arrived, and for
 * Jest means an assertion that passes or fails depending on the runner's TZ.
 *
 * ⚠ This is the datatable equivalent of the `lightning-formatted-date-time` that
 * `c/competingBrokerSubmissions` uses for its own "Submitted" value. That component can use the base
 * component because it renders its own markup; a datatable CELL cannot host one without a custom
 * column type, and this column deliberately does not introduce one (same structural reason the deal
 * link below is a `type: 'url'` column). Hence a derived string.
 */
const RECEIVED_FORMAT = new Intl.DateTimeFormat(LOCALE, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: TIME_ZONE
});

const COLUMNS = [
    // The deal link. A `type: 'url'` column, matching `recentLeads`' own 'Deal Name' precedent — NOT
    // a per-cell NavigationMixin call.
    //
    // 🔴 THAT IS NOT A STYLE CHOICE: a datatable cell CANNOT invoke NavigationMixin without a custom
    // column type (the cell is rendered by lightning/datatable, not by this component), so "navigate
    // on click" would mean building a custom type for a link the platform already renders.
    // NavigationMixin IS mixed in below — it is used for the "View All" footer — so nothing is lost.
    //
    // ⚠ `recordUrl` is built by APEX, not here. Composing it client-side would hardcode
    // 'Portfolio_Deal__c' in a second place, and the server already owns that string.
    //
    // ⚠ THE LABEL IS THE OBJECT'S OWN Name-FIELD LABEL ('Deal Name'), so a user reading the column
    // and the record page sees one word. Only `label` has ever moved: `fieldName`, `type` and the DTO
    // member `name` are API-side.
    {
        label: 'Deal Name',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    // ⚠ NO `initialWidth` ON ANY COLUMN, deliberately: the template sets
    // `column-widths-mode="auto"` (as recentLeads does), and a fixed width mixed into auto mode wins
    // for that one column, producing a table that is neither fully auto-sized nor consistently
    // hand-sized. recentOpportunities sets initialWidths precisely because it does NOT use auto mode.
    { label: 'Properties', fieldName: 'properties', type: 'text' },
    { label: 'Broker', fieldName: 'broker', type: 'text' },
    // ⚠ HISTORY — THE 'Linked Records' COLUMN WAS REMOVED 2026-08-17 (user request), AND THE
    // `linkedRecordsLabel` / `plural` HELPERS WENT WITH IT. It rendered `2 Leads · 1 Opportunity`
    // from the DTO's `leadCount` / `opportunityCount`, omitting a zero segment so a fully-converted
    // deal read as a success rather than a loss, and falling back to an em dash for a memberless one
    // (design residual R6).
    //
    // 🔴 THE SERVER STILL SENDS BOTH COUNTS, DELIBERATELY — see `get rows()` below. That is a
    // DIVERGENCE from the same day's `recentLeads` column removal, which DID strip its DTO members,
    // and the difference is FLS surface, which is the only currency that doctrine trades in: there,
    // the deal Id/Name cost a lookup field + a spanning `.Name` in a `WITH USER_MODE` SELECT, and a
    // persona missing either grant lost the WHOLE Lead Funnel homepage. Here the counts cost two
    // child subqueries selecting `Id` ONLY — and `Id` cannot be FLS-restricted — so retiring them
    // would buy nothing on that axis while deleting the `WHERE IsConverted = false` guard those
    // subqueries carry (code review C3) and the real-`Database.convertLead` falsifier that protects
    // it. Do not "finish" this removal in Apex without re-reading `PortfolioDealSelector.selectRecent`'s
    // own header first.
    { label: 'Received', fieldName: 'receivedLabel', type: 'text' }
];

export default class RecentPortfolioDeals extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    data;
    error;
    listUrl = '#';

    @wire(getRecentPortfolioDeals)
    wired({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            // The error branch is handled EXPLICITLY. An ignored wire error would leave the card
            // showing the empty state, which reads as "no multi-property emails have arrived" — a
            // plausible, wrong, and completely silent answer.
            this.error = error;
            this.data = undefined;
        }
    }

    get hasError() {
        return !!this.error;
    }

    get errorMessage() {
        const e = this.error;
        return (e && e.body && e.body.message) || GENERIC_ERROR;
    }

    /**
     * True only while the wire has produced NEITHER data NOR an error. The `c/callForOffersList`
     * getter, verbatim.
     */
    get isLoading() {
        return !this.data && !this.error;
    }

    /**
     * Whether to show the empty message instead of the table. Mutually exclusive with the table in
     * the template — the sibling `c/callForOffersList` pattern on this same page — so a brand-new org
     * (which genuinely has no deals) shows a sentence rather than an empty header row.
     *
     * 🔴 THE `!!this.data` HALF IS NOT DEFENSIVE — WITHOUT IT THIS GETTER ANSWERS THE WRONG QUESTION.
     * `rows` returns `[]` whenever `data` is undefined, which is true both when the server genuinely
     * returned zero deals AND for the whole window before the wire has delivered anything. A bare
     * `this.rows.length === 0` therefore made "no multi-property broker emails have arrived yet" —
     * a factual claim about the org's inbox — flash on EVERY page load before correcting itself.
     * `data` being set is the only evidence the server has actually answered; test
     * `zeroRowsFromTheServerShowsTheEmptyMessage` and `loadingShowsTheSpinnerAndMakesNoEmptinessClaim`
     * discriminate the two states in opposite directions and would both have to be broken to
     * reintroduce it.
     *
     * ⚠ `this.rows.length`, not `this.data.length`: here they are interchangeable (this component's
     * Apex returns the row list DIRECTLY, so `data` IS the array and `rows` is a 1:1 `map` of it), but
     * `rows` is the collection the template actually renders, so it stays the one the emptiness check
     * is derived from.
     */
    get isEmpty() {
        return !!this.data && this.rows.length === 0;
    }

    /**
     * Whether to render the table. The POSITIVE complement of `isEmpty` — deliberately not
     * `if:false={isEmpty}` in the template.
     *
     * 🔴 THIS GETTER EXISTS SO THE TEMPLATE CANNOT MASK AN `isEmpty` DEFECT, AND THAT IS A MEASURED
     * CONCERN RATHER THAN A STYLISTIC ONE. The first attempt at this fix wrapped both branches in
     * `if:false={isLoading}`, which made the three states exclusive in the MARKUP — and the whole suite
     * then passed with the old, broken `isEmpty` restored, because the wrapper hid the empty message
     * during loading no matter what the getter said. A template that compensates for a getter makes
     * that getter untestable. With the load state expressed only once — here and in `isEmpty`, both
     * keyed on `data` having arrived — reverting either one reds a test.
     *
     * ⚠ `isEmpty` and `hasRows` are NOT negations of each other and must not be collapsed into one
     * `if:true`/`if:false` pair: all three of loading, empty and populated need to be distinguishable,
     * and two states cannot cover three. While the wire is in flight BOTH are false, which is exactly
     * how the spinner ends up being the only thing on the card.
     */
    get hasRows() {
        return this.rows.length > 0;
    }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => {
            this.listUrl = url;
        });
    }

    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Portfolio_Deal__c', actionName: 'list' },
            state: { filterName: '__Recent' }
        };
    }

    viewAll(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }

    get rows() {
        if (!this.data) {
            return [];
        }
        // ⚠ NO `.slice()`. See the class header — the Apex LIMIT is the only cutoff.
        //
        // ⚠ `r.leadCount` / `r.opportunityCount` ARRIVE AND ARE DELIBERATELY NOT READ (2026-08-17).
        // The 'Linked Records' column they fed was removed at the user's request; the members stay on
        // `PortfolioDealController.RecentPortfolioDealRow` for the reason recorded on that column
        // above (their marginal `WITH USER_MODE` FLS surface is nil — the subqueries select `Id` only
        // — while deleting them would take the C3 `IsConverted = false` guard with them). A future
        // consumer reads them from here; nothing needs re-querying.
        return this.data.map((r) => ({
            id: r.id,
            recordUrl: r.recordUrl,
            name: r.name,
            properties: r.propertyCount == null ? EMPTY : String(r.propertyCount),
            broker: brokerLabel(r.brokerName, r.brokerEmail),
            receivedLabel: receivedLabel(r.receivedDateTime, r.createdDate)
        }));
    }

    get count() {
        return this.rows.length;
    }
}

/**
 * One cell carrying the broker's name with their address as supporting text, e.g.
 * `Dana Reyes · dana@brokerage.com`.
 *
 * ⚠ ONE COLUMN, NOT TWO, and not a custom two-line cell type. `recentLeads` renders its broker as a
 * single text column, and `c/listDatatable` exposes exactly two custom types (`pill`, `progress`);
 * adding a third to the SHARED subclass so one widget can stack two lines in a cell would change a
 * component every list card in the repo depends on. A composed string is the honest option at this
 * size.
 *
 * ⚠ The address is dropped when it merely repeats the name (some senders' display name IS their
 * address), so the cell never reads `dana@x.com · dana@x.com`.
 */
function brokerLabel(name, email) {
    const hasName = !!name;
    const hasEmail = !!email;
    if (hasName && hasEmail && name.toLowerCase() !== email.toLowerCase()) {
        return `${name} · ${email}`;
    }
    // Either one alone, whichever exists — a deal always came from someone, but the LLM extraction
    // that supplies these can miss a name, an address, or both.
    return name || email || EMPTY;
}

/*
 * ⚠ HISTORY — `linkedRecordsLabel(leadCount, opportunityCount)` AND ITS `plural` HELPER LIVED HERE
 * AND WERE REMOVED WITH THE 'Linked Records' COLUMN (2026-08-17). Two facts they carried are worth
 * keeping on the record, because both are properties of the DATA rather than of the column:
 *
 *   • A ZERO SEGMENT WAS OMITTED, NOT PRINTED — a fully-worked deal read `3 Opportunities`, never
 *     `0 Leads · 3 Opportunities`, because every member converting is the SUCCESS case. Both zero
 *     yielded the em dash (design residual R6: a multi-property email whose properties all failed to
 *     route after the deal row was created). Anything that re-displays these counts must decide
 *     that again — a naive `${leadCount} Leads · ${opportunityCount} Opportunities` reads a success
 *     as a loss.
 *   • `leadCount` COUNTS OPEN LEADS ONLY — `PortfolioDealSelector.selectRecent` filters
 *     `IsConverted = false`, because conversion copies the deal onto the Opportunity and never
 *     clears it off the Lead, so an unfiltered count double-counts every worked asset. Read that
 *     method's header before "fixing" a total that looks low.
 */

/**
 * The `Received` cell: the parsed email send time when there is one, otherwise a relative age off the
 * deal's own `CreatedDate`.
 *
 * 🔴 DISPLAY ONLY — THIS MUST NEVER INFLUENCE ROW ORDER. `receivedDateTime` is null whenever
 * `parseSentDatetime` could not read the sender's headers, which is exactly why the SERVER sorts on
 * `CreatedDate` (see the class header and `PortfolioDealSelector.selectRecent`). The fallback exists
 * so such a row still says something true — "this arrived 2 days ago" — rather than rendering a blank
 * cell that looks like missing data.
 */
function receivedLabel(receivedDateTime, createdDate) {
    if (receivedDateTime) {
        const received = new Date(receivedDateTime);
        if (!isNaN(received.getTime())) {
            return RECEIVED_FORMAT.format(received);
        }
    }
    if (!createdDate) {
        return EMPTY;
    }
    const created = new Date(createdDate);
    if (isNaN(created.getTime())) {
        return EMPTY;
    }
    const days = Math.floor((Date.now() - created.getTime()) / 86400000);
    return days <= 0 ? 'Today' : `${days}d ago`;
}
