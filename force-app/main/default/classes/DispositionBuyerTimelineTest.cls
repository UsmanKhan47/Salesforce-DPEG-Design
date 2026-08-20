/**
 * @description Tests the buyer activity timeline read path end to end —
 * `DispositionBuyerTimelineController` -> `DispositionBuyerTimelineService` ->
 * `NdaSelector.selectBuyerTimelineByDispositionId` + `DispositionOfferSelector.selectEarliestByBuyerIds`
 * (`agent-output/disposition-tranche-2-requirements.md` §3 D6.3, added 2026-08-20).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE TWO TESTS THAT MATTER MOST ARE THE LATCH TESTS. EVERYTHING ELSE IS SUPPORTING WORK.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The whole feature exists in the shadow of one trap with two halves:
 *
 *   HALF 1 — `NDA_Signed__c` LATCHES. It is only ever CLEARED on `Declined`; it stays true through
 *            `Sent`, and it stayed true forever for any party who walked away before Workstream A3.
 *            `sentNdaWithLatchedSignedFlag_showsNoSignedDate` sets exactly that state — checkbox
 *            true, status `Sent` — and asserts NO signed date appears. If anyone ever "simplifies"
 *            the service onto the checkbox, that test goes red.
 *
 *   HALF 2 — `Date_Signed__c` IS **NEVER CLEARED**, by explicit design. `NDA_Signed_Status_Sync`'s
 *            own description says so in terms: *"It NEVER clears Date_Signed__c, so a declined party
 *            keeps a signature date beside a false checkbox: gate on Status__c, not on either field
 *            alone."* So `declinedNdaWithRetainedSignedDate_showsNoDatesAtAll` gives the declined
 *            party a REAL signature date and a REAL materials date — the actual production shape,
 *            not a contrived one — and asserts every date comes back null.
 *
 * ⚠ THE GATE IS `Status__c = 'Signed'`. `Date_Signed__c` IS ONLY THE VALUE SHOWN ONCE IT PASSES.
 *
 * ── ⚠ WHY THE FIXTURES SET `NDA_Signed__c` AND `Date_Signed__c` BY HAND ──
 * `NDA_Signed_Status_Sync` is an ACTIVE before-save flow: it sets `NDA_Signed__c` true on `Signed`,
 * false on `Declined`, and stamps `Date_Signed__c = TODAY` the first time Status reaches `Signed`
 * WITH A BLANK DATE. Setting an explicit date therefore SURVIVES (the flow's `Date_Signed_Is_Blank`
 * gate skips it), and setting the checkbox on a `Sent` row survives too (no branch of the flow
 * touches it for that value). Both are load-bearing for the fixtures above and are stated here so
 * nobody "cleans them up".
 *
 * ── BULK ──
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does NOT attach to this class, and that
 * is an argued position rather than an omission: nothing here is a trigger, a batch, a queueable or
 * a DML-performing service — it is a READ invoked once per page view. The mandate DOES apply in full
 * to this tranche's write paths, and the 251-record tests live where they belong, in
 * `NdaBuyerStampServiceTest` and `DispositionOfferBuyerStampServiceTest`.
 * 🔴 THE PROPERTY THAT MATTERS HERE IS A **CONSTANT QUERY COUNT ACROSS MANY BUYERS**, and it IS
 * asserted (`manyBuyers_costsExactlyTwoQueries`). A per-buyer offer read would be SOQL in a loop on
 * a page render — the specific defect `selectEarliestByBuyerIds`'s ApexDoc was written to prevent —
 * and a row count alone would never catch it.
 *
 * ── THE CROSS-PERMISSION-SET PIN (added 2026-08-20, re-review S3) ──
 * `NdaSelector.selectBuyerTimelineByDispositionId` selects `Buyer__r.Name`, and `WITH USER_MODE`
 * enforces OBJECT read on the traversed `Contact`. NEITHER disposition permission set grants it —
 * it arrives from `DPEG_Contact_View` / `DPEG_Contact_Edit`, separate members of the same permission
 * set GROUPS. Until this class carried `contactReadDenied_theBuyerTraversalThrows` there was no
 * `System.runAs` anywhere in the `DispositionBuyerTimeline*` classes, so a future PSG edit that
 * dropped the Contact member would break the card in PRODUCTION with nothing going red first.
 *
 * @see force-app/main/default/classes/DispositionDealSummaryServiceTest.cls (`userDeniedAccessTo`,
 *      the dynamic-permission-set technique this borrows)
 *
 * @see force-app/main/default/classes/DispositionBuyerTimelineService.cls
 * @see force-app/main/default/classes/DispositionBuyerTimelineController.cls
 */
