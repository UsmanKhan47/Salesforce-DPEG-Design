/**
 * DEAL SUMMARY (disposition) — the NDA, LOI and PSA state of one sale, on one card, on every
 * stage. Tranche 2 Workstream C (design D5), 2026-08-20. Server half:
 * `DispositionDealSummaryController` -> `DispositionDealSummaryService` -> four selectors.
 *
 * ═══ 🔴 DATA ACCESS: IMPERATIVE APEX, WHICH DIVERGES FROM ARCHITECTURE.md §5 ═══
 * §5 ranks LDS first and Apex last, and that ranking is right for almost every card in this repo.
 * It is wrong here, and the argument is specific rather than a preference:
 *
 *   1. THE CARD NEEDS THE LATEST CHILD OF THREE DIFFERENT OBJECTS — `NDA__c`, `LOI__c` and
 *      `Contract_Review__c` — hanging off ONE `Disposition__c`, plus two counters on the parent.
 *      `getRelatedListRecords` would mean three separate wires, each sorted and truncated on the
 *      client, plus a fourth `getRecord`.
 *   2. 🔴 NONE OF THEM CAN EXPRESS THE TIE-BREAK THE READ ACTUALLY REQUIRES. "Latest" here is
 *      `ORDER BY CreatedDate DESC, Id DESC LIMIT 1`. `CreatedDate` is SECOND-granular, so two NDAs
 *      created under one Disposition inside the same second — routine in a test transaction,
 *      reachable in a bulk load or a double-click — leave a single-key sort free to return either
 *      row, and the card then shows a different NDA on every refresh.
 *      `NdaSelector.selectLatestByDispositionId` documents that tie-break as REQUIRED; a
 *      client-side sort over a page of related-list records cannot reproduce it reliably, and
 *      would be re-deriving in JavaScript exactly what SOQL already does correctly.
 *   3. ARCHITECTURE.md §5 item 3 permits imperative Apex "when LDS cannot express the query". This
 *      is that case. The controller stays thin and every query stays in a selector, so the
 *      layering rule is honoured in full.
 *
 * ⚠ THE KNOWN ALTERNATIVE, RECORDED SO IT IS NOT RE-PROPOSED AS A DISCOVERY: `NDA_Count__c` and
 * `Signed_NDA_Count__c` live on the PARENT, so a `getRecord` wire could supply the NDA *counters*
 * with no Apex. Design D5 raises that and rejects it for this build — the LOI and PSA halves need
 * Apex regardless, and splitting the card across two data sources would give it two refresh clocks
 * and two failure shapes for no reduction in server code.
 *
 * ═══ 🔴 TWO LOI FIELDS ARE EXCLUDED ON PURPOSE — DO NOT "FIX" THE OMISSION ═══
 * Both look like obvious additions to anyone reading the LOI object rather than the sell-side
 * automation, which is why the exclusions are stated here, in the DTO, and in the selector:
 *
 *   - **`LOI__c.LOI_Status__c` is EXCLUDED.** No automation ever sets it (the
 *     `LOI_Signed_Status_Sync` flow's own header says so), so on a disposition LOI it holds its
 *     `Draft` default forever. Showing it would routinely print "Draft" beside a real `Stage__c`
 *     — a card contradicting itself. Design §0 C-10. ⚠ Unchanged by the 2026-08-21 stage change.
 *   - **`LOI__c.LOI_Signed_Date__c` is EXCLUDED — BUT NOT FOR THE REASON THIS BULLET USED TO
 *     GIVE.** Retracted, verbatim: "`LOI_Signed_Status_Sync` keys on `Stage__c = 'Signed'`, the
 *     ACQUISITION terminal; the disposition terminal is `Executed`, so that flow is
 *     acquisition-only BY CONSTRUCTION and the field is STRUCTURALLY always blank on a sale. It
 *     would render a permanent em-dash that reads as missing data."
 *     On 2026-08-21 the user made `Signed` the DISPOSITION terminal too. `LOI_Signed_Status_Sync`
 *     is a before-save flow on `LOI__c` with no record-type and no lookup criterion, so it now
 *     fires on sell-side LOIs reaching Signed and stamps a REAL date. The exclusion survives as a
 *     product decision (§0 C-11 stands), not as a structural fact. If it is ever revisited, weigh
 *     a populated date — not an em-dash.
 *
 * The LOI row therefore shows `Stage__c`, `Offer_Price__c` and `Ball_In_Court__c`. ⚠ On a sale
 * `Ball_In_Court__c = 'Seller'` means DPEG and 'Buyer' means the counterparty — the value is
 * rendered raw because this card only ever appears on a Disposition page.
 *
 * ═══ 🔴 THE COUNTERS ARE NULL, NOT ZERO, ON PRE-EXISTING ROWS ═══
 * `NDA_Count__c` / `Signed_NDA_Count__c` are maintained by the `NDA_Signed_Rollup` after-save flow
 * (not a roll-up summary — every child->Disposition relationship is a Lookup, so none is possible)
 * and hold null on any Disposition that predates it. Every reader in this repo coalesces with
 * `BLANKVALUE(...,0)`; this component does the same with `?? 0`, and it is the ONLY place the
 * coalescing happens — Apex passes the raw nulls through so the wire cannot hide a real null.
 *
 * ═══ 🔴 RESTYLED 2026-08-21 TO MATCH `c/dealDocStatus`, WITH ONE STATE IT DOES NOT HAVE ═══
 * The user's requirement was that this card "give the same feel" as the Opportunity page's
 * `c/dealDocStatus`: a `lightning-card` with a `standard:document` icon, a tinted round icon chip
 * per document type, the row name as a click-through link, and a soft-tinted status pill.
 * All of that is now here. THREE THINGS WERE DELIBERATELY NOT COPIED:
 *
 *   1. 🔴 `dealDocStatus` HAS TWO ROW STATES; THIS CARD HAS THREE. It renders "has record" and
 *      "no record", and nothing else. This card must additionally render "exists, but the read
 *      was refused" — see the block below, and design §0 C-1 for the live provisioning gap that
 *      hid behind exactly that collapse for months. So the borrowed visual language gained a
 *      state rather than losing one: the `Unavailable` pill is the ONLY pill on this card that
 *      stays SOLID-FILLED rather than soft-tinted, its icon chip is error-toned, and its hint is
 *      non-italic and semibold. Three visual axes, so it cannot read as "just another status".
 *   2. 🔴 NO INLINE `style` AND NO AUTHORED HEX. `dealDocStatus` sets its icon colours with an
 *      inline `style="--slds-c-icon-color-foreground-default:#2E86DE"` on every `lightning-icon`,
 *      and hard-codes every pill colour. ARCHITECTURE.md §5 requires SLDS 2 design tokens, and
 *      this bundle lints at ZERO violations. The chip colour is set on the WRAPPING SPAN from the
 *      stylesheet instead — custom properties inherit across the shadow boundary into
 *      `lightning-icon`'s own root, which is what makes that work.
 *   3. 🔴 NO `<a onclick>` WITHOUT AN `href`. `dealDocStatus` uses `<a class="doc-name"
 *      onclick={openNda}>` with no `href`, which is not keyboard-focusable and is not announced
 *      as a link. The in-repo accessible precedent is `c/bovComparisonMatrix`'s "View All" footer
 *      (`NavigationMixin.GenerateUrl` populating a real `href`, plus `preventDefault()` in the
 *      click handler so in-app navigation stays a SPA transition). That shape is used here.
 *
 * ⚠ URL GENERATION IS ASYNCHRONOUS, WHICH IS WHY `hasLink` EXISTS SEPARATELY FROM `exists`.
 * `GenerateUrl` returns a Promise, and unlike `bovComparisonMatrix` — whose one link target is a
 * static list page resolvable in `connectedCallback` — this card's targets are record Ids that
 * only arrive with the wire. Until the promise settles (and if it rejects) the row renders as a
 * muted, unlinked label: never a bare `<a>` with no destination, and never the literal string
 * "undefined" in an `href`.
 *
 * ⚠ THE CARD IS IN THE ~340px SIDEBAR of `Disposition_Record_Page`, not the wide main column
 * `dealDocStatus` occupies. `.row-head` wraps and the pill drops to its own line rather than
 * overflowing — see the stylesheet. Do not re-tighten that.
 *
 * ═══ 🔴 THE PROPERTY ASSET: A ROW-SHAPED CONTEXT LINE, AT CLOSING ONLY (2026-08-24) ═══
 * The card links the sale's Property Asset by name, so IR can open the full asset record. It
 * renders ABOVE the three document rows, because it is the SUBJECT of the deal rather than another
 * piece of its paperwork. Absent (a null lookup, which `deleteConstraint = SetNull` makes
 * reachable) renders NOTHING AT ALL rather than a placeholder.
 *
 * 🔴 IT WEARS THE DOCUMENT ROWS' TREATMENT (second pass, same day). It first shipped as a bare
 * `Property  <name>` line above the rows and read as bolted on, so it now reuses `.row-head` /
 * `.row-left` / `.row-icon` / `.row-label` / `.pill` verbatim: icon chip, bold label, right-aligned
 * pill. THE SLOT ASSIGNMENT IS THE ONLY JUDGEMENT CALL IN IT — label "Property", pill = the asset
 * NAME:
 *   - The left column then reads NDA / LOI / PSA / Property — one vocabulary, "what this row is
 *     about" — and the right column reads "the current value of that thing", which for a property
 *     is WHICH property. Inverting the two (name on the left, "Property" in the pill) breaks the
 *     left-column scan and puts a type tag among status words.
 *   - The pill tone is `neutral`, the only tone on this card that asserts nothing. Every other
 *     tone is a status the asset does not have.
 *   - THE MUTED META SLOT IS LEGITIMATELY EMPTY. The payload carries an Id and a name and nothing
 *     else, and the idiom already renders rows with zero meta lines (an empty NDA row has none; the
 *     LOI row drops its price line when null). Inventing a sentence to fill it would be inventing
 *     data.
 *   - It is NOT one of the `<ul>`'s items and its outer hook is `.asset-row`, not `.row` — the
 *     list's accessible name is "Deal documents", and `.row` is what the suite counts to prove
 *     there are exactly three of them. The stylesheet shares one declaration block between the two
 *     selectors so they cannot drift.
 *
 * 🔴 IT RENDERS ONLY AT `Disposition_Stage__c = 'Closing'` (user requirement, 2026-08-24). The
 * stage comes from a SECOND wire — `getRecord` on the one field — and NOT from the Apex payload:
 * widening `DispositionDealSummaryService` for a rendering decision would put a picklist value the
 * client tests into the server's DTO and its test fixtures, and LDS already holds this record's
 * stage in cache for the record page it is sitting on. See `wiredStage` for why an unknown stage
 * and a wrong one are the same answer.
 *
 * ⚠ NO SECOND SERVER READ WAS ADDED. `propertyAssetId` / `propertyAssetName` come from the query
 * that was ALREADY reading the parent Disposition for the NDA counters
 * (`DispositionSelector.selectDealSummaryParentById`, renamed from `selectNdaCountsById`). The
 * consequence is recorded at `DispositionDealSummaryService.applyParentFields`: one query means
 * one catch, so a `Property_Asset__c` CRUD gap degrades the NDA COUNTER line too.
 *
 * ═══ FAIL-SOFT IS PER ROW, AND A DEGRADED ROW SAYS SO ═══
 * The service catches per read and flags the row (`ndaUnavailable`, `loiUnavailable`,
 * `psaUnavailable`, `ndaCountsUnavailable`) instead of failing the card, because this card is
 * placed UNGATED and renders on all 11 disposition stages — a whole-card error banner would be a
 * permanent fixture. The whole-card error branch below is therefore reached only when the
 * controller itself throws.
 * ⚠ A degraded row is rendered DIFFERENTLY from an empty one. `c/bovOutreach` deliberately
 * collapses the two, and design §0 C-1 found that exact collapse had been hiding a live
 * provisioning gap on the BOV NDA pill — "No NDA" forever, for every disposition-only persona,
 * with nothing on screen to suggest a permissions problem. This card keeps them distinct.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Disposition__c.Disposition_Stage__c';
import { formatLongDate, formatMoney } from 'c/utils';
import getDealSummary from '@salesforce/apex/DispositionDealSummaryController.getDealSummary';

/**
 * The stage at which the Property row renders — named ONCE.
 *
 * ⚠ EXACT MATCH ON THE PICKLIST'S OWN API VALUE. It is a value of
 * `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` (position 10 of 11) and
 * exists on BOTH record types — On_Market step 10, Off_Market step 8 — so no record-type wire is
 * needed to decide whether the gate can ever open.
 *
 * 🔴 A SECOND LITERAL WOULD FAIL SILENTLY IN BOTH DIRECTIONS, which is why this is a constant and
 * not an inline string: a typo'd value renders the row NEVER (indistinguishable from a sale with
 * no asset, which renders nothing by design) and a widened one renders it ALWAYS (indistinguishable
 * from the pre-2026-08-24 behaviour). Neither throws, and neither looks wrong on screen.
 */
