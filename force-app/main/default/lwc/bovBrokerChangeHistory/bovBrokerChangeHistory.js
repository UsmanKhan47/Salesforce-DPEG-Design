import { LightningElement, api, wire } from 'lwc';
import getHistory from '@salesforce/apex/BovBrokerChangeController.getHistory';

/** Notes longer than this are clipped inline and get a "View" button (mirrors c/brokerAssignmentHistory). */
const NOTE_PREVIEW = 60;

/**
 * The card's visible title, WITHOUT the count — see `get cardTitle` for the count rule and for why
 * a "(0)" must never appear pre-wire or on a failed read. Keep this in step with the
 * `<masterLabel>` in `.js-meta.xml`, which App Builder shows and which is not readable from here.
 */
const TITLE_BASE = 'Broker Selection';

/** Muted, non-alarming text for a failed read. DELIBERATELY NOT the empty-state sentence. */
const UNAVAILABLE =
    'Broker change history is unavailable right now.';

/**
 * 🔴 BOTH FIRM COLUMNS ARE NULLABLE AND A ROW WITH NEITHER IS POSSIBLE, so the headline needs a
 * WORD rather than a blank span, an em dash or the literal "undefined". Measured on live data
 * 2026-08-24: `Incoming_Broker_Firm__c` was null on a real retirement row (the incoming Contact
 * carried no firm when the change was written), and `Outgoing_Broker_Firm__c` is null on EVERY
 * initial appointment. This card is an audit log — a nameless row still has a date and a reason
 * worth reading, so it renders, and it says plainly that the name is what is missing.
 */
const UNNAMED_BROKER = 'Broker not recorded';

/**
 * 🔴 THE ONE PLACE THE DISPLAYED BROKER IS CHOSEN. Used by both `historyRows` (the headline) and
 * `openNote` (the popup subtitle) so the two cannot drift — before 2026-08-24 each composed its
 * own fallback string and a test existed purely to catch that drift.
 *
 * WHICH FIRM IS "THE BROKER" DEPENDS ON THE ROW SHAPE, and the shape is read off the DATA (is
 * there an outgoing firm?) rather than off the Reason__c picklist TEXT. A picklist relabel must
 * not change which name this card prints.
 *   • REPLACEMENT (an outgoing firm exists) → the OUTGOING firm. That is the broker who was
 *     replaced, which is the fact the entry records; the incoming firm is the sale's CURRENT
 *     broker and is already shown elsewhere on this record page.
 *   • INITIAL APPOINTMENT (no outgoing firm) → the INCOMING firm. Nobody was replaced, and the
 *     appointed firm is the only broker the row names at all.
 */
