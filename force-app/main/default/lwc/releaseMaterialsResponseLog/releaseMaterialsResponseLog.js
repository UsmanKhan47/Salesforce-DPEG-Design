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
    emDash = EM_DASH;

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
     * The card's visible title, with the count appended ONLY once the wire has answered.
     *
     * 🔴 A PREMATURE "(0)" IS A CLAIM THIS CARD IS NOT ENTITLED TO MAKE. Before
     * the wire settles nothing is known about the sale, and
     * "Release materials responses (0)" would state — in the same words it uses
     * for a genuinely empty sale — that nobody has responded. The same reasoning
     * keeps the EMPTY STATE out of the pre-wire render.
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
     * The rendered rows, in SERVER ORDER — newest first. This component does NOT
     * sort; `ReleaseMaterialsResponseSelector` does, and two sorts would be free
     * to disagree.
     */
    get entries() {
        if (!this.hasContext) {
            return [];
        }
        return this.context.responses.map((row) => {
            const responseName = row.responseName || EM_DASH;
            const method = row.method || EM_DASH;
            return {
                id: row.responseId,
                responseName,
                method,
                brokerName: row.brokerName || EM_DASH,
                // Notes are OPTIONAL on a response — an em-dash is the correct
                // rendering of "none entered", not a missing value.
                notes: row.notes || EM_DASH,
                entryDateTime: row.entryDateTime,
                // The accessible name for the whole tile group. The badge and
                // the subtitle are reinforcement; THIS is what a screen reader
                // announces for the row.
                rowLabel: `${responseName} — ${method} from ${row.brokerName || 'no broker'}`
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
