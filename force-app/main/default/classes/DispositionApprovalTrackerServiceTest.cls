/**
 * Tests for `DispositionApprovalTrackerService` AND its `@AuraEnabled` boundary
 * `DispositionApprovalTrackerController` — the five-row approval checklist on the Disposition
 * record page. Built 2026-08-31 (Tranche 3 item 3).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE PROPERTY THIS CLASS EXISTS TO PROVE, AND WHY NOTHING ELSE CAN
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The BA's five approval types map to SIX processes, because broker selection is
 * `Broker_Finalize_Approval` on an ON-market sale (raised against the selected BOV submission) and
 * `Broker_Selection_Approval` on an OFF-market one (raised against the Disposition, entry criterion
 * `Is_On_Market__c = False`). Row 2 therefore reads a DIFFERENT process depending on the record
 * type, and if the pair is swapped the card reports that 100% of sales of one type skipped an
 * approval they in fact passed — with no exception, no row-count change and nothing in a log.
 *
 * 🔴 THE ORG HELD **ZERO** `Disposition__c` RECORDS ON 2026-08-31, so there is no data to catch that
 * by hand and there will not be before this ships. `bothRecordTypes_...` below is the ONLY thing
 * standing between an inverted pair and production, which is why it asserts on the PROCESS API
 * NAMES rather than on the rendered state: an inversion is invisible in the state alone (both
 * variants read "Not started" on a sale nothing has been submitted against).
 *
 * ── ⚠ THESE ARE REAL APPROVAL SUBMISSIONS, NOT FABRICATED ProcessInstance ROWS ────────────────
 * `ProcessInstance` is NOT CREATEABLE — no fixture can insert one — so every state assertion below
 * comes from a genuine `Approval.ProcessSubmitRequest`, exactly as the platform would produce it.
 * That is a feature: the entry criteria in the `approvalProcesses/` files are part of what these
 * tests hold in place. `submit()` asserts `result.isSuccess()` as a PRECONDITION for that reason —
 * a silently refused submit would leave every downstream assertion measuring "Not started", which
 * on a CHECKLIST is a plausible-looking answer rather than an obviously empty one.
 *
 * 🔴 AND IT IS EXACTLY WHY ROW 3'S ARITHMETIC IS TESTED THROUGH A PURE FUNCTION INSTEAD.
 * `NDA_Issue_Approval` is being created concurrently and is NOT IN THE ORG YET. A test that
 * submitted an NDA to prove the `n of m` aggregate would fail on a dependency this class does not
 * have. `ndaAggregate_...` below feeds `ndaAggregateState` four integers and falsifies all five
 * rules today, with no approval process at all; `ndaRow_...` proves the WIRING that produces those
 * integers, using the state the org is actually in — no process, so no instances.
 * ⚠ THAT SPLIT IS ALSO THE "MISSING ProcessDefinition" TEST THE BRIEF ASKED FOR. An undeployed
 * process is not a special case in this class: it matches no instance, so row 3 reads
 * `NotStarted` / `0 of m`. There is no `ProcessDefinition` lookup to fail.
 *
 * ── WHY THE FIXTURE SITS AT `Closing` ────────────────────────────────────────────────────────
 * It is the one stage at which three approvals can be pending AT ONCE, which is what makes a
 * single-disposition, three-row state assertion possible:
 *   • `Closing_Approval` needs `Disposition_Stage__c = 'Closing'` AND
 *     `Wire_Verification_Completed__c = true`;
 *   • `Broker_Finalize_Approval` needs only `Submission_Status__c = 'Selected'` on the BOV;
 *   • `Offer_Selection_Approval` needs only `Is_Selected__c = true` on the offer.
 * The signed NDA is required by `All_NDAs_Signed_Before_Progression`. The whole recipe is lifted
 * from `DispositionApprovalHistoryServiceTest`, which lifted it from
 * `DispositionApprovalProcessesTest`.
 *
 * ⚠ THE PARENT IS SUBMITTED **LAST** IN EVERY TEST THAT SUBMITS IT. These approvals carry
 * `recordEditability = AdminOnly`, so a submitted Disposition LOCKS; inserting or updating a child
 * that writes back to the parent after that point fails on the lock, not on anything under test.
 *
 * ── BULK ──
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does NOT attach to this class, and that
 * is an argued position rather than an omission: nothing here is a trigger, a batch, a queueable or
 * a DML-performing service — it is a READ invoked once per page view, and it performs no DML at
 * all. 🔴 THE PROPERTY THAT MATTERS AT VOLUME IS A **CONSTANT QUERY COUNT ACROSS MANY CHILDREN**,
 * and it IS asserted (`manyChildren_costsExactlyFiveQueries`). A sale with a dozen BOVs, a dozen
 * offers and half a dozen NDAs is ordinary; a per-child lookup would be SOQL in a loop on a page
 * render, and no row-count assertion would ever catch it.
 *
 * @see force-app/main/default/classes/DispositionApprovalTrackerService.cls
 * @see force-app/main/default/classes/DispositionApprovalHistoryServiceTest.cls (the sibling suite,
 *      whose four-query assertion this deliberately does NOT disturb)
 */
@isTest
private class DispositionApprovalTrackerServiceTest {

    private static final String STAGE_CLOSING = 'Closing';

    private static final String STATE_NOT_STARTED = 'NotStarted';
    private static final String STATE_NOT_APPLICABLE = 'NotApplicable';
    private static final String STATE_PENDING = 'Pending';
    private static final String STATE_APPROVED = 'Approved';
    private static final String STATE_REJECTED = 'Rejected';

    /**
     * ⚠ THE PROCESS NAMES ARE RE-DECLARED HERE AS INDEPENDENT LITERALS RATHER THAN ALIASED FROM
     * `DispositionApprovalTrackerService`'s `@TestVisible` constants, AND THAT IS DELIBERATE. If
     * the assertions read the service's own constants, a mis-cased or swapped literal in the
     * service would propagate identically into every expectation, every comparison would still
     * match itself, and this whole suite would stay GREEN while the card matched nothing in the
     * org. Same argument `DispositionDomain`'s header makes for `TestDataFactory` keeping its own
     * record-type literals. If the two ever disagree, THAT IS THE TEST WORKING — check them against
     * `approvalProcesses/` and fix the wrong one; do not collapse them.
     */
    private static final String PROC_SALE_DECISION = 'Sale_Decision_Approval';
    private static final String PROC_BROKER_FINALIZE = 'Broker_Finalize_Approval';
    private static final String PROC_BROKER_SELECTION = 'Broker_Selection_Approval';
    private static final String PROC_NDA_ISSUE = 'NDA_Issue_Approval';
    private static final String PROC_OFFER_SELECTION = 'Offer_Selection_Approval';
    private static final String PROC_CLOSING = 'Closing_Approval';