function brokerNameOf(row) {
    return row.outgoingBrokerFirm || row.incomingBrokerFirm || UNNAMED_BROKER;
}

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
 * 🔴 A VERTICAL TIMELINE IN A ~340px SIDEBAR COLUMN. DO NOT REINTRODUCE THE TWO-COLUMN ROW.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * RESTYLED 2026-08-24 to a design the user supplied: a dot-and-line rail down the left, and per
 * entry a bold headline, a calendar-icon/date/pipe/reason line, and a "Logged By: {name}" line.
 * It was a self-labelling dt/dd TILE before that (2026-08-21) and a two-column flex row before
 * that (2026-08-20).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 ONE BROKER NAME PER ENTRY. THE "{outgoing} → {incoming}" ARROW HEADLINE IS GONE (2026-08-24).
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The user asked for "just the broker name, when he was replaced, and what was the reason". The
 * arrow pairing put TWO firm names and a relationship glyph on the first line of a ~340px sidebar
 * card, where it routinely wrapped to three lines to say one thing. Per entry now:
 *   line 1  the broker's NAME — see `brokerNameOf` for WHICH firm that is and why;
 *   line 2  calendar icon · date-time · "|" · reason;
 *   line 3  "Logged By: {name}";
 *   line 4  the RETAINED notes affordance (see the template).
 *
 * 🔴 THE ENTRY MUST NOT CALL AN APPOINTMENT A REPLACEMENT — AND STILL MUST NOT, UNDER THE 2026-08-25
 * TITLE. When the card was titled "Broker Replace History" a bare name did exactly that on an
 * initial-appointment row, where nobody was replaced at all. The title is now "Broker Selection",
 * which no longer asserts a replacement — but it does not distinguish the two row shapes either, so
 * a bare name is now simply UNLABELLED rather than actively wrong. The mechanisms below are
 * unchanged and still earn their place; what changed is the failure they prevent. Neither invents
 * a type field:
 *   1. `brokerLabel` — a visually-hidden, shape-specific label on the headline ("Replaced broker:"
 *      / "Appointed broker:"). It also replaces the old assistive "replaced by", which described a
 *      relationship this card no longer renders and must not be left behind announcing one.
 *   2. Reason__c itself, rendered on line 2, which already reads "Initial Appointment" on those
 *      rows. That is the sighted reader's distinction, and it is why NO visible badge was added:
 *      the brief was to remove furniture from this card, not to add a new label to every row.
 * ⚠ THE RESIDUAL CASE is an appointment whose reason is null — line 2 then carries a date and
 * nothing else, and only assistive tech gets the distinction. Accepted deliberately (a visible
 * qualifier on every row is the thing being removed); revisit here if a null Reason__c turns out
 * to happen in practice rather than in theory.
 *
 * `reason` and `loggedBy` below are BARE VALUES and must stay that way. They were pre-composed
 * strings ("Reason: X" / "Logged by X") in the original row layout; the tile promoted the wording
 * to a real <dt>, and the timeline renders it as a visible "Logged By:" span (the name) or as a
 * visually-hidden label (the reason, whose visible separator is a pipe). Putting the word back
 * into the value would render "Logged By: Logged by Avery Chen".
 *
 * ⚠ `notesClass` NO LONGER CARRIES `bbc-value`. That class was the tile's dd; it does not exist
 * in the stylesheet any more, so re-adding it here would be a silent no-op that outlives whoever
 * added it.
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
     * "Broker Selection (0)" is a claim about the SALE — that no broker was ever appointed or
     * replaced — in exactly the words a genuinely empty card uses. On a failed read the card knows
     * nothing about the sale, which is the whole reason `isUnavailable` exists as a state separate
     * from `isEmpty`; leaking a "(0)" into the title would reintroduce the collapse that state was
     * created to prevent, in the one place the state templates below cannot guard.
     *
     * ⚠ RENAMED 2026-08-25, user-instructed: "Broker Replace History" → "Broker Selection". The
     * count and all three states are unchanged. TITLE_BASE is the single source for both branches
     * and for `.js-meta.xml`'s masterLabel — the old code repeated the literal twice and a rename
     * had to hit both. Title history: "Broker Replace History" (2026-08-20) → "Broker Selection"
     * (2026-08-25); the LAYOUT history (row → tile → timeline) is in the class header.
     *
     * ⚠ "Broker Selection" is ALSO a `Disposition__c.Disposition_Stage__c` picklist value and the
     * label of an approval process, both live on this same record page. THIS CARD IS NOT SCOPED TO
     * THAT STAGE and must not be made so: it lists every appointment and replacement ever recorded,
     * including ones written long after the sale left that stage.
     */
    get cardTitle() {
        return this.hasRows || this.isEmpty
            ? `${TITLE_BASE} (${this._rows.length})`
            : TITLE_BASE;
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
            // 🔴 THE ROW SHAPE, READ OFF THE DATA. An outgoing firm exists ⇒ somebody was
            // replaced. No outgoing firm ⇒ this is the sale's FIRST appointment and there was no
            // incumbent — the service writes those rows with blank outgoing columns. Do NOT
            // re-derive this from `reason`: that picklist can be relabelled.
            const isReplacement = !!row.outgoingBrokerFirm;
            return {
                id: row.id,
                changeNumber: row.changeNumber,
                // 🔴 ONE NAME, AND NEVER BLANK — see `brokerNameOf` and UNNAMED_BROKER above.
                brokerName: brokerNameOf(row),
                // Visually hidden, and the trailing COLON is load-bearing: the template compiler
                // discards the whitespace between this span and the name beside it, so the
                // heading's accessible name is the two strings CONCATENATED — without punctuation
                // a screen reader is handed "Replaced brokerJLL".
                brokerLabel: isReplacement
                    ? 'Replaced broker:'
                    : 'Appointed broker:',
                entryDateTime: row.entryDateTime,
                // ⚠ BARE VALUES — the wording lives in the template (see the class header).
                // A line with no value is OMITTED from the markup entirely rather than rendered
                // empty: an absent reason and a blank reason look identical on screen and mean
                // different things, and an empty reason would leave the separating pipe dangling
                // after the timestamp, promising a value that is not there.
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
                    ? 'bbc-notes bbc-notes--clip'
                    : 'bbc-notes'
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
            // The popup has to name WHICH entry the note belongs to, and must name it the same
            // way the entry itself does — hence the SHARED helper rather than a second composed
            // string here. This line used to build its own "{outgoing} → {incoming}" and its own
            // two fallbacks, which is a drift risk that no longer exists.
            subtitle: brokerNameOf(row)
        };
    }

    closeNote() {
        this._note = {};
    }
}