const STAGE_CLOSING = 'Closing';

// Row status -> pill tone. Anything unmapped falls back to 'neutral' so a picklist value added
// later renders its own text on a defined style rather than an unstyled pill.
const NDA_TONE = {
    Pending: 'neutral',
    'Not Sent': 'neutral',
    Sent: 'progress',
    Received: 'progress',
    Signed: 'complete',
    Declined: 'blocked'
};

// LOI__c.Stage__c carries BOTH vocabularies (the picklist is shared with the acquisition record
// type). The disposition sequence is Received -> Under Review -> Negotiation -> Signed; the
// acquisition values are mapped too so a mis-typed record still renders sensibly rather than
// falling to neutral.
// ⚠ COMMENT REPOINTED 2026-08-21 — THE MAP BELOW IS UNCHANGED AND NEEDED NO EDIT. It already
// mapped 'Negotiation' ('progress') and 'Signed' ('complete') as acquisition values, so the new
// sell-side sequence renders correctly with no code change. The sequence read
// "Received -> Under Review -> Countered by DPEG -> Counter Received from Buyer -> Executed" until
// the user retired the sell-side counter loop.
// 🔴 'Countered by DPEG', 'Counter Received from Buyer' and 'Executed' ARE DELIBERATELY RETAINED
// as keys. They are on no record type any more, but they stay ACTIVE on the master value set
// (design gate G3), so a data load or a direct Apex write can still land one here — and an
// unmapped value falls to 'neutral', which reads as "no status" rather than as "unexpected value".
// Do not prune them as dead code.
const LOI_TONE = {
    Received: 'progress',
    'Under Review': 'progress',
    'Countered by DPEG': 'attention',
    'Counter Received from Buyer': 'attention',
    Executed: 'complete',
    Draft: 'neutral',
    'Prepare/Review': 'progress',
    Sent: 'progress',
    Counter: 'attention',
    Submitted: 'progress',
    Negotiation: 'progress',
    Signed: 'complete',
    Completed: 'complete'
};