    /**
     * ONE ON-MARKET disposition at `Closing`, with the signed NDA the progression rule requires,
     * ONE selected BOV submission and ONE selected offer. Nothing is submitted here — the approvals
     * are raised inside each test, so a test that needs a clean, never-submitted sale simply does
     * not submit.
     */
    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);

        Disposition__c disposition = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false
        );
        disposition.Disposition_Stage__c = STAGE_CLOSING;
        insert disposition;

        NDA__c nda = TestDataFactory.createDispositionNda(disposition.Id, false);
        nda.Status__c = 'Signed';
        insert nda;

        BOV_Submission__c submission = TestDataFactory.createBovSubmission(disposition.Id, false);
        submission.Submission_Status__c = 'Selected';
        insert submission;

        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(disposition.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 6100000;
        insert offer;

        // Last, so `Closing_Approval`'s second entry criterion holds without the record being
        // locked while its children are created.
        disposition.Wire_Verification_Completed__c = true;
        update disposition;
    }

    /** The scaffold sale. Keyed on the stage so a disposition created INSIDE a test cannot match. */
    private static Disposition__c scaffold() {
        return [
            SELECT Id, Name
            FROM Disposition__c
            WHERE Disposition_Stage__c = :STAGE_CLOSING
            LIMIT 1
        ];
    }

    private static BOV_Submission__c scaffoldBov() {
        return [SELECT Id, Name FROM BOV_Submission__c LIMIT 1];
    }

    private static Disposition_Offer__c scaffoldOffer() {
        return [SELECT Id, Name FROM Disposition_Offer__c LIMIT 1];
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    /**
     * Submits a record into whichever active approval process it satisfies, and ASSERTS that it was
     * accepted. The assertion is the point: a refused submit would leave the row reading
     * "Not started", which on a checklist looks like a finding rather than like a broken fixture.
     *
     * @param targetId The record to submit.
     */
    private static void submit(Id targetId) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(targetId);
        Approval.ProcessResult result = Approval.process(req);
        Assert.isTrue(result.isSuccess(),
            'PRECONDITION FAILED: ' + targetId + ' was not accepted into an approval process. '
            + 'Every downstream assertion in this test is meaningless until this passes.');
    }

    /** Acts on the one outstanding workitem for a target. */
    private static void decide(Id targetId, String action) {
        ProcessInstanceWorkitem item = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :targetId LIMIT 1
        ];
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setWorkitemId(item.Id);
        req.setAction(action);
        Approval.process(req);
    }

    private static Map<String, DispositionApprovalTrackerService.TrackerRow> byKey(
        List<DispositionApprovalTrackerService.TrackerRow> rows
    ) {
        Map<String, DispositionApprovalTrackerService.TrackerRow> keyed =
            new Map<String, DispositionApprovalTrackerService.TrackerRow>();
        for (DispositionApprovalTrackerService.TrackerRow row : rows) {
            keyed.put(row.rowKey, row);
        }
        return keyed;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE HEADLINE TEST — THE RECORD-TYPE-DEPENDENT ROW, IN BOTH DIRECTIONS
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ONE ASSERTION NOTHING ELSE IN THIS ORG CAN MAKE. Row 2 must track
     * `Broker_Finalize_Approval` on an ON-market sale and `Broker_Selection_Approval` on an
     * OFF-market one, and must mark the OTHER variant `NotApplicable` — never "not started".
     *
     * ⚠ BOTH DIRECTIONS LIVE IN ONE METHOD ON PURPOSE. A swapped pair is a SYMMETRIC defect: two
     * separate one-direction tests would both have to be written correctly to catch it, and
     * whoever swaps the pair is exactly the person likely to "fix" the failing one by swapping the
     * expectation too. Asserting both sides against each other, in one place, makes that
     * impossible without noticing.
     *
     * 🔴 IT ASSERTS ON PROCESS API NAMES, NOT ON RENDERED STATE, AND THAT IS THE WHOLE DESIGN OF
     * THE TEST. Neither sale here has a broker approval submitted, so BOTH would read
     * "Not started" if the row merely reported a state — an inverted pair would be completely
     * invisible. The API name is the only thing that differs.
     *
     * ⚠ RETRACTED 2026-08-31 (review S-3). This paragraph claimed: *"AND IT PINS THE MASTER-ROW
     * FALLBACK BY IMPLICATION. `DispositionDomain.recordTypeNameOf` answers `On_Market` for a
     * Master/unset row … this test is what would red if someone swapped the resolver."* IT DOES
     * NOT. Both fixtures here carry a NAMED record type, on which `recordTypeNameOf` and an
     * `Is_On_Market__c` read agree exactly — so swapping the resolver for a field read would leave
     * this method GREEN on both directions. Only a Master row distinguishes them, and there was no
     * Master fixture in this class. `masterTypedSale_takesTheOnMarketBranch` below is that fixture
     * and is where the resolver is actually pinned.
     */
    @isTest
    static void bothRecordTypes_row2TracksTheApplicableVariantAndMarksTheOtherNotApplicable() {
        Disposition__c onMarket = scaffold();
        Disposition__c offMarket = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, true
        );

        Test.startTest();
        Map<String, DispositionApprovalTrackerService.TrackerRow> onRows =
            byKey(DispositionApprovalTrackerService.getTracker(onMarket.Id));
        Map<String, DispositionApprovalTrackerService.TrackerRow> offRows =
            byKey(DispositionApprovalTrackerService.getTracker(offMarket.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow onBroker = onRows.get('BROKER_SELECTION');
        DispositionApprovalTrackerService.TrackerRow offBroker = offRows.get('BROKER_SELECTION');

        Assert.isNotNull(onBroker, 'The on-market tracker must carry a BROKER_SELECTION row');
        Assert.isNotNull(offBroker, 'The off-market tracker must carry a BROKER_SELECTION row');

        Assert.areEqual(PROC_BROKER_FINALIZE, onBroker.processApiName,
            'AN ON-MARKET SALE APPOINTS ITS BROKER THROUGH Broker_Finalize_Approval, raised against '
            + 'the selected BOV submission. If this reads Broker_Selection_Approval the pair is '
            + 'INVERTED: that process\'s entry criterion is Is_On_Market__c = False, so it can NEVER '
            + 'run here, and every on-market sale would report a broker approval it never skipped');
        Assert.areEqual(PROC_BROKER_SELECTION, onBroker.naProcessApiName,
            'and the off-market variant must be published as the one that does NOT apply');

        Assert.areEqual(PROC_BROKER_SELECTION, offBroker.processApiName,
            'AN OFF-MARKET SALE HAS NO BOV MATRIX AT ALL and appoints directly through '
            + 'Broker_Selection_Approval, raised against the Disposition itself');
        Assert.areEqual(PROC_BROKER_FINALIZE, offBroker.naProcessApiName,
            'and the on-market variant must be published as the one that does NOT apply');

        // 🔴 THE N/A RULE ITSELF. The variant that cannot run must carry NotApplicable, NOT
        // NotStarted — "not started" invites someone to go and start something that does not exist
        // on this record type.
        Assert.areEqual(STATE_NOT_APPLICABLE, onBroker.naState,
            'The inapplicable variant must read NotApplicable. NotStarted here would tell every '
            + 'reader of an on-market sale that an approval is outstanding which cannot be raised');
        Assert.areEqual(STATE_NOT_APPLICABLE, offBroker.naState,
            'and the same on the off-market side');

        Assert.areNotEqual(onBroker.processApiName, onBroker.naProcessApiName,
            'A row can never track and disclaim the SAME process');
        Assert.areNotEqual(offBroker.processApiName, offBroker.naProcessApiName,
            'and likewise off-market');

        // No broker approval was submitted on either sale, so BOTH rows read NotStarted. Asserted
        // to make the point explicit: the STATE cannot distinguish the two record types, which is
        // exactly why the assertions above are on the API names.
        Assert.areEqual(STATE_NOT_STARTED, onBroker.state,
            'Nothing was submitted, so the tracked variant is NotStarted on both record types — '
            + 'which is why an inverted pair is invisible in the state alone');
        Assert.areEqual(STATE_NOT_STARTED, offBroker.state, 'and likewise off-market');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE THIRD RECORD-TYPE STATE — MASTER. Two tests, and they are NOT variants of each other.
    //    The first pins the RESOLVER (which process a Master row is presumed to run); the second
    //    pins that live EVIDENCE overrides that presumption (review W-1).
    //
    // ⚠ A THIRD CASE IS DELIBERATELY NOT TESTED, AND THE GAP IS RECORDED RATHER THAN HIDDEN.
    // `brokerRow`'s correction 2 suppresses the N/A claim entirely when BOTH broker processes have
    // a ProcessInstance. Nothing here reaches that branch, so deleting the
    // `if (!newestByProcess.containsKey(inapplicable))` wrapper leaves this suite GREEN.
    //
    // WHAT IT WOULD TAKE: a MASTER sale at 'Broker Selection' (satisfying
    // Broker_Selection_Approval, whose criteria are stage + Is_On_Market__c = False — measured
    // FALSE on Master) carrying a BOV_Submission__c at Submission_Status__c = 'Selected'
    // (satisfying Broker_Finalize_Approval, whose entry criteria reference ONLY that field and
    // nothing about the parent), with BOTH submitted — the BOV first, because submitting the
    // parent LOCKS it. Expected: processApiName = Broker_Finalize_Approval (no swap, since the
    // inferred variant now HAS evidence) and naProcessApiName / naState both null.
    //
    // WHY IT WAS NOT BUILT ON 2026-09-01: it needs the broker-Contact chain
    // `TestDataFactory.createBovSubmission` builds (BOV_Amount__c is validation-required and
    // Broker__c is a real Contact), and `BovAutoSelectionService.reselect` runs on BOV afterInsert
    // and could re-rank a hand-built row out of 'Selected' — which would make the fixture fail for
    // a reason unrelated to what the test claims. That could not be settled without submitting
    // approvals against the live org, and approval request emails SURVIVE a rollback. The branch
    // is cheap, correct and defensive; the test for it is not free, and an unproven-but-correct
    // guard beats a fixture that might be proving something else. Fund it if row 2 ever misreports
    // on a Master sale with both approvals raised.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ONLY TEST IN THIS CLASS THAT CAN TELL `DispositionDomain.recordTypeNameOf` FROM AN
     * `Is_On_Market__c` READ, and the fixture the headline test above wrongly claimed to imply.
     *
     * On a Master row the two answers DIVERGE: `recordTypeNameOf` returns `On_Market` (its chosen
     * fallback — see `DispositionDomain`'s header for why), while `Is_On_Market__c` is a formula on
     * `RecordType.DeveloperName` and reads FALSE, i.e. off-market. Row 2 must take the ON-market
     * branch. Anyone replacing the domain helper with the field read reds HERE and nowhere else.
     *
     * ⚠ NOT MERELY ACADEMIC. Master is where every disposition sits before post-deploy gate T-A1
     * assigns the record types to a profile, and `DispositionApprovalService` /
     * `DispositionApprovalAdvanceService` disagreeing about this exact question WAS defect C-2.
     */
    @isTest
    static void masterTypedSale_takesTheOnMarketBranch() {
        Disposition__c master = insertMasterTypedSale(null);

        Test.startTest();
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(master.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow broker = rows.get('BROKER_SELECTION');
        Assert.isNotNull(broker, 'A Master-typed sale must still produce a BROKER_SELECTION row');

        Assert.areEqual(PROC_BROKER_FINALIZE, broker.processApiName,
            'A MASTER-TYPED SALE MUST TAKE THE ON-MARKET BRANCH. Reading '
            + 'Broker_Selection_Approval here means the record type is being resolved from '
            + 'Is_On_Market__c (blank on Master, therefore FALSE) instead of from '
            + 'DispositionDomain.recordTypeNameOf — the two disagree on Master and NOWHERE else, '
            + 'which is why no other test in this class can catch the swap');
        Assert.areEqual(PROC_BROKER_SELECTION, broker.naProcessApiName,
            'and with nothing submitted, the off-market variant is still the disclaimed one');
        Assert.areEqual(STATE_NOT_APPLICABLE, broker.naState,
            'and the disclaimer must read NotApplicable');
    }

    /**
     * 🔴 REVIEW W-1 — THE CARD MUST NOT DISCLAIM AN APPROVAL THAT IS ACTUALLY RUNNING.
     *
     * `Approval.process` routes by ENTRY CRITERIA ALONE — no code names either broker process — and
     * `Broker_Selection_Approval`'s criteria are `Disposition_Stage__c = 'Broker Selection'` AND
     * `Is_On_Market__c = False`. BOTH HOLD ON A MASTER ROW, because that formula reads FALSE there.
     * So a Master sale can carry a real, PENDING `Broker_Selection_Approval` while
     * `recordTypeNameOf` says On_Market — and before this fix the card published that pending
     * approval as `NotApplicable` with the tracked row reading "Not started" beside it. An itemised
     * false claim about a live approval, which is the one thing this card's fail-hard design exists
     * to prevent.
     *
     * ⚠ THE SUBMIT IS REAL (`ProcessInstance` is not createable), so this test also holds the
     * approval's entry criteria in place: if anyone adds a record-type predicate to
     * `Broker_Selection_Approval`, `submit()`'s precondition fails and names itself rather than
     * letting the row silently read "Not started".
     *
     * ⚠ THE N/A ASSERTIONS ARE THE POINT. "Tracks the right process" and "reads Pending" would
     * both be satisfied by a row that ALSO still disclaimed the pending approval — the N/A line is
     * rendered independently of the tracked one, so it needs its own falsifier.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 CORRECTED 2026-09-01. THIS METHOD ASSERTED `Assert.isNull(naProcessApiName)` AND WENT RED
     *    ON THE VALIDATE RUN. THE GUARD WAS RIGHT AND THE ASSERTION WAS WRONG — MY ERROR, IN THE
     *    TEST, NOT IN PRODUCTION CODE. THE ASSERTION IS NOT WEAKENED; IT IS RESTATED CORRECTLY.
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * `brokerRow` makes TWO corrections and they answer different questions. On this fixture only
     * ONE of the two processes has an instance, so only the first fires:
     *
     *   Correction 1 (the SWAP)   fires. Master infers On_Market -> Broker_Finalize_Approval, but
     *                             the instance is on Broker_Selection_Approval, so the row TRACKS
     *                             the one with evidence. Pinned by the processApiName + state
     *                             assertions below.
     *   Correction 2 (the NULL)   does NOT fire, and must not. It suppresses the N/A claim only
     *                             when BOTH processes have an instance. Here
     *                             Broker_Finalize_Approval has none, so disclaiming it is a TRUE
     *                             statement and the card should make it.
     *
     * ⇒ So the invariant W-1 actually establishes is **"the process with a live instance is never
     * the one disclaimed"**, not "nothing is disclaimed". `areNotEqual(PROC_BROKER_SELECTION, …)`
     * states it directly; `areEqual(PROC_BROKER_FINALIZE, …)` pins the behaviour exactly so the
     * test cannot pass vaguely. BOTH still fail RED against the pre-W-1 build, which published
     * `naProcessApiName = Broker_Selection_Approval` on precisely this row — nothing was traded
     * away to make this green.
     *
     * ⚠ CORRECTION 2's NULL BRANCH IS THEREFORE NOT FALSIFIED BY ANY TEST IN THIS CLASS — see the
     * block above `masterTypedSale_takesTheOnMarketBranch` for what a test would need and why it
     * was not built. Deleting the `if (!newestByProcess.containsKey(inapplicable))` wrapper in
     * `brokerRow` would leave this whole suite GREEN.
     */
    @isTest
    static void masterTypedSaleWithPendingBrokerSelection_isNotDisclaimed() {
        Disposition__c master = insertMasterTypedSale('Broker Selection');

        Test.startTest();
        submit(master.Id);
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(master.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow broker = rows.get('BROKER_SELECTION');
        Assert.isNotNull(broker, 'A Master-typed sale must still produce a BROKER_SELECTION row');

        Assert.areEqual(PROC_BROKER_SELECTION, broker.processApiName,
            'EVIDENCE BEATS THE RECORD-TYPE INFERENCE. This sale has a real ProcessInstance for '
            + 'Broker_Selection_Approval and none for Broker_Finalize_Approval, so the row must '
            + 'track the one that actually ran. Reading Broker_Finalize_Approval here means the '
            + 'row is still keyed on the record type alone');
        Assert.areEqual(STATE_PENDING, broker.state,
            'and it must report the LIVE state of that instance, not NotStarted');

        Assert.areNotEqual(PROC_BROKER_SELECTION, broker.naProcessApiName,
            '🔴 THE W-1 FIX, AND THE ASSERTION THE WHOLE TEST EXISTS FOR. '
            + 'Broker_Selection_Approval is PENDING in somebody\'s queue on this sale, so it must '
            + 'NOT be the process the card disclaims. Reading it here means the row is still '
            + 'keyed on the record type alone and the card asserts, itemised, that a running '
            + 'approval does not exist — the exact false claim the fail-hard design prevents');
        Assert.areEqual(PROC_BROKER_FINALIZE, broker.naProcessApiName,
            'and the variant with NO instance is the one correctly disclaimed. An N/A claim is '
            + 'still MADE here — see this method\'s header for why null would be wrong');
        Assert.areEqual(STATE_NOT_APPLICABLE, broker.naState,
            'and it carries NotApplicable, paired with naProcessApiName — the component gates on '
            + 'BOTH being set, so a half-populated pair renders an empty pill');
    }

    /**
     * A Disposition on NO record type — the Master state, which is neither of the two named ones
     * and is where every row sits until post-deploy gate T-A1 assigns the types to a profile.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 HAND-BUILT, NOT FACTORY-BUILT. AN EXPLICIT `RecordTypeId = null` IS **NOT** THE SAME AS
     *    OMITTING THE FIELD — IT THROWS. THIS HELPER SHIPPED THE FACTORY VERSION AND IT FAILED.
     * ═══════════════════════════════════════════════════════════════════════════════════════════
     * It read `TestDataFactory.createDisposition(assetId(), DISPOSITION_RT_ON_MARKET, false)` and
     * then assigned `sale.RecordTypeId = null` over the stamp. Both Master tests failed with:
     *
     *     System.DmlException: INVALID_CROSS_REFERENCE_KEY,
     *     Record Type ID: this ID value isn't valid for the user: : [RecordTypeId]
     *
     * Assigning null over a POPULATED field leaves it in the row's populated-field map, so the DML
     * sends `RecordTypeId` explicitly blank and the platform rejects the blank. Omitting the field
     * sends nothing and the platform applies the profile's default record-type mapping — which on
     * this org is **Master**.
     *
     * MEASURED on usman-dpeg at API 67.0 on 2026-08-31, savepoint-probed and rolled back, both
     * arms in one transaction:
     *
     *   RecordTypeId never touched          -> ACCEPTED, reads back RecordTypeId = null
     *   RecordTypeId set, then set to null  -> REFUSED, the exact message above
     *
     * ⚠ THE FACTORY CANNOT BE USED HERE. `createDispositions` always populates `RecordTypeId` when
     * the type resolves, and Apex offers no way to UN-populate a field once assigned. Every other
     * fixture in this class is factory-built and must stay that way; this one is the exception.
     * `Property_Asset__c` is set because `Property_Asset_Required_On_Save` is an ISNEW() rule.
     *
     * ⚠ THE READ-BACK IS STILL A PRECONDITION. If the profile's default mapping ever stops being
     * Master, the row is not Master and both tests below would be vacuous rather than red.
     *
     * @param stage The stage to insert at, or null for the standard starting stage.
     */
    private static Disposition__c insertMasterTypedSale(String stage) {
        // 🔴 DO NOT set RecordTypeId here, and do NOT route this through TestDataFactory. Read the
        // block above before "tidying" this into a factory call — the tidy version cannot insert.
        Disposition__c sale = new Disposition__c(
            Property_Asset__c = assetId(),
            Disposition_Stage__c = String.isBlank(stage) ? 'Disposition Readiness' : stage
        );
        insert sale;

        Disposition__c stored = [
            SELECT Id, RecordTypeId, Disposition_Stage__c
            FROM Disposition__c
            WHERE Id = :sale.Id
        ];
        Assert.isNull(stored.RecordTypeId,
            'PRECONDITION FAILED, not a service defect: this fixture was meant to be MASTER-typed '
            + 'and came back on record type ' + stored.RecordTypeId + '. That means the profile\'s '
            + 'default record-type mapping is no longer Master, which would make every Master-row '
            + 'assertion in this class vacuous rather than red. Neither test may be softened to go '
            + 'green.');
        return stored;
    }

    /**
     * 🔴 ONLY ROW 2 CARRIES AN N/A VARIANT. Every other row's type maps to exactly one process on
     * both record types, so publishing an inapplicable variant there would be a claim about nothing.
     *
     * ⚠ AN ABSENCE PIN, SO IT CARRIES ITS PRESENCE CONTROL: the same loop asserts row 2 DOES carry
     * one. Without that control, a service that stopped populating `naProcessApiName` entirely
     * would pass this test perfectly.
     */
    @isTest
    static void onlyTheBrokerRowCarriesAnInapplicableVariant() {
        Disposition__c disposition = scaffold();

        Test.startTest();
        List<DispositionApprovalTrackerService.TrackerRow> rows =
            DispositionApprovalTrackerService.getTracker(disposition.Id);
        Test.stopTest();

        Integer withVariant = 0;
        for (DispositionApprovalTrackerService.TrackerRow row : rows) {
            if ('BROKER_SELECTION'.equals(row.rowKey)) {
                withVariant++;
                continue;
            }
            Assert.isNull(row.naProcessApiName,
                'Row ' + row.rowKey + ' maps to ONE process on both record types, so it must not '
                + 'disclaim a variant. A stray N/A line here would read as a rule that does not '
                + 'exist');
            Assert.isNull(row.naState,
                'and it must not carry an N/A state either: ' + row.rowKey);
        }
        Assert.areEqual(1, withVariant,
            'PRESENCE CONTROL for the absence pin above: exactly ONE row — BROKER_SELECTION — must '
            + 'carry an inapplicable variant. Zero here means the feature stopped working and the '
            + 'nulls above are vacuous');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CHECKLIST
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * A sale nothing has ever been submitted against returns FIVE rows, in BA order, every one
     * `NotStarted`.
     *
     * 🔴 "FIVE ROWS OF NOTHING" IS THE EMPTY STATE AND IT IS NOT AN EMPTY LIST. A checklist whose
     * un-ticked boxes disappear cannot report that nothing has happened, which is the single most
     * common state of a sale in its first stage and the one a principal most needs to see.
     * ⚠ THE ORDER IS ASSERTED AS A LIST, NOT AS A SET. The sequence IS the content — these are the
     * BA's numbered gates 1-5 and "which one are we on" is the question the card answers.
     */
    @isTest
    static void nothingSubmitted_returnsFiveNotStartedRowsInOrder() {
        Disposition__c disposition = scaffold();

        Test.startTest();
        List<DispositionApprovalTrackerService.TrackerRow> rows =
            DispositionApprovalTrackerService.getTracker(disposition.Id);
        Test.stopTest();

        Assert.areEqual(5, rows.size(),
            'The tracker is FIVE fixed rows whatever the sale has done. A shorter list means a row '
            + 'was suppressed, and a suppressed row is indistinguishable from a passed one');

        List<String> keys = new List<String>();
        List<Integer> sequences = new List<Integer>();
        for (DispositionApprovalTrackerService.TrackerRow row : rows) {
            keys.add(row.rowKey);
            sequences.add(row.sequence);
            Assert.areEqual(STATE_NOT_STARTED, row.state,
                'Nothing was submitted, so every row must be NotStarted: ' + row.rowKey);
            Assert.isNull(row.targetId,
                'A row with no approval has no target record: ' + row.rowKey);
            Assert.isNull(row.submittedDateTime,
                'nor a submission time: ' + row.rowKey);
            Assert.isNull(row.decidedDateTime,
                'nor a decision time: ' + row.rowKey);
        }

        Assert.areEqual(
            new List<String>{
                'SALE_DECISION', 'BROKER_SELECTION', 'NDA_ISSUE', 'FINAL_TERMS', 'CLOSING'
            },
            keys,
            'The five rows must arrive in the BA\'s own order — the component does NOT re-sort, '
            + 'deliberately, so this list IS the rendered order');
        Assert.areEqual(new List<Integer>{ 1, 2, 3, 4, 5 }, sequences,
            'and the sequence numbers must match that order. A mismatch would render "3" beside the '
            + 'second row');
    }

    /**
     * The tracked process for each of the four record-type-independent rows.
     *
     * ⚠ IT LOOKS LIKE A TAUTOLOGY AND IS NOT. These four names are the join key between this class
     * and six XML files nothing else compiles together. A rename in `approvalProcesses/` — or a
     * typo introduced while adding a row — produces a permanently "Not started" checklist with no
     * error anywhere; this is the only assertion in the codebase that would go red.
     */
    @isTest
    static void eachRowNamesItsProcessApiName() {
        Disposition__c disposition = scaffold();

        Test.startTest();
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(disposition.Id));
        Test.stopTest();

        Assert.areEqual(PROC_SALE_DECISION, rows.get('SALE_DECISION').processApiName,
            'Row 1 tracks Sale_Decision_Approval');
        Assert.areEqual(PROC_NDA_ISSUE, rows.get('NDA_ISSUE').processApiName,
            'Row 3 tracks NDA_Issue_Approval — the process being built concurrently. The row must '
            + 'name it whether or not it is deployed yet');
        Assert.areEqual(PROC_OFFER_SELECTION, rows.get('FINAL_TERMS').processApiName,
            'Row 4 tracks Offer_Selection_Approval, which targets the SELECTED offer');
        Assert.areEqual(PROC_CLOSING, rows.get('CLOSING').processApiName,
            'Row 5 tracks Closing_Approval');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // STATE FROM ProcessInstance — INCLUDING THE OFFER ROW, WHICH HAS NO FLAG TO LEAN ON
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Three approvals raised against three DIFFERENT objects all report `Pending` on the right rows,
     * each naming and linking to the record it actually targets.
     *
     * 🔴 THE OFFER ROW IS THE POINT OF THIS TEST. `Disposition_Offer__c` HAS NO `Approval_Pending__c`
     * FIELD — `BOV_Submission__c` does, and this class's row 4 would be structurally blind if the
     * tracker were keyed on those flags. The only source that answers for all six processes is
     * `ProcessInstance.Status`. A build that read flags would pass rows 2 and 5 here and fail row 4,
     * which is exactly the signal.
     *
     * ⚠ THE TARGET LINKS ARE ASSERTED BECAUSE ROWS 2 AND 4 POINT AT RECORDS THAT ARE **NOT** THE ONE
     * THE USER IS LOOKING AT — and Recall for those two approvals lives THERE, not on this page. A
     * link back to the Disposition would be worse than no link.
     */
    @isTest
    static void submittedApprovals_reportPendingWithTheirOwnTargets() {
        Disposition__c disposition = scaffold();
        BOV_Submission__c submission = scaffoldBov();
        Disposition_Offer__c offer = scaffoldOffer();

        // Parent LAST — a submitted Disposition locks (recordEditability = AdminOnly).
        submit(submission.Id);
        submit(offer.Id);
        submit(disposition.Id);

        Test.startTest();
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(disposition.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow broker = rows.get('BROKER_SELECTION');
        DispositionApprovalTrackerService.TrackerRow terms = rows.get('FINAL_TERMS');
        DispositionApprovalTrackerService.TrackerRow closing = rows.get('CLOSING');

        Assert.areEqual(STATE_PENDING, broker.state,
            'The BOV submission was submitted, so the broker row is Pending');
        Assert.areEqual(submission.Id, broker.targetId,
            'and it must name the BOV_SUBMISSION as its target, not the sale — that approval is '
            + 'structurally invisible in the standard related list on this page, and the link is '
            + 'the only route to its Recall button');
        Assert.isTrue(broker.targetUrl.contains('/BOV_Submission__c/'),
            'the link must point at the child object: ' + broker.targetUrl);
        Assert.areEqual('BOV-', broker.targetLabel.left(4),
            'labelled with its own AutoNumber, not the parent\'s: ' + broker.targetLabel);

        Assert.areEqual(STATE_PENDING, terms.state,
            '🔴 THE OFFER ROW. Disposition_Offer__c has NO Approval_Pending__c field, so a '
            + 'flag-keyed tracker reads NotStarted here forever. State must come from '
            + 'ProcessInstance.Status');
        Assert.areEqual(offer.Id, terms.targetId,
            'and the offer row must name the OFFER as its target');
        Assert.isTrue(terms.targetUrl.contains('/Disposition_Offer__c/'),
            'with a link to the offer record: ' + terms.targetUrl);

        Assert.areEqual(STATE_PENDING, closing.state,
            'The Disposition itself was submitted at Closing');
        Assert.areEqual(disposition.Id, closing.targetId,
            'and the closing row targets the sale');
        Assert.areEqual(disposition.Name, closing.targetLabel,
            'labelled with the DISP- number');

        Assert.areEqual(STATE_NOT_STARTED, rows.get('SALE_DECISION').state,
            'The sale-decision approval was never raised on this fixture and must stay NotStarted — '
            + 'a tracker that reported every row from any submission would be useless');

        for (String key : new List<String>{ 'BROKER_SELECTION', 'FINAL_TERMS', 'CLOSING' }) {
            Assert.isNotNull(rows.get(key).submittedDateTime,
                'A submitted row carries its submission time: ' + key);
            Assert.isNull(rows.get(key).decidedDateTime,
                'and NO decision time while pending — null is the live state, and the component '
                + 'must not be handed a fabricated one: ' + key);
        }
    }

    /**
     * A decided approval reports its outcome, and the decision time arrives with it.
     *
     * ⚠ THE OFFER IS THE ONE DECIDED HERE because `Offer_Selection_Approval` is the only one of the
     * five with no `finalApprovalActions` chain to drag other machinery into a test about a READ.
     */
    @isTest
    static void decidedApproval_reportsItsOutcomeAndDecisionTime() {
        Disposition__c disposition = scaffold();
        Disposition_Offer__c offer = scaffoldOffer();

        submit(offer.Id);

        Test.startTest();
        decide(offer.Id, 'Reject');
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(disposition.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow terms = rows.get('FINAL_TERMS');
        Assert.areEqual(STATE_REJECTED, terms.state,
            'A rejected approval must report Rejected. The raw platform status is published '
            + 'deliberately — the component owns the wording, so a test asserting on a display '
            + 'string would be asserting on Apex for a decision the UI makes');
        Assert.isNotNull(terms.decidedDateTime,
            'and a decided approval carries its completion time, which is what lets the card show '
            + 'WHEN rather than only WHAT');
    }

    /**
     * 🔴 NEWEST WINS. A resubmitted approval must report its CURRENT state, not its first.
     *
     * ⚠ THIS IS THE ONLY TEST THAT HOLDS THE SELECTOR'S `ORDER BY CreatedDate DESC, Id DESC` IN
     * PLACE. `DispositionApprovalTrackerService` takes the FIRST row it sees per process and
     * ignores the rest; if that order is ever reversed or dropped, nothing throws, no row count
     * changes, and a recalled-then-resubmitted approval reads its stale outcome forever. There is
     * no second copy of the rule to disagree with — only this assertion.
     *
     * ⚠ IT REJECTS RATHER THAN RECALLS because `Offer_Selection_Approval`'s `finalRejectionActions`
     * writes only `Approval_Status__c` and its `finalRejectionRecordLock` is FALSE — so the offer is
     * left unlocked with `Is_Selected__c` still true, and the entry criterion still holds for the
     * second submission. A recall would test the same ordering through a more fragile fixture.
     *
     * 🔴 IT IS THE ONE TEST IN THIS CLASS WITH AN ENVIRONMENTAL DEPENDENCY, STATED SO A RED IS
     * DIAGNOSED CORRECTLY. Both instances are created in ONE transaction, so their `CreatedDate`
     * values are identical to the second and the tie-break `Id DESC` is what actually decides. That
     * relies on `ProcessInstance` Ids ascending within a table, which this repo assumes wherever it
     * writes `ORDER BY CreatedDate DESC, Id DESC` but has not measured. If this test ever goes red
     * while `dispositionApprovalTracker`'s behaviour is demonstrably correct in the browser,
     * suspect the tie-break assumption BEFORE changing the service — and do not soften the
     * assertion to make it green, because the property it guards is real.
     */
    @isTest
    static void resubmittedApproval_reportsTheNewestInstanceNotTheFirst() {
        Disposition__c disposition = scaffold();
        Disposition_Offer__c offer = scaffoldOffer();

        submit(offer.Id);
        decide(offer.Id, 'Reject');

        Test.startTest();
        submit(offer.Id);
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(disposition.Id));
        Test.stopTest();

        Assert.areEqual(STATE_PENDING, rows.get('FINAL_TERMS').state,
            'THE ROW MUST REPORT THE SECOND SUBMISSION, WHICH IS PENDING. "Rejected" here means the '
            + 'service is reading the OLDEST instance — i.e. the selector\'s '
            + 'ORDER BY CreatedDate DESC has been reversed or dropped, and every resubmitted '
            + 'approval on this card is showing a stale outcome');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ROW 3 — THE AGGREGATE, AND THE UNDEPLOYED PROCESS
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE FIVE AGGREGATE RULES, FALSIFIED DIRECTLY. See the class header for why this takes four
     * integers instead of building approvals: `ProcessInstance` is not createable and
     * `NDA_Issue_Approval` is not in the org yet, so this is the only way to reach four of the five
     * branches at all today.
     *
     * ⚠ THE FIRST CASE IS THE ONE THAT MATTERS MOST. `0 of 0` must read `NotStarted`, NOT
     * `Approved`. "Every NDA is approved" is VACUOUSLY TRUE of a sale with no NDAs, so deleting the
     * `total == 0` guard makes the row turn green on the emptiest possible state — no exception, no
     * count change, and a reader told the NDA gate is cleared on a sale that has issued nothing.
     */
    @isTest
    static void ndaAggregate_appliesItsFiveRulesInOrder() {
        Test.startTest();
        String noNdas = DispositionApprovalTrackerService.ndaAggregateState(0, 0, 0, 0);
        String noneSubmitted = DispositionApprovalTrackerService.ndaAggregateState(3, 0, 0, 0);
        String allApproved = DispositionApprovalTrackerService.ndaAggregateState(3, 3, 3, 0);
        String oneRejected = DispositionApprovalTrackerService.ndaAggregateState(3, 3, 2, 1);
        String partly = DispositionApprovalTrackerService.ndaAggregateState(3, 1, 1, 0);
        String pending = DispositionApprovalTrackerService.ndaAggregateState(3, 3, 0, 0);
        Test.stopTest();

        Assert.areEqual(STATE_NOT_STARTED, noNdas,
            '🔴 THE VACUOUS-TRUTH GUARD. A sale with NO NDAs has not cleared the NDA gate — it has '
            + 'not started it. "Approved" here means the total == 0 guard was removed and the '
            + '"every NDA approved" rule answered for an empty set');
        Assert.areEqual(STATE_NOT_STARTED, noneSubmitted,
            'Three NDAs and nothing submitted is NotStarted. THIS IS ALSO THE READING WHEN '
            + 'NDA_Issue_Approval IS NOT DEPLOYED — an absent process matches no instance, which is '
            + 'how the row degrades gracefully rather than throwing');
        Assert.areEqual(STATE_APPROVED, allApproved,
            'Approved ONLY when every party\'s NDA is approved — a naive "show the latest" would '
            + 'report the sale approved on the strength of one party out of three');
        Assert.areEqual(STATE_REJECTED, oneRejected,
            'A rejection outranks the pending remainder. Reported as Pending it would hide behind a '
            + 'word that reads like "wait", on the one row a reader has to act on');
        Assert.areEqual(STATE_PENDING, partly,
            'Partial approval with nothing outstanding is IN PROGRESS, not Approved. The n of m '
            + 'count is what keeps that honest');
        Assert.areEqual(STATE_PENDING, pending,
            'and three submitted, none decided, is Pending');
    }

    /**
     * The WIRING that feeds those integers: every NDA on the sale counts toward the denominator,
     * and the row degrades to `NotStarted` while `NDA_Issue_Approval` does not exist.
     *
     * 🔴 THIS IS THE "MISSING ProcessDefinition" TEST. There is no `ProcessDefinition` lookup in
     * this feature and there must not be one: an absent process simply matches no instance. A build
     * that resolved the definition and HID the row when it was missing would fail the row-count
     * assertion here — and hiding it is the wrong answer anyway, because a hidden row on a
     * checklist is indistinguishable from a passed one.
     *
     * ⚠ THE DENOMINATOR IS ASSERTED AT **THREE**, NOT AT ONE. The NDA row is the only row whose
     * cardinality is not 1; a service that took "the latest NDA" would report `0 of 1` here and
     * would later report a three-party sale fully approved on one signature.
     * ⚠ AND THE NDAs ARE UNFILTERED BY STATUS — one is Declined on purpose. A read that dropped it
     * would silently shrink the denominator, which is worse than dropping a row: `2 of 2 approved`
     * on a sale with three parties.
     */
    @isTest
    static void ndaRow_countsEveryNdaOnTheSaleAndIsNotStartedWithoutTheProcess() {
        Disposition__c sale = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true
        );
        List<NDA__c> ndas = TestDataFactory.createDispositionNdas(3, sale.Id, false);
        ndas[2].Status__c = 'Declined';
        insert ndas;

        Test.startTest();
        Map<String, DispositionApprovalTrackerService.TrackerRow> rows =
            byKey(DispositionApprovalTrackerService.getTracker(sale.Id));
        Test.stopTest();

        DispositionApprovalTrackerService.TrackerRow nda = rows.get('NDA_ISSUE');
        Assert.areEqual(5, rows.size(),
            'The row must still be present with no approval process deployed — a checklist hides '
            + 'nothing');
        Assert.areEqual(3, nda.totalCount,
            'EVERY NDA on the sale is in the denominator, including the Declined one. An '
            + 'approval-history read filters on nothing but parentage; a status filter here would '
            + 'report "n of 2" on a three-party sale');
        Assert.areEqual(0, nda.approvedCount,
            'and none is approved, because NDA_Issue_Approval is not deployed yet');
        Assert.areEqual(STATE_NOT_STARTED, nda.state,
            'which degrades to NotStarted rather than throwing. This is the state the org is '
            + 'actually in on the day this ships');
        Assert.isNull(nda.targetId,
            'The aggregate row names no single target — it is the one row whose cardinality is not '
            + '1, and naming one NDA would misreport which party the state describes');
    }

    /**
     * The counts are published on the NDA row and NOWHERE ELSE, so the component can tell "this row
     * has no count" from "this row counts zero".
     *
     * ⚠ ABSENCE PIN WITH ITS PRESENCE CONTROL IN THE SAME METHOD — a service that stopped
     * publishing counts entirely would satisfy the nulls perfectly.
     */
    @isTest
    static void onlyTheNdaRowCarriesCounts() {
        Disposition__c disposition = scaffold();

        Test.startTest();
        List<DispositionApprovalTrackerService.TrackerRow> rows =
            DispositionApprovalTrackerService.getTracker(disposition.Id);
        Test.stopTest();

        Integer withCounts = 0;
        for (DispositionApprovalTrackerService.TrackerRow row : rows) {
            if ('NDA_ISSUE'.equals(row.rowKey)) {
                withCounts++;
                Assert.isNotNull(row.totalCount, 'The NDA row always carries a denominator');
                Assert.isNotNull(row.approvedCount, 'and a numerator');
                continue;
            }
            Assert.isNull(row.totalCount,
                'A one-approval row has no denominator: ' + row.rowKey);
            Assert.isNull(row.approvedCount,
                'nor a numerator: ' + row.rowKey);
        }
        Assert.areEqual(1, withCounts,
            'PRESENCE CONTROL: exactly one row carries counts. Zero means the feature stopped '
            + 'working and every null above is vacuous');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // COST, AND THE BOUNDARY
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE HIGHEST-VALUE GOVERNOR ASSERTION IN THIS CLASS. The cost of the card is FIVE queries —
     * four target lookups and one `ProcessInstance` read — regardless of how many BOVs, offers, NDAs
     * or approvals the sale carries. A future change that resolved one child per row would be SOQL
     * in a loop on a page render, and no row-count assertion would notice.
     *
     * ⚠ THE FIXTURE IS BUILT AND THE ID RESOLVED **BEFORE** THE MEASUREMENT WINDOW OPENS. A helper
     * called inside `Limits.getQueries()` brackets counts its own SELECTs and quietly inflates the
     * budget until the assertion means nothing.
     * ⚠ AND NO APPROVALS ARE SUBMITTED HERE ON PURPOSE: the query count is a property of the SHAPE
     * of the read, not of how many rows come back.
     *
     * ⚠ FIVE, NOT FOUR, AND THE DIFFERENCE FROM THE SIBLING CARD IS THE NDA LOOKUP.
     * `DispositionApprovalHistoryServiceTest.manyChildren_costsExactlyFourQueries` pins FOUR and is
     * DELIBERATELY UNTOUCHED — that card resolves three target objects and this one resolves four.
     * If both cards are ever placed on the same page the page pays nine; neither number grows with
     * data volume. Do not "reconcile" the two assertions.
     */
    @isTest
    static void manyChildren_costsExactlyFiveQueries() {
        Disposition__c busy = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true
        );
        TestDataFactory.createBovSubmissions(5, busy.Id, true);
        TestDataFactory.createDispositionOffers(5, busy.Id, true);
        TestDataFactory.createDispositionNdas(5, busy.Id, true);
        Id busyId = busy.Id;

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionApprovalTrackerService.getTracker(busyId);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(5, used,
            'The card must cost a FIXED five queries — Disposition context, BOV targets, offer '
            + 'targets, NDA targets, ProcessInstance — for any number of children. Used: ' + used);
    }

    /**
     * A null Id is a legitimate transient state on a record page (the wire fires before `recordId`
     * is provisioned) and must cost nothing and throw nothing.
     */
    @isTest
    static void nullDispositionId_returnsEmptyAndQueriesNothing() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<DispositionApprovalTrackerService.TrackerRow> rows =
            DispositionApprovalTrackerService.getTracker(null);
        Integer used = Limits.getQueries() - before;
        List<DispositionApprovalTrackerService.TrackerRow> viaController =
            DispositionApprovalTrackerController.getTracker(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A null Id returns an EMPTY list, NOT five NotStarted rows. Empty is a statement about '
            + 'the WIRING; five zeros would be a statement about the SALE, and there is no sale');
        Assert.areEqual(0, used, 'and it must issue no query at all');
        Assert.areEqual(0, viaController.size(), 'the controller agrees, and does not throw');
    }

    /**
     * 🔴 AN ID OF THE WRONG SOBJECT IS REFUSED, LOUDLY. Binding a foreign Id into
     * `WHERE Disposition__c = :id` throws NOTHING — it matches no rows — so without the controller's
     * guard a component wired to the wrong `record-id` would render a confident, permanent
     * five-row "Not started" checklist. On a CHECKLIST that is the worst silent failure available:
     * it does not look empty, it looks like a finding.
     */
    @isTest
    static void wrongSObjectType_isRefusedWithItsOwnMessage() {
        Id bovId = scaffoldBov().Id;

        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            DispositionApprovalTrackerController.getTracker(bovId);
        } catch (AuraHandledException e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'A BOV_Submission__c Id must be REFUSED, not answered with an empty checklist');
        Assert.areEqual('The approval tracker can only be read for a Disposition.', message,
            'and with the PRECISE wiring message, not the generic read-failure one. The guard sits '
            + 'OUTSIDE the try for exactly this reason — inside it, the catch would swallow its own '
            + 'AuraHandledException and replace this with "refresh the page"');
    }

    /**
     * The controller returns what the service returns, unmodified, on the happy path — the only
     * thing between them is the type guard and the catch.
     */
    @isTest
    static void controller_returnsTheServicePayload() {
        Disposition__c disposition = scaffold();

        Test.startTest();
        List<DispositionApprovalTrackerService.TrackerRow> rows =
            DispositionApprovalTrackerController.getTracker(disposition.Id);
        Test.stopTest();

        Assert.areEqual(5, rows.size(),
            'The controller is THIN — it adds no rows and removes none');
        Assert.areEqual('SALE_DECISION', rows[0].rowKey,
            'and it does not re-order: the BA sequence is the service\'s');
    }

    /**
     * 🔴 REVIEW S-2 — THE READ-FAILURE BRANCH, IN APEX. The one branch this card's whole fail-hard
     * design rests on was previously unproven on the server: the Jest suite covers the CLIENT half
     * (what the component renders when the wire errors), and nothing reached
     * `catch (Exception) -> READ_FAILURE_MESSAGE`.
     *
     * ⚠ WHY IT MATTERS MORE HERE THAN ON AN ORDINARY CONTROLLER. Every read in the service is
     * `WITH USER_MODE`, and USER_MODE THROWS — it does not degrade. A persona missing one field
     * grant gets `System.QueryException: No such column`, an FLS denial wearing a schema error. If
     * that ever leaked out unwrapped, the component's error branch would not fire and the user
     * would see a raw platform string; if it were instead swallowed into an empty list, the card
     * would render as "no sale found" and hide a pure provisioning gap. The catch is what makes it
     * a legible error, and this is what proves the catch is wired.
     *
     * ⚠ TWO ASSERTIONS, AND THE SECOND IS THE ARCHITECTURE.md §5 HALF: the raw platform detail must
     * NOT reach the client. `BovControllerTest.testGetOutreachSummary_invalidId_...` sets the
     * precedent for both.
     *
     * ⚠ A DELETED Id WOULD NOT REACH THIS BRANCH — the selector returns an empty LIST, so the
     * service returns an empty list and nothing throws. A denied READER is the only route.
     */
    @isTest
    static void readFailureUnderARestrictedUser_surfacesTheUserSafeMessage() {
        Id dispositionId = scaffold().Id;
        User bare = bareUser();

        Test.startTest();
        String message = '';
        Boolean threw = false;
        System.runAs(bare) {
            try {
                DispositionApprovalTrackerController.getTracker(dispositionId);
            } catch (AuraHandledException e) {
                threw = true;
                message = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'A reader with no Disposition access must be REFUSED. Returning an empty list here '
            + 'would render the card as "sale not found" and hide a pure provisioning gap');
        Assert.areEqual(
            'The approval tracker could not be loaded. Refresh the page or contact your '
            + 'administrator.',
            message,
            'and with the FIXED user-safe message, not the generic wiring one and not the '
            + 'platform\'s own text: ' + message);
        Assert.isFalse(message.toLowerCase().contains('no such column'),
            'ARCHITECTURE.md §5: the raw USER_MODE FLS detail must be masked at the boundary and '
            + 'kept in the debug log, which is admin-only: ' + message);
    }

    /**
     * A user with no DPEG grants at all — the only way to reach the controller's read-failure
     * catch, because every read in the service is `WITH USER_MODE` and USER_MODE THROWS on a denied
     * object rather than returning nothing. Same shape and same reason as `BovControllerTest`'s.
     */
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'datbare',
            Email = 'datbare@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'DAT Bare',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'datbare.' + DateTime.now().getTime()
                + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
        insert u;
        return u;
    }
}
