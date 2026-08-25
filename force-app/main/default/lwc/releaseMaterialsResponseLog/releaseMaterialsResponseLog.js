/**
 * c-release-materials-response-log
 * ---------------------------------------------------------------------------
 * The "Release materials responses" card. Rendered by `c/dispositionMain` at the
 * `Release Materials` disposition stage, and the ONLY way to create a
 * `Release_Materials_Response__c` — the object ships with no tab and no list
 * view. Added 2026-08-24.
 *
 * A response is what comes back after the offering materials go out: the broker
 * asks MORE QUESTIONS, gives a DECISION, or signals an OFFER.
 *
 * ==========================================================================
 * 🔴 THREE INPUTS, IN THIS ORDER — AND THE SECOND IS NOT A CONTROL
 * ==========================================================================
 *   1. METHOD         a combobox over the three restricted picklist values.
 *   2. RESPONSE FROM  the APPOINTED BROKER, RESOLVED AND RENDERED READ-ONLY.
 *   3. NOTES          free text, OPTIONAL.
 *
 * User decision, 2026-08-24: *"lookup to the appointed broker only"*. There is
 * exactly ONE appointed listing broker per sale, so a picker would be a control
 * with one correct answer and several wrong ones. It is therefore:
 *   · resolved on the SERVER (`ReleaseMaterialsResponseService` reuses
 *     `DispositionOfferFormService.getFormContext` — the same rule, the same
 *     two record-type sources, one definition);
 *   · displayed here as TEXT rather than as a disabled lookup, for the reason
 *     `c/dispositionLogOfferModal` records for the same value: a disabled
 *     lookup still looks like a control somebody may enable;
 *   · 🔴 NEVER SENT BY THIS COMPONENT. `saveResponse` takes no broker argument
 *     at all, so a forged or stale broker Id is unexpressible rather than
 *     merely discouraged. Do not "helpfully" add one.
 * ⚠ IT SITS INSIDE THE FORM, BETWEEN Method AND Notes, BECAUSE THE ORDER IS THE
 * REQUIREMENT. An earlier draft placed it ABOVE the form on the reasoning that
 * it is "a fact about the sale rather than a field of the entry" — which
 * rendered `Response from, Method, Notes` and was WRONG. A Jest test that walks
 * the rendered tree in document order caught it. Do not move it back out.
 * ⚠ THE "no broker appointed" WARNING ALSO APPEARS AT CARD LEVEL WHEN THE FORM
 * IS CLOSED (`showNoBrokerNotice`), because a user needs to know before they
 * decide to log. The two never render together.
 *
 * ==========================================================================
 * 🔴 NO BROKER DOES NOT BLOCK THE LOG. THIS DELIBERATELY DIFFERS FROM
 *    c/dispositionLogOfferModal, WHICH REFUSES TO SAVE WITHOUT ONE.
 * ==========================================================================
 * User instruction, 2026-08-24: *"If no broker is resolvable, still allow the
 * entry with a blank broker rather than blocking the log; say so in the
 * header."* The Log Offer dialog refuses because `Broker__c` is the only party
 * on an offer, so an unattributed offer cannot be told apart from another offer
 * on the same sale. None of that transfers: "a decision came back on the 3rd"
 * is a complete and useful record on its own, and refusing it would lose a real
 * event to protect a field nothing downstream reads.
 * 🔴 BUT THE CARD MUST SAY SO. A blank value under a "Response from" label is
 * indistinguishable from a rendering failure, so the template states the
 * absence in words and still names where a broker WOULD come from.
 *
 * ==========================================================================
 * 🔴 NO `lightning-record-edit-form`, AND THAT IS AGAINST THE USUAL PREFERENCE
 * ==========================================================================
 * ARCHITECTURE.md §5 puts LDS first and `lightning-record-*` above imperative
 * Apex. Two things make this the exception rather than a shortcut:
 *   1. THE BROKER IS NOT A FORM FIELD. It is resolved server-side at save time
 *      and must not be in any client payload. An LDS form FLS-checks every key
 *      it is given, including programmatic ones, and drops a non-editable one
 *      SILENTLY WITH A SUCCESS TOAST (measured in this repo) — so the failure
 *      mode of doing it that way is a response saved with no broker and nobody
 *      told.
 *   2. THE METHOD ALLOW-LIST CARRIES AN AUTHORED MESSAGE. The platform's own
 *      refusal for a bad restricted-picklist value is
 *      `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, which the controller is
 *      obliged to replace with a generic sentence because raw DML text leaks
 *      field API names.
 * The write is therefore imperative Apex through a thin controller over a
 * service that owns the resolution, the validation and the `USER_MODE` insert.
 *
 * ── DATA ACCESS ──────────────────────────────────────────────────────────
 * ONE `@wire(getLogContext, { dispositionId: '$recordId' })` carrying the
 * broker, the create-permission affordance AND the rows. One round trip rather
 * than three cacheable methods: the card cannot render a half-answer, and three
 * wires would be three cache entries free to disagree. The wire RESULT is kept
 * un-destructured so `refreshApex` can re-provision it after a save — that is
 * what closes the `cacheable = true` staleness window for the only writer that
 * exists.
 *
 * ── ERROR BRANCH ─────────────────────────────────────────────────────────
 * The controller throws `AuraHandledException` rather than returning an empty
 * context, so this component renders a visible inline alert — never a silent
 * blank. ⚠ EXPECT THIS BRANCH IMMEDIATELY AFTER A DEPLOY that lands the object
 * before its permission sets: a Metadata-API-deployed field arrives with NO FLS
 * for anyone, System Administrator included, so the `WITH USER_MODE` read
 * throws until both disposition sets grant all five fields. Deploy-order
 * dependency, not a defect.
 *
 * ── ⚠ `canLog` IS AN AFFORDANCE, NEVER THE GUARD ─────────────────────────
 * It hides the opener for a `DPEG_Disposition_View` persona, who holds
 * `allowCreate = false` and would be refused on click. The REAL enforcement is
 * `AccessLevel.USER_MODE` on the insert, which refuses the write whatever this
 * flag says, and there is an Apex test that runs a read-only persona through
 * the service to prove it.
 *
 * ==========================================================================
 * 🔴 THE LOG RENDERS THROUGH `c-list-datatable`, LIKE `c/loiCounterOffer`
 *    (2026-08-25) — AND THE ARGUMENT AGAINST IT WAS BASED ON A FALSE PREMISE
 * ==========================================================================
 * This card previously rendered its logged responses as a `<ul>` of hand-rolled
 * tiles. The 2026-08-24 theming pass recorded that as "DIVERGENCE 4" and gave
 * two reasons. BOTH ARE RETRACTED — quoted here rather than deleted, because the
 * second is the kind a future reader would rebuild from first principles:
 *
 *   RETRACTED (1): "It is a REWRITE, not a theme." True at the time and no
 *   longer a reason: the rewrite was subsequently ASKED FOR.
 *
 *   🔴 RETRACTED (2): "A fixed-column table does not survive the ~340px record-
 *   page sidebar." THE PREMISE IS SIMPLY FALSE. This card is rendered by
 *   `c/dispositionMain`, and `c_dispositionMain` is a componentInstance of the
 *   **`main`** region of `flexipages/Disposition_Record_Page` (template
 *   `flexipage:recordHomeWithSubheaderTemplateDesktop`) — the WIDE region. The
 *   `sidebar` region holds `dispositionSidebar` and its neighbours; this card has
 *   never been in it. DO NOT RE-USE THE WIDTH ARGUMENT.
 *
 * ⚠ AND THE DATA SHAPE WAS THE REAL QUESTION, NOT THE WIDTH — it was checked:
 * `loiCounterOffer`'s "Counter Response" column already carries
 * `Counter_Offer__c.Counter_Response__c`, which is `LongTextArea`, length 32768,
 * `visibleLines` 3 — BYTE-FOR-BYTE THE SAME FIELD DEFINITION as this object's
 * `Notes__c`. The idiom for it is `wrapText: true` with NO `initialWidth`, so the
 * column absorbs the remaining width; that is copied verbatim below.
 *
 * ⚠ WHAT WAS DELIBERATELY *NOT* COPIED FROM loiCounterOffer, AND WHY — two
 * things, both because they would change BEHAVIOUR rather than presentation:
 *   1. SORTABLE COLUMNS + `onsort`. loiCounterOffer re-sorts client-side. This
 *      card does not sort at all, on purpose: `ReleaseMaterialsResponseSelector`
 *      orders `Entry_DateTime__c DESC NULLS LAST, Name DESC` and two sorts would
 *      be free to disagree. No column is `sortable`, so no sort affordance is
 *      offered that the component would then have to honour.
 *   2. A `url`-TYPE FIRST COLUMN. loiCounterOffer links each row to its
 *      Counter_Offer__c record. `Release_Materials_Response__c` ships with no tab
 *      and no list view and its record page is unconfigured, so a link would be a
 *      NEW navigation affordance landing on a bare default page. The response
 *      number is carried as plain text instead.
 */
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLogContext from '@salesforce/apex/ReleaseMaterialsResponseController.getLogContext';
import saveResponse from '@salesforce/apex/ReleaseMaterialsResponseController.saveResponse';