// Contract_Review__c.Negotiation_Status__c — the SOURCE field, not the derived Stage__c
// projection, which collapses several negotiation states into three.
// The two record types' sequences (2026-08-21):
//   Acquisition_PSA   Draft -> Negotiation -> Signed -> Executed
//   Disposition_PSA   Initial Draft -> Negotiation -> Signed
// ⚠ COMMENT ONLY — THE MAP BELOW IS UNCHANGED AND NEEDED NO EDIT. It already mapped 'Negotiation'
// and 'Signed', so the harmonised sell-side sequence renders correctly with no code change.
// 🔴 'Revised', 'Ready for Execution' and 'Executed' ARE DELIBERATELY RETAINED as keys, exactly as
// in LOI_TONE above. 'Executed' is still live on ACQUISITION PSAs. The other two are on no record
// type but remain ACTIVE on the master value set, so a data load can still land one here — and an
// unmapped value falls to 'neutral', which reads as "no status" rather than "unexpected value".
// 🔴 'Signed' MEANS DIFFERENT THINGS BY SIDE and this card cannot tell them apart: it is the
// DISPOSITION terminal ('complete' is right) and a MID-SEQUENCE acquisition state ('complete' would
// be premature). That is acceptable only because this component renders on a Disposition record
// page and never on an Opportunity — do not reuse PSA_TONE behind an acquisition surface.
const PSA_TONE = {
    'Initial Draft': 'neutral',
    Draft: 'neutral',
    Revised: 'progress',
    Negotiation: 'progress',
    'Ready for Execution': 'attention',
    Signed: 'complete',
    Executed: 'complete'
};