@isTest
private class DispositionBuyerTimelineTest {

    private static final String STATUS_SIGNED = 'Signed';
    private static final String STATUS_SENT = 'Sent';
    private static final String STATUS_DECLINED = 'Declined';
    private static final String ROLE_BUYER = 'Buyer';
    private static final String ROLE_BROKER = 'Introducing Broker';

    /**
     * A disposition with no children of its own.
     *
     * ⚠ Created at `Disposition Readiness` (the factory default) and NEVER advanced by `update`.
     * `All_NDAs_Signed_Before_Progression` blocks a stage change into `Release Materials` and beyond
     * unless every non-Declined NDA is Signed, and none of these tests needs a stage at all — the
     * timeline reads NDAs and offers, not the parent's stage.
     */
    private static Disposition__c freshDisposition() {
        return TestDataFactory.createDisposition(null, true);
    }

    /**
     * A buyer-role NDA on a disposition, unsaved, with its factory `Counterparty_Name__c` replaced
     * by a caller-supplied literal so a name assertion can only pass on purpose.
     */
    private static NDA__c buyerNda(Id dispositionId, String counterpartyName) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Counterparty_Name__c = counterpartyName;
        return nda;
    }

    /** The single row for a disposition, asserted to exist. */
    private static DispositionBuyerTimelineService.BuyerRow onlyRow(Id dispositionId) {
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(dispositionId);
        Assert.areEqual(1, rows.size(), 'FIXTURE PRECONDITION: exactly one timeline row expected');
        return rows[0];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 THE LATCH TESTS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 HALF 1 OF THE TRAP. `NDA_Signed__c` is TRUE and `Status__c` is `Sent` — the exact state the
     * latching checkbox produces, and the state every NDA sat in between `Sent` and `Signed`. The
     * timeline must show NO signed date, because the party has not signed.
     */
    @isTest
    static void sentNdaWithLatchedSignedFlag_showsNoSignedDate() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Latched Larry');
        nda.Status__c = STATUS_SENT;
        // The latch: true while the status says otherwise. The flow does not touch the checkbox for
        // 'Sent', so this value survives the save — see the class header.
        nda.NDA_Signed__c = true;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 1);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isNull(row.ndaSignedDate,
            '🔴 A `Sent` NDA has NOT been signed, whatever the latching NDA_Signed__c checkbox says. '
            + 'If this is ever green with a date, someone has wired the timeline to the checkbox.');
        Assert.isFalse(row.isDeclined, 'Sent is an in-flight state, not a terminated one');
        Assert.areEqual(STATUS_SENT, row.status, 'and the raw status travels for the a11y label');
    }

    /**
     * 🔴 HALF 2 OF THE TRAP, AND THE SHARPER HALF. A DECLINED party who really did sign earlier
     * retains a non-null `Date_Signed__c` forever — `NDA_Signed_Status_Sync` never clears it. The
     * timeline must show NO dates at all for them: not the signature date, not the materials date,
     * and neither duration.
     */
    @isTest
    static void declinedNdaWithRetainedSignedDate_showsNoDatesAtAll() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Walked-Away Wanda');
        nda.Status__c = STATUS_DECLINED;
        // The retained date. This is the real production shape, not a contrivance.
        nda.Date_Signed__c = Date.newInstance(2026, 2, 14);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 2, 20);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isTrue(row.isDeclined, 'The row must be flagged terminated');
        Assert.isNull(row.ndaSignedDate,
            '🔴 The RETAINED signature date must never cross the boundary — it is exactly the '
            + 'misleading value this whole feature exists to suppress');
        Assert.isNull(row.materialsReleasedDate, 'nor the materials date');
        Assert.isNull(row.firstOfferDate, 'nor a first offer');
        Assert.isNull(row.daysToRelease, 'nor either duration');
        Assert.isNull(row.daysToRespond, 'nor either duration');
        Assert.areEqual('Walked-Away Wanda', row.buyerName,
            'but the buyer IS named — a declined party is audit evidence and is never hidden');
    }

    /** A declined party APPEARS. Hiding them would make this card disagree with the related list. */
    @isTest
    static void declinedParty_isIncludedNotHidden() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Walked-Away Wanda');
        nda.Status__c = STATUS_DECLINED;
        insert nda;

        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'A declined party must still produce a row: NDA__c.allowDelete is FALSE by decision '
            + 'D20, so they persist, and the NDAs related list on the same page will show them');
    }

    /** Declined parties sort LAST, after every active party, whatever order they were created in. */
    @isTest
    static void declinedParties_sortAfterActiveOnes() {
        Disposition__c d = freshDisposition();
        // Deliberately created declined-FIRST so a passing assertion cannot be creation order.
        NDA__c declined = buyerNda(d.Id, 'Aaron Declined');
        declined.Status__c = STATUS_DECLINED;
        NDA__c active = buyerNda(d.Id, 'Zoe Active');
        active.Status__c = STATUS_SENT;
        insert new List<NDA__c>{ declined, active };

        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both parties appear');
        Assert.areEqual('Zoe Active', rows[0].buyerName,
            'The ACTIVE party comes first even though the declined one was created first — and '
            + 'even though its name sorts later alphabetically, which rules out a name sort');
        Assert.areEqual('Aaron Declined', rows[1].buyerName, 'and the declined one is last');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The happy path and the durations
    // ─────────────────────────────────────────────────────────────────────────

    /** The complete journey: three dates and both durations, computed from the signed gate. */
    @isTest
    static void signedNdaWithMaterialsAndOffer_computesBothDurations() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'IGNORED - THE LOOKUP WINS');
        nda.Buyer__c = buyer.Id;
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 3, 9);
        insert nda;

        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Buyer__c = buyer.Id;
        offer.Offer_Date__c = Date.newInstance(2026, 3, 24);
        insert offer;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 3, 2), row.ndaSignedDate, 'signed date');
        Assert.areEqual(Date.newInstance(2026, 3, 9), row.materialsReleasedDate, 'materials date');
        Assert.areEqual(Date.newInstance(2026, 3, 24), row.firstOfferDate, 'first offer date');
        Assert.areEqual(7, row.daysToRelease, 'Mar 2 -> Mar 9 is seven days');
        Assert.areEqual(15, row.daysToRespond, 'Mar 9 -> Mar 24 is fifteen days');
        Assert.isFalse(row.hasDateAnomaly, 'and nothing is out of order');
        Assert.areEqual(buyer.FirstName + ' ' + buyer.LastName, row.buyerName,
            'The linked Contact WINS over the typed Counterparty_Name__c when both are present');
    }

    /** A mid-journey row: signed, nothing released. Both durations null, and NOT flagged. */
    @isTest
    static void signedButNothingReleased_leavesDurationsNullWithoutFlagging() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Mid-Journey Mo');
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 3, 2), row.ndaSignedDate, 'the signature shows');
        Assert.isNull(row.materialsReleasedDate, 'a blank materials date is NORMAL');
        Assert.isNull(row.daysToRelease, 'so the duration cannot be stated');
        Assert.isFalse(row.hasDateAnomaly,
            '🔴 A MISSING date must NOT raise the anomaly flag. Most rows sit mid-journey, and '
            + 'flagging them would cry wolf on the majority of the card.');
    }

    /**
     * 🔴 NEVER RENDER A NEGATIVE DURATION. Materials back-dated to BEFORE the signature — reachable
     * with ordinary data entry — must yield a null duration AND raise the anomaly flag, so the
     * analyst learns their dates disagree instead of seeing an unexplained blank.
     */
    @isTest
    static void materialsBeforeSignature_suppressesTheDurationAndFlagsTheRow() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Backwards Bob');
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 4, 10);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 4, 6);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isNull(row.daysToRelease,
            '🔴 A negative duration must never reach the component. -4 days is not a duration.');
        Assert.isTrue(row.hasDateAnomaly,
            'and the row must be FLAGGED, so the contradiction is visible rather than merely blank');
    }

    /** An offer that pre-dates the materials release flags the SECOND duration the same way. */
    @isTest
    static void offerBeforeMaterialsRelease_suppressesTheResponseDurationAndFlags() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'Eager Ellie');
        nda.Buyer__c = buyer.Id;
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 5, 1);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 5, 10);
        insert nda;

        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Buyer__c = buyer.Id;
        // Bid before the formal package went out — unusual but entirely real.
        offer.Offer_Date__c = Date.newInstance(2026, 5, 4);
        insert offer;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(9, row.daysToRelease, 'The FIRST duration is fine and must still compute');
        Assert.isNull(row.daysToRespond, 'The second is negative and must be suppressed');
        Assert.isTrue(row.hasDateAnomaly, 'and the row is flagged');
    }

    /** A same-day span is ZERO, not null — zero is a real, meaningful duration. */
    @isTest
    static void materialsReleasedOnTheSigningDay_computesZeroNotNull() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Same-Day Sam');
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 6, 1);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 6, 1);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(0, row.daysToRelease,
            '🔴 ZERO IS A REAL DURATION (same-day release) and must not collapse into null. A '
            + 'truthiness test instead of an explicit null test is how that regression happens.');
        Assert.isFalse(row.hasDateAnomaly, 'and zero is not negative');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scoping — role, disposition, and the offer tie-break
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 AN `Introducing Broker` NDA IS NOT A BUYER AND MUST NOT APPEAR. Every column on this card is
     * a statement about a prospective purchaser; a broker row would also inflate the buyer count the
     * analyst reads off it.
     */
    @isTest
    static void introducingBrokerNda_isExcluded() {
        Disposition__c d = freshDisposition();
        NDA__c buyerRow = buyerNda(d.Id, 'Real Buyer');
        NDA__c brokerRow = buyerNda(d.Id, 'Introducing Broker Bob');
        brokerRow.Party_Role__c = ROLE_BROKER;
        insert new List<NDA__c>{ buyerRow, brokerRow };

        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the BUYER-role NDA may produce a row');
        Assert.areEqual('Real Buyer', rows[0].buyerName, 'and it is the buyer, not the broker');
    }

    /**
     * 🔴 THE SAME BUYER'S OFFER ON A **DIFFERENT** DISPOSITION MUST NOT LEAK IN. Without the
     * `dispositionId` term in `selectEarliestByBuyerIds`, another sale's earlier bid would be
     * reported as this sale's first offer — a wrong date with nothing on the page to contradict it.
     */
    @isTest
    static void offerOnAnotherDisposition_isNotCounted() {
        Disposition__c thisSale = freshDisposition();
        Disposition__c otherSale = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);

        NDA__c nda = buyerNda(thisSale.Id, 'Cross-Deal Chris');
        nda.Buyer__c = buyer.Id;
        insert nda;

        // An EARLIER offer, by the same buyer, on the OTHER sale. If scoping is broken this wins.
        Disposition_Offer__c foreign = TestDataFactory.createDispositionOffer(otherSale.Id, false);
        foreign.Buyer__c = buyer.Id;
        foreign.Offer_Date__c = Date.newInstance(2026, 1, 1);
        Disposition_Offer__c own = TestDataFactory.createDispositionOffer(thisSale.Id, false);
        own.Buyer__c = buyer.Id;
        own.Offer_Date__c = Date.newInstance(2026, 7, 15);
        insert new List<Disposition_Offer__c>{ foreign, own };

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(thisSale.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 7, 15), row.firstOfferDate,
            'The first offer ON THIS SALE. The other sale\'s earlier bid must not leak in.');
    }

    /** Of several offers by one buyer, the EARLIEST wins. */
    @isTest
    static void severalOffersByOneBuyer_takesTheEarliest() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'Repeat Bidder');
        nda.Buyer__c = buyer.Id;
        insert nda;

        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(3, d.Id, false);
        offers[0].Offer_Date__c = Date.newInstance(2026, 8, 20);
        offers[1].Offer_Date__c = Date.newInstance(2026, 8, 4);
        offers[2].Offer_Date__c = Date.newInstance(2026, 8, 11);
        for (Disposition_Offer__c offer : offers) {
            offer.Buyer__c = buyer.Id;
        }
        insert offers;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 8, 4), row.firstOfferDate,
            'The earliest of the three, regardless of insert order');
    }

    /**
     * 🔴 AN UNDATED OFFER MUST NOT WIN. SOQL sorts NULLS FIRST on an ASC order, so without the
     * `Offer_Date__c != NULL` filter an undated offer would sort to the top and become "the earliest
     * offer" — with a null date — blanking the column for a buyer who demonstrably DID bid.
     */
    @isTest
    static void undatedOffer_doesNotDisplaceTheDatedOne() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'Half-Keyed Hank');
        nda.Buyer__c = buyer.Id;
        insert nda;

        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, d.Id, false);
        offers[0].Offer_Date__c = null;
        offers[1].Offer_Date__c = Date.newInstance(2026, 9, 9);
        for (Disposition_Offer__c offer : offers) {
            offer.Buyer__c = buyer.Id;
        }
        insert offers;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 9, 9), row.firstOfferDate,
            'The DATED offer must win. A null sorting first would blank this column.');
    }

    /**
     * TWO OFFERS ON THE SAME DAY — the `Id ASC` tie-break. `Offer_Date__c` is a Date, so ties are
     * routine rather than contrived; without the second sort key the chosen row (and therefore the
     * rendered value) is non-deterministic between renders.
     *
     * ⚠ Both rows carry the SAME date, so the asserted VALUE cannot distinguish them. What this
     * test pins is DETERMINISM: repeated calls in one transaction must agree, and the value must be
     * that shared date rather than null.
     */
    @isTest
    static void twoOffersOnTheSameDay_resolveDeterministically() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'Tie-Break Tina');
        nda.Buyer__c = buyer.Id;
        insert nda;

        Date sameDay = Date.newInstance(2026, 10, 5);
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, d.Id, false);
        for (Disposition_Offer__c offer : offers) {
            offer.Buyer__c = buyer.Id;
            offer.Offer_Date__c = sameDay;
        }
        insert offers;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow first = onlyRow(d.Id);
        DispositionBuyerTimelineService.BuyerRow second = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(sameDay, first.firstOfferDate, 'the shared date is returned');
        Assert.areEqual(first.firstOfferDate, second.firstOfferDate,
            'and two reads in one transaction agree — the Id ASC tie-break is what guarantees it');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Legacy rows — no lookup, no backfill
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A LEGACY row (typed `Counterparty_Name__c`, NULL `Buyer__c`) still renders, named from the
     * text. **There is no backfill and none is in scope** — this fallback is the entire mitigation.
     *
     * ⚠ ITS FIRST-OFFER COLUMN IS PERMANENTLY BLANK, AND THAT IS ASSERTED RATHER THAN TOLERATED:
     * with no Contact Id there is nothing to match an offer against. Matching on NAME was rejected —
     * two buyers can share a name, and a name-matched offer would attribute one buyer's bid to
     * another.
     */
    @isTest
    static void legacyNdaWithNoBuyerLookup_fallsBackToTheTypedName() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Legacy Lorraine');
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        // An offer exists on this sale, but it can never be attributed to a lookup-less NDA.
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Offer_Date__c = Date.newInstance(2026, 3, 20);
        insert offer;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual('Legacy Lorraine', row.buyerName,
            'The typed Counterparty_Name__c is the fallback for pre-Buyer__c rows');
        Assert.isNull(row.firstOfferDate,
            'and with no Contact Id there is nothing to match an offer against — matching on NAME '
            + 'was rejected because two buyers can share one');
    }

    /** Neither a lookup nor a typed name yields a placeholder, never a blank first column. */
    @isTest
    static void ndaWithNeitherLookupNorTypedName_rendersAPlaceholder() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, null);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.BuyerRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(row.buyerName),
            'A blank first column is indistinguishable from a rendering failure, so a placeholder '
            + 'is used instead');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Budget
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE CONSTANT-QUERY FALSIFIER: MANY buyers, EXACTLY TWO queries. A per-buyer offer read is
     * the specific defect `selectEarliestByBuyerIds` was written to prevent, and only a query-count
     * assertion catches it — every row-value assertion in this class would stay green.
     */
    @isTest
    static void manyBuyers_costsExactlyTwoQueries() {
        Disposition__c d = freshDisposition();
        Integer buyerCount = 25;
        List<Contact> buyers = TestDataFactory.createContacts(buyerCount, null, true);

        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(buyerCount, d.Id, false);
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(buyerCount, d.Id, false);
        for (Integer i = 0; i < buyerCount; i++) {
            ndas[i].Buyer__c = buyers[i].Id;
            ndas[i].Status__c = STATUS_SIGNED;
            ndas[i].Date_Signed__c = Date.today().addDays(-30);
            ndas[i].Materials_Released_Date__c = Date.today().addDays(-20);
            offers[i].Buyer__c = buyers[i].Id;
            offers[i].Offer_Date__c = Date.today().addDays(-10);
        }
        insert ndas;
        insert offers;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(buyerCount, rows.size(), 'One row per buyer NDA');
        Assert.areEqual(2, queriesUsed,
            'EXACTLY TWO queries for ' + buyerCount + ' buyers — one for the NDAs and one for ALL '
            + 'the offers. A per-buyer offer read would be SOQL in a loop on a page render.');
        for (DispositionBuyerTimelineService.BuyerRow row : rows) {
            Assert.areEqual(10, row.daysToRelease, 'and every row computed its first duration');
            Assert.areEqual(10, row.daysToRespond, 'and its second');
        }
    }

    /**
     * The FLOOR of that budget is ONE, not two. When no NDA carries a buyer lookup — every
     * legacy-only disposition — the offer selector returns empty WITHOUT querying.
     */
    @isTest
    static void noBuyerLookups_skipsTheOfferQueryEntirely() {
        Disposition__c d = freshDisposition();
        insert TestDataFactory.createDispositionNdas(3, d.Id, false);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'The legacy rows still render');
        Assert.areEqual(1, queriesUsed,
            'ONE query. With no buyer Ids to match, the offer read must be skipped entirely rather '
            + 'than issued against an empty set.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Selector contracts
    // ─────────────────────────────────────────────────────────────────────────

    /** Both new selector methods are null/empty-safe and issue NO query on the guard path. */
    @isTest
    static void selectors_areNullAndEmptySafeWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<NDA__c> noNdas = NdaSelector.selectBuyerTimelineByDispositionId(null);
        List<Disposition_Offer__c> noOffersNullSet =
            DispositionOfferSelector.selectEarliestByBuyerIds(null, null);
        List<Disposition_Offer__c> noOffersEmptySet =
            DispositionOfferSelector.selectEarliestByBuyerIds(new Set<Id>(), null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.isTrue(noNdas.isEmpty(), 'A null disposition Id yields an empty list, never null');
        Assert.isTrue(noOffersNullSet.isEmpty(), 'and so does a null buyer set');
        Assert.isTrue(noOffersEmptySet.isEmpty(), 'and an empty one');
        Assert.areEqual(0, queriesUsed, 'None of the three may issue a query');
    }

    /**
     * `selectEarliestByBuyerIds` refuses an UNSCOPED read. A null disposition returns empty rather
     * than every offer those buyers ever made, because an unscoped answer here would be actively
     * wrong rather than merely broad.
     */
    @isTest
    static void selectEarliestByBuyerIds_withNullDisposition_returnsEmpty() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Buyer__c = buyer.Id;
        offer.Offer_Date__c = Date.today();
        insert offer;

        Test.startTest();
        List<Disposition_Offer__c> rows = DispositionOfferSelector.selectEarliestByBuyerIds(
            new Set<Id>{ buyer.Id }, null
        );
        Test.stopTest();

        Assert.isTrue(rows.isEmpty(),
            'A null disposition must return NOTHING, not every offer this buyer ever made');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Controller boundary
    // ─────────────────────────────────────────────────────────────────────────

    /** The controller returns the service's rows unchanged, in order. */
    @isTest
    static void controller_returnsTheTimeline() {
        Disposition__c d = freshDisposition();
        NDA__c nda = buyerNda(d.Id, 'Controller Carol');
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineController.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One row');
        Assert.areEqual('Controller Carol', rows[0].buyerName, 'passed through unchanged');
        Assert.areEqual(Date.newInstance(2026, 3, 2), rows[0].ndaSignedDate, 'dates included');
    }

    /** A null Id is a normal early render, not an error. */
    @isTest
    static void controller_withNullId_returnsEmptyList() {
        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineController.getTimeline(null);
        Test.stopTest();

        Assert.isNotNull(rows, 'Never null — the component would have to guard it');
        Assert.isTrue(rows.isEmpty(), 'and empty');
    }

    /** A disposition with no buyer NDA is an empty state, not an error. */
    @isTest
    static void controller_withNoBuyerNdas_returnsEmptyList() {
        Disposition__c d = freshDisposition();

        Test.startTest();
        List<DispositionBuyerTimelineService.BuyerRow> rows =
            DispositionBuyerTimelineController.getTimeline(d.Id);
        Test.stopTest();

        Assert.isTrue(rows.isEmpty(),
            '"No buyer has signed yet" is a normal early state, rendered as an empty state');
    }

    /**
     * 🔴 A WRONG SOBJECT TYPE IS REFUSED, LOUDLY. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it simply matches no rows — so without this
     * guard a component wired to the wrong `record-id` would render a confident, permanent empty
     * state and nobody would ever learn the card was pointed at the wrong record.
     */
    @isTest
    static void controller_withWrongSObjectType_throwsAuraHandledException() {
        Contact notADisposition = TestDataFactory.createContact(null, true);
        Boolean threw = false;

        Test.startTest();
        try {
            DispositionBuyerTimelineController.getTimeline(notADisposition.Id);
            Assert.fail('A Contact Id must not be accepted as a Disposition Id');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Disposition'),
                'and the message must name the expected object rather than being the generic '
                + 'read-failure text — a wiring mistake and a permission gap need different fixes');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The guard must fire');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 🔴 The cross-permission-set coupling: Contact read
    // ─────────────────────────────────────────────────────────────────────────

    /** The disposition read grant every timeline persona has. Grants NO `Contact` access. */
    private static final String PERMSET_DISPOSITION_VIEW = 'DPEG_Disposition_View';

    /** The SEPARATE set the `Buyer__r.Name` traversal actually depends on. */
    private static final String PERMSET_CONTACT_VIEW = 'DPEG_Contact_View';

    /**
     * A persona holding the REAL deployed `DPEG_Disposition_View`, plus the REAL deployed
     * `DPEG_Contact_View` when `withContactRead` is true — the ONLY difference between the two users
     * this test builds.
     *
     * 🔴 THE BASE PROFILE IS `Minimum Access - Salesforce`, NOT `Standard User`, AND THAT IS THE
     * WHOLE REASON THIS TEST CAN WORK. Measured against `usman-dpeg` on 2026-08-20: the
     * `Standard User` profile carries `ObjectPermissions.PermissionsRead = true` on `Contact`, so a
     * persona built on it can read Contact NO MATTER WHAT permission sets are withheld — the denial
     * would be silently masked and the "denied" persona would read the timeline just fine. The
     * sibling helper this is modelled on (`DispositionDealSummaryServiceTest.userDeniedAccessTo`) can
     * safely use `Standard User` because every object IT denies is a CUSTOM one the profile does not
     * grant; `Contact` is standard, and that difference is load-bearing here.
     * `Minimum Access - Salesforce` has no `Contact` ObjectPermissions row at all (same measurement).
     *
     * ⚠ THE REAL PERMISSION SETS ARE USED, NOT A DYNAMICALLY BUILT ONE. That is deliberate and is the
     * point of the test: a hand-built set would only prove the platform enforces Contact read (which
     * is not in doubt), whereas assigning the ACTUAL `DPEG_Disposition_View` also asserts that it
     * still does NOT grant Contact — verified 2026-08-20, it has no `Contact` ObjectPermissions row —
     * so if someone ever folds Contact read into the disposition set, the denial test below goes red
     * and the documented coupling gets re-examined instead of quietly ceasing to exist.
     *
     * ⚠ `User` DML is SETUP-object DML and every caller also inserts `Disposition__c` / `NDA__c`
     * (non-setup) in the same transaction, so it runs inside
     * `System.runAs(new User(Id = UserInfo.getUserId()))` — the MIXED_DML_OPERATION workaround used
     * by `DispositionDealSummaryServiceTest` and `RecordStageAdvanceServiceTest`.
     *
     * @param withContactRead Whether to also assign `DPEG_Contact_View`.
     * @return The persona, inserted and assigned.
     */
    private static User dispositionPersona(Boolean withContactRead) {
        Profile minimumAccess = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];

        List<String> setNames = new List<String>{ PERMSET_DISPOSITION_VIEW };
        if (withContactRead) {
            setNames.add(PERMSET_CONTACT_VIEW);
        }
        List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name IN :setNames];
        Assert.areEqual(setNames.size(), sets.size(),
            'FIXTURE PRECONDITION: ' + setNames + ' must all exist in the org. If a set was RENAMED, '
            + 'fix the constant — do not delete this test, the coupling it pins is still real.');

        String unique = 'btlfls' + String.valueOf(DateTime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User persona = new User(
            FirstName = 'Buyer',
            LastName = withContactRead ? 'TimelineContactOk' : 'TimelineNoContact',
            Alias = 'btlfls',
            Email = 'btlfls@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert persona;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : sets) {
                assignments.add(new PermissionSetAssignment(
                    AssigneeId = persona.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return persona;
    }

    /**
     * 🔴 PINS THE EIGHTH GATE: `Buyer__r.Name` NEEDS `Contact` OBJECT READ, AND THE DISPOSITION
     * PERMISSION SETS DO NOT GRANT IT.
     *
     * `NdaSelector.selectBuyerTimelineByDispositionId`'s header documents this at length — the
     * traversal's grant comes from `DPEG_Contact_View` / `DPEG_Contact_Edit`, which are SEPARATE
     * members of the same permission set GROUPS (`DPEG_Principal_PSG`, `DPEG_Junior_Analyst_PSG`).
     * Both groups carry them today, so both intended personas work. But a documented coupling that
     * nothing executes is a coupling that can be dissolved by a PSG edit in Setup, and the first
     * anyone would learn of it is an error banner on a production record page.
     *
     * ── WHY TWO PERSONAS AND NOT ONE ──
     * "The denied persona throws" on its own proves almost nothing: this query has EIGHT other FLS
     * gates, and ANY of them missing produces the same `QueryException`. The control persona is
     * identical in every respect except that it also holds `DPEG_Contact_View`, so the exception is
     * attributable to that one set and to nothing else. If the control ALSO throws, the finding is a
     * real provisioning gap somewhere else in the ten grants — read its message, do not weaken it.
     *
     * ⚠ THE CONTROL ASSERTS "DID NOT THROW", NOT A ROW COUNT, AND THAT IS NOT LAZINESS.
     * `DPEG_Disposition_View` grants `NDA__c` read with `PermissionsViewAllRecords = FALSE` (measured
     * 2026-08-20) and `NDA__c` is OWD Private, so a persona holding it cannot SEE rows this test's
     * admin context created. FLS/CRUD is evaluated when the query is validated, before sharing
     * filters any rows, so the denial still throws for the second persona with zero visible rows —
     * but the granted persona legitimately reads an EMPTY list. Asserting `1` here would fail for a
     * sharing reason that has nothing to do with what this test is about.
     *
     * ⚠ AND IT ASSERTS `QueryException`, NOT `Exception`. That is the type both selector headers and
     * `DispositionBuyerTimelineService`'s `@throws` clause promise. If the platform ever delivers a
     * different type here, that is a genuine finding worth writing down — widen this catch only
     * together with those three docs, never on its own.
     */
    @isTest
    static void contactReadDenied_theBuyerTraversalThrows() {
        Disposition__c d = freshDisposition();
        Contact buyer = TestDataFactory.createContact(null, true);
        NDA__c nda = buyerNda(d.Id, 'Gated Gary');
        nda.Buyer__c = buyer.Id;
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        User contactGranted = dispositionPersona(true);
        User contactDenied = dispositionPersona(false);

        Exception controlFailure;
        Exception deniedFailure;

        Test.startTest();
        System.runAs(contactGranted) {
            try {
                DispositionBuyerTimelineService.getTimeline(d.Id);
            } catch (Exception e) {
                controlFailure = e;
            }
        }
        System.runAs(contactDenied) {
            try {
                DispositionBuyerTimelineService.getTimeline(d.Id);
            } catch (Exception e) {
                deniedFailure = e;
            }
        }
        Test.stopTest();

        Assert.isNull(controlFailure,
            'CONTROL: the SAME read must succeed for a persona differing only by DPEG_Contact_View. '
            + 'It did not, so the failure below is NOT attributable to Contact — one of the other ten '
            + 'documented grants is missing. Actual: '
            + (controlFailure == null ? 'none' : controlFailure.getTypeName() + ': '
                + controlFailure.getMessage()));

        Assert.isNotNull(deniedFailure,
            '🔴 A persona holding DPEG_Disposition_View but NOT DPEG_Contact_View MUST NOT be able '
            + 'to read this timeline: Buyer__r.Name traverses to Contact and USER_MODE enforces '
            + 'object read on the traversed object. If this is green, either the disposition set has '
            + 'started granting Contact (re-check the cross-permission-set note in NdaSelector) or '
            + 'the traversal was removed from the query.');
        Assert.isTrue(deniedFailure instanceof QueryException,
            'and the documented type is System.QueryException. Actual: '
            + deniedFailure.getTypeName() + ': ' + deniedFailure.getMessage());

        // The user-visible half: the controller converts it to the generic READ failure, NOT to the
        // wrong-SObject-type message — a permission gap and a wiring mistake need different fixes.
        Boolean controllerRefused = false;
        System.runAs(contactDenied) {
            try {
                DispositionBuyerTimelineController.getTimeline(d.Id);
                Assert.fail('The controller must not return an empty timeline for a permission gap');
            } catch (AuraHandledException e) {
                controllerRefused = true;
                Assert.isTrue(e.getMessage().contains('could not be loaded'),
                    'The generic read-failure message is required here. A permission gap must NOT '
                    + 'borrow the wrong-SObject-type wording. Actual: ' + e.getMessage());
            }
        }
        Assert.isTrue(controllerRefused,
            'and the boundary must convert it rather than swallowing it into an empty card');
    }
}
