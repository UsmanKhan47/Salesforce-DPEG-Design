/**
 * Builds the BUYER ACTIVITY TIMELINE for one Disposition — one row per buyer-role NDA, carrying the
 * three dates of the buyer journey (NDA signed -> materials released -> first offer) and the two
 * durations between them. Backs `DispositionBuyerTimelineController` -> `c/dispositionBuyerTimeline`
 * (Tranche 2 Workstream D, `agent-output/disposition-tranche-2-requirements.md` §3 D6.3).
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
 * other.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 DECLINED PARTIES ARE INCLUDED, NEVER HIDDEN — AND THEIR RETAINED DATE IS NEVER SHOWN
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NDA__c.allowDelete` is FALSE on both disposition permission sets by decision D20, so a declined
 * party PERSISTS as audit evidence. Two consequences, both deliberate:
 *   - THEY APPEAR. Hiding them would make this card DISAGREE WITH THE NDAs RELATED LIST SITTING ON
 *     THE SAME PAGE — the analyst would count three parties in one component and two in the other,
 *     with nothing to explain the difference.
 *   - THEY CARRY NO DATES AT ALL. Every date and both durations are nulled for a declined row, so
 *     the component renders em-dashes across the board. `Date_Signed__c` is suppressed HERE, in the
 *     service, rather than in the component — a value that must never be displayed should not cross
 *     the `@AuraEnabled` boundary at all, because a future template change cannot then leak it.
 * They sort LAST, after the active parties, mirroring `brokerAssignmentHistory`'s active-first sort.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ ONLY `Party_Role__c = 'Buyer'` ROWS EXIST HERE, AND THE FILTER IS IN THE QUERY
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * An `Introducing Broker` NDA is a real and expected row on a disposition and is NOT a buyer. It is
 * excluded by `NdaSelector.selectBuyerTimelineByDispositionId`'s own `WHERE` clause, so this class
 * never sees one and does not re-test it. Read that method before assuming this class is missing a
 * guard.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 NEVER RENDER A NEGATIVE DURATION
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `daysToRelease` and `daysToRespond` are null whenever either end of the span is null, AND whenever
 * the arithmetic comes out negative. A negative duration is not a small display defect: "-14 days
 * for the buyer to respond" reads as a data-entry instruction to nobody and as a bug to everyone.
 * Out-of-order dates are REACHABLE without anything being broken — an analyst can back-date
 * `Materials_Released_Date__c` to before the signature, or record an offer that pre-dates the
 * package (a buyer who bid before the formal release). So the row is not silently blanked either:
 * `hasDateAnomaly` is set, and the component flags it, so the analyst learns their dates disagree
 * instead of just seeing an em-dash.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ LEGACY ROWS: THE NAME FALLS BACK TO `Counterparty_Name__c`, AND THERE IS NO BACKFILL
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NDA__c.Buyer__c` was added on 2026-08-20; every NDA created before it has a NULL lookup and a
 * typed `Counterparty_Name__c`. **No backfill is in scope — that is a decision, not an omission.**
 * So the buyer name is `Buyer__r.Name` where the lookup is set and `Counterparty_Name__c` otherwise.
 * ⚠ CONSEQUENCE, STATED: a legacy row has no buyer Contact Id, so it can never be matched to an
 * offer and its "first offer" column and response duration are permanently `—`. That is truthful —
 * nothing in the data says which offers were theirs — and it self-heals the moment someone sets the
 * lookup. It is NOT a reason to match on NAME instead: two buyers can share a name, and a
 * name-matched offer would attribute one buyer's bid to another.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). **ZERO SOQL and ZERO DML.** Both reads go to
 * selectors — `NdaSelector.selectBuyerTimelineByDispositionId` and
 * `DispositionOfferSelector.selectEarliestByBuyerIds` — both `WITH USER_MODE`, because a human
 * opened the record page and asked for exactly this. A `QueryException` from either is a REAL
 * PROVISIONING GAP and is deliberately allowed to propagate to the controller, which converts it to
 * a user-safe `AuraHandledException`. **It is NOT swallowed into an empty timeline**: a card that
 * silently renders zero buyers on a sale that has three is the "wrong answer, not an error" failure
 * this repo has paid for repeatedly, and it is strictly worse here than a visible error message.
 *
 * ── BUDGET ──────────────────────────────────────────────────────────────────────────────────
 * **EXACTLY TWO SOQL AND ZERO DML PER CALL, CONSTANT IN THE NUMBER OF BUYERS** — one for the NDAs,
 * one for the offers, and the second is skipped entirely when no NDA carries a buyer lookup (every
 * legacy-only disposition), making the floor ONE. 🔴 The offer read takes the WHOLE buyer Set at
 * once and must never become a per-buyer read; `selectEarliestByBuyerIds`'s ApexDoc explains why a
 * `LIMIT 1` sibling called in a loop would be SOQL-in-a-loop on a page render.
 * ⚠ This is a read path invoked once per page view, not a trigger path, so
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate does not attach to THIS class — it attaches
 * in full to the two stamp services and the trigger, which is where those tests live. The falsifier
 * that matters here is the CONSTANT query count across many buyers, and it is asserted.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`. Both selector reads are `USER_MODE` on `with sharing` selectors, so a row the
 * running user cannot see simply does not appear — the correct direction for a card a human is
 * reading. **Do not add a `without sharing` escape**: an under-count here is visible (the related
 * list beside it shows the same scoping) rather than an inverted automated verdict, which is the
 * only shape that has ever justified one in this repo.
 *
 * @see force-app/main/default/classes/DispositionBuyerTimelineController.cls (the thin boundary)
 * @see force-app/main/default/classes/NdaSelector.cls (selectBuyerTimelineByDispositionId)
 * @see force-app/main/default/classes/DispositionOfferSelector.cls (selectEarliestByBuyerIds)
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
     * other silently.
     */
    @TestVisible
    private static final String STATUS_SIGNED = 'Signed';

    /**
     * The terminal `NDA__c.Status__c` value that makes a party a TERMINATED row.
     *
     * ⚠ It is tested EXPLICITLY rather than inferred as "not Signed". `Not Sent`, `Sent`,
     * `Received` and `Pending` are all IN-FLIGHT states — the buyer has not signed YET — and must
     * render as an ordinary active row with an empty signature date, not as a terminated one. Only
     * `Declined` is an ending.
     */
    @TestVisible
    private static final String STATUS_DECLINED = 'Declined';

    /**
     * One buyer's row on the timeline. A DTO across the `@AuraEnabled` boundary (ARCHITECTURE.md §2)
     * — every field is a value the component renders directly, and nothing it must not display ever
     * crosses.
     *
     * 🔴 THERE IS NO `ndaSignedRaw` / `rawStatus` / `isSigned` ESCAPE HATCH, DELIBERATELY. A declined
     * party's retained `Date_Signed__c` is suppressed in `buildRow` and never enters this object, so
     * no template change and no future consumer can leak it. That is why the suppression lives in
     * the service rather than in the component's getters.
     */
    public class BuyerRow {

        /** The NDA row's Id — the component's `for:each` key and its record link target. */
        @AuraEnabled
        public Id ndaId;

        /**
         * `Buyer__r.Name`, falling back to `Counterparty_Name__c` for legacy rows, falling back
         * again to a fixed placeholder. Never null and never blank — a blank cell in the first
         * column of a table is indistinguishable from a rendering failure.
         */
        @AuraEnabled
        public String buyerName;

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

        /**
         * The earliest DATED offer this buyer made ON THIS DISPOSITION. The clock stops here
         * (user-confirmed). Null for a legacy row with no buyer lookup — see the class header.
         */
        @AuraEnabled
        public Date firstOfferDate;

        /** `materialsReleasedDate - ndaSignedDate`. Null if either end is null OR if negative. */
        @AuraEnabled
        public Integer daysToRelease;

        /** `firstOfferDate - materialsReleasedDate`. Null if either end is null OR if negative. */
        @AuraEnabled
        public Integer daysToRespond;

        /**
         * True when a duration was suppressed because the arithmetic went NEGATIVE — i.e. the dates
         * on this row are out of order. Deliberately NOT set merely because a date is missing: a
         * blank materials date is normal and flagging it would cry wolf on most rows.
         */
        @AuraEnabled
        public Boolean hasDateAnomaly;
    }

    /** Rendered when a row has neither a buyer Contact nor a typed counterparty name. */
    @TestVisible
    private static final String UNNAMED_BUYER = 'Unnamed buyer';

    /**
     * The timeline for one Disposition — active parties first (in NDA creation order), declined
     * parties last.
     *
     * NOT-FOUND CONTRACT: a null Id, or a Disposition with no buyer NDA, returns an EMPTY LIST
     * rather than null. "No buyer has signed yet" is a completely normal early state that the
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
     * first party to be engaged reads first. The sort below is STABLE with respect to that: it moves
     * declined rows to the end and touches nothing else.
     *
     * @param dispositionId The Disposition whose buyer journey to build; null-safe.
     * @return One row per buyer-role NDA, actives first then declined; empty when the input is null
     *         or there are no buyer NDAs. Never null.
     * @throws System.QueryException when the running user lacks read on `NDA__c`, on `Contact`, on
     *         `Disposition_Offer__c`, or on any selected custom field. Deliberately allowed to
     *         propagate — see the class header's layering note.
     * @example
     * List&lt;DispositionBuyerTimelineService.BuyerRow&gt; rows =
     *     DispositionBuyerTimelineService.getTimeline(dispositionId);
     */
    public static List<BuyerRow> getTimeline(Id dispositionId) {
        List<BuyerRow> rows = new List<BuyerRow>();
        if (dispositionId == null) {
            return rows;
        }

        // QUERY 1 of at most 2. Buyer-role NDAs only; `Party_Role__c` is filtered in the selector.
        List<NDA__c> ndas = NdaSelector.selectBuyerTimelineByDispositionId(dispositionId);
        if (ndas.isEmpty()) {
            return rows;
        }

        Set<Id> buyerIds = new Set<Id>();
        for (NDA__c nda : ndas) {
            if (nda.Buyer__c != null) {
                buyerIds.add(nda.Buyer__c);
            }
        }

        // QUERY 2 of at most 2 — ONE query for EVERY buyer, never one per buyer. The selector
        // returns an empty list WITHOUT querying when the set is empty, so a disposition whose NDAs
        // are all legacy (no buyer lookup) costs exactly one query in total.
        Map<Id, Date> firstOfferByBuyer = new Map<Id, Date>();
        for (Disposition_Offer__c offer
                : DispositionOfferSelector.selectEarliestByBuyerIds(buyerIds, dispositionId)) {
            // Rows arrive `Offer_Date__c ASC, Id ASC`, so the FIRST row seen for a buyer is their
            // earliest offer. `containsKey` — not `get(...) == null` — is what makes this
            // first-wins rather than last-wins.
            if (!firstOfferByBuyer.containsKey(offer.Buyer__c)) {
                firstOfferByBuyer.put(offer.Buyer__c, offer.Offer_Date__c);
            }
        }

        // Two passes so the declined rows land last without a comparator. A Comparable/Comparator
        // implementation would need its own class and its own tie-break to stay stable; splitting
        // the single ordered list in two preserves the selector's ordering within each group for
        // free, which is exactly the guarantee the ApexDoc promises.
        List<BuyerRow> declined = new List<BuyerRow>();
        for (NDA__c nda : ndas) {
            BuyerRow row = buildRow(nda, firstOfferByBuyer);
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
     * @param nda               A buyer-role NDA with the eight timeline fields populated.
     * @param firstOfferByBuyer Buyer Contact Id -> their earliest dated offer on this disposition.
     * @return The row. Never null.
     */
    private static BuyerRow buildRow(NDA__c nda, Map<Id, Date> firstOfferByBuyer) {
        BuyerRow row = new BuyerRow();
        row.ndaId = nda.Id;
        row.status = nda.Status__c;
        row.isDeclined = STATUS_DECLINED.equals(nda.Status__c);
        row.buyerName = resolveName(nda);
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
        if (nda.Buyer__c != null) {
            row.firstOfferDate = firstOfferByBuyer.get(nda.Buyer__c);
        }

        row.daysToRelease = span(row.ndaSignedDate, row.materialsReleasedDate, row);
        row.daysToRespond = span(row.materialsReleasedDate, row.firstOfferDate, row);
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
     * @param fromDate The earlier end; null-safe.
     * @param toDate   The later end; null-safe.
     * @param row      The row being built — mutated ONLY to set `hasDateAnomaly`.
     * @return Whole days, or null.
     */
    private static Integer span(Date fromDate, Date toDate, BuyerRow row) {
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
     * The buyer's display name: the linked Contact, else the legacy typed text, else a placeholder.
     *
     * ⚠ `String.isNotBlank` RATHER THAN A NULL CHECK ON `Counterparty_Name__c`. It is free Text and
     * a whitespace-only value is reachable; a row rendering a single space in its first column looks
     * like a broken component rather than like missing data.
     *
     * @param nda The NDA, with `Buyer__r` resolved when `Buyer__c` is set.
     * @return A non-blank display name. Never null.
     */
    private static String resolveName(NDA__c nda) {
        if (nda.Buyer__c != null && nda.Buyer__r != null && String.isNotBlank(nda.Buyer__r.Name)) {
            return nda.Buyer__r.Name;
        }
        if (String.isNotBlank(nda.Counterparty_Name__c)) {
            return nda.Counterparty_Name__c;
        }
        return UNNAMED_BUYER;
    }
}
