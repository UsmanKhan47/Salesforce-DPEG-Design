import { LightningElement, api, wire } from 'lwc';
import getPrimaryChildId from '@salesforce/apex/DispositionChildDetailsController.getPrimaryChildId';

/**
 * Empty-state text, keyed by UPPER-CASED child object API name. Upper-cased to stay in step with
 * the controller, which lower-cases both its allow-list keys and the incoming `childObject` so a
 * hand-edited FlexiPage carrying `loi__c` still resolves. If this map were keyed on the exact API
 * names, that same page would get a working card with the WRONG empty sentence - the generic
 * fallback - which is a worse failure than a refusal because nothing looks broken.
 *
 * The wording names the DOCUMENT, not the object: a user reads "PSA", not "Contract Review".
 */
const EMPTY_TEXT_BY_OBJECT = {
    LOI__C: 'No LOI on this sale yet.',
    CONTRACT_REVIEW__C: 'No PSA on this sale yet.'
};

const FALLBACK_EMPTY_TEXT = 'Nothing to show on this sale yet.';
const FALLBACK_ERROR_TEXT =
    'This section could not be loaded. Refresh the page or contact your administrator.';

/**
 * Pulls the user-safe message out of whatever shape the platform hands back. An `AuraHandledException`
 * arrives as `error.body.message`; a wire-level failure can arrive as an array of bodies or as a
 * plain string. Falling back to fixed text rather than rendering `[object Object]` is the point.
 *
 * @param {*} error the error emitted by the wire adapter
 * @returns {string} a single sentence safe to show a user
 */
function toUserMessage(error) {
    if (!error) {
        return FALLBACK_ERROR_TEXT;
    }
    const body = error.body === undefined ? error : error.body;
    if (Array.isArray(body)) {
        const joined = body
            .map((b) => (b && b.message ? b.message : ''))
            .filter((m) => m)
            .join(' ');
        return joined || FALLBACK_ERROR_TEXT;
    }
    if (typeof body === 'string') {
        return body;
    }
    return body && body.message ? body.message : FALLBACK_ERROR_TEXT;
}

/**
 * Shows ONE child record of a Disposition - its own fields, read-only - inside the Disposition
 * record page.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * WHY IT IS GENERIC RATHER THAN TWO PURPOSE-BUILT CARDS
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * The requirement is two stage-scoped Details panels - LOI fields at the LOI stage, PSA fields at
 * the PSA stage - that differ ONLY in which object they read and which fields they list. Both of
 * those are FlexiPage-configurable, so a second bundle would be a copy of this one with two string
 * literals changed. One bundle, two itemInstances on
 * `flexipages/Disposition_Record_Page.flexipage-meta.xml`, each with its own visibilityRule.
 *
 * 🔴 IT IS NOT A FIELD SECTION BECAUSE THE SCHEMA WILL NOT ALLOW ONE. The NDA-stage section on the
 * same page renders `Record.NDA_*__c` formula fields that traverse `Disposition__c.Primary_NDA__c`.
 * There is NO `Primary_LOI__c` and NO `Primary_PSA__c` - so a FlexiPage fieldSection has nothing
 * to reference, and building the equivalent would mean two lookups, a stamping queueable, a
 * backfill and nine formula fields. See `DispositionChildDetailsController`'s header for the full
 * trade.
 *
 * ── DATA ACCESS: Apex for the Id, LDS for everything the user actually reads ─────────────────
 * ARCHITECTURE.md §5 is LDS-first, and this honours it in the only place it can. LDS cannot answer
 * "the latest child of this parent" - `getRelatedListRecords` is layout-driven and returns rows,
 * not a resolved primary, and a GraphQL wire would be a second query shape to maintain for one Id.
 * So exactly ONE Apex call resolves ONE Id, and from there `lightning-record-view-form` +
 * `lightning-output-field` do all the reading: LDS caching, FLS per field, real field labels, and
 * automatic refresh when the LOI or PSA is edited on its own page. No field values pass through
 * Apex at all.
 */
export default class DispositionChildDetails extends LightningElement {
    /**
     * The Disposition Id. Injected implicitly by `lightning__RecordPage` - it is deliberately NOT
     * declared as a targetConfig property and there is deliberately NO `recordId`
     * componentInstanceProperties block on the FlexiPage. Both of those have been measured to
     * fail or to be unnecessary on this exact page; the two sibling cards in its sidebar
     * (`bovBrokerChangeHistory`, `dispositionBuyerTimeline`) use this same shape.
     */
    @api recordId;

    /** `LOI__c` or `Contract_Review__c`. Anything else is refused by the controller. */
    @api childObject;

    /** Comma-separated field API names on {@link childObject}, rendered in the order given. */
    @api fields;

    /**
     * ⚠ `cardTitle`, NOT `title`. `title` is a global HTML attribute on the host element and an
     * `@api title` would collide with it. In-repo precedent for this exact rename: `dealMessageLog`.
     */
    @api cardTitle = 'Details';

    childId;
    errorMessage;
    _loaded = false;

    /**
     * ⚠ REACTIVE ON BOTH PARAMETERS. `$childObject` matters as much as `$recordId`: App Builder
     * sets design-time properties AFTER the element is created, so a wire keyed only on recordId
     * would fire once with `childObject` undefined, take the controller's refusal path, and cache
     * an error the component never recovers from.
     */
    @wire(getPrimaryChildId, { dispositionId: '$recordId', childObject: '$childObject' })
    wiredChildId({ data, error }) {
        this._loaded = true;
        if (error) {
            this.childId = undefined;
            this.errorMessage = toUserMessage(error);
            return;
        }
        this.errorMessage = undefined;
        // `data` is null when the sale genuinely has no child yet - a real answer, not a failure.
        // Normalising to undefined keeps the template's lwc:elseif={childId} test single-valued.
        this.childId = data || undefined;
    }

    /** True until the wire has emitted once, so the empty state never flashes before the read. */
    get isLoading() {
        return !this._loaded;
    }

    /**
     * The configured field list, split and cleaned. Blank entries are dropped so a trailing comma
     * in App Builder cannot render an empty output field.
     *
     * @returns {string[]} field API names in configured order
     */
    get fieldList() {
        if (!this.fields) {
            return [];
        }
        return this.fields
            .split(',')
            .map((f) => f.trim())
            .filter((f) => f.length > 0);
    }

    /** @returns {string} the honest one-line empty state - never a blank card. */
    get emptyMessage() {
        const key = (this.childObject || '').toUpperCase();
        return EMPTY_TEXT_BY_OBJECT[key] || FALLBACK_EMPTY_TEXT;
    }
}
