/**
 * The Active Listing traction monitor — the single place in this application that decides whether a
 * broker-listed property is getting traction, and the successor to the hardcoded 21/28/42-day
 * ladder that used to live inside `BrokerListingController.getListing`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. THE CLOCK IS 60 DAYS WITH A 30-DAY CHECKPOINT (D27.1 / D28-Q2)
 * ═══════════════════════════════════════════════════════════════════════════
 * `docs/DPEG-Stage-by-Stage.docx` Part 2 line 213: *"The property is given about two months on the
 * market. If there is no traction within the first month — no offers and no real interest — the
 * team discusses it internally and decides whether to change the broker."* D27.1 made the document
 * authoritative over the deployed 6-week Path guidance.
 *
 * ── HOW THE INTERMEDIATE BAND WAS DERIVED, RATHER THAN GUESSED ──────────────
 * The retired ladder had three rungs at 21 / 28 / 42 days against a 6-week (42-day) clock, i.e. at
 * exactly ½ / ⅔ / 1 of the clock. Keeping those three RATIOS against a 60-day clock gives
 * 30 / 40 / 60 — and the ½ mark lands precisely on the checkpoint the document itself names, so
 * the derivation and the document agree instead of competing.
 *
 *   ½ × 60 = 30  TRACTION_CHECKPOINT_DAYS   ← the document's number, not a derivation
 *   ⅔ × 60 = 40  REVIEW_OVERDUE_DAYS        ← inherited by ratio; the only derived threshold here
 *   1 × 60 = 60  MARKETING_PERIOD_DAYS      ← the document's number ("about two months")
 *
 * ⚠ SO A READER KNOWS WHICH NUMBERS ARE AUTHORITATIVE: 30 and 60 come from the document. 40 is the
 * successor to the old middle rung and exists for the reason that rung existed — to make the badge
 * escalate WITHIN the at-risk window rather than sitting on one wording for a month. Nothing in the
 * document mandates it (nothing mandated day 28 either), so it is the one threshold a future
 * revision may move without contradicting the source.
 *
 * ⚠ THE NUMBERS ARE HARDCODED ON PURPOSE. Configurable thresholds (Custom Metadata / a Custom
 * Setting) were offered at Gate 1 and NOT chosen — D28/Q2. Do not "improve" them into config.
 * D28 also notes this is the SECOND time these numbers have been disputed; a third revision is the
 * point at which to revisit, not before.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. "NO TRACTION" MEANS ZERO OFFERS. NOTHING ELSE. (D28-Q1)
 * ═══════════════════════════════════════════════════════════════════════════
 * The checkpoint fires on an offer count of zero. "Real interest" stays exactly what the document
 * says it is — a human judgement made in the internal discussion — and is deliberately NOT modelled
 * as a field. Gate 1 rejected both alternatives and the reasons are worth keeping: a recordable
 * interest signal works only if it is maintained, and an unmaintained field reads as *zero
 * interest*; a manual "there is interest" flag inverts the burden, so silence becomes a positive
 * assertion that there is none rather than an absence of data.
 *
 * 🔴 THIS IS THE SUBSTANTIVE BEHAVIOUR CHANGE, NOT THE THRESHOLDS. The retired ladder ignored
 * offers entirely: a listing with five offers at day 42 was labelled "Hard Stop". Under this rule
 * an offer is traction, so the checkpoint never fires while one exists.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. WHERE THE COMPUTATION LIVES, AND WHY IT IS NOT A FORMULA OR A JOB
 * ═══════════════════════════════════════════════════════════════════════════
 * FORMULA — IMPOSSIBLE, not merely unattractive. `Disposition_Offer__c.Disposition__c` is a
 * `<type>Lookup</type>` (measured in the field file), and a roll-up summary requires Master-Detail.
 * There is therefore no way for a `Disposition__c` formula to count offers at any price, so the
 * offer half of D28/Q1 cannot be expressed declaratively.
 *
 * SCHEDULED JOB — REJECTED, and the reason is this tranche's own risk framing. D9 defers every
 * notification including the month-1 traction alert, so a job's ONLY product today would be a
 * STORED COPY of a value that is already a pure function of two stored facts (the listing date and
 * the offer count). A stored copy has to be MAINTAINED to stay true; a computed one is true by
 * construction on every server evaluation. There is no scheduled job in
 * the disposition module today, so it would arrive with a post-deploy scheduling gate, and a deploy
 * that missed that gate would leave the UI showing a band nothing maintains — silently, which is
 * exactly the Item B failure profile D28 called out ("a clock keyed on a date nobody sets computes
 * day 0 forever and looks healthy").
 *
 * APEX AT READ TIME — CHOSEN. Nothing has to be maintained and there is no schedule to forget.
 *
 * ⚠ THE COST, STATED: a computed band is NOT reportable and NOT filterable. `Listing_Status__c` and
 * the `Broker_Alert_Due` report cannot see it. That is the real argument for a job, and it is why
 * the shape below exists.
 *
 * ── 🔴 RESIDUAL: "IT CANNOT GO STALE" IS TRUE OF THIS CLASS AND FALSE OF THE SCREEN ─────────
 * Recorded 2026-08-10 (review W1). The paragraph above used to read "a computed one cannot [go
 * stale]" flatly, and that sentence was correct only as far as the `@AuraEnabled` boundary. Both
 * consumers — `DispositionTractionController.getTraction` and `BrokerListingController.getListing`
 * — are `cacheable=true`, so the CLIENT holds the payload and nothing in this feature invalidates
 * it. The concrete sequence, all on one Disposition record page:
 *
 *   1. `c-disposition-offer` (sidebar) navigates to the standard new-record page for
 *      `Disposition_Offer__c` and the user saves.
 *   2. That component's LDS `getRelatedListRecords` wire is invalidated by the create, so the
 *      offers list comes back showing the new offer.
 *   3. `c-listing-alerts` and `c-broker-listing` (main region) are plain Apex wires and may keep
 *      serving the cached payload — i.e. "Month one has passed with no offers. Review the listing
 *      internally and decide whether to change the broker." beside a list that shows an offer,
 *      plus an "Offers Received: 0" stat on the listing card.
 *
 * ⚠ THE WINDOW IS UNMEASURED. How long the client cache actually holds across that navigation was
 * not measured here, so no bound is claimed. What IS established is that there is no invalidation
 * anywhere in the code and no test covers one. A page reload always shows the true band.
 *
 * ── WHY THE REFRESH RELAY WAS NOT BUILT — A STRUCTURAL MEASUREMENT, NOT A PREFERENCE ────────
 * The obvious fix ("`c-disposition-offer` fires a CustomEvent, `c-disposition-main` relays it, the
 * two panels call `refreshApex`") CANNOT BE BUILT AS DESCRIBED, because the two components are not
 * in one tree. Measured against `flexipages/Disposition_Record_Page.flexipage-meta.xml`:
 * `dispositionMain` sits in the **`main`** region (line 380) and `dispositionSidebar` — the only
 * component in the repo that renders `c-disposition-offer` — sits in the **`sidebar`** region
 * (line 436). A DOM `CustomEvent` propagates up its OWN tree and stops there, so
 * `c-disposition-main` is not an ancestor of `c-disposition-offer` and has nothing to relay. The
 * real mechanism would be Lightning Message Service, and `force-app/main/default/` contains **no
 * `messageChannels/` directory at all** — it would be the first message channel in the
 * application, not "~15 lines, no server change".
 *
 * A second problem outlives the first: logging an offer NAVIGATES AWAY and back, so the panels are
 * re-created and a freshly mounted publisher has no previous count to compare against. To close the
 * gap it would have to publish unconditionally on every wire delivery — forcing a server round trip
 * on every page view for both panels, which is exactly what `cacheable=true` exists to avoid.
 *
 * 🔴 SO THE RESIDUAL IS ACCEPTED AND WRITTEN DOWN RATHER THAN PAPERED OVER. It is bounded by what
 * this panel is: D9 defers every notification, so nothing acts on the band automatically — it is
 * advisory text a human reads, and the human who just logged the offer is the one person who
 * already knows it exists. When D9's alert is built, the alert must be driven from a SERVER
 * evaluation (this class), never from what a cached panel happens to be showing.
 *
 * ⚠ FOR THE AUTHOR WHO PICKS THIS UP: do NOT reach for `getRecordNotifyChange`. The band is an
 * Apex computation, not a field on the `Disposition__c` record, so notifying LDS of a record change
 * does not invalidate these wires. `refreshApex` on a retained wire result is the only tool, and it
 * needs a cross-region channel to be triggered from the offer card.
 *
 * ── 🔴 THE SEAM FOR THE DEFERRED D9 ALERT — "a later addition, not a rewrite" ──
 * `evaluate(Date, Integer)` is PURE: no SOQL, no DML, no `Date.today()` beyond the one argument it
 * is handed. A future `Schedulable` that writes `Listing_Status__c` and raises the deferred alert
 * calls THIS method over a batch and calls `listingStatusValue(...)` to get the picklist value —
 * it does not re-derive a threshold, so the stored value and the displayed badge cannot drift.
 * That job additionally needs: a recipient population (D9 flags "Disposition team" as neither a
 * queue nor a public group in this repo — unresolved org-wide), a
 * `notificationtypes/*.notiftype-meta.xml` (the module has zero), and a post-deploy scheduling
 * gate. None of those is built here.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. 🔴 WHICH "DAYS ON MARKET" — AND WHY NEITHER STORED FIELD IS USED
 * ═══════════════════════════════════════════════════════════════════════════
 * Two fields share the name `Days_On_Market__c` and they are not the same kind of thing:
 *
 *   `Broker_Listing__c.Days_On_Market__c`  Number(4,0), NO formula, written by NOTHING. The
 *                                          retired ladder read THIS — a static number a human
 *                                          typed, which is why the deployed clock could not tick.
 *   `Disposition__c.Days_On_Market__c`     Formula `IF(ISBLANK(Listing_Date__c), null, TODAY() -
 *                                          Listing_Date__c)` with `formulaTreatBlanksAs =
 *                                          BlankAsZero`.
 *
 * This class reads NEITHER. It computes from the raw `Disposition__c.Listing_Date__c`, because
 * `BlankAsZero` makes the formula return **0** for an unset date — indistinguishable from "listed
 * today", which is the precise shape of "a clock that looks healthy and never ticks" (D28/Q3).
 * Computing from the date lets a blank return `NOT_LISTED`, an honest state a caller can render
 * differently. Both stored fields are now legacy display-only and this feature writes neither.
 *
 * ⚠ THE CLOCK IS THE PARENT'S, NOT THE LISTING'S. `Disposition__c.Listing_Date__c` is the start of
 * the MARKETING PERIOD, which survives a broker change; `Broker_Listing__c.List_Date__c` is
 * per-broker and restarts when a second listing row opens. Using the child's date would silently
 * reset the 60-day clock the moment a broker was replaced — i.e. exactly when the clock matters
 * most.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2). Zero inline SOQL — the two reads go to
 * `DispositionSelector.selectListingClockByIds` and `DispositionOfferSelector.countByDispositionIds`.
 * Zero DML. `evaluateAll` is 2 SOQL for ANY number of dispositions.
 *
 * @see force-app/main/default/classes/DispositionOfferSelector.cls
 * @see force-app/main/default/classes/DispositionTractionController.cls (the LWC boundary)
 * @see force-app/main/default/classes/BrokerListingController.cls (the second consumer)
 */
