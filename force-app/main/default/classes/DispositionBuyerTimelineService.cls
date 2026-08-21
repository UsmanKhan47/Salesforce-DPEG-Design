/**
 * Builds the card titled "BROKER ACTIVITY TIMELINE" for one Disposition — one row per buyer-role NDA, carrying the
 * NDA's number, the broker it names, the two dates of the NDA journey (signed -> materials
 * released) and the duration between them. Backs `DispositionBuyerTimelineController` ->
 * `c/dispositionBuyerTimeline` (Tranche 2 Workstream D,
 * `agent-output/disposition-tranche-2-requirements.md` §3 D6.3; retargeted 2026-08-21).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THREE NAMES, ALL DIFFERENT, ALL DELIBERATE — READ THIS BEFORE "CORRECTING" ANY OF THEM
 * ══════════════════════════════════════════════════════════════════════════════════════════
 *   API NAMES (this class, the controller, the test, the LWC bundle) say  BUYER
 *   THE CARD TITLE ON SCREEN says                        "Broker Activity Timeline"
 *   ONE ROW IS                                            ONE NDA
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
 * 2. 🔴 THE TITLE SAYS "BROKER"; THE ROWS ARE NOT GROUPED BY BROKER, AND GROUPING THEM WOULD
 *    DESTROY THE CARD. There is ONE appointed broker per sale, so `brokerName` BELOW IS THE SAME
 *    STRING ON EVERY ROW of a normal disposition. That is the data being true, not duplication to
 *    be cleaned up. The title (user instruction, 2026-08-21; it was briefly "NDA Activity Timeline")
 *    names the party DPEG deals with — it is not a promise of a per-broker rollup. A GROUP BY here
 *    would collapse a three-NDA sale to a single row and delete the timeline the card exists to
 *    show. `buildRow` therefore stays strictly one-row-per-NDA, and the LWC renders the broker as a
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
 * `daysToRelease` is null whenever either end of the span is null, AND whenever the arithmetic comes
 * out negative. A negative duration is not a small display defect: "-14 days to release" reads as a
 * data-entry instruction to nobody and as a bug to everyone. Out-of-order dates are REACHABLE
 * without anything being broken — an analyst can back-date `Materials_Released_Date__c` to before
 * the signature. So the row is not silently blanked either: `hasDateAnomaly` is set, and the
 * component flags it, so the analyst learns their dates disagree instead of just seeing an em-dash.
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
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO SOQL and ZERO DML.** The one read goes to a
 * selector — `NdaSelector.selectBuyerTimelineByDispositionId`, `WITH USER_MODE`, because a human
 * opened the record page and asked for exactly this. A `QueryException` from it is a REAL
 * PROVISIONING GAP and is deliberately allowed to propagate to the controller, which converts it to
 * a user-safe `AuraHandledException`. **It is NOT swallowed into an empty timeline**: a card that
 * silently renders zero NDAs on a sale that has three is the "wrong answer, not an error" failure
 * this repo has paid for repeatedly, and it is strictly worse here than a visible error message.
 *
 * ── BUDGET ──────────────────────────────────────────────────────────────────────────────────
 * **EXACTLY ONE SOQL AND ZERO DML PER CALL, CONSTANT IN THE NUMBER OF NDAs** — it was two until
 * 2026-08-21, when the offer read went with the first-offer column. 🔴 The broker name is
 * TRAVERSED IN THE SAME QUERY (`Broker__r.Name`) and must never become a second Contact read, per
 * NDA or otherwise; that would be SOQL-in-a-loop on a page render.
 * ⚠ This is a read path invoked once per page view, not a trigger path, so
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not attach to THIS class — it attaches
 * in full to the two stamp services and the trigger, which is where those tests live. The falsifier
 * that matters here is the CONSTANT query count across many NDAs, and it is asserted.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`. The selector read is `USER_MODE` on a `with sharing` selector, so a row the
 * running user cannot see simply does not appear — the correct direction for a card a human is
 * reading. **Do not add a `without sharing` escape**: an under-count here is visible (the related
 * list beside it shows the same scoping) rather than an inverted automated verdict, which is the
 * only shape that has ever justified one in this repo.
 *
 * @see force-app/main/default/classes/DispositionBuyerTimelineController.cls (the thin boundary)
 * @see force-app/main/default/classes/NdaSelector.cls (selectBuyerTimelineByDispositionId)
 * @see force-app/main/default/lwc/dispositionBuyerTimeline/dispositionBuyerTimeline.js
 */
