import { LightningElement, api, wire } from 'lwc';
import getHistory from '@salesforce/apex/BovBrokerChangeController.getHistory';

/** Notes longer than this are clipped inline and get a "View" button (mirrors c/brokerAssignmentHistory). */
const NOTE_PREVIEW = 60;

/** Muted, non-alarming text for a failed read. DELIBERATELY NOT the empty-state sentence. */
const UNAVAILABLE =
    'Broker change history is unavailable right now.';

/**
 * c-bov-broker-change-history — every broker replacement recorded against one disposition, newest
 * first (2026-08-20, Tranche 2 Workstream B / design D4.6).
 *
 * ── 🔴 ANCHORED ON THE DISPOSITION, NOT ON AN ASSIGNMENT ─────────────────────
 * `recordId` here is a `Disposition__c` Id. The UX is modelled on `c/brokerAssignmentHistory` —
 * same newest-first list, same `Reason:` line, same 60-character note preview with a View popup —
 * but that component is a **presentation model only**. It reads a PARENT record and renders a
 * synthetic history assembled by `BrokerAssignmentController.getDetail`; this one reads a real
 * child object through its own selector. Do not copy its data layer across.
 *
 * ── 🔴 THREE STATES, AND THE ONE THAT MATTERS MOST IS "EMPTY" ────────────────
 * MOST DISPOSITIONS WILL NEVER REPLACE A BROKER. Empty is not an edge case here, it is the
 * majority of the org's disposition record pages, so it gets a plain sentence — "No broker changes
 * recorded" — and NEVER an error banner and NEVER a spinner. This is the specific failure the
 * design called out, and it is easy to reintroduce: `c/brokerAssignmentHistory` renders a red
 * `role="alert"` banner on failure and renders NOTHING at all when it has no data, which on this
 * component would leave a titled card with a permanent hole in it.
 *
 * ⚠ AND "UNAVAILABLE" IS A THIRD STATE, NOT A FLAVOUR OF EMPTY. An empty list and a failed read say
 * completely different things about an audit log: "no broker was ever replaced" is a fact about the
 * SALE, "we could not read the log" is a fact about the READER. Collapsing the second into the
 * first would have this card assert, in plain English, that nothing ever happened — on a sale where
 * something may well have. It is rendered as muted text rather than a red alert because a
 * secondary informational card cannot read the situation well enough to alarm anyone: the realistic
 * cause is a missing FLS grant on a 2026-08-20 object, which is an administrator's problem, not
 * this user's emergency.
 *
 * ⚠ NO SPINNER, DELIBERATELY. Before the wire settles, `_loaded` is false and the component renders
 * an EMPTY CARD BODY. A spinner would be the only element on screen able to hang forever if the
 * wire never emitted — which is the exact symptom the design forbids — and it would flash on every
 * page load of a card that is usually empty anyway.
 *
 * ⚠ AMENDED 2026-08-21: that paragraph used to say "renders nothing at all", which was literally
 * true of the old markup — it had no card chrome, so the whole component was invisible pre-wire.
 * The `lightning-card` is now UNCONDITIONAL and only the BODY is empty pre-wire. The requirement
 * the sentence protected is unchanged and still pinned by the tests: no rows, no empty state, no
 * unavailable state and no spinner until the wire has answered.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DESIGNED FOR A ~340px SIDEBAR COLUMN. DO NOT REINTRODUCE THE TWO-COLUMN ROW.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The rendered unit is a self-labelling TILE — see the long note in the template. `reason` and
 * `loggedBy` below are now BARE VALUES rather than the pre-composed "Reason: X" / "Logged by X"
 * strings they used to be, because the label is now a real <dt> beside them. Do not put the word
 * back into the value: it would render as "Reason  Reason: Better BOV Received".
 *
 * ⚠ THE ROWS ARE NOT RE-SORTED HERE. `BovBrokerChangeSelector` orders them
 * `Entry_DateTime__c DESC, Name DESC`, tie-break included; a client-side sort would be a second,
 * weaker copy of that ordering (JS cannot see the AutoNumber tie-break's intent) and would drift
 * from it silently. Contrast `c/brokerAssignmentHistory`, which sorts in JS because its Apex does
 * not sort at all.
 */
export default class BovBrokerChangeHistory extends LightningElement {
    /** 🔴 A Disposition__c Id — see the header. Not a BOV submission and not an assignment. */
    @api recordId;

    _rows = [];
    _loaded = false;
    _failed = false;

