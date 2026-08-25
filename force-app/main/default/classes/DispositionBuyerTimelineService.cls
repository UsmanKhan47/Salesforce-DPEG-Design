/**
 * Builds the card titled "BUYER ACTIVITY TIMELINE" for one Disposition — a SINGLE CHRONOLOGICAL LIST
 * MERGED FROM TWO SOURCES: buyer-role NDAs (the NDA's number, the broker it names, the two dates of
 * the NDA journey and the duration between them) and Release Materials RESPONSES (what came back
 * after the offering materials went out). Backs `DispositionBuyerTimelineController` ->
 * `c/dispositionBuyerTimeline` (Tranche 2 Workstream D,
 * `agent-output/disposition-tranche-2-requirements.md` §3 D6.3; retargeted 2026-08-21; MERGED
 * 2026-08-24).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE MERGE (2026-08-24) — WHAT CHANGED, AND THE ONE RULE IT RETIRED
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * User decision, 2026-08-24: *"merge both sources into one chronological timeline"*. Two kinds of
 * entry now share one list, newest first, interleaved by date. `TimelineRow.kind` says which kind a
 * row is, and every row carries the timestamp it sorted on.
 *
 *   KIND_NDA       one buyer-role NDA. Sort key = `NDA__c.CreatedDate` — the moment the NDA was
 *                  RAISED, i.e. the moment that entry joined the timeline.
 *   KIND_RESPONSE  one `Release_Materials_Response__c`. Sort key = `Entry_DateTime__c` — when the
 *                  response HAPPENED, which a user may deliberately backdate.
 *
 * 🔴 THE NDA SORT KEY IS `CreatedDate` AND **NOT** THE NDA'S OWN SIGNED / RELEASED DATES. Three
 * reasons, and the third is the one that would bite:
 *   1. Those two fields are `Date`, not `Datetime`. Promoting a Date to a Datetime to compare it
 *      against `Entry_DateTime__c` invents a time of day and makes the merged order TIMEZONE-
 *      DEPENDENT — this repo already carries a measured off-by-one incident from exactly that
 *      conversion, and the whole point of this card is to be right about when things happened.
 *   2. Both are routinely NULL (most rows sit mid-journey), so a key built from them would leave
 *      most NDAs unplaceable.
 *   3. 🔴 A "LATEST ACTIVITY" KEY WOULD MAKE A TILE **MOVE** WHEN SOMEONE BACK-DATES A MATERIALS
 *      DATE. A timeline whose rows re-order on an unrelated edit is not a timeline. `CreatedDate` is
 *      immutable, always present, and is already the ordering the selector applied — so the merge
 *      reuses the card's existing ordering rather than making a new claim about the data.
 * ⚠ `CreatedDate` IS SECOND-GRANULAR, so several NDAs raised in one transaction share a key. The
 * comparator's tie-break is a TOTAL order (see `NewestFirst`); tests that need distinct keys use
 * `Test.setCreatedDate`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE MERGE RETIRED THE "DECLINED PARTIES SORT LAST" RULE. THAT IS DELIBERATE, AND IT IS THE
 *    ONE BEHAVIOUR CHANGE ANY EXISTING USER WILL NOTICE. DO NOT "RESTORE" IT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Until 2026-08-24 this method split the rows in two and appended the declined ones, on the ground
 * that *"a party who walked away is not part of the live sequence"*. **A chronological merge and a
 * status-pinned tail cannot both be true**: pinning declined rows to the end would place an NDA
 * declined yesterday BELOW a response logged last month, in a list whose entire ordering promise is
 * that the newest thing is at the top. The instruction was explicit ("interleave by date, newest
 * first"), so the chronological rule won and the status rule was deleted rather than quietly
 * weakened.
 * 🔴 WHAT SURVIVES, AND IT IS THE PART THAT MATTERED: declined parties are still INCLUDED, still
 * badged `Declined` in readable text, and still carry NO DATES AT ALL. Only their POSITION changed.
 * The audit argument (`NDA__c.allowDelete` is false by D20; hiding them would make this card
 * disagree with the NDAs related list on the same page) is untouched.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ AN NDA ROW'S RENDERED CONTENT IS UNCHANGED BY THE MERGE, BY INSTRUCTION AND BY DESIGN
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Every field an NDA row carried before 2026-08-24 it still carries, under the SAME NAME and with
 * the same contract — the DTO gained fields, it did not reshape. *"A user should see new entries
 * appear, not their existing ones change shape."* The inner class WAS renamed (`NdaRow` ->
 * `TimelineRow`) because it now describes two kinds of row and an inner class has no org-level
 * identity, so the rename is fully compile-checked — the same reason `BuyerRow` -> `NdaRow` was
 * safe on 2026-08-21. The wire keys the component reads are unchanged.
 *
 * ⚠ THE RESPONSE ROWS ARE NOT READ HERE. `ReleaseMaterialsResponseService.getResponses` owns that
 * object's query AND its mapping (including the `No broker recorded` placeholder), and this class
 * calls it. Reading `ReleaseMaterialsResponseSelector` directly from here would give the two cards
 * two copies of the broker-name fallback and let them drift on the value most likely to be null.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THREE NAMES, ALL DIFFERENT, ALL DELIBERATE — READ THIS BEFORE "CORRECTING" ANY OF THEM
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   API NAMES (this class, the controller, the test, the LWC bundle) say  BUYER
 *   THE CARD TITLE ON SCREEN says                        "Buyer Activity timeline" (2026-08-24)
 *   ONE ROW IS                        ONE NDA **OR** ONE RELEASE MATERIALS RESPONSE (2026-08-24)
 *
 * 1. THE API NAMES ARE HISTORICAL AND STAY. DPEG communicates only with the appointed listing
 *    broker; buyers sit behind them and are not tracked (user decision, 2026-08-21), so this card
 *    stopped rendering a buyer identity — but it was NOT renamed. `c/dispositionBuyerTimeline` is
 *    placed by `flexipages/Disposition_Record_Page` and this class is compiled into the org under
 *    this name, so a rename is a FlexiPage edit PLUS a destructive Apex delete: a two-sided deploy
 *    that a check-only validation cannot verify and that leaves a dangling reference if either half
 *    lands alone. Only the USER-VISIBLE strings were changed, which costs nothing and is what
 *    anyone actually reads.
 *    ⚠ Treat every occurrence of "buyer" in an API NAME on this feature as historical. The DTO's
 *    inner class WAS renamed (`BuyerRow` -> `NdaRow`) because an inner class has no org-level
 *    identity of its own and the rename is fully compile-checked.
 *
 * 2. 🔴 THE ROWS ARE NOT GROUPED BY BROKER, AND GROUPING THEM WOULD
 *    DESTROY THE CARD. There is ONE appointed broker per sale, so `brokerName` BELOW IS THE SAME
 *    STRING ON EVERY ROW of a normal disposition. That is the data being true, not duplication to
 *    be cleaned up. The title (user instruction, 2026-08-21; it was briefly "NDA Activity Timeline")
 *    names the party DPEG deals with — it is not a promise of a per-broker rollup. A GROUP BY here
 *    would collapse a three-NDA sale to a single row and delete the timeline the card exists to
 *    show. `buildNdaRow` therefore stays strictly one-row-per-NDA, and the LWC renders the broker as a
 *    per-tile SUBTITLE under the NDA number rather than as the tile heading.
 *
 * 3. The row's identity is the NDA AutoNumber — the only per-row identity always present (a broker
 *    can be null; see the no-backfill note below). The card's intro line and empty state still say
 *    "NDA" for that reason and are correct: they describe the ROWS, the title names the party.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 🔴 THIS TIMELINE MUST NOT READ `NDA__c.NDA_Signed__c`. IT DOES NOT. DO NOT ADD IT. 🔴 🔴
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * That checkbox **LATCHES**. Even after Workstream A3 it is only ever CLEARED on `Declined`; it
 * stays true through `Sent`, and it stayed true FOREVER for any counterparty who walked away before
 * A3 landed. A timeline that read it would show a SIGNED NDA FOR A COUNTERPARTY WHO REFUSED —
 * directly beside the NDAs related list on the same record page, which would say `Declined`. The
 * field is not selected by `NdaSelector.selectBuyerTimelineByDispositionId` and is not referenced
 * anywhere in this class; that is deliberate and is the single most important line in this header.
 *
 * ⚠ AND `Date_Signed__c` ALONE IS NOT SUFFICIENT EITHER — THIS IS THE SHARPER HALF OF THE SAME TRAP,
 * AND IT IS THE ONE A CAREFUL READER IS MOST LIKELY TO GET WRONG. The before-save flow
 * `NDA_Signed_Status_Sync` **NEVER CLEARS `Date_Signed__c`**, by explicit design
 * (`NDA_Path_Disposition`: *"it never clears `Date_Signed__c` — so the historical signature date is
 * retained while the record stops counting as signed"*). A `Signed -> Declined` party therefore
 * keeps a NON-NULL `Date_Signed__c` forever, and "just render the date, it's null if unsigned" would
 * reproduce the exact bug avoiding `NDA_Signed__c` was meant to prevent.
 *
 * 🔴 **THE GATE IS `Status__c = 'Signed'`. `Date_Signed__c` IS ONLY THE VALUE DISPLAYED ONCE THAT
 * GATE PASSES.** Both are used, in that order, in `buildRow` below. Neither substitutes for the
 * other. ⚠ THE 2026-08-21 RETARGET DID NOT TOUCH THIS. It is stated because the retarget deleted a
 * different column and it must be obvious that the signed gate was not part of that deletion.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE "FIRST OFFER" COLUMN AND ITS DURATION WERE DELETED 2026-08-21. DO NOT RE-ADD THEM.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * This class used to take a second query — `DispositionOfferSelector.selectEarliestByBuyerIds` —
 * and join each NDA's BUYER Contact to that buyer's earliest dated offer on the same Disposition.
 * With the buyer gone from `Disposition_Offer__c`'s entry point, **nothing links an offer to a
 * specific NDA any more**, so no attribution this class could make would be true.
 *
 * 🔴 THE TEMPTING SUBSTITUTE IS THE WRONG ANSWER, AND IT IS WORSE THAN THE MISSING COLUMN. The
 * disposition's earliest offer across ALL its NDAs is one query away and would render happily —
 * as the SAME DATE ON EVERY ROW, in a column whose header says "first offer", read by an analyst
 * as a per-row fact. This repo deleted a whole component three weeks ago on exactly that ground:
 * a component rendering a fixed lie is worse than an empty one. The selector method was deleted
 * with the column so the shortcut has no one-liner to reach for.
 * ⚠ IF A PER-NDA OFFER LINK EVER EXISTS (an `NDA__c` lookup on `Disposition_Offer__c`, say), this
 * column can come back — from THAT join, never from a disposition-level aggregate.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DECLINED PARTIES ARE INCLUDED, NEVER HIDDEN — AND THEIR RETAINED DATE IS NEVER SHOWN
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NDA__c.allowDelete` is FALSE on both disposition permission sets by decision D20, so a declined
 * party PERSISTS as audit evidence. Two consequences, both deliberate:
 *   - THEY APPEAR. Hiding them would make this card DISAGREE WITH THE NDAs RELATED LIST SITTING ON
 *     THE SAME PAGE — the analyst would count three NDAs in one component and two in the other,
 *     with nothing to explain the difference.
 *   - THEY CARRY NO DATES AT ALL. Every date and the duration are nulled for a declined row, so the
 *     component renders em-dashes across the board. `Date_Signed__c` is suppressed HERE, in the
 *     service, rather than in the component — a value that must never be displayed should not cross
 *     the `@AuraEnabled` boundary at all, because a future template change cannot then leak it.
 * They sort LAST, after the active parties, mirroring `brokerAssignmentHistory`'s active-first sort.
 * ⚠ THE WORD "Declined" REACHES THE USER AS READABLE TEXT, not as a colour — the component's own
 * header and Jest suite pin that, and `status` below is what feeds it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ ONLY `Party_Role__c = 'Buyer'` ROWS EXIST HERE, AND THE FILTER IS IN THE QUERY — UNCHANGED
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * An `Introducing Broker` NDA is a real and expected row on a disposition and is excluded by
 * `NdaSelector.selectBuyerTimelineByDispositionId`'s own `WHERE` clause, so this class never sees
 * one and does not re-test it.
 * 🔴 THE 2026-08-21 RETARGET DELIBERATELY DID NOT WIDEN THIS. The card stopped labelling rows with
 * a buyer; it did not change WHICH rows it shows. Admitting `Introducing Broker` NDAs would change
 * the count on the card — a behavioural change nobody asked for, and one made hard to notice by
 * the fact that the buyer column is gone. It is one line in the selector if it is ever wanted, and
 * it needs its own decision.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 NEVER RENDER A NEGATIVE DURATION
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `daysToRelease` AND `daysToRespond` (added 2026-08-25) are each null whenever either end of their
 * span is null, AND whenever the arithmetic comes out negative. A negative duration is not a small
 * display defect: "-14 days to release" reads as a data-entry instruction to nobody and as a bug to
 * everyone. Out-of-order dates are REACHABLE without anything being broken — an analyst can back-date
 * `Materials_Released_Date__c` to before the signature, and a broker's `Entry_DateTime__c` can be
 * back-dated to before the release. So the row is not silently blanked either: `hasDateAnomaly` is
 * set, and the component flags it, so the analyst learns their dates disagree instead of just seeing
 * an em-dash. Both durations go through the ONE `span` helper; see its note on the shared flag.
 *
 * 🔴 AND NULL IS NEVER SOFTENED TO `0` ON EITHER. `0` is a REAL answer for both — an NDA signed and
 * released the same day, a broker responding the day materials landed — so a `0` standing in for
 * "no data" would erase the best-case row into the not-yet-started ones. Every null renders as an
 * em-dash; nothing renders as a zero it did not earn.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ A NULL BROKER IS A REACHABLE, NORMAL STATE — AND THERE IS NO BACKFILL
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NDA__c.Broker__c` is a 2026-08-21 field. **Every NDA created before it has a NULL lookup, and no
 * backfill is in scope — that is a decision, not an omission.** So `brokerName` falls back to a
 * fixed placeholder, which is why it is NEVER blank: a blank first column on a tile is
 * indistinguishable from a rendering failure. The row still identifies itself by its NDA NUMBER,
 * which is always present (an AutoNumber), so a broker-less row is still a usable row.
 * ⚠ AND `Broker__r` CAN BE NULL WHILE `Broker__c` IS NOT: `USER_MODE` returns the Id but not the
 * related sObject when the running user cannot see that Contact under SHARING (mode lifts FLS,
 * never sharing). That is a REACHABLE state, not a defensive nicety.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO SOQL and ZERO DML.** Both reads go to
 * selectors — `NdaSelector.selectBuyerTimelineByDispositionId` directly, and
 * `ReleaseMaterialsResponseSelector.selectByDispositionId` through
 * `ReleaseMaterialsResponseService.getResponses`. Both are `WITH USER_MODE`, because a human opened
 * the record page and asked for exactly this. A `QueryException` from either is a REAL PROVISIONING
 * GAP and is deliberately allowed to propagate to the controller, which converts it to a user-safe
 * `AuraHandledException`. **It is NOT swallowed into an empty timeline**: a card that silently
 * renders zero entries on a sale that has three is the "wrong answer, not an error" failure this
 * repo has paid for repeatedly, and it is strictly worse here than a visible error message.
 * 🔴 AND THE TWO READS FAIL TOGETHER, ON PURPOSE. Catching one so the other's rows still render
 * would produce a timeline that is silently HALF a timeline — the shape a reader cannot detect.
 *
 * ── BUDGET ──────────────────────────────────────────────────────────────────────────────────
 * **EXACTLY TWO SOQL AND ZERO DML PER CALL, CONSTANT IN THE NUMBER OF ENTRIES OF EITHER KIND** —
 * one NDA read and one response read. (It was one from 2026-08-21 until the 2026-08-24 merge, and
 * two before that for a different reason.) 🔴 Each broker name is TRAVERSED IN ITS OWN QUERY
 * (`Broker__r.Name`) and must never become a per-row Contact read; that would be SOQL-in-a-loop on
 * a page render. Both halves of the ceiling are ASSERTED, not described.
 * ⚠ This is a read path invoked once per page view, not a trigger path, so
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not attach to THIS class — it attaches
 * in full to the two stamp services and the trigger, which is where those tests live. The falsifier
 * that matters here is the CONSTANT query count across many entries, and it is asserted.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`. Both selector reads are `USER_MODE` on `with sharing` selectors, so a row the
 * running user cannot see simply does not appear — the correct direction for a card a human is
 * reading. (Both objects carry `viewAllRecords = true` on both disposition permission sets, so
 * nothing is scoped away today.) **Do not add a `without sharing` escape**: an under-count here is
 * visible (the related list beside it shows the same scoping) rather than an inverted automated
 * verdict, which is the only shape that has ever justified one in this repo.
 *
 * @see force-app/main/default/classes/DispositionBuyerTimelineController.cls (the thin boundary)
 * @see force-app/main/default/classes/NdaSelector.cls (selectBuyerTimelineByDispositionId)
 * @see force-app/main/default/classes/ReleaseMaterialsResponseService.cls (the second source)
 * @see force-app/main/default/lwc/dispositionBuyerTimeline/dispositionBuyerTimeline.js
 */