const UNAVAILABLE_LABEL = 'Unavailable';
const UNAVAILABLE_HINT = 'Not readable with your current permissions — contact your administrator.';

/**
 * The per-document-type icon chip class. The type colour is kept on an EMPTY row as well as a
 * populated one — the chip identifies which document the row is about, which is true whether or
 * not the document exists. Only a DEGRADED row overrides it (`row-icon_blocked`), which is one of
 * the three axes that keep the third state from reading as a fourth status value.
 */
const ICON_CLASS = {
    nda: 'row-icon row-icon_nda',
    loi: 'row-icon row-icon_loi',
    psa: 'row-icon row-icon_psa'
};

/**
 * @param {string} recordId A record Id to open.
 * @returns {object} The `standard__recordPage` page reference for it.
 */
function recordPageRef(recordId) {
    return {
        type: 'standard__recordPage',
        attributes: { recordId, actionName: 'view' }
    };
}

export default class DispositionDealSummary extends NavigationMixin(LightningElement) {
    @api recordId;

    summary;
    loadError;

    /**
     * `Disposition__c.Disposition_Stage__c`, or `undefined` while it is unknown.
     * ⚠ UNKNOWN AND WRONG ARE THE SAME ANSWER HERE — see `wiredStage` and `showPropertyRow`.
     */
    _stage;