    @wire(getHistory, { dispositionId: '$recordId' })
    wiredHistory({ data, error }) {
        if (data) {
            this._rows = data;
            this._failed = false;
            this._loaded = true;
        } else if (error) {
            // The Apex message is deliberately ignored: BovBrokerChangeController already replaced
            // every underlying failure with one fixed generic sentence, and re-surfacing it here
            // would put "contact your administrator" on a card the user did not ask to interact
            // with. The muted line says what the user needs — this panel is not showing you
            // everything — without dressing a secondary card up as an incident.
            this._rows = [];
            this._failed = true;
            this._loaded = true;
        }
    }

    // ⚠ `get intro()` — 'Every broker ever appointed to this sale — nothing is deleted.' — WAS
    // DELETED ON 2026-08-21. The user quoted this exact string as prose they did not want. It
    // rendered in TWO places (above the tiles, and as the empty state's sub-line) and both went;
    // the `id="bbc-intro"` / `aria-describedby` pair went with it, because an aria-describedby
    // naming a removed element is worse than none at all.
    // 🔴 THE EMPTY STATE ITSELF SURVIVED — "No broker changes recorded" is still rendered, still
    // with role="status" and an icon and never an alert or a spinner. That requirement (see the
    // three-states block above) is about the STATE being distinguishable, not about this sentence.

    /**
     * The card's visible title, with the change count appended ONLY once the wire has answered
     * successfully.
     *
     * 🔴 THE UNAVAILABLE STATE MUST NOT SHOW A COUNT, AND NEITHER MUST THE PRE-WIRE RENDER.
     * "Broker Change History (0)" is a claim about the SALE — that no broker was ever replaced —
     * in exactly the words a genuinely empty card uses. On a failed read the card knows nothing
     * about the sale, which is the whole reason `isUnavailable` exists as a state separate from
     * `isEmpty`; leaking a "(0)" into the title would reintroduce the collapse that state was
     * created to prevent, in the one place the state templates below cannot guard.
     */
    get cardTitle() {
        return this.hasRows || this.isEmpty
            ? `Broker Change History (${this._rows.length})`
            : 'Broker Change History';
    }

    /** True only once the wire has actually answered, which is what keeps the empty state honest. */
    get hasRows() {
        return this._loaded && !this._failed && this._rows.length > 0;
    }
    get isEmpty() {
        return this._loaded && !this._failed && this._rows.length === 0;
    }
    get isUnavailable() {
        return this._loaded && this._failed;
    }
    get unavailableText() {
        return UNAVAILABLE;
    }

    get historyRows() {
        return this._rows.map((row) => {
            const notes = row.notes || '';
            const notesLong = notes.length > NOTE_PREVIEW;
            return {
                id: row.id,
                changeNumber: row.changeNumber,
                // 🔴 THE FIRM STRINGS ARE STAMPED SNAPSHOTS, and an absent OUTGOING firm is a
                // meaningful state rather than missing data: the service records an APPOINTMENT
                // (no incumbent to replace) with blank outgoing columns. Naming it beats an em dash
                // the reader has to interpret.
                outgoing: row.outgoingBrokerFirm || 'No previous broker',
                incoming: row.incomingBrokerFirm || '—',
                entryDateTime: row.entryDateTime,
                // ⚠ BARE VALUES — the "Reason:" / "Logged by" wording now lives in the <dt>
                // beside them (see the class header). A pair with no value is OMITTED from the
                // markup entirely rather than rendered empty: an absent reason and a blank
                // reason look identical on screen and mean different things.
                hasReason: !!row.reason,
                reason: row.reason || '',
                hasLoggedBy: !!row.loggedBy,
                loggedBy: row.loggedBy || '',
                hasNotes: !!notes,
                notesPreview: notesLong
                    ? `${notes.slice(0, NOTE_PREVIEW).trimEnd()}…`
                    : notes,
                notesLong,
                notesClass: notesLong
                    ? 'bbc-value bbc-notes bbc-notes--clip'
                    : 'bbc-value bbc-notes'
            };
        });
    }

    // ----- full-note popup (same affordance as c/brokerAssignmentHistory) -----
    _note = {};
    get showNoteModal() {
        return !!this._note.open;
    }
    get noteText() {
        return this._note.text || '';
    }
    /**
     * ⚠ RETURNS '' AND NEVER undefined. This value is bound to an ATTRIBUTE in the template, and an
     * attribute binding is written UNCONDITIONALLY — an undefined getter renders the literal string
     * "undefined" in the DOM. Assert on the rendered markup, not on this getter.
     */
    get noteSubtitle() {
        return this._note.subtitle || '';
    }

    openNote(event) {
        const id = event.currentTarget.dataset.id;
        const row = this._rows.find((r) => r.id === id);
        if (!row) {
            return;
        }
        this._note = {
            open: true,
            text: row.notes || '',
            subtitle: `${row.outgoingBrokerFirm || 'No previous broker'} → ${
                row.incomingBrokerFirm || '—'
            }`
        };
    }

    closeNote() {
        this._note = {};
    }
}