public with sharing class DispositionTractionService {

    /** The full marketing period the document allows ("about two months"). */
    @TestVisible
    private static final Integer MARKETING_PERIOD_DAYS = 60;

    /** The month-1 traction check the document names. Half the clock; see the class header. */
    @TestVisible
    private static final Integer TRACTION_CHECKPOINT_DAYS = 30;

    /** Two-thirds of the clock — the successor to the retired 6-week ladder's day-28 rung. */
    @TestVisible
    private static final Integer REVIEW_OVERDUE_DAYS = 40;

    /**
     * The traction state of one broker-listed disposition.
     *
     * ⚠ ORDER IS MEANINGFUL AND IS RELIED ON BY `isAtRisk`: everything from `CHECKPOINT_DUE`
     * onward is a state a human is expected to act on. Insert a new value in the right place or
     * `isAtRisk` silently changes meaning.
     */
    public enum Band {
        /** `Listing_Date__c` is blank — the marketing clock has not started. NOT "day 0". */
        NOT_LISTED,
        /** Inside the first month, or an offer exists at any point. */
        ON_TRACK,
        /** Day 30+, zero offers. The document's month-1 discussion is due. */
        CHECKPOINT_DUE,
        /** Day 40+, zero offers. Two-thirds of the marketing period gone. */
        REVIEW_OVERDUE,
        /** Day 60+, zero offers. The whole marketing period elapsed without an offer. */
        HARD_STOP
    }

    /** One disposition's computed traction state. All fields are derived; none is stored. */
    public class Traction {
        /** `Band` name — an enum cannot cross the `@AuraEnabled` boundary, so it travels as text. */
        @AuraEnabled public String band;
        /** Short human label for the badge, e.g. `Day 34 of 60 — checkpoint: no offers`. */
        @AuraEnabled public String label;
        /** One sentence naming what the band means and what happens next. Never a promise of a notification. */
        @AuraEnabled public String detail;
        /** Days since `Disposition__c.Listing_Date__c`; null when the clock has not started. */
        @AuraEnabled public Integer daysOnMarket;
        /** Offers logged against the disposition. Always a number, never null. */
        @AuraEnabled public Integer offerCount;
        /** `Disposition__c.Listing_Date__c` verbatim; null means NOT_LISTED. */
        @AuraEnabled public Date listingDate;
        /** Day 30 in absolute terms; null when the clock has not started. */
        @AuraEnabled public Date checkpointDate;
        /** Day 60 in absolute terms; null when the clock has not started. */
        @AuraEnabled public Date hardStopDate;
        /** Whole days left of the 60; 0 once elapsed; null when the clock has not started. */
        @AuraEnabled public Integer daysRemaining;
        /** True from `CHECKPOINT_DUE` onward — the single flag the UI colours off. */
        @AuraEnabled public Boolean isAtRisk;
        /** True once the clock has started, i.e. band != NOT_LISTED. */
        @AuraEnabled public Boolean isListed;
        /** The `Listing_Status__c` value this band maps to. Nothing writes it today — see the header. */
        @AuraEnabled public String listingStatusValue;
        /** The full period, surfaced so a caller never hardcodes 60 a second time. */
        @AuraEnabled public Integer marketingPeriodDays;
        /** The checkpoint, surfaced for the same reason. */
        @AuraEnabled public Integer checkpointDays;
    }

    /**
     * THE PURE FUNCTION. Every band decision in the application is made here and nowhere else.
     *
     * No SOQL, no DML, and — deliberately — no `Date.today()`: the caller supplies the listing date
     * and the count, so the same inputs always give the same answer and every branch is reachable
     * from a test without a clock fixture.
     *
     * @param listingDate `Disposition__c.Listing_Date__c`; null means the clock has not started.
     * @param offerCount  Offers logged against the disposition; null is treated as 0.
     * @return The computed traction state. Never null.
     */
    public static Traction evaluate(Date listingDate, Integer offerCount) {
        Integer offers = (offerCount == null) ? 0 : offerCount;
        Traction t = new Traction();
        t.offerCount = offers;
        t.listingDate = listingDate;
        t.marketingPeriodDays = MARKETING_PERIOD_DAYS;
        t.checkpointDays = TRACTION_CHECKPOINT_DAYS;

        // RETURN EARLY. A blank listing date is not "day 0" — it is "the clock has not started",
        // and collapsing the two is the defect this whole item exists to remove.
        if (listingDate == null) {
            t.band = Band.NOT_LISTED.name();
            t.isListed = false;
            t.isAtRisk = false;
            t.label = 'Not listed yet';
            t.detail = 'The ' + MARKETING_PERIOD_DAYS
                + '-day marketing clock starts when a listing date is set.';
            t.listingStatusValue = 'On Track';
            return t;
        }

        // daysBetween is signed, so a future listing date reads negative. Clamp at 0: a listing
        // dated tomorrow is on day 0 of its clock, not day -1.
        Integer days = listingDate.daysBetween(Date.today());
        if (days < 0) {
            days = 0;
        }
        t.isListed = true;
        t.daysOnMarket = days;
        t.checkpointDate = listingDate.addDays(TRACTION_CHECKPOINT_DAYS);
        t.hardStopDate = listingDate.addDays(MARKETING_PERIOD_DAYS);
        t.daysRemaining = Math.max(0, MARKETING_PERIOD_DAYS - days);

        // 🔴 OFFERS FIRST. An offer is traction (D28/Q1), so it short-circuits every threshold
        // below. The retired ladder had no such branch, which is why it labelled a listing with
        // offers "Hard Stop".
        if (offers > 0) {
            t.band = Band.ON_TRACK.name();
            t.isAtRisk = false;
            t.label = 'Day ' + days + ' of ' + MARKETING_PERIOD_DAYS + ' — On Track';
            t.detail = offers + (offers == 1 ? ' offer' : ' offers')
                + ' received, so the day-' + TRACTION_CHECKPOINT_DAYS
                + ' traction check does not apply.';
            t.listingStatusValue = 'On Track';
            return t;
        }

        if (days >= MARKETING_PERIOD_DAYS) {
            t.band = Band.HARD_STOP.name();
            t.isAtRisk = true;
            t.label = 'Day ' + days + ' — Hard Stop: no offers';
            t.detail = 'The ' + MARKETING_PERIOD_DAYS
                + '-day marketing period has elapsed with no offers.';
            t.listingStatusValue = 'Hard Stop';
            return t;
        }
        if (days >= REVIEW_OVERDUE_DAYS) {
            t.band = Band.REVIEW_OVERDUE.name();
            t.isAtRisk = true;
            t.label = 'Day ' + days + ' — Review overdue: still no offers';
            t.detail = 'Past the day-' + TRACTION_CHECKPOINT_DAYS
                + ' checkpoint with no offers, and ' + t.daysRemaining
                + ' days of the marketing period remain.';
            t.listingStatusValue = 'At Risk';
            return t;
        }
        if (days >= TRACTION_CHECKPOINT_DAYS) {
            t.band = Band.CHECKPOINT_DUE.name();
            t.isAtRisk = true;
            t.label = 'Day ' + days + ' — Traction checkpoint: no offers';
            t.detail = 'Month one has passed with no offers. Review the listing internally and '
                + 'decide whether to change the broker.';
            t.listingStatusValue = 'At Risk';
            return t;
        }

        t.band = Band.ON_TRACK.name();
        t.isAtRisk = false;
        t.label = 'Day ' + days + ' of ' + MARKETING_PERIOD_DAYS + ' — On Track';
        t.detail = 'The day-' + TRACTION_CHECKPOINT_DAYS + ' traction check is due in '
            + (TRACTION_CHECKPOINT_DAYS - days)
            + ((TRACTION_CHECKPOINT_DAYS - days) == 1 ? ' day.' : ' days.');
        t.listingStatusValue = 'On Track';
        return t;
    }

    /**
     * Bulk entry point: the traction state of every supplied disposition.
     *
     * 🔴 BUDGET: 2 SOQL, 0 DML, CONSTANT IN THE NUMBER OF DISPOSITIONS. That constancy is the
     * property that makes this safe to call from a future batch or Schedulable, and it is asserted
     * by the tests rather than left to inspection.
     *
     * A disposition Id that resolves to no readable row is simply absent from the returned map —
     * callers must handle a miss, and `DispositionTractionController` renders it as "not listed".
     *
     * @param dispositionIds Dispositions to evaluate; null/empty safe.
     * @return Disposition__c Id -> Traction, omitting Ids that resolved to no row.
     */
    public static Map<Id, Traction> evaluateAll(Set<Id> dispositionIds) {
        Map<Id, Traction> result = new Map<Id, Traction>();
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return result;
        }
        List<Disposition__c> dispositions =
            DispositionSelector.selectListingClockByIds(dispositionIds);
        if (dispositions.isEmpty()) {
            return result;
        }
        // Counted only for the dispositions that actually resolved, so an unreadable Id costs
        // nothing in the second query either.
        Map<Id, Integer> offerCounts =
            DispositionOfferSelector.countByDispositionIds(new Map<Id, Disposition__c>(dispositions).keySet());
        for (Disposition__c d : dispositions) {
            // A disposition with no offers is ABSENT from the count map (GROUP BY emits no row for
            // an empty group), which is why the miss defaults to 0 here rather than to null.
            Integer offers = offerCounts.containsKey(d.Id) ? offerCounts.get(d.Id) : 0;
            result.put(d.Id, evaluate(d.Listing_Date__c, offers));
        }
        return result;
    }

    /**
     * The `Broker_Listing__c.Listing_Status__c` picklist value a band maps to.
     *
     * NOTHING CALLS THIS TODAY, AND THAT IS DELIBERATE — it is the seam the deferred D9 job writes
     * through, kept next to the thresholds so the stored value and the displayed badge can never
     * derive from two different ladders. The three values are the field's entire restricted value
     * set (`On Track` / `At Risk` / `Hard Stop`, measured), so this feature needs NO new picklist
     * value and the standing "grep the repo and query the org before touching a picklist" rule is
     * not engaged.
     *
     * ⚠ THE PARAMETER IS NOT CALLED `band`, AND THAT IS NOT STYLE. Apex identifiers are
     * case-INSENSITIVE, so a parameter named `band` shadows the enum TYPE `Band` inside this
     * method and `Band.HARD_STOP` then resolves against the parameter — which fails to compile with
     * the genuinely misleading `Static field cannot be referenced from a non static context:
     * HARD_STOP`. Measured on this exact method 2026-08-10. Keep the names distinct.
     *
     * @param tractionBand The computed band.
     * @return `On Track`, `At Risk` or `Hard Stop`.
     */
    public static String listingStatusValue(Band tractionBand) {
        if (tractionBand == Band.HARD_STOP) {
            return 'Hard Stop';
        }
        if (tractionBand == Band.CHECKPOINT_DUE || tractionBand == Band.REVIEW_OVERDUE) {
            return 'At Risk';
        }
        return 'On Track';
    }
}