public with sharing class DispositionBuyerTimelineService {

    /**
     * The ONLY `NDA__c.Status__c` value that counts as signed for this card.
     *
     * 🔴 IT IS A GATE, NOT A LABEL. See the class header: `Date_Signed__c` survives a
     * `Signed -> Declined` transition, so this string is the only thing standing between the card
     * and a signature date for a party who refused. Must match
     * `objects/NDA__c/fields/Status__c.field-meta.xml`, whose MASTER value set is
     * `Pending / Prepare / Review / Approved / Not Sent / Sent / Received / Signed / Declined`
     * (⚠ this listed six values until 2026-08-24/25; the three pre-send values are Disposition_NDA
     * only, and 'Not Sent' is now legacy-read-only — on no record type. Neither fact touches this
     * gate: 'Signed' is unchanged on both types).
     * ⚠ It matches `NdaSelector.STATUS_SIGNED` and is deliberately NOT shared with it — that one
     * scopes the ACQUISITION expiry-reminder batch and is pinned to a deployed report's filter. Two
     * unrelated decisions that happen to agree; coupling them would let a change to either move the
     * other silently. (A third consumer briefly existed — the Log Offer buyer picker — and was
     * deleted on 2026-08-21 with the buyer.)
     */
    @TestVisible
    private static final String STATUS_SIGNED = 'Signed';

    /**
     * The terminal `NDA__c.Status__c` value that makes a party a TERMINATED row.
     *
     * ⚠ It is tested EXPLICITLY rather than inferred as "not Signed". `Prepare`, `Review`,
     * `Approved`, `Not Sent`, `Sent`, `Received` and `Pending` are all IN-FLIGHT states — the
     * counterparty has not signed YET (2026-08-25: the first three are where a new disposition NDA
     * now LIVES, since the seed moved to 'Prepare'; a blank Status__c on a hand-created NDA is
     * in-flight too, because the record type no longer supplies a default) — and
     * must render as an ordinary active row with an empty signature date, not as a terminated one.
     * Only `Declined` is an ending.
     */
    @TestVisible
    private static final String STATUS_DECLINED = 'Declined';

    /** `TimelineRow.kind` for a buyer-role NDA entry. Matches the LWC's own constant. */
    @TestVisible
    private static final String KIND_NDA = 'NDA';

    /** `TimelineRow.kind` for a Release Materials response entry. Matches the LWC's own constant. */
    @TestVisible
    private static final String KIND_RESPONSE = 'Response';

    /**
     * ONE ENTRY ON THE MERGED TIMELINE — either an NDA or a Release Materials response. A DTO across
     * the `@AuraEnabled` boundary (ARCHITECTURE.md §2): every field is a value the component renders
     * directly, and nothing it must not display ever crosses.
     *
     * ⚠ IT IS A FLAT UNION, NOT TWO NESTED OBJECTS, AND THAT IS THE POINT. Nesting the NDA half
     * under a `nda` property would have renamed every wire key the component already reads
     * (`row.ndaName` -> `row.nda.ndaName`) and reshaped an entry the 2026-08-24 instruction said
     * must not change. Every field below that predates the merge keeps its exact name and contract;
     * the merge ADDED `kind`, `entryDateTime` and the four response fields and touched nothing else.
     * 🔴 READ `kind` BEFORE READING ANYTHING ELSE. The other-kind fields are NULL, not empty — a
     * consumer that renders `ndaName` on a response row renders nothing at all.
     *
     * 🔴 THERE IS NO `ndaSignedRaw` / `rawStatus` / `isSigned` ESCAPE HATCH, DELIBERATELY. A declined
     * party's retained `Date_Signed__c` is suppressed in `buildNdaRow` and never enters this object,
     * so no template change and no future consumer can leak it. That is why the suppression lives in
     * the service rather than in the component's getters.
     *
     * 🔴 THERE IS STILL NO `buyerName` AND NO `firstOfferDate`. Both were removed on 2026-08-21 —
     * the first because buyer identity is not tracked, the second because nothing links an OFFER to
     * a specific NDA. Re-adding either is re-adding a claim the data cannot support.
     *
     * ⚠ `daysToRespond` WAS ALSO REMOVED THAT DAY AND CAME BACK ON 2026-08-25 — READ WHY BEFORE
     * ASSUMING THE REMOVAL WAS SIMPLY REVERSED. The deleted one measured to the first OFFER, and
     * died with `firstOfferDate` for the reason above. This one measures to the first RELEASE
     * MATERIALS RESPONSE, an object that did not exist on this card until the 2026-08-24 merge and
     * that IS linked to the sale. The old objection therefore does not reach it.
     * 🔴 BUT IT IS A SALE-LEVEL NUMBER RENDERED ON A PER-NDA TILE, AND THAT IS THE HONEST LIMIT OF
     * IT. `Release_Materials_Response__c` carries `Disposition__c` and `Broker__c` — there is NO NDA
     * lookup — so the earliest response cannot be attributed to one NDA, and the value is
     * deliberately the SAME on every tile whose released date matches (which is normally all of
     * them, because `DispositionStageEntryService` stamps them in one pass). It is a fact about the
     * SALE shown in the NDA's context, not a fact about that NDA. Do not "improve" it by picking the
     * response whose `Broker__c` matches the NDA's `Broker__c`: most NDAs carry a NULL broker (a
     * 2026-08-21 field with no backfill), so that version would silently render blank on the
     * majority of rows — worse than a repeated-but-true number.
     */
    public class TimelineRow {

        /**
         * `KIND_NDA` or `KIND_RESPONSE`. NEVER null — the component branches on it, and an
         * unrecognised value must be impossible rather than merely unlikely.
         */
        @AuraEnabled
        public String kind;

        /**
         * THE VALUE THIS ROW SORTED ON, and the one the component displays on a RESPONSE row.
         *
         * NDA rows       -> `NDA__c.CreatedDate`. Always non-null (a system audit field).
         * Response rows  -> `Release_Materials_Response__c.Entry_DateTime__c`. CAN be null — the
         *                   field defaults to `NOW()` but is not `required`, so an API or
         *                   data-loader row may carry none. Such a row sorts LAST; see `NewestFirst`.
         *
         * ⚠ IT IS EXPOSED RATHER THAN CONSUMED-AND-DISCARDED so the ordering is FALSIFIABLE from
         * the client as well as from Apex: a Jest test can assert the rendered order matches the
         * timestamps it was given, instead of trusting that the server sorted.
         */
        @AuraEnabled
        public Datetime entryDateTime;

        /**
         * The broker's display name — the ONE field both kinds populate, and the reason it sits
         * here rather than in either half. Never null and never blank on either kind: both
         * builders fall back to a fixed placeholder. See `resolveBrokerName`.
         */
        @AuraEnabled
        public String brokerName;

        // ── NDA HALF. All null on a response row. ────────────────────────────────────────────

        /** The NDA row's Id — the component's `for:each` key and its record link target. */
        @AuraEnabled
        public Id ndaId;

        /**
         * `NDA__c.Name` — the `NDA-{0000}` AutoNumber. THE ROW'S IDENTITY, and the one value on this
         * DTO that is guaranteed non-blank by the platform rather than by this class.
         */
        @AuraEnabled
        public String ndaName;

        /** Raw `Status__c`, for the component's accessible state text. Never a display date. */
        @AuraEnabled
        public String status;

        /** True when `Status__c = 'Declined'`. Drives the terminated row treatment AND the sort. */
        @AuraEnabled
        public Boolean isDeclined;

        /**
         * `Date_Signed__c`, **and only when `Status__c = 'Signed'`**. Null on every other status,
         * including a declined party who retains a real date. See the class header.
         */
        @AuraEnabled
        public Date ndaSignedDate;

        /** `Materials_Released_Date__c`. Null is normal — the analyst may not have released yet. */
        @AuraEnabled
        public Date materialsReleasedDate;

        /** `materialsReleasedDate - ndaSignedDate`. Null if either end is null OR if negative. */
        @AuraEnabled
        public Integer daysToRelease;

        /**
         * Whole days from `materialsReleasedDate` to the EARLIEST
         * `Release_Materials_Response__c.Entry_DateTime__c` on the same Disposition — i.e. how long
         * the market took to come back once the materials went out. Null if either end is null OR if
         * negative, exactly like `daysToRelease`.
         *
         * 🔴 NULL IS THE ONLY CORRECT VALUE FOR "NOT RELEASED YET" AND FOR "NOBODY HAS RESPONDED
         * YET", AND IT IS NEVER `0`. Zero is a REAL and reachable answer here — a broker responding
         * the same day the materials landed is the best possible outcome, and it is exactly the row
         * an analyst most wants to see. A `0` standing in for "no data" would make that row
         * indistinguishable from silence.
         *
         * ⚠ THE SAME NUMBER ON EVERY TILE IS THE EXPECTED RENDERING, NOT A BUG — see the DTO header.
         */
        @AuraEnabled
        public Integer daysToRespond;

        /**
         * True when the duration was suppressed because the arithmetic went NEGATIVE — i.e. the
         * dates on this row are out of order. Deliberately NOT set merely because a date is missing:
         * a blank materials date is normal and flagging it would cry wolf on most rows.
         */
        @AuraEnabled
        public Boolean hasDateAnomaly;

        // ── RESPONSE HALF (2026-08-24). All null on an NDA row. ──────────────────────────────

        /** The response row's Id — the component's `for:each` key and its record link target. */
        @AuraEnabled
        public Id responseId;

        /** `Name` — the `RMR-{0000}` AutoNumber. The response row's identity, always present. */
        @AuraEnabled
        public String responseName;

        /**
         * `Method__c`: `More questions`, `Decision` or `Offer`. Rendered as the visible badge TEXT
         * on a response tile, never as a colour alone — the same accessibility rule the `Declined`
         * badge follows.
         */
        @AuraEnabled
        public String method;

        /** `Notes__c`, or null when none was entered. Notes are optional on a response. */
        @AuraEnabled
        public String notes;
    }

    /**
     * Rendered when an NDA carries no broker Contact. See the class header — no backfill exists.
     *
     * ⚠ IT IS BYTE-IDENTICAL TO `ReleaseMaterialsResponseService.NO_BROKER` AND IS DELIBERATELY NOT
     * SHARED WITH IT. The two placeholders appear as tiles in ONE merged list, so they must AGREE —
     * two different strings for the same absence read as two different states — but coupling them
     * would let a change to either card's wording move the other silently. The merged card's Jest
     * suite asserts both tiles render the same string, which is the falsifier that keeps them honest
     * without the coupling.
     */
    @TestVisible
    private static final String NO_BROKER = 'No broker recorded';

    /**
     * The MERGED timeline for one Disposition — NDA entries and Release Materials responses in ONE
     * chronological list, NEWEST FIRST.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition with neither a buyer NDA nor a response,
     * returns an EMPTY LIST rather than null. "Nothing has happened yet" is a completely normal
     * early state that the component renders as an empty state; it must not be an exception and must
     * not be a null the caller has to guard.
     * ⚠ NEITHER SOURCE SHORT-CIRCUITS THE OTHER. Both reads always run: a sale can carry logged
     * responses with no buyer NDA on it at all, and the pre-merge `if (ndas.isEmpty()) return rows;`
     * would have rendered that sale's timeline as EMPTY. That line was DELETED, not moved.
     *
     * ── ⚠ THE SORT IS DONE **HERE**, NOT IN THE COMPONENT, AND THAT IS A CHOICE ─────────────────
     * `brokerAssignmentHistory` sorts in JavaScript. This one sorts in Apex because the ordering is
     * a STATEMENT ABOUT THE DATA (one chronology across two objects), not a presentation preference,
     * because an Apex sort is falsifiable by an Apex test that also has the records in front of it,
     * and because merging on the client would mean the client knowing which timestamp belongs to
     * which kind. The component preserves server order and does not re-sort;
     * `dispositionBuyerTimeline.js`'s header says so, so the two cannot start disagreeing.
     *
     * 🔴 THE OLD "ACTIVE FIRST, DECLINED LAST" TWO-PASS SPLIT IS GONE — the class header records why
     * a chronological merge and a status-pinned tail cannot both be true. Its replacement is a
     * single TOTAL-ORDER comparator over the combined list.
     *
     * @param dispositionId The Disposition whose activity to build; null-safe.
     * @return One row per buyer-role NDA plus one per logged response, NEWEST FIRST; empty when the
     *         input is null or the sale has neither. Never null.
     * @throws System.QueryException when the running user lacks read on `NDA__c`, on
     *         `Release_Materials_Response__c`, on `Contact`, or on any selected custom field.
     *         Deliberately allowed to propagate — see the class header's layering note.
     * @example
     * List&lt;DispositionBuyerTimelineService.TimelineRow&gt; rows =
     *     DispositionBuyerTimelineService.getTimeline(dispositionId);
     */
    public static List<TimelineRow> getTimeline(Id dispositionId) {
        List<TimelineRow> rows = new List<TimelineRow>();
        if (dispositionId == null) {
            return rows;
        }

        // ── SOURCE 1. Release Materials responses, through the SERVICE that owns that object's
        // query and its mapping — never through its selector directly. See the class header.
        // ⚠ THIS READ MOVED AHEAD OF THE NDA READ ON 2026-08-25 AND THE REASON IS `daysToRespond`,
        // NOT PREFERENCE. That column measures to the earliest response on the sale, so the NDA rows
        // cannot be built until this list is in hand. The QUERY COUNT IS UNCHANGED (still exactly
        // two, still constant in the number of entries) and the merged ORDER is unaffected — the
        // comparator below imposes a TOTAL order, so the sequence rows are appended in is not
        // load-bearing. 🔴 BOTH READS STILL ALWAYS RUN AND NEITHER SHORT-CIRCUITS THE OTHER; the
        // class header's rule survives the swap, and there is no `return` between them.
        List<ReleaseMaterialsResponseService.ResponseRow> responses =
            ReleaseMaterialsResponseService.getResponses(dispositionId);

        // Null when nobody has responded yet — a normal early state, NOT an error and NOT a zero.
        Date firstResponseDate = earliestResponseDate(responses);

        // ── SOURCE 2. Buyer-role NDAs only; `Party_Role__c` is filtered in the selector, and the
        // broker's name is TRAVERSED in that query rather than resolved by a second read.
        for (NDA__c nda : NdaSelector.selectBuyerTimelineByDispositionId(dispositionId)) {
            rows.add(buildNdaRow(nda, firstResponseDate));
        }

        for (ReleaseMaterialsResponseService.ResponseRow response : responses) {
            rows.add(buildResponseRow(response));
        }

        // ONE chronology across both kinds. A TOTAL order, so the result does not depend on
        // `List.sort` being stable — which is not documented and must not be assumed.
        rows.sort(new NewestFirst());
        return rows;
    }

    /**
     * Newest first across both kinds, with a TOTAL order so the result is deterministic.
     *
     * 🔴 IT IS A TOTAL ORDER ON PURPOSE. `List.sort(Comparator)` is not documented as stable, and
     * `NDA__c.CreatedDate` is SECOND-granular — several NDAs raised in one transaction (routine in a
     * test, reachable in a bulk load) share a key exactly. Without the tie-break their rendered
     * order would be free to change between two renders of the same unchanged data, which on a
     * timeline reads as the data having changed.
     *
     * ⚠ AN UNDATED ROW SINKS TO THE BOTTOM RATHER THAN FLOATING TO THE TOP.
     * `Entry_DateTime__c` defaults to `NOW()` but is NOT `required`, so an API or data-loader row
     * can carry null. The platform's default for a `DESC` sort is NULLS FIRST, which would put a row
     * claiming no time at all above every row that does — the exact opposite of what "newest first"
     * means. (`ReleaseMaterialsResponseSelector` makes the same choice in SOQL for the same reason;
     * this comparator is what enforces it once the two lists are combined.)
     *
     * ⚠ THE TIE-BREAK IS THE ROW'S OWN 18-CHARACTER Id, DESCENDING. Ids are unique across both
     * objects, so the order is total; the direction between two rows that genuinely share an instant
     * is arbitrary, and it is FIXED, which is the only property that matters.
     */
    private class NewestFirst implements Comparator<TimelineRow> {
        public Integer compare(TimelineRow a, TimelineRow b) {
            if (a.entryDateTime == b.entryDateTime) {
                return rowKey(b).compareTo(rowKey(a));
            }
            if (a.entryDateTime == null) {
                return 1;
            }
            if (b.entryDateTime == null) {
                return -1;
            }
            return a.entryDateTime > b.entryDateTime ? -1 : 1;
        }
    }

    /**
     * The row's own record Id as a String — the comparator's tie-break key.
     *
     * @param row Either kind of row; exactly one of the two Ids is populated.
     * @return The 18-character Id.
     */
    private static String rowKey(TimelineRow row) {
        return String.valueOf(row.ndaId == null ? row.responseId : row.ndaId);
    }

    /**
     * The EARLIEST `Entry_DateTime__c` across every response on the sale, as a Date. Pure: no SOQL.
     *
     * 🔴 IT SCANS FOR A MINIMUM AND DOES **NOT** READ `responses[size - 1]`. The selector returns
     * these `Entry_DateTime__c DESC`, so the last element is the earliest TODAY and the index would
     * work — which is exactly what makes it dangerous. That ordering is a decision owned by
     * `ReleaseMaterialsResponseSelector`, made for the CARD's benefit (newest first), and nothing
     * anywhere tells that selector its ORDER BY is load-bearing for an arithmetic column in a
     * different class. A re-sort there would silently turn this into "days to the LATEST response" —
     * a wrong number, not an error. The scan costs one pass over a handful of rows and cannot be
     * broken from another file.
     *
     * ⚠ A NULL `Entry_DateTime__c` IS SKIPPED, NOT TREATED AS EARLIEST. The field defaults to
     * `NOW()` but is not `required`, so a data-loader row can carry none (the class header and
     * `NewestFirst` both already handle this). A row claiming no time at all must not become the
     * start of the clock — that would report a span to an instant nobody recorded.
     *
     * ⚠ `Datetime.date()` CONVERTS IN THE RUNNING USER'S TIMEZONE, which is deliberate: the value is
     * compared against `Materials_Released_Date__c`, a plain `Date` that every user sees the same,
     * and the response's own timestamp is already rendered on its tile in the viewer's timezone. So
     * the subtraction agrees with what is on screen. It does mean two users in different timezones
     * can see a duration differing by one day on a response logged near midnight — the same
     * documented trade-off `formatDate` in the component already carries.
     *
     * @param responses Every response on the sale, in any order; null-safe and empty-safe.
     * @return The earliest response's date, or null when there are none (or none carries a time).
     */
    private static Date earliestResponseDate(
            List<ReleaseMaterialsResponseService.ResponseRow> responses) {
        if (responses == null || responses.isEmpty()) {
            return null;
        }
        Datetime earliest = null;
        for (ReleaseMaterialsResponseService.ResponseRow response : responses) {
            if (response.entryDateTime == null) {
                continue;
            }
            if (earliest == null || response.entryDateTime < earliest) {
                earliest = response.entryDateTime;
            }
        }
        return earliest == null ? null : earliest.date();
    }

    /**
     * One Release Materials response -> one row. Pure: no SOQL, no DML, no state.
     *
     * ⚠ IT MAPS AN ALREADY-BUILT DTO RATHER THAN A QUERIED SOBJECT, which is what keeps the broker
     * placeholder and the null-notes contract owned by `ReleaseMaterialsResponseService`. The only
     * things this method decides are the row's KIND and its SORT KEY.
     *
     * @param response A response row from `ReleaseMaterialsResponseService.getResponses`.
     * @return The timeline row. Never null; every NDA-half field is left null.
     */
    private static TimelineRow buildResponseRow(
            ReleaseMaterialsResponseService.ResponseRow response) {
        TimelineRow row = new TimelineRow();
        row.kind = KIND_RESPONSE;
        row.entryDateTime = response.entryDateTime;
        row.brokerName = response.brokerName;
        row.responseId = response.responseId;
        row.responseName = response.responseName;
        row.method = response.method;
        row.notes = response.notes;
        return row;
    }

    /**
     * One NDA -> one row. Pure: no SOQL, no DML, no state.
     *
     * 🔴 THE ORDER OF THE TWO SIGNED TESTS IS THE WHOLE POINT. `Status__c` is the GATE and
     * `Date_Signed__c` is the VALUE. Reversing them — reading the date and then deciding whether to
     * show it — is the same code with the same output today and is one careless edit away from
     * leaking a declined party's retained signature date.
     *
     * ⚠ RENAMED FROM `buildRow` ON 2026-08-24. There are two builders now, and a bare `buildRow`
     * sitting beside `buildResponseRow` would read as the generic one.
     *
     * @param nda               A buyer-role NDA with the timeline fields populated.
     * @param firstResponseDate The earliest response date on the SALE (see `earliestResponseDate`),
     *                          or null when nobody has responded yet. Passed IN rather than queried
     *                          here — this method stays pure, and the read stays in `getTimeline`.
     * @return The row. Never null; every response-half field is left null.
     */
    private static TimelineRow buildNdaRow(NDA__c nda, Date firstResponseDate) {
        TimelineRow row = new TimelineRow();
        row.kind = KIND_NDA;
        // 🔴 THE SORT KEY IS `CreatedDate`, NOT EITHER OF THE NDA'S OWN DATES. The three reasons are
        // in the class header, and the third — a tile that MOVES when a materials date is back-dated
        // — is what makes the obvious alternative wrong rather than merely awkward.
        row.entryDateTime = nda.CreatedDate;
        row.ndaId = nda.Id;
        row.ndaName = nda.Name;
        row.status = nda.Status__c;
        row.isDeclined = STATUS_DECLINED.equals(nda.Status__c);
        row.brokerName = resolveBrokerName(nda);
        row.hasDateAnomaly = false;

        // ── DECLINED: NO DATES AT ALL, AND THE RETAINED `Date_Signed__c` NEVER LEAVES THIS METHOD.
        // Returning early is what guarantees it: there is no path below this line that could set a
        // date on a declined row, however the arithmetic is later changed.
        if (row.isDeclined) {
            return row;
        }

        // 🔴 GATE FIRST. `Status__c` decides; `Date_Signed__c` is only then read.
        if (STATUS_SIGNED.equals(nda.Status__c)) {
            row.ndaSignedDate = nda.Date_Signed__c;
        }
        row.materialsReleasedDate = nda.Materials_Released_Date__c;

        row.daysToRelease = span(row.ndaSignedDate, row.materialsReleasedDate, row);

        // ── HOW LONG THE MARKET TOOK TO COME BACK. Both ends can be null independently — materials
        // not released yet, or released with nobody responding yet — and `span` returns null for
        // either, which the component renders as an em-dash. A same-day response yields 0, a real
        // answer that must survive: see the DTO field's note on why 0 is never a stand-in for null.
        row.daysToRespond = span(row.materialsReleasedDate, firstResponseDate, row);
        return row;
    }

    /**
     * Whole days from `fromDate` to `toDate`, or NULL when the span cannot be stated truthfully.
     *
     * Two null outcomes with two different meanings, both rendered as an em-dash by the component
     * but only one of them flagged:
     *   EITHER END NULL -> null, NOT flagged. Normal and expected — most rows sit mid-journey.
     *   NEGATIVE        -> null, AND `hasDateAnomaly` set on the row. The dates contradict each
     *                      other, which the analyst needs to know about, and which no amount of
     *                      staring at two em-dashes would tell them.
     *
     * ⚠ `Date.daysBetween` IS THE RIGHT PRIMITIVE AND SUBTRACTION IS NOT. `Date` arithmetic in Apex
     * has no `-` operator, and `getTime()` differencing would introduce a millisecond/timezone
     * dependency into a pure-Date calculation. `daysBetween` is signed, which is precisely why the
     * negative test below is needed and is not defensive decoration.
     *
     * ⚠ IT IS BACK TO TWO CALLERS (it had two until 2026-08-21, then one, then two again from
     * 2026-08-25's `daysToRespond`). The reason it was KEPT as a helper at one caller was that
     * inlining it would put the negative-suppression rule and the anomaly flag inside the builder's
     * happy path, "where the next date column added would be written without them" — and the next
     * date column duly arrived. It is reused verbatim rather than copied.
     *
     * 🔴 SO `hasDateAnomaly` IS NOW SET BY EITHER SPAN, AND ITS MEANING WIDENED ACCORDINGLY: it says
     * "some pair of dates on this row is out of order", not specifically "signed after released".
     * That is correct for its only consumer — the component renders ONE anomaly badge per tile, and
     * a second, differently-worded badge for the second pair would be noise. A response logged
     * BEFORE the materials release is exactly as reachable as a back-dated release date (the
     * response's `Entry_DateTime__c` is user-editable) and deserves the same visible flag rather
     * than a silent em-dash.
     *
     * @param fromDate The earlier end; null-safe.
     * @param toDate   The later end; null-safe.
     * @param row      The row being built — mutated ONLY to set `hasDateAnomaly`.
     * @return Whole days, or null.
     */
    private static Integer span(Date fromDate, Date toDate, TimelineRow row) {
        if (fromDate == null || toDate == null) {
            return null;
        }
        Integer days = fromDate.daysBetween(toDate);
        if (days < 0) {
            // 🔴 NEVER RENDER A NEGATIVE DURATION. Suppress the number, raise the flag.
            row.hasDateAnomaly = true;
            return null;
        }
        return days;
    }

    /**
     * The broker's display name: the linked Contact, else a fixed placeholder.
     *
     * ⚠ `String.isNotBlank` RATHER THAN A NULL CHECK. `Broker__r` can come back null even when
     * `Broker__c` is set — `USER_MODE` lifts FLS, never sharing — so both halves are reachable.
     * 🔴 IT NEVER RETURNS BLANK. A blank cell here reads as a rendering failure rather than as
     * missing data, and the placeholder is what tells the analyst the NDA has no broker on it yet.
     *
     * @param nda The NDA, with `Broker__r` resolved when `Broker__c` is set and visible.
     * @return A non-blank display name. Never null.
     */
    private static String resolveBrokerName(NDA__c nda) {
        if (nda.Broker__c != null && nda.Broker__r != null && String.isNotBlank(nda.Broker__r.Name)) {
            return nda.Broker__r.Name;
        }
        return NO_BROKER;
    }
}