/** Rendered wherever a value cannot be stated. Matches `c/dispositionBuyerTimeline`. */
const EM_DASH = '—';

/**
 * 🔴 THE THREE VALUES MUST MATCH
 * `objects/Release_Materials_Response__c/fields/Method__c.field-meta.xml` EXACTLY,
 * including the space and the lower-case "q" in `More questions`. The value set
 * is `restricted` and Apex DML enforces it, and the service checks the same
 * three server-side — so a typo here does not corrupt data, it produces a Save
 * button that always fails.
 * ⚠ THEY ARE NOT FETCHED VIA `getPicklistValues`. That adapter needs a record
 * type Id, this object has none, and one more wire would be one more way for
 * the card to fail before it can show anything. The server-side allow-list is
 * the authority; this list is the affordance.
 */
const METHOD_OPTIONS = [
    { label: 'More questions', value: 'More questions' },
    { label: 'Decision', value: 'Decision' },
    { label: 'Offer', value: 'Offer' }
];

/** loiCounterOffer's own cellAttributes constant — left-align every text column. */
const LEFT = { alignment: 'left' };

/**
 * `[background, dot]` per `Method__c` value, for the `pill` custom cell type that
 * `c/listDatatable` registers. This is the datatable-native replacement for the
 * `slds-badge` the tiles used, and it is the same construction loiCounterOffer
 * uses for its "Countered By" column.
 *
 * 🔴 BUT EVERY COLOUR IS A STYLING HOOK WITH A LITERAL FALLBACK, WHICH IS A
 * DELIBERATE DEPARTURE FROM THE SIXTEEN OTHER `pillWrap` HELPERS IN THIS REPO —
 * every one of them, loiCounterOffer included, hardcodes raw hex. Raw hex does
 * not re-resolve under the dark theme, and this bundle's stylesheet carries an
 * explicit dark-mode pin BECAUSE NOTHING ELSE IN THE PIPELINE CATCHES A DARK-MODE
 * FAILURE (the SLDS linter only checks that a hook was used, Jest asserts class
 * names, and axe's colour-contrast rule is inert in jsdom). Moving the method
 * badge from CSS into an inline style string would have moved it OUT of reach of
 * that pin — so the pin moved too, onto the rendered row data. See the test.
 * ⚠ `-base-95` + `-base-30` IS THE SAFE TINT PAIRING. NOT `-container-1`, which
 * is a SOLID DARK FILL (#2e844a for success, #ba0517 for error) whose pale
 * literal fallback describes only the hook-undefined case — a file using it reads
 * as correct while rendering dark-on-dark.
 * ⚠ THE KEYS MUST MATCH `METHOD_OPTIONS` EXACTLY. A miss is not fatal — it falls
 * through to the neutral pill below and the WORD still renders — which is
 * precisely why a test asserts the resolved style per method rather than trusting
 * the lookup.
 */
