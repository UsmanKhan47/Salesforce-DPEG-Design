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
    'Broker selection is unavailable right now.';

/**
 * The empty state's sentence. ⚠ CHANGED 2026-08-25 from "No broker changes recorded", and the
 * change is the POINT of that day's rework rather than a tidy-up: the card now renders the current
 * selection as well as the change log, so it is only empty when NEITHER exists, and the old
 * sentence answered a question nobody asked ("were there changes?") on a card titled "Broker
 * Selection". A user reading that title literally saw "(0) — No broker changes recorded" on a sale
 * whose broker had been selected and simply never replaced.
 */
const EMPTY_TEXT = 'No broker selected yet';

/**
 * 🔴 A SELECTED ROW'S NAME FALLBACK, AND IT IS DELIBERATELY *NOT* `UNNAMED_BROKER` BELOW.
 * `Contact_Name__c` and `Broker_Firm__c` are both stamped from `Broker__c` and both nullable, so a
 * Selected row can name nobody. The two fallbacks differ because the two rows differ: a change row
 * is an AUDIT ENTRY whose broker column was never filled in ("Broker not recorded" — a statement
 * about the LOG), while a selected row is a broker who holds a slot RIGHT NOW and whose name is
 * merely missing ("Unnamed broker" — a statement about the BROKER). Saying "not recorded" of a
 * currently-appointed broker would read as though the appointment itself were in doubt.
 */