    /**
     * Resolved record-page URLs, keyed by the RECORD Id rather than by row key.
     *
     * ⚠ Keying by Id is what makes this self-invalidating. If the wire re-emits with a different
     * latest NDA, the new Id is simply not in the map yet, so the row falls back to its unlinked
     * rendering for one tick instead of pointing at the previous record — the stale-link bug a
     * row-keyed cache would have to be explicitly cleared to avoid.
     *
     * Reassigned wholesale (never mutated in place) because LWC's reactivity tracks field
     * ASSIGNMENT; `this._urlsById[id] = url` would resolve the URL and render nothing.
     */
    _urlsById = {};

    /**
     * The parent's stage, and the ONLY thing this second wire exists for.
     *
     * 🔴 IT STAYS `undefined` UNTIL THE WIRE EMITS, AND THAT IS THE FEATURE. `showPropertyRow`
     * tests for equality with `STAGE_CLOSING`, so an unknown stage is indistinguishable from a
     * wrong one and the row renders NOTHING. The alternative — defaulting to "show, then hide once
     * the stage arrives" — is exactly the flash the requirement forbids, and it would be invisible
     * in Jest (both states are green one microtask apart) while being obvious to a user.
     *
     * ⚠ A WIRE ERROR ALSO LEAVES IT `undefined` — FAIL CLOSED, DELIBERATELY. `Disposition__c` is
     * OWD Private and a reader who cannot see the parent record cannot see its stage; the honest
     * rendering there is no row at all, not a row at every stage. It is NOT surfaced as the
     * card-level error either: this card renders ungated on all 11 stages and the three document
     * rows are unaffected by a stage read, so a banner would be a permanent fixture over a working
     * card (the same argument as the service's per-row catches).
     *
     * ⚠ ONE FIELD, ON PURPOSE. `getRecord` with an explicit `fields` list — never `layoutTypes` —
     * so the wire cannot start dragging a layout's worth of fields (and a layout's worth of FLS
     * exposure) behind a rendering decision.
     */
    @wire(getRecord, { recordId: '$recordId', fields: [STAGE_FIELD] })
    wiredStage({ data, error }) {
        if (data) {
            this._stage = getFieldValue(data, STAGE_FIELD);
        } else if (error) {
            this._stage = undefined;
        }
    }

    @wire(getDealSummary, { dispositionId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.loadError = undefined;
            this.resolveRecordUrls(data);
        } else if (error) {
            this.loadError = "Couldn't load the deal summary.";
            this.summary = undefined;
        }
    }