const METHOD_PILL = {
    'More questions': [
        'var(--slds-g-color-warning-base-95, #fff1ea)',
        'var(--slds-g-color-warning-base-30, #8a5300)'
    ],
    Decision: [
        'var(--slds-g-color-brand-base-95, #eef4ff)',
        'var(--slds-g-color-brand-base-30, #014486)'
    ],
    Offer: [
        'var(--slds-g-color-success-base-95, #ebf7e6)',
        'var(--slds-g-color-success-base-30, #1b7a4b)'
    ]
};

/** For a method the server sends that this client does not know, and for the em-dash. */
const METHOD_PILL_NEUTRAL = [
    'var(--slds-g-color-neutral-base-95, #f3f3f3)',
    'var(--slds-g-color-neutral-base-30, #444444)'
];

const pillWrap = (bg) =>
    `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:4px;font-weight:600;color:var(--slds-g-color-on-surface-2, #2e2e2e);background:${bg}`;
const pillDot = (c) =>
    `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;

/**
 * The logged-response columns, in the required reading order: the response
 * number, then METHOD, RESPONSE FROM, NOTES and finally the DATE — loiCounterOffer
 * puts its date last too.
 *
 * ⚠ `Received` IS `type: 'date'`, NOT `date-local`. loiCounterOffer's date column
 * is `date-local` because `Counter_Date__c` is an Apex **Date** — a bare
 * `YYYY-MM-DD` with no instant attached, which `date-local` renders without a
 * timezone shift. `Entry_DateTime__c` is a **DateTime**: an unambiguous instant,
 * correctly rendered in the viewer's own timezone. Using `date-local` on it would
 * render the DAY BEFORE for any viewer west of Greenwich. The typeAttributes are
 * the same five the retired `lightning-formatted-date-time` carried.
 * ⚠ A NULL `Entry_DateTime__c` (the field is `required=false`, defaulted to NOW()
 * but editable) now renders an EMPTY CELL where the tile rendered an em-dash.
 * That is the correct idiom change, not an oversight: an empty cell in a labelled
 * column reads as "no value", whereas a blank under a tile's label reads as a
 * rendering failure. The em-dash survives where it still carries meaning — Notes,
 * the broker and the method are all `text`/`pill` and keep theirs.
 * 🔴 NO `sortable` ON ANY COLUMN. See the class header: the order is the server's.
 */
const COLUMNS = [
    {
        label: 'Response',
        fieldName: 'responseName',
        type: 'text',
        initialWidth: 110,
        cellAttributes: LEFT
    },
    {
        label: 'Method',
        fieldName: 'method',
        type: 'pill',
        initialWidth: 150,
        typeAttributes: {
            wrapStyle: { fieldName: 'methodWrap' },
            dotStyle: { fieldName: 'methodDot' }
        }
    },
    {
        label: 'Response from',
        fieldName: 'brokerName',
        type: 'text',
        initialWidth: 180,
        cellAttributes: LEFT
    },
    {
        // No initialWidth: this column absorbs the remaining width (fixed mode),
        // exactly as loiCounterOffer's "Counter Response" column does for the
        // identically-defined Counter_Response__c.
        label: 'Notes',
        fieldName: 'notes',
        type: 'text',
        wrapText: true,
        cellAttributes: LEFT
    },
    {
        label: 'Received',
        fieldName: 'entryDateTime',
        type: 'date',
        initialWidth: 150,
        cellAttributes: LEFT,
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    }
];

export default class ReleaseMaterialsResponseLog extends LightningElement {
    @api recordId;

    context;
    loadError;
    isFormOpen = false;
    isSaving = false;
    method = '';
    notes = '';

    /** The un-destructured wire result — `refreshApex` needs the whole thing. */
    _wiredContext;

    methodOptions = METHOD_OPTIONS;
    columns = COLUMNS;

    @wire(getLogContext, { dispositionId: '$recordId' })
    wiredLogContext(result) {
        this._wiredContext = result;
        if (result.data) {
            this.context = result.data;
            this.loadError = undefined;
        } else if (result.error) {
            // The fallback names the card the user is looking at, not the
            // objects behind it — a message naming a card the user cannot see
            // on screen is not actionable.
            this.loadError =
                result.error?.body?.message ||
                "Couldn't load the release materials responses.";
            this.context = undefined;
        }
    }

    get hasError() {
        return !!this.loadError;
    }

    get errorMessage() {
        return this.loadError || '';
    }

    /** True only once the wire has answered. Guards every getter that reads `context`. */
    get hasContext() {
        return !!this.context;
    }

    get hasEntries() {
        return this.hasContext && this.context.responses.length > 0;
    }

    /** True only once the wire has answered AND there is genuinely nothing logged. */
    get isEmpty() {
        return this.hasContext && this.context.responses.length === 0;
    }

    /**
     * Whether to render `<c-list-datatable>` at all.
     *
     * 🔴 ADDED 2026-08-25, WITH THE REMOVAL OF THE HARDCODED EMPTY STATE (user
     * instruction). The card used to branch `hasEntries` → table /
     * `isEmpty` → "No responses yet" + "Rows appear here as brokers respond…".
     * That text is gone, and an empty log now reads the way every other card on
     * this page reads when it is empty: the datatable's column HEADERS over an
     * empty `data` array.
     *
     * ⚠ IT IS `hasEntries || isEmpty`, NOT A BARE `true` OR `!hasError`, AND THE
     * DIFFERENCE IS THE PRE-WIRE RENDER. Both getters require `hasContext`, so
     * this stays false until the server has actually answered — an empty grid
     * shown before then states "nothing has come back on this sale" in the same
     * shape it uses once that is known, which is the same confident wrong answer
     * the deleted text would have been. It is the reasoning that keeps a
     * premature "(0)" out of `cardTitle` above.
     */
    get showTable() {
        return this.hasEntries || this.isEmpty;
    }

    /**
     * The card's visible title, with the count appended ONLY once the wire has answered.
     *
     * 🔴 A PREMATURE "(0)" IS A CLAIM THIS CARD IS NOT ENTITLED TO MAKE. Before
     * the wire settles nothing is known about the sale, and
     * "Release materials responses (0)" would state — in the same words it uses
     * for a genuinely empty sale — that nobody has responded. The same reasoning
     * keeps the TABLE out of the pre-wire render — see `showTable` below (the
     * hardcoded empty state it used to keep out was removed 2026-08-25).
     */
    get cardTitle() {
        return this.hasContext
            ? `Release materials responses (${this.context.responses.length})`
            : 'Release materials responses';
    }

    /** True when a broker resolved. Gated on the ID, never on the NAME — see `brokerName`. */
    get hasBroker() {
        return this.hasContext && !!this.context.brokerId;
    }

    /**
     * The broker's display name.
     *
     * ⚠ NEVER `undefined` AND NEVER `null`: a getter bound into the DOM is
     * written unconditionally, so either would render the literal text
     * "undefined" (measured in this repo).
     * ⚠ AND THE `hasBroker` GATE READS `brokerId`, NOT THIS. `Broker__r` can
     * come back null while `Broker__c` is set — `USER_MODE` lifts FLS, never
     * sharing — so a broker IS appointed while its name is ''. Gating on the
     * name would report that sale as having no broker.
     */
    get brokerName() {
        return (this.hasContext && this.context.brokerName) || '';
    }

    /** Why that broker — the record-type-specific source line. Never null. */
    get brokerSource() {
        return (this.hasContext && this.context.brokerSource) || '';
    }

    /** Whether to offer a Save button at all. An affordance — see the class header. */
    get canLog() {
        return this.hasContext && this.context.canLog === true;
    }

    /**
     * Whether to render the "Add" opener in the CARD'S ACTIONS SLOT.
     *
     * Added 2026-08-24 by the theming pass that aligned this card with
     * `c/loiCounterOffer`, which places its own "Add" button there. A slotted
     * element is a child of `<lightning-card>` and therefore CANNOT sit inside
     * the body's `lwc:if` / `lwc:elseif` chain, so the two conditions the chain
     * used to express have to be stated here instead:
     *   · `canLog`   — an affordance, never the guard (see the class header).
     *     It is false before the wire answers AND on the error branch, because
     *     both leave `context` undefined, which is what keeps the button off a
     *     card that is still loading or has failed.
     *   · `!isFormOpen` — the opener is REPLACED by the form, not shown beside
     *     it. ⚠ THIS IS BEHAVIOUR, NOT STYLING, and it is pinned by a Jest
     *     test. loiCounterOffer instead keeps its button mounted and disabled
     *     while editing; that difference was left alone deliberately, because
     *     the pass was scoped to presentation.
     * 🔴 NO NEW STATE. This getter reads two existing ones and adds nothing to
     * the component's behaviour.
     */
    get showOpener() {
        return this.canLog && !this.isFormOpen;
    }

    /**
     * The card-level "no broker appointed" line — the *"say so in the header"*
     * half of the 2026-08-24 instruction.
     *
     * ⚠ SUPPRESSED WHILE THE FORM IS OPEN, because the form's own "Response
     * from" block carries the same fact. Rendering both at once puts the same
     * sentence twice on one small card, which reads as an error rather than as
     * emphasis.
     * ⚠ AND SUPPRESSED FOR A PERSONA WHO CANNOT LOG. The line's whole purpose is
     * to warn someone about to record something; a read-only viewer is not, and
     * for them it is noise about a decision they cannot take.
     */
    get showNoBrokerNotice() {
        return this.hasContext && !this.context.brokerId && !this.isFormOpen && this.canLog;
    }

    /**
     * Save is disabled until a method is chosen, and while a save is in flight.
     * ⚠ THE SECOND HALF IS NOT COSMETIC: without it a double click logs two rows.
     */
    get isSaveDisabled() {
        return this.isSaving || !this.method;
    }

    /**
     * The datatable rows, in SERVER ORDER — newest first.
     *
     * 🔴 THIS COMPONENT DOES NOT SORT, AND `.map()` IS THE WHOLE IMPLEMENTATION
     * FOR THAT REASON. `ReleaseMaterialsResponseSelector` orders
     * `Entry_DateTime__c DESC NULLS LAST, Name DESC`; two sorts would be free to
     * disagree, and there is no sort affordance on any column to honour. Note the
     * contrast with `c/loiCounterOffer`'s own `rows` getter, which ends in a
     * `[...data].sort(...)` because it DOES offer sortable columns — copying that
     * tail along with the rest of the idiom is the mistake to avoid.
     * ⚠ NAMED `rows`, NOT `entries`: it is what `data={rows}` binds to, and it
     * carries per-row STYLE STRINGS the tiles never needed. Anything reading it as
     * a generic "the entries" list is reading it wrong.
     */
    get rows() {
        if (!this.hasContext) {
            return [];
        }
        return this.context.responses.map((row) => {
            const method = row.method || EM_DASH;
            const [background, dot] = METHOD_PILL[method] || METHOD_PILL_NEUTRAL;
            return {
                id: row.responseId,
                responseName: row.responseName || EM_DASH,
                method,
                methodWrap: pillWrap(background),
                methodDot: pillDot(dot),
                brokerName: row.brokerName || EM_DASH,
                // Notes are OPTIONAL on a response — an em-dash is the correct
                // rendering of "none entered", not a missing value.
                notes: row.notes || EM_DASH,
                // ⚠ PASSED RAW. The `date` column formats it; a pre-formatted
                // string here would be formatted twice and render as NaN.
                entryDateTime: row.entryDateTime
            };
        });
    }

    handleOpenForm() {
        this.method = '';
        this.notes = '';
        this.isFormOpen = true;
    }

    handleCancel() {
        this.isFormOpen = false;
        this.method = '';
        this.notes = '';
    }

    handleMethodChange(event) {
        this.method = event.detail.value;
    }

    handleNotesChange(event) {
        this.notes = event.detail.value;
    }

    /**
     * Logs the response, then re-provisions the wire so the list and the count
     * update without a page refresh.
     *
     * 🔴 NO `brokerId` IN THE PAYLOAD. See the class header — the server
     * resolves it, and sending one would be a forgeable attribution on a record
     * whose whole purpose is attribution.
     * ⚠ `refreshApex` IS AWAITED BEFORE THE SUCCESS TOAST. Toasting first would
     * tell the user the row is saved while the list beside them still shows the
     * old set, which reads as the save having failed.
     * ⚠ THE ERROR PATH SHOWS THE SERVER'S MESSAGE WHEN THERE IS ONE. The
     * controller surfaces an authored, user-fixable sentence verbatim for an
     * input problem and a fixed generic sentence for anything else — swallowing
     * either into a house string would throw away the only actionable half.
     */
    handleSave() {
        this.isSaving = true;
        return saveResponse({
            dispositionId: this.recordId,
            method: this.method,
            notes: this.notes
        })
            .then(() => refreshApex(this._wiredContext))
            .then(() => {
                this.isFormOpen = false;
                this.method = '';
                this.notes = '';
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Response logged', variant: 'success' })
                );
            })
            .catch((error) => {
                const message =
                    error?.body?.message || 'Unexpected error. Try again.';
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not log this response',
                        message,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.isSaving = false;
            });
    }
}