public with sharing class DispositionBuyerTimelineService {

    /**
     * The ONLY `NDA__c.Status__c` value that counts as signed for this card.
     *
     * 🔴 IT IS A GATE, NOT A LABEL. See the class header: `Date_Signed__c` survives a
     * `Signed -> Declined` transition, so this string is the only thing standing between the card
     * and a signature date for a party who refused. Must match
     * `objects/NDA__c/fields/Status__c.field-meta.xml`, whose value set is
     * `Pending / Not Sent / Sent / Received / Signed / Declined`.
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
     * ⚠ It is tested EXPLICITLY rather than inferred as "not Signed". `Not Sent`, `Sent`,
     * `Received` and `Pending` are all IN-FLIGHT states — the counterparty has not signed YET — and
     * must render as an ordinary active row with an empty signature date, not as a terminated one.
     * Only `Declined` is an ending.
     */
    @TestVisible
    private static final String STATUS_DECLINED = 'Declined';

    /**
     * One NDA's row on the timeline. A DTO across the `@AuraEnabled` boundary (ARCHITECTURE.md §2)
     * — every field is a value the component renders directly, and nothing it must not display ever
     * crosses.
     *
     * 🔴 THERE IS NO `ndaSignedRaw` / `rawStatus` / `isSigned` ESCAPE HATCH, DELIBERATELY. A declined
     * party's retained `Date_Signed__c` is suppressed in `buildRow` and never enters this object, so
     * no template change and no future consumer can leak it. That is why the suppression lives in
     * the service rather than in the component's getters.
     *
     * 🔴 AND THERE IS NO `buyerName`, NO `firstOfferDate` AND NO `daysToRespond`. All three were
     * removed on 2026-08-21 — the first because buyer identity is not tracked, the other two because
     * nothing links an offer to a specific NDA. Re-adding any of them is re-adding a claim the data
     * cannot support; read the class header first.
     */
    public class NdaRow {

        /** The NDA row's Id — the component's `for:each` key and its record link target. */
        @AuraEnabled
        public Id ndaId;

        /**
         * `NDA__c.Name` — the `NDA-{0000}` AutoNumber. THE ROW'S IDENTITY, and the one value on this
         * DTO that is guaranteed non-blank by the platform rather than by this class.
         */
        @AuraEnabled
        public String ndaName;

        /**
         * `Broker__r.Name`, falling back to a fixed placeholder. Never null and never blank — see
         * `resolveBrokerName` and the class header's note on why a null broker is normal.
         */
        @AuraEnabled
        public String brokerName;

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
         * True when the duration was suppressed because the arithmetic went NEGATIVE — i.e. the
         * dates on this row are out of order. Deliberately NOT set merely because a date is missing:
         * a blank materials date is normal and flagging it would cry wolf on most rows.
         */
        @AuraEnabled
        public Boolean hasDateAnomaly;
    }

    /** Rendered when an NDA carries no broker Contact. See the class header — no backfill exists. */
    @TestVisible
    private static final String NO_BROKER = 'No broker recorded';

    /**
     * The timeline for one Disposition — active NDAs first (in creation order), declined last.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition with no buyer NDA, returns an EMPTY LIST
     * rather than null. "No NDA has been raised yet" is a completely normal early state that the
     * component renders as an empty state; it must not be an exception and must not be a null the
     * caller has to guard.
     *
     * ── ⚠ THE SORT IS DONE **HERE**, NOT IN THE COMPONENT, AND THAT IS A CHOICE ─────────────────
     * `brokerAssignmentHistory` sorts in JavaScript. This one sorts in Apex because the ordering is
     * a STATEMENT ABOUT THE DATA ("a party who walked away is not part of the live sequence"), not a
     * presentation preference, and because an Apex sort is falsifiable by an Apex test that also has
     * the records in front of it. The component preserves server order and does not re-sort;
     * `dispositionBuyerTimeline.js`'s header says so, so the two cannot start disagreeing.
     *
     * ⚠ ACTIVE ROWS KEEP THE SELECTOR'S `CreatedDate ASC, Id ASC` ORDER — this is a TIMELINE, so the
     * first NDA raised reads first. The sort below is STABLE with respect to that: it moves declined
     * rows to the end and touches nothing else.
     *
     * @param dispositionId The Disposition whose NDA journey to build; null-safe.
     * @return One row per buyer-role NDA, actives first then declined; empty when the input is null
     *         or there are no buyer NDAs. Never null.
     * @throws System.QueryException when the running user lacks read on `NDA__c`, on `Contact`, or
     *         on any selected custom field — `Broker__c` most likely of all, since it is new.
     *         Deliberately allowed to propagate — see the class header's layering note.
     * @example
     * List&lt;DispositionBuyerTimelineService.NdaRow&gt; rows =
     *     DispositionBuyerTimelineService.getTimeline(dispositionId);
     */
    public static List<NdaRow> getTimeline(Id dispositionId) {
        List<NdaRow> rows = new List<NdaRow>();
        if (dispositionId == null) {
            return rows;
        }

        // THE ONLY QUERY. Buyer-role NDAs only; `Party_Role__c` is filtered in the selector, and the
        // broker's name is TRAVERSED here rather than resolved by a second read.
        List<NDA__c> ndas = NdaSelector.selectBuyerTimelineByDispositionId(dispositionId);
        if (ndas.isEmpty()) {
            return rows;
        }

        // Two passes so the declined rows land last without a comparator. A Comparable/Comparator
        // implementation would need its own class and its own tie-break to stay stable; splitting
        // the single ordered list in two preserves the selector's ordering within each group for
        // free, which is exactly the guarantee the ApexDoc promises.
        List<NdaRow> declined = new List<NdaRow>();
        for (NDA__c nda : ndas) {
            NdaRow row = buildRow(nda);
            if (row.isDeclined) {
                declined.add(row);
            } else {
                rows.add(row);
            }
        }
        rows.addAll(declined);
        return rows;
    }

    /**
     * One NDA -> one row. Pure: no SOQL, no DML, no state.
     *
     * 🔴 THE ORDER OF THE TWO SIGNED TESTS IS THE WHOLE POINT. `Status__c` is the GATE and
     * `Date_Signed__c` is the VALUE. Reversing them — reading the date and then deciding whether to
     * show it — is the same code with the same output today and is one careless edit away from
     * leaking a declined party's retained signature date.
     *
     * @param nda A buyer-role NDA with the timeline fields populated.
     * @return The row. Never null.
     */
    private static NdaRow buildRow(NDA__c nda) {
        NdaRow row = new NdaRow();
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
     * ⚠ IT STAYS A HELPER EVEN THOUGH IT NOW HAS ONE CALLER (it had two until 2026-08-21). Inlining
     * it would put the negative-suppression rule and the anomaly flag inside `buildRow`'s happy
     * path, where the next date column added would be written without them.
     *
     * @param fromDate The earlier end; null-safe.
     * @param toDate   The later end; null-safe.
     * @param row      The row being built — mutated ONLY to set `hasDateAnomaly`.
     * @return Whole days, or null.
     */
    private static Integer span(Date fromDate, Date toDate, NdaRow row) {
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