const UNNAMED_SELECTED = 'Unnamed broker';

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
 * c-bov-broker-change-history — the "Broker Selection" card: who is selected on this disposition
 * RIGHT NOW, then every broker replacement recorded against it, newest first (2026-08-20, Tranche 2
 * Workstream B / design D4.6).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 TWO SECTIONS IN ONE TIMELINE SINCE 2026-08-25 — CURRENT SELECTION FIRST, THEN THE LOG
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * THE DEFECT THIS FIXES, IN THE USER'S OWN TERMS: the card is titled "Broker Selection" (renamed
 * 2026-08-25, see `cardTitle`) and listed only `BOV_Broker_Change__c` rows — REPLACEMENTS. On a
 * sale where a broker HAD been selected but never replaced, it therefore read "(0) — No broker
 * changes recorded", i.e. it denied the existence of the thing its own title names. The current
 * selection was never in the payload at all.
 *
 * The wire now returns `{ selected, changes }` and the card renders both, IN ONE `<ul>`:
 *   • `selected` — up to TWO rows, because a disposition has TWO SELECTION SLOTS (the preferred
 *     broker and the score-selected one — `BovAutoSelectionService`'s "TWO SLOTS, NOT ONE"). Server
 *     order is preferred first; see `selectedRows` for the per-row shape.
 *   • `changes`  — the replacement log, UNCHANGED in data, markup and behaviour.
 *
 * 🔴 ONE LIST, NOT TWO, AND THAT IS LOAD-BEARING FOR THE RAIL. The dot-and-line rail is drawn by
 * `.bbc-entry:last-child .bbc-track { display: none }` — a single CSS rule that ends the line on
 * the last dot. Two sibling `<ul>`s would each have their own last child, so the rail would stop
 * and restart between the sections and read as two unrelated cards stacked inside one. One list
 * also means one `role="list"` and one accurate item count for a screen reader.
 *
 * ⚠ THE SELECTED ENTRIES USE THE SAME MARKUP AND THE SAME CLASSES as the change entries, by
 * instruction: same rail, same `.bbc-tile-head` headline, same `.bbc-facts` stack, same
 * `.bbc-meta` line register. No badge and no accent colour distinguishes them — consistent with
 * this card's standing decision (see the appointment/replacement note further down) that the
 * distinction is carried by VISIBLE TEXT plus an assistive label, not by new furniture.
 *
 * ── 🔴 REFRESH: THERE IS NONE, AND THAT IS A FINDING RATHER THAN AN OMISSION ────────────────
 * The card is driven ENTIRELY by its cacheable `@wire(getHistory, { dispositionId: '$recordId' })`.
 * When a selection changes elsewhere on the page it does NOT update until the page is reloaded.
 * ⚠ THIS WAS CHECKED BEFORE IT WAS ACCEPTED (2026-08-25, grep across `lwc/`): the repo has NO
 * message channel and no `lightning/messageService` consumer anywhere, so there is no bus to
 * subscribe to. `c/bovBrokerPanel` calls `refreshApex` on ITS OWN wire result only — a private
 * refresh that cannot reach this component — and `c/brokerReplaceQuickAction` calls
 * `notifyRecordUpdateAvailable`, which invalidates the LDS RECORD cache and does nothing at all to
 * a cacheable APEX wire. Inventing a `bovselectionchanged` DOM event here would be half a bus:
 * DOM events do not cross sibling components on a FlexiPage, so it would be dead code that looks
 * like a feature. If live refresh is wanted, the right change is a real Lightning Message Channel
 * published by every writer (Replace Broker, Add Preferred Broker, auto-selection's client) —
 * a cross-component piece of work, not a change to this file.
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

    /** `HistoryView.changes` — the replacement log, newest first, exactly as the server ordered it. */
    _rows = [];
    /** `HistoryView.selected` — the current selection, preferred slot first. Up to two rows. */
    _selected = [];
    _loaded = false;
    _failed = false;

    @wire(getHistory, { dispositionId: '$recordId' })
    wiredHistory({ data, error }) {
        if (data) {
            // ⚠ BOTH HALVES ARE DEFAULTED. Apex instantiates both lists and never returns null for
            // either, but this getter feeds a `for:each` and a `.length` in the title — the two
            // places where an unexpected undefined stops being invisible and becomes a render
            // error on a card the user did not ask to interact with.
            this._selected = data.selected || [];
            this._rows = data.changes || [];
            this._failed = false;
            this._loaded = true;
        } else if (error) {
            // The Apex message is deliberately ignored: BovBrokerChangeController already replaced
            // every underlying failure with one fixed generic sentence, and re-surfacing it here
            // would put "contact your administrator" on a card the user did not ask to interact
            // with. The muted line says what the user needs — this panel is not showing you
            // everything — without dressing a secondary card up as an incident.
            this._rows = [];
            this._selected = [];
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
     *
     * 🔴 THE COUNT IS A SUM OVER BOTH SECTIONS SINCE 2026-08-25 — selected rows PLUS change rows,
     * which is simply the number of entries rendered below it. A count of one half would be a
     * number that disagrees with what the user can see, and on the exact sale that produced this
     * rework (one selection, no replacements) the old count read "(0)" beside a visible entry.
     * ⚠ This is also why the count cannot be moved back onto `this._rows.length` as a
     * "simplification": that expression is now the CHANGE count, not the entry count.
     */
    get cardTitle() {
        return this.hasRows || this.isEmpty
            ? `${TITLE_BASE} (${this._entryCount})`
            : TITLE_BASE;
    }

    /** Entries rendered in the timeline: the current selection plus the change log. */
    get _entryCount() {
        return this._selected.length + this._rows.length;
    }

    /** True only once the wire has actually answered, which is what keeps the empty state honest. */
    get hasRows() {
        return this._loaded && !this._failed && this._entryCount > 0;
    }
    /**
     * 🔴 EMPTY MEANS *BOTH* HALVES ARE EMPTY. A sale with a selected broker and no replacements is
     * the single most common populated shape there is, and it is exactly what the pre-2026-08-25
     * card mis-rendered as empty. Testing one list here would restore that defect.
     */
    get isEmpty() {
        return this._loaded && !this._failed && this._entryCount === 0;
    }
    get isUnavailable() {
        return this._loaded && this._failed;
    }
    get unavailableText() {
        return UNAVAILABLE;
    }
    get emptyText() {
        return EMPTY_TEXT;
    }

    /**
     * THE CURRENT SELECTION, one entry per occupied slot, in the server's order (preferred first).
     *
     * ⚠ NOT RE-SORTED HERE, for the same reason `historyRows` is not: the order is
     * `BovSubmissionSelector.selectSelectedSlotsByDispositionId`'s `ORDER BY`, which is deliberately
     * identical to the clause `DispositionApprovalService` submits on. A client-side sort would be a
     * second, weaker copy of it (JS cannot see the `BOV_Score__c` / `CreatedDate` tie-breaks the
     * query applies) and would let the card disagree with Submit for Approval about which of two
     * Selected brokers comes first.
     *
     * ⚠ `basis` IS RENDERED VERBATIM AND IS NOT RE-MAPPED HERE. The four phrases are composed once,
     * in `BovBrokerChangeController.basisOf`, together with the precedence rule that chooses between
     * them — a second mapping in JS would be a second place for that rule to live and drift. This
     * getter's only jobs are the NAME FALLBACK CHAIN and the has-a-value flags the template needs.
     */
    get selectedRows() {
        return this._selected.map((row) => ({
            id: row.id,
            // 🔴 NAME → FIRM → A WORD. Both server columns are nullable (see UNNAMED_SELECTED), and
            // a currently-appointed broker must never render as a blank line or "undefined".
            brokerName: row.brokerName || row.brokerFirm || UNNAMED_SELECTED,
            // ⚠ SUPPRESSED WHEN IT IS THE HEADLINE. If the name fell back TO the firm, repeating the
            // firm on the line below would print the same string twice and imply two facts where
            // there is one.
            hasFirm: !!row.brokerFirm && !!row.brokerName,
            firm: row.brokerFirm || '',
            basis: row.basis || '',
            selectedDateTime: row.selectedDateTime
        }));
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