    /**
     * Generates a record-page URL for each row that has a record behind it.
     *
     * ⚠ A row with no Id is skipped entirely, and that covers BOTH the empty state (nothing to
     * link to) and the degraded state (the service leaves the Id null when the read threw, on
     * purpose — see `DispositionDealSummaryService.DealSummary.ndaId`). Neither can therefore
     * acquire a link by accident.
     *
     * ⚠ A rejected `GenerateUrl` is swallowed: the row keeps rendering with a muted label. A
     * navigation convenience failing must not take out a status card that has to survive on all
     * 11 disposition stages — the same reasoning as the service's per-row catches.
     *
     * @param {object} data The wire payload.
     */
    resolveRecordUrls(data) {
        // ⚠ `propertyAssetId` IS IN THIS LIST, NOT IN A SECOND RESOLVER. It is a record Id like
        // any other, its URL is cached in the same Id-keyed map, and a rejected `GenerateUrl` for
        // it degrades the same way — the asset renders as plain text instead of a link.
        [data.ndaId, data.loiId, data.psaId, data.propertyAssetId].forEach((id) => {
            if (!id || this._urlsById[id]) {
                return;
            }
            this[NavigationMixin.GenerateUrl](recordPageRef(id))
                .then((url) => {
                    this._urlsById = { ...this._urlsById, [id]: url };
                })
                .catch(() => {
                    // Leave the row unlinked. See the note above.
                });
        });
    }

    get hasError() {
        return !!this.loadError;
    }

    get hasSummary() {
        return !!this.summary && !this.loadError;
    }

    /**
     * Opens the record behind a row label.
     *
     * `preventDefault()` + `NavigationMixin.Navigate` keeps an in-app click a SPA transition while
     * the real `href` on the anchor keeps it keyboard-focusable, middle-clickable and announced as
     * a link — the `c/bovComparisonMatrix` "View All" shape, and the reason this card does not copy
     * `c/dealDocStatus`'s href-less `<a onclick>`.
     *
     * @param {Event} event The click, whose `data-record-id` carries the target.
     */
    handleOpenRecord(event) {
        event.preventDefault();
        const targetId = event.currentTarget.dataset.recordId;
        if (!targetId) {
            return;
        }
        this[NavigationMixin.Navigate](recordPageRef(targetId));
    }

    /**
     * Whether the Property row renders at all: BOTH gates, in one place.
     *
     * 🔴 THE STAGE GATE IS SEPARATE FROM `assetLink.exists` ON PURPOSE. They answer different
     * questions — "should this card be showing the subject right now?" and "is there a subject to
     * show?" — and folding the stage into `assetLink` would make a getter documented as "is there
     * an asset" quietly return false on a sale that has one. The template asks this getter and
     * nothing else, so there is exactly one place to read to know when the row appears.
     *
     * ⚠ THE STAGE IS THE OUTER TEST AND THE ASSET THE INNER ONE, which is also the evaluation
     * order: at the ten non-Closing stages the asset never has to be considered.
     *
     * @returns {boolean} True only at `Closing`, with a readable asset, and only once the stage
     *   wire has actually answered.
     */
    get showPropertyRow() {
        return this._stage === STAGE_CLOSING && this.assetLink.exists;
    }

    /**
     * The sale's SUBJECT — the Property Asset — as a link, or nothing at all.
     *
     * 🔴 RETRACTED 2026-08-24, SECOND PASS — DO NOT RESTORE IT FROM THE GIT HISTORY. This block
     * used to read: "Rendering it as a fourth `.row` would give it a pill it has no value for."
     * The user's judgement is that a value slot with nothing status-like in it is not a reason to
     * abandon the card's own visual language — the line read as bolted-on precisely because it
     * refused the treatment. The row treatment is now worn in full and the pill DOES have a value:
     * see `showPropertyRow` and the template.
     * WHAT SURVIVES THE RETRACTION: it is still not one of the `<ul>`'s items (the list is named
     * "Deal documents" and a property is not one), it still has no empty state, no status and no
     * independent degraded state, and it still sits ABOVE the three document rows because it is
     * what the deal is ABOUT rather than another piece of its paperwork.
     *
     * ⚠ ABSENT MEANS NOTHING RENDERS — NOT AN EM-DASH, NOT A MUTED PLACEHOLDER, NOT A DEAD LINK.
     * `Disposition__c.Property_Asset__c` is an optional Lookup with `deleteConstraint = SetNull`, so
     * a sale genuinely can have no asset (and deleting an asset nulls it on every Disposition that
     * referenced it). A placeholder would be a claim that something is missing; there is nothing to
     * miss. This differs from the three document rows on purpose — for those, 'No LOI yet' IS the
     * information.
     *
     * ⚠ `hasLink` IS SEPARATE FROM `exists` FOR THE SAME REASON IT IS ON THE ROWS: `GenerateUrl`
     * returns a Promise, so for the first tick after the wire emits there is a name but no URL. The
     * name still renders — it is real context — as a plain span rather than a bare `<a>` with no
     * destination. `url` is `''` and never `undefined`, because a getter bound to an element's
     * ATTRIBUTE is written unconditionally and `undefined` renders as the literal text "undefined"
     * in an `href`.
     *
     * @returns {object} `{ exists, name, hasLink, url, recordId, title }`. Every string member is
     *   a string, never undefined.
     */
    get assetLink() {
        const s = this.summary || {};
        const name = s.propertyAssetName;
        // Both halves are required. An Id with no readable name would render a link with no text;
        // a name with no Id has nothing to navigate to.
        if (!s.propertyAssetId || !name) {
            return { exists: false, name: '', hasLink: false, url: '', recordId: '', title: '' };
        }
        const url = this._urlsById[s.propertyAssetId];
        return {
            exists: true,
            name: name,
            hasLink: !!url,
            url: url || '',
            recordId: s.propertyAssetId,
            title: `Open ${name}`
        };
    }

