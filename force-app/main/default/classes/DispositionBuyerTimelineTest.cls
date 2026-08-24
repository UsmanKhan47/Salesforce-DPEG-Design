/**
 * @description Tests the read path behind the card titled "Buyer Activity timeline" end to end —
 * `DispositionBuyerTimelineController` -> `DispositionBuyerTimelineService` ->
 * `NdaSelector.selectBuyerTimelineByDispositionId` **and**
 * `ReleaseMaterialsResponseService.getResponses`
 * (`agent-output/disposition-tranche-2-requirements.md` §3 D6.3, added 2026-08-20;
 * RETARGETED 2026-08-21; MERGED 2026-08-24).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THE 2026-08-24 MERGE CHANGED IN THIS CLASS
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The card now carries TWO KINDS OF ROW in one chronological list, newest first: buyer-role NDAs
 * and Release Materials responses. Three consequences here, and the second is the important one:
 *   1. `NdaRow` -> `TimelineRow` throughout. A pure rename; no assertion changed meaning.
 *   2. 🔴 `declinedParties_sortAfterActiveOnes` WAS REPLACED, NOT EDITED. Its rule ("declined last")
 *      was deliberately retired — a chronological merge and a status-pinned tail cannot both be
 *      true. ⚠ AND IT WOULD HAVE SURVIVED THE CHANGE **VACUOUSLY**: its fixture created the
 *      declined NDA first, so "the active row comes first" is ALSO true under newest-first, for a
 *      completely different reason. The replacement inverts the fixture so only one rule can pass.
 *      Read `declinedParty_takesItsCHRONOLOGICALPlace_notATailPosition`.
 *   3. The budget went from ONE query to TWO (`manyNdas_costsExactlyTwoQueries`). The second read
 *      is unconditional by design — a sale can carry responses and no NDA at all.
 * ⚠ AN NDA ROW'S CONTENT IS UNCHANGED and `ndaRow_carriesEveryPreMergeFieldUnchanged` pins that
 * field by field, because the Jest fixtures in `lwc/dispositionBuyerTimeline/__tests__` were
 * written before the merge and must keep rendering identically.
 *
 * ⚠ THE API NAMES SAY "BUYER", THE CARD SAYS "BROKER", AND A ROW IS AN NDA — all three disagree on
 * purpose (`DispositionBuyerTimelineService`'s header carries the argument: a rename is a FlexiPage
 * edit plus a destructive Apex delete, so only the user-visible strings changed). Nothing in THIS
 * class asserts on the title — it is a server-side suite and the title lives in the LWC, pinned by
 * `lwc/dispositionBuyerTimeline/__tests__` — so a re-titling does not and should not touch it.
 * 🔴 What this suite DOES pin against the title is the row shape: **one element per NDA**, with the
 * SAME broker name repeating across a sale's rows. That repetition is correct — one appointed
 * broker per disposition — and any future "group by broker" would break these tests, which is the
 * intended outcome: grouping would collapse a multi-NDA sale to one row and delete the timeline.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHAT THE 2026-08-21 RETARGET DELETED FROM THIS CLASS, AND WHY IT IS RECORDED HERE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * DPEG communicates only with the appointed listing broker; buyers sit behind them and are not
 * tracked. The card became one row per NDA, labelled by the NDA's NUMBER with its BROKER beneath.
 * SIX tests were DELETED rather than weakened, all of them about the "first offer" column:
 *   `offerOnAnotherDisposition_isNotCounted`, `severalOffersByOneBuyer_takesTheEarliest`,
 *   `undatedOffer_doesNotDisplaceTheDatedOne`, `twoOffersOnTheSameDay_resolveDeterministically`,
 *   `offerBeforeMaterialsRelease_suppressesTheResponseDurationAndFlags`, and
 *   `selectEarliestByBuyerIds_withNullDisposition_returnsEmpty`.
 * They were good tests. They tested a JOIN THAT NO LONGER EXISTS: with the buyer gone from the
 * offer form, nothing links a `Disposition_Offer__c` to a specific `NDA__c`, so no attribution the
 * card could make would be true. 🔴 THE SUBSTITUTE — the disposition's earliest offer across all
 * NDAs — WAS REFUSED: it renders the same date on every row under a per-row label, which is a fixed
 * lie rather than a missing value.
 * ⚠ Their fixtures (`Offer_Date__c != NULL` beating a null sort, the `Id ASC` tie-break on a
 * same-day pair) encode non-obvious SOQL behaviour. Recover them from git history if a per-NDA
 * offer link is ever built; do not re-derive them.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE TWO TESTS THAT MATTER MOST ARE THE LATCH TESTS. EVERYTHING ELSE IS SUPPORTING WORK.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The whole feature exists in the shadow of one trap with two halves, and the retarget did NOT
 * touch either half:
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
 * ── 🔴 DEPLOY-ORDER NOTE: `NDA__c.Broker__c` IS NEW ──
 * It is a 2026-08-21 field owned by the admin agent and did NOT exist in `usman-dpeg` when this
 * class was written (confirmed by `sf sobject describe`). Until it deploys, every test here that
 * inserts an `NDA__c` carrying a broker fails at RUNTIME with `DmlException: Operation failed due to
 * fields being inaccessible` or `QueryException: No such column` — neither of which means what it
 * says, and neither of which is a defect in this class. See the header of
 * `.claude/agent-memory-local/salesforce-developer/dryrun-with-undeployed-dependencies.md`.
 *
 * ── BULK ──
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does NOT attach to this class, and that
 * is an argued position rather than an omission: nothing here is a trigger, a batch, a queueable or
 * a DML-performing service — it is a READ invoked once per page view. The mandate DOES apply in full
 * to this tranche's write paths, and the 251-record tests live where they belong, in
 * `NdaBuyerStampServiceTest` and `DispositionOfferBuyerStampServiceTest`.
 * 🔴 THE PROPERTY THAT MATTERS HERE IS A **CONSTANT QUERY COUNT ACROSS MANY NDAs**, and it IS
 * asserted (`manyNdas_costsExactlyOneQuery`). The broker's name is TRAVERSED in the same query; a
 * per-NDA Contact read would be SOQL in a loop on a page render, and a row count alone would never
 * catch it. ⚠ THE BUDGET DROPPED FROM TWO QUERIES TO ONE when the offer read was deleted — the
 * number is asserted, so a re-added read fails here first.
 *
 * ── THE CROSS-PERMISSION-SET PIN (added 2026-08-20, re-review S3; retargeted 2026-08-21) ──
 * `NdaSelector.selectBuyerTimelineByDispositionId` traverses a Contact lookup, and `WITH USER_MODE`
 * enforces OBJECT read on the traversed `Contact`. NEITHER disposition permission set grants it —
 * it arrives from `DPEG_Contact_View` / `DPEG_Contact_Edit`, separate members of the same permission
 * set GROUPS. Until this class carried `contactReadDenied_theBrokerTraversalThrows` there was no
 * `System.runAs` anywhere in the `DispositionBuyerTimeline*` classes, so a future PSG edit that
 * dropped the Contact member would break the card in PRODUCTION with nothing going red first.
 * ⚠ THE TRAVERSAL MOVED FROM `Buyer__r.Name` TO `Broker__r.Name`. The gate is identical; only the
 * lookup changed.
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
    private static final String ROLE_BROKER = 'Introducing Broker';

    /**
     * A disposition with no children of its own.
     *
     * ⚠ Created at `Disposition Readiness` (the factory default) and NEVER advanced by `update`.
     * `All_NDAs_Signed_Before_Progression` blocks a stage change into `Release Materials` and beyond
     * unless every non-Declined NDA is Signed, and none of these tests needs a stage at all — the
     * timeline reads NDAs, not the parent's stage.
     */
    private static Disposition__c freshDisposition() {
        return TestDataFactory.createDisposition(null, true);
    }

    /**
     * A buyer-role NDA on a disposition, unsaved, optionally carrying a broker Contact.
     *
     * ⚠ `createBrokerContact` IS USED RATHER THAN `createContact`, DELIBERATELY. Every `Broker__c`
     * lookup in this org carries an ACTIVE, non-optional lookup filter on the `Contact.Broker`
     * record type, and DML — unlike SOQL — enforces it. A plain Contact would be refused at insert
     * with `FIELD_FILTER_VALIDATION_EXCEPTION`, which reads like a defect in the service.
     *
     * @param dispositionId  the parent sale
     * @param brokerContactId the appointed broker, or null for a pre-2026-08-21 row
     */
    private static NDA__c timelineNda(Id dispositionId, Id brokerContactId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Broker__c = brokerContactId;
        return nda;
    }

    /** A broker Contact, inserted. */
    private static Contact broker() {
        return TestDataFactory.createBrokerContact(null, true);
    }

    /** The single row for a disposition, asserted to exist. */
    private static DispositionBuyerTimelineService.TimelineRow onlyRow(Id dispositionId) {
        List<DispositionBuyerTimelineService.TimelineRow> rows =
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
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_SENT;
        // The latch: true while the status says otherwise. The flow does not touch the checkbox for
        // 'Sent', so this value survives the save — see the class header.
        nda.NDA_Signed__c = true;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 1);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
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
     * and not the duration.
     */
    @isTest
    static void declinedNdaWithRetainedSignedDate_showsNoDatesAtAll() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c nda = timelineNda(d.Id, appointed.Id);
        nda.Status__c = STATUS_DECLINED;
        // The retained date. This is the real production shape, not a contrivance.
        nda.Date_Signed__c = Date.newInstance(2026, 2, 14);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 2, 20);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isTrue(row.isDeclined, 'The row must be flagged terminated');
        Assert.isNull(row.ndaSignedDate,
            '🔴 The RETAINED signature date must never cross the boundary — it is exactly the '
            + 'misleading value this whole feature exists to suppress');
        Assert.isNull(row.materialsReleasedDate, 'nor the materials date');
        Assert.isNull(row.daysToRelease, 'nor the duration');
        Assert.isTrue(String.isNotBlank(row.ndaName),
            'but the NDA IS named — a declined party is audit evidence and is never hidden');
        Contact expected = [SELECT Name FROM Contact WHERE Id = :appointed.Id LIMIT 1];
        Assert.areEqual(expected.Name, row.brokerName, 'and its broker is still shown');
    }

    /** A declined party APPEARS. Hiding them would make this card disagree with the related list. */
    @isTest
    static void declinedParty_isIncludedNotHidden() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_DECLINED;
        insert nda;

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'A declined party must still produce a row: NDA__c.allowDelete is FALSE by decision '
            + 'D20, so they persist, and the NDAs related list on the same page will show them');
    }

    /**
     * 🔴 REPLACES `declinedParties_sortAfterActiveOnes`, WHICH THE 2026-08-24 MERGE RETIRED.
     *
     * That test pinned the rule "declined parties sort LAST, after every active party, whatever
     * order they were created in". **The merge deleted that rule on purpose** — a chronological
     * newest-first list and a status-pinned tail cannot both be true, and the instruction was
     * explicit. `DispositionBuyerTimelineService`'s header carries the full argument.
     *
     * ⚠ THE OLD TEST WOULD HAVE SURVIVED THE CHANGE **VACUOUSLY**, WHICH IS WHY IT WAS REPLACED
     * RATHER THAN LEFT ALONE. It created the declined NDA FIRST and the active one SECOND, then
     * asserted the active row came first. Under newest-first that assertion is ALSO true — for a
     * completely different reason (the active row is simply newer). It would have gone on passing
     * while testing nothing.
     *
     * So this test inverts the fixture: the DECLINED party is created LAST, i.e. it is the NEWEST
     * entry. Under the old rule it would have to be at the bottom; under the new one it must be at
     * the TOP. Those are the two possible answers and the test can only agree with one.
     * ⚠ `Test.setCreatedDate` IS REQUIRED. `CreatedDate` is second-granular, so two NDAs inserted in
     * one transaction share a key exactly and only the comparator's Id tie-break would decide —
     * which is deterministic but is not the property under test.
     */
    @isTest
    static void declinedParty_takesItsCHRONOLOGICALPlace_notATailPosition() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c active = timelineNda(d.Id, appointed.Id);
        active.Status__c = STATUS_SENT;
        NDA__c declined = timelineNda(d.Id, appointed.Id);
        declined.Status__c = STATUS_DECLINED;
        insert new List<NDA__c>{ active, declined };

        // The declined party is the NEWEST entry on the sale — the state the old rule would have
        // pushed to the bottom of the card.
        Test.setCreatedDate(active.Id, Datetime.now().addDays(-10));
        Test.setCreatedDate(declined.Id, Datetime.now().addDays(-1));

        Map<Id, NDA__c> named = new Map<Id, NDA__c>(
            [SELECT Id, Name FROM NDA__c WHERE Disposition__c = :d.Id]
        );

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both parties appear — inclusion is unchanged');
        // ⚠ ASSERTED ON THE **NDA Id**, NOT ON THE AUTONUMBER STRING. The AutoNumber increments
        // org-wide, is not predictable from a test, and happens to sort in creation order — so a
        // name-based assertion here could pass for the wrong reason.
        Assert.areEqual(declined.Id, rows[0].ndaId,
            '🔴 THE DECLINED PARTY IS FIRST BECAUSE IT IS THE NEWEST. If this is the ACTIVE row, '
            + 'the retired "declined last" rule has been restored — read the service header before '
            + '"fixing" it, because that removal was deliberate and was instructed.');
        Assert.areEqual(active.Id, rows[1].ndaId, 'and the older, still-active party is below it');
        Assert.isTrue(rows[0].isDeclined,
            'and the row is still MARKED declined — only its POSITION changed, not its treatment');
        Assert.areEqual(named.get(declined.Id).Name, rows[0].ndaName,
            'and it carries its own NDA number');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The happy path and the duration
    // ─────────────────────────────────────────────────────────────────────────

    /** The complete journey: both dates and the duration, computed from the signed gate. */
    @isTest
    static void signedNdaWithMaterials_computesTheDuration() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c nda = timelineNda(d.Id, appointed.Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 3, 9);
        insert nda;

        Contact expected = [SELECT Name FROM Contact WHERE Id = :appointed.Id LIMIT 1];
        NDA__c saved = [SELECT Name FROM NDA__c WHERE Id = :nda.Id LIMIT 1];

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 3, 2), row.ndaSignedDate, 'signed date');
        Assert.areEqual(Date.newInstance(2026, 3, 9), row.materialsReleasedDate, 'materials date');
        Assert.areEqual(7, row.daysToRelease, 'Mar 2 -> Mar 9 is seven days');
        Assert.isFalse(row.hasDateAnomaly, 'and nothing is out of order');
        // 🔴 THE ROW'S IDENTITY IS THE NDA NUMBER, and its BROKER is the party shown beside it.
        // Both replaced the buyer name on 2026-08-21.
        Assert.areEqual(saved.Name, row.ndaName, 'The row is identified by its NDA number');
        Assert.areEqual(expected.Name, row.brokerName, 'and labelled with the appointed broker');
    }

    /** A mid-journey row: signed, nothing released. The duration is null, and NOT flagged. */
    @isTest
    static void signedButNothingReleased_leavesTheDurationNullWithoutFlagging() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
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
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 4, 10);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 4, 6);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.isNull(row.daysToRelease,
            '🔴 A negative duration must never reach the component. -4 days is not a duration.');
        Assert.isTrue(row.hasDateAnomaly,
            'and the row must be FLAGGED, so the contradiction is visible rather than merely blank');
    }

    /** A same-day span is ZERO, not null — zero is a real, meaningful duration. */
    @isTest
    static void materialsReleasedOnTheSigningDay_computesZeroNotNull() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 6, 1);
        nda.Materials_Released_Date__c = Date.newInstance(2026, 6, 1);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(0, row.daysToRelease,
            '🔴 ZERO IS A REAL DURATION (same-day release) and must not collapse into null. A '
            + 'truthiness test instead of an explicit null test is how that regression happens.');
        Assert.isFalse(row.hasDateAnomaly, 'and zero is not negative');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scoping and identity
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 AN `Introducing Broker` NDA IS NOT ADMITTED, AND THE RETARGET DELIBERATELY DID NOT CHANGE
     * THAT. The card stopped labelling rows with a buyer; it did not change WHICH rows it shows.
     * Admitting broker-role NDAs would silently change the count the analyst reads off the card —
     * and it would be easy to do by accident now that the word "buyer" has left the UI.
     */
    @isTest
    static void introducingBrokerRoleNda_isStillExcluded() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c buyerRoleRow = timelineNda(d.Id, appointed.Id);
        NDA__c brokerRoleRow = timelineNda(d.Id, appointed.Id);
        brokerRoleRow.Party_Role__c = ROLE_BROKER;
        insert new List<NDA__c>{ buyerRoleRow, brokerRoleRow };

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'Only the BUYER-role NDA may produce a row. If this ever returns 2, the population was '
            + 'widened — which is a decision that needs making explicitly, not a tidy-up.');
        Assert.areEqual(buyerRoleRow.Id, rows[0].ndaId, 'and it is the buy-side one');
    }

    /** NDAs on another sale must not leak in. */
    @isTest
    static void ndasOnAnotherDisposition_areNotReturned() {
        Disposition__c thisSale = freshDisposition();
        Disposition__c otherSale = freshDisposition();
        Contact appointed = broker();

        NDA__c mine = timelineNda(thisSale.Id, appointed.Id);
        NDA__c theirs = timelineNda(otherSale.Id, appointed.Id);
        insert new List<NDA__c>{ mine, theirs };

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(thisSale.Id);
        Test.stopTest();

        Assert.areEqual(mine.Id, row.ndaId, 'One sale, one NDA list');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Legacy rows — no broker lookup, no backfill
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 A PRE-2026-08-21 NDA HAS NO `Broker__c` AND THERE IS NO BACKFILL. It must still render,
     * named by its NDA number, with a non-blank placeholder where the broker would be.
     *
     * ⚠ THE PLACEHOLDER IS THE WHOLE MITIGATION, AND A BLANK WOULD NOT DO. A blank subtitle on a
     * tile reads as a rendering failure rather than as missing data, and this state is the MAJORITY
     * of rows in `usman-dpeg` on the day the field ships.
     */
    @isTest
    static void ndaWithNoBrokerLookup_rendersThePlaceholderNotABlank() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, null);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row = onlyRow(d.Id);
        Test.stopTest();

        Assert.areEqual(DispositionBuyerTimelineService.NO_BROKER, row.brokerName,
            'A null broker resolves to the fixed placeholder, never to blank');
        Assert.isTrue(String.isNotBlank(row.ndaName),
            'and the row still identifies itself — the AutoNumber is always present, which is '
            + 'exactly why it, and not the party, is the row heading');
        Assert.areEqual(Date.newInstance(2026, 3, 2), row.ndaSignedDate,
            'and a missing broker suppresses nothing else on the row');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Budget
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE CONSTANT-QUERY FALSIFIER: MANY NDAs, EXACTLY ONE query.
     *
     * ⚠ THE NUMBER CHANGED FROM 2 TO 1 ON 2026-08-21 when the offer read was deleted, and asserting
     * the EXACT count is what makes that deletion stick: `areEqual(1, ...)` fails the moment anyone
     * re-adds a second read, including the disposition-level "earliest offer" shortcut the service
     * header refuses. A `<= 2` ceiling would have let it back in silently.
     * 🔴 The broker's NAME is traversed in that one query. A per-NDA Contact read would be SOQL in a
     * loop on a page render, and every row-value assertion in this class would stay green.
     */
    @isTest
    static void manyNdas_costsExactlyTwoQueries() {
        Disposition__c d = freshDisposition();
        Integer ndaCount = 25;
        List<Contact> brokers = TestDataFactory.createBrokerContacts(ndaCount, null, true);

        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(ndaCount, d.Id, false);
        for (Integer i = 0; i < ndaCount; i++) {
            ndas[i].Broker__c = brokers[i].Id;
            ndas[i].Status__c = STATUS_SIGNED;
            ndas[i].Date_Signed__c = Date.today().addDays(-30);
            ndas[i].Materials_Released_Date__c = Date.today().addDays(-20);
        }
        insert ndas;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(ndaCount, rows.size(), 'One row per buyer-role NDA');
        Assert.areEqual(2, queriesUsed,
            'EXACTLY TWO queries for ' + ndaCount + ' NDAs — one NDA read and one response read, '
            + 'with the broker names traversed INSIDE each. ⚠ IT WAS ONE UNTIL THE 2026-08-24 '
            + 'MERGE; the second query is the Release Materials response source and is unconditional '
            + 'by design (a sale can carry responses and no NDA). A THIRD is either a per-NDA '
            + 'Contact lookup (SOQL in a loop) or the disposition-level offer read the service '
            + 'header refuses.');
        for (DispositionBuyerTimelineService.TimelineRow row : rows) {
            Assert.areEqual(10, row.daysToRelease, 'and every row computed its duration');
            Assert.isTrue(String.isNotBlank(row.brokerName), 'and named its broker');
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE MERGE (2026-08-24) — two sources, ONE chronological list
    //
    // User decision: *"merge both sources into one chronological timeline"*. These tests own the
    // interleaving, the kind marker, the deleted early-return, and the fact that an NDA row's
    // CONTENT did not change. The ORDERING rule they pin REPLACED "declined last" — see
    // `declinedParty_takesItsCHRONOLOGICALPlace_notATailPosition` above.
    // ═════════════════════════════════════════════════════════════════════════

    private static final String KIND_NDA = 'NDA';
    private static final String KIND_RESPONSE = 'Response';

    /**
     * 🔴 THE CENTRAL MERGE TEST. Two NDAs and two responses, timestamps deliberately INTERLEAVED so
     * that neither "all NDAs then all responses" nor "all responses then all NDAs" can pass.
     *
     * ⚠ THE FIXTURE IS BUILT SO THAT SOURCE ORDER AND ANSWER ORDER DISAGREE. Both NDAs are older
     * than one response and newer than the other. A merge that simply concatenated the two
     * already-ordered lists would produce N,N,R,R or R,R,N,N; only a genuine sort produces the
     * expected sequence below.
     * ⚠ `Test.setCreatedDate` IS REQUIRED FOR THE NDA HALF — `CreatedDate` is second-granular and
     * every row inserted in one transaction shares it.
     */
    @isTest
    static void mergedTimeline_interleavesBothKindsNewestFirst() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();

        NDA__c olderNda = timelineNda(d.Id, appointed.Id);
        olderNda.Status__c = STATUS_SENT;
        NDA__c newerNda = timelineNda(d.Id, appointed.Id);
        newerNda.Status__c = STATUS_SENT;
        insert new List<NDA__c>{ olderNda, newerNda };
        Test.setCreatedDate(olderNda.Id, Datetime.now().addDays(-30));
        Test.setCreatedDate(newerNda.Id, Datetime.now().addDays(-20));

        Release_Materials_Response__c newestResponse =
            TestDataFactory.createReleaseMaterialsResponse(d.Id, false);
        newestResponse.Entry_DateTime__c = Datetime.now().addDays(-5);
        Release_Materials_Response__c oldestResponse =
            TestDataFactory.createReleaseMaterialsResponse(d.Id, false);
        oldestResponse.Entry_DateTime__c = Datetime.now().addDays(-40);
        insert new List<Release_Materials_Response__c>{ newestResponse, oldestResponse };

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(4, rows.size(), 'Every entry of both kinds appears exactly once');
        Assert.areEqual(
            new List<String>{ KIND_RESPONSE, KIND_NDA, KIND_NDA, KIND_RESPONSE },
            new List<String>{ rows[0].kind, rows[1].kind, rows[2].kind, rows[3].kind },
            '🔴 THE KINDS MUST ALTERNATE THE WAY THE DATES DO. N,N,R,R or R,R,N,N here means the '
            + 'two lists were CONCATENATED rather than merged — which would also be the result of '
            + 'deleting the sort entirely, since both source reads are already ordered.');
        Assert.areEqual(newestResponse.Id, rows[0].responseId, '-5 days: the newest entry');
        Assert.areEqual(newerNda.Id, rows[1].ndaId, 'then -20 days');
        Assert.areEqual(olderNda.Id, rows[2].ndaId, 'then -30 days');
        Assert.areEqual(oldestResponse.Id, rows[3].responseId, 'and -40 days is the oldest');
    }

    /**
     * 🔴 THE DELETED EARLY RETURN. Before the merge this method opened with
     * `if (ndas.isEmpty()) return rows;`, which after the merge would render a sale with logged
     * responses and no NDA as COMPLETELY EMPTY — a confident wrong answer nothing on the page
     * contradicts.
     *
     * ⚠ THIS STATE IS NORMAL, NOT CONTRIVED. `Release_Materials_Response__c` carries no NDA
     * dependency of any kind, and a response can be logged on any sale at any time.
     */
    @isTest
    static void responsesWithNoNdaAtAll_stillRenderATimeline() {
        Disposition__c d = freshDisposition();
        TestDataFactory.createReleaseMaterialsResponses(2, d.Id, true);

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            '🔴 A SALE WITH RESPONSES AND NO NDA IS NOT AN EMPTY TIMELINE. Zero here means the '
            + 'pre-merge `if (ndas.isEmpty()) return rows;` short-circuit has come back.');
        Assert.areEqual(KIND_RESPONSE, rows[0].kind, 'and both rows are response entries');
        Assert.areEqual(KIND_RESPONSE, rows[1].kind, 'both of them');
    }

    /** A response row carries everything the tile renders, and nothing an NDA row would. */
    @isTest
    static void responseRow_carriesItsMethodNotesBrokerAndTimestamp() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        Release_Materials_Response__c response =
            TestDataFactory.createReleaseMaterialsResponse(d.Id, false);
        response.Method__c = 'Offer';
        response.Notes__c = 'Verbal at 4.2m, 6.1 cap.';
        response.Broker__c = appointed.Id;
        insert response;
        Contact named = [SELECT Id, Name FROM Contact WHERE Id = :appointed.Id LIMIT 1];

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        DispositionBuyerTimelineService.TimelineRow row = rows[0];
        Assert.areEqual(KIND_RESPONSE, row.kind, 'The kind marker is what the tile branches on');
        Assert.areEqual(response.Id, row.responseId, 'the record link target');
        Assert.isTrue(String.isNotBlank(row.responseName), 'the RMR AutoNumber identity');
        Assert.areEqual('Offer', row.method, 'the method, rendered as readable badge TEXT');
        Assert.areEqual('Verbal at 4.2m, 6.1 cap.', row.notes, 'and the note itself');
        Assert.areEqual(named.Name, row.brokerName, 'and the broker, from the same traversal');
        Assert.isNotNull(row.entryDateTime, 'and the timestamp it sorted on');
        // 🔴 THE NDA HALF IS NULL, NOT EMPTY. A consumer that renders ndaName on a response row
        // renders nothing at all — which is why the component reads `kind` FIRST.
        Assert.isNull(row.ndaId, 'no NDA Id on a response row');
        Assert.isNull(row.ndaName, 'no NDA number');
        Assert.isNull(row.status, 'no NDA status');
    }

    /**
     * ⚠ THE REGRESSION PIN FOR *"a user should see new entries appear, not their existing ones
     * change shape"*. Every field an NDA row carried before the merge it still carries, under the
     * same name — this is what a Jest fixture written before 2026-08-24 depends on.
     */
    @isTest
    static void ndaRow_carriesEveryPreMergeFieldUnchanged() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c nda = timelineNda(d.Id, appointed.Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.today().addDays(-9);
        nda.Materials_Released_Date__c = Date.today().addDays(-2);
        insert nda;
        Contact named = [SELECT Id, Name FROM Contact WHERE Id = :appointed.Id LIMIT 1];

        Test.startTest();
        DispositionBuyerTimelineService.TimelineRow row =
            DispositionBuyerTimelineService.getTimeline(d.Id)[0];
        Test.stopTest();

        Assert.areEqual(KIND_NDA, row.kind, 'The new marker says NDA');
        Assert.areEqual(nda.Id, row.ndaId, 'ndaId unchanged');
        Assert.isTrue(String.isNotBlank(row.ndaName), 'ndaName unchanged');
        Assert.areEqual(named.Name, row.brokerName, 'brokerName unchanged');
        Assert.areEqual(STATUS_SIGNED, row.status, 'status unchanged');
        Assert.isFalse(row.isDeclined, 'isDeclined unchanged');
        Assert.areEqual(Date.today().addDays(-9), row.ndaSignedDate, 'ndaSignedDate unchanged');
        Assert.areEqual(Date.today().addDays(-2), row.materialsReleasedDate,
            'materialsReleasedDate unchanged');
        Assert.areEqual(7, row.daysToRelease, 'daysToRelease unchanged');
        Assert.isFalse(row.hasDateAnomaly, 'hasDateAnomaly unchanged');
        Assert.isNotNull(row.entryDateTime,
            'and the ONE new value on an NDA row is its CreatedDate sort key');
        Assert.isNull(row.method, 'while every response-half field stays null');
        Assert.isNull(row.notes, 'including the notes');
    }

    /**
     * 🔴 AN UNDATED ROW SINKS, IT DOES NOT FLOAT. `Entry_DateTime__c` defaults to `NOW()` but is
     * NOT `required`, so an API or data-loader row can carry null — and the platform's default for
     * a `DESC` sort is NULLS **FIRST**, which would put a row claiming no time at all above every
     * dated entry on the card.
     */
    @isTest
    static void anUndatedResponse_sinksToTheBottomRatherThanFloatingToTheTop() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, broker().Id);
        nda.Status__c = STATUS_SENT;
        insert nda;
        Test.setCreatedDate(nda.Id, Datetime.now().addDays(-100));

        Release_Materials_Response__c undated =
            TestDataFactory.createReleaseMaterialsResponse(d.Id, false);
        undated.Entry_DateTime__c = null;
        insert undated;

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineService.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both entries appear — an undated row is not discarded');
        Assert.areEqual(nda.Id, rows[0].ndaId,
            'A 100-day-old NDA still outranks an undated response. If the undated row is first, '
            + 'the comparator has lost its null handling and NULLS FIRST has taken over.');
        Assert.isNull(rows[1].entryDateTime, 'and the undated row is at the bottom');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Selector contract
    // ─────────────────────────────────────────────────────────────────────────

    /** The selector is null-safe and issues NO query on the guard path. */
    @isTest
    static void selector_isNullSafeWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<NDA__c> noNdas = NdaSelector.selectBuyerTimelineByDispositionId(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.isTrue(noNdas.isEmpty(), 'A null disposition Id yields an empty list, never null');
        Assert.areEqual(0, queriesUsed, 'and it must not issue a query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Controller boundary
    // ─────────────────────────────────────────────────────────────────────────

    /** The controller returns the service's rows unchanged, in order. */
    @isTest
    static void controller_returnsTheTimeline() {
        Disposition__c d = freshDisposition();
        Contact appointed = broker();
        NDA__c nda = timelineNda(d.Id, appointed.Id);
        nda.Status__c = STATUS_SIGNED;
        nda.Date_Signed__c = Date.newInstance(2026, 3, 2);
        insert nda;

        NDA__c saved = [SELECT Name FROM NDA__c WHERE Id = :nda.Id LIMIT 1];

        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineController.getTimeline(d.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One row');
        Assert.areEqual(saved.Name, rows[0].ndaName, 'passed through unchanged');
        Assert.areEqual(Date.newInstance(2026, 3, 2), rows[0].ndaSignedDate, 'dates included');
    }

    /** A null Id is a normal early render, not an error. */
    @isTest
    static void controller_withNullId_returnsEmptyList() {
        Test.startTest();
        List<DispositionBuyerTimelineService.TimelineRow> rows =
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
        List<DispositionBuyerTimelineService.TimelineRow> rows =
            DispositionBuyerTimelineController.getTimeline(d.Id);
        Test.stopTest();

        Assert.isTrue(rows.isEmpty(),
            '"No NDA has been raised yet" is a normal early state, rendered as an empty state');
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

    /** The SEPARATE set the `Broker__r.Name` traversal actually depends on. */
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
            FirstName = 'Nda',
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
     * 🔴 PINS THE TRAVERSAL GATE: `Broker__r.Name` NEEDS `Contact` OBJECT READ, AND THE DISPOSITION
     * PERMISSION SETS DO NOT GRANT IT.
     *
     * `NdaSelector.selectBuyerTimelineByDispositionId`'s header documents this at length — the
     * traversal's grant comes from `DPEG_Contact_View` / `DPEG_Contact_Edit`, which are SEPARATE
     * members of the same permission set GROUPS (`DPEG_Principal_PSG`, `DPEG_Junior_Analyst_PSG`).
     * Both groups carry them today, so both intended personas work. But a documented coupling that
     * nothing executes is a coupling that can be dissolved by a PSG edit in Setup, and the first
     * anyone would learn of it is an error banner on a production record page.
     * ⚠ RETARGETED 2026-08-21 FROM `Buyer__r.Name`. The lookup moved; the gate is identical, and
     * that is precisely why this test had to move with it rather than being deleted — the coupling
     * survives the retarget and would have stopped being executed if this test had gone with the
     * buyer.
     *
     * ── WHY TWO PERSONAS AND NOT ONE ──
     * "The denied persona throws" on its own proves almost nothing: this query has several other FLS
     * gates, and ANY of them missing produces the same `QueryException`. The control persona is
     * identical in every respect except that it also holds `DPEG_Contact_View`, so the exception is
     * attributable to that one set and to nothing else. If the control ALSO throws, the finding is a
     * real provisioning gap somewhere else in the grants — read its message, do not weaken it.
     * 🔴 AS OF 2026-08-21 THE MOST LIKELY CAUSE OF A FAILING **CONTROL** IS `NDA__c.Broker__c`, a
     * brand-new field that neither disposition permission set can grant until the admin agent's
     * change lands. If the control's message names `Broker__c`, this is the deploy-order dependency
     * in the class header, not a defect.
     *
     * ⚠ THE CONTROL ASSERTS "DID NOT THROW", NOT A ROW COUNT, AND THAT IS NOT LAZINESS.
     * `DPEG_Disposition_View` grants `NDA__c` read with `PermissionsViewAllRecords = FALSE` (measured
     * 2026-08-20) and `NDA__c` is OWD Private, so a persona holding it cannot SEE rows this test's
     * admin context created. FLS/CRUD is evaluated when the query is validated, before sharing
     * filters any rows, so the denial still throws for the second persona with zero visible rows —
     * but the granted persona legitimately reads an EMPTY list. Asserting `1` here would fail for a
     * sharing reason that has nothing to do with what this test is about.
     *
     * ⚠ AND IT ASSERTS `QueryException`, NOT `Exception`. That is the type both the selector header
     * and `DispositionBuyerTimelineService`'s `@throws` clause promise. If the platform ever delivers
     * a different type here, that is a genuine finding worth writing down — widen this catch only
     * together with those docs, never on its own.
     */
    @isTest
    static void contactReadDenied_theBrokerTraversalThrows() {
        Disposition__c d = freshDisposition();
        NDA__c nda = timelineNda(d.Id, broker().Id);
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
            + 'It did not, so the failure below is NOT attributable to Contact — one of the other '
            + 'documented grants is missing (NDA__c.Broker__c is the newest and the likeliest). '
            + 'Actual: '
            + (controlFailure == null ? 'none' : controlFailure.getTypeName() + ': '
                + controlFailure.getMessage()));

        Assert.isNotNull(deniedFailure,
            '🔴 A persona holding DPEG_Disposition_View but NOT DPEG_Contact_View MUST NOT be able '
            + 'to read this timeline: Broker__r.Name traverses to Contact and USER_MODE enforces '
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