    /**
     * The three rows, in deal order (NDA -> LOI -> PSA), each fully resolved for the template.
     * Building them here rather than in markup keeps the template flat and makes every rendered
     * string assertable from Jest without reaching into private state.
     *
     * @returns {Array<object>} Row descriptors: `{ key, label, statusLabel, pillClass, iconClass,
     *   metaLines, isUnavailable, hintText, hintClass, hasLink, recordUrl, recordIdForLink,
     *   linkTitle }`.
     */
    get rows() {
        const s = this.summary || {};
        return [
            this.buildRow({
                key: 'nda',
                label: 'NDA',
                iconName: 'utility:lock',
                status: s.ndaStatus,
                toneMap: NDA_TONE,
                exists: s.hasNda === true,
                unavailable: s.ndaUnavailable === true,
                recordId: s.ndaId,
                emptyLabel: 'No NDA',
                emptyHint: 'No NDA on this sale yet',
                metaLines: this.ndaMetaLines
            }),
            this.buildRow({
                key: 'loi',
                label: 'LOI',
                iconName: 'utility:contract',
                status: s.loiStage,
                toneMap: LOI_TONE,
                exists: s.hasLoi === true,
                unavailable: s.loiUnavailable === true,
                recordId: s.loiId,
                emptyLabel: 'No LOI',
                emptyHint: 'No LOI on this sale yet',
                metaLines: this.loiMetaLines
            }),
            this.buildRow({
                key: 'psa',
                label: 'PSA',
                iconName: 'utility:signature',
                status: s.psaStatus,
                toneMap: PSA_TONE,
                exists: s.hasPsa === true,
                unavailable: s.psaUnavailable === true,
                recordId: s.psaId,
                emptyLabel: 'No PSA',
                emptyHint: 'No PSA on this sale yet',
                metaLines: this.psaMetaLines
            })
        ];
    }

    /**
     * Resolves one row's pill text, tone class and secondary lines.
     *
     * ⚠ Precedence is unavailable > exists > empty, and it matters: a row whose read FAILED must
     * never fall through to the empty-state wording, because "No LOI on this sale yet" is a claim
     * about the data rather than about the reader's access (design §0 C-1).
     *
     * ⚠ ONLY THE THIRD BRANCH CAN PRODUCE A LINK. `hasLink` is false in both the unavailable and
     * the empty branch by construction — not by a condition that a later edit could invert — and
     * `recordUrl` is `''` there, never `undefined`, because a getter bound to an element's
     * attribute is written UNCONDITIONALLY and `undefined` renders as the literal text
     * "undefined" in the `href`.
     *
     * @param {object} cfg Row configuration.
     * @returns {object} The rendered row descriptor. Every string member is a string — never
     *   undefined — for the reason above.
     */
    buildRow(cfg) {
        const iconClass = ICON_CLASS[cfg.key];
        if (cfg.unavailable) {
            return {
                key: cfg.key,
                label: cfg.label,
                iconName: cfg.iconName,
                // The error-toned chip is the second of the three axes that separate a DEGRADED
                // row from an empty one (solid pill, error chip, non-italic alert hint).
                iconClass: 'row-icon row-icon_blocked',
                statusLabel: UNAVAILABLE_LABEL,
                pillClass: 'pill pill_blocked',
                metaLines: [],
                isUnavailable: true,
                hintText: UNAVAILABLE_HINT,
                hintClass: 'row-hint row-hint_alert',
                hasLink: false,
                recordUrl: '',
                recordIdForLink: '',
                linkTitle: ''
            };
        }
        if (!cfg.exists) {
            return {
                key: cfg.key,
                label: cfg.label,
                iconName: cfg.iconName,
                iconClass: iconClass,
                statusLabel: cfg.emptyLabel,
                pillClass: 'pill pill_neutral',
                metaLines: [],
                isUnavailable: false,
                hintText: cfg.emptyHint,
                hintClass: 'row-hint',
                hasLink: false,
                recordUrl: '',
                recordIdForLink: '',
                linkTitle: ''
            };
        }
        const status = cfg.status || '—';
        const tone = cfg.toneMap[cfg.status] || 'neutral';
        const url = cfg.recordId ? this._urlsById[cfg.recordId] : undefined;
        return {
            key: cfg.key,
            label: cfg.label,
            iconName: cfg.iconName,
            iconClass: iconClass,
            statusLabel: status,
            pillClass: `pill pill_${tone}`,
            metaLines: cfg.metaLines,
            isUnavailable: false,
            hintText: '',
            hintClass: 'row-hint',
            hasLink: !!url,
            recordUrl: url || '',
            recordIdForLink: cfg.recordId || '',
            linkTitle: `Open ${cfg.label}`
        };
    }

    /**
     * NDA secondary lines: the signed-of-total counter, then the signed date.
     *
     * 🔴 `?? 0` IS THE WHOLE POINT OF THIS GETTER. `NDA_Count__c` / `Signed_NDA_Count__c` hold
     * NULL — not 0 — on every Disposition that predates the `NDA_Signed_Rollup` flow, and Apex
     * passes that null through untouched by design. Without the coalescing this line would render
     * "null of null signed".
     *
     * ⚠ The counter line is suppressed when the COUNTER read specifically failed
     * (`ndaCountsUnavailable`), which is a different failure from the NDA row's own read — the two
     * are separate objects with independent FLS and the service catches them separately, so a
     * readable status can survive an unreadable counter and vice versa.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the NDA row.
     */
    get ndaMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.ndaCountsUnavailable === true) {
            lines.push({ key: 'nda-counts', text: 'NDA counts unavailable' });
        } else {
            const signed = s.ndaSignedCount ?? 0;
            const total = s.ndaCount ?? 0;
            lines.push({ key: 'nda-counts', text: `${signed} of ${total} signed` });
        }
        if (s.ndaSignedDate) {
            lines.push({ key: 'nda-date', text: `Signed ${formatLongDate(s.ndaSignedDate)}` });
        }
        return lines;
    }

    /**
     * LOI secondary lines: offer price, then whose court the LOI sits in.
     *
     * ⚠ There is deliberately no signed-date line and no `LOI_Status__c` line — see the exclusion
     * block in this file's header. Adding either is a regression, not a widening.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the LOI row.
     */
    get loiMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.loiOfferPrice != null) {
            lines.push({ key: 'loi-price', text: formatMoney(s.loiOfferPrice) });
        }
        if (s.loiBallInCourt) {
            lines.push({ key: 'loi-court', text: `Ball in court: ${s.loiBallInCourt}` });
        }
        return lines;
    }

    /**
     * PSA secondary lines: the maintained version number, then the execution date.
     *
     * @returns {Array<{key: string, text: string}>} Lines for the PSA row.
     */
    get psaMetaLines() {
        const s = this.summary || {};
        const lines = [];
        if (s.psaLatestVersion != null) {
            lines.push({ key: 'psa-version', text: `Version ${s.psaLatestVersion}` });
        }
        if (s.psaExecutionDate) {
            lines.push({ key: 'psa-date', text: `Executed ${formatLongDate(s.psaExecutionDate)}` });
        }
        return lines;
    }
}
