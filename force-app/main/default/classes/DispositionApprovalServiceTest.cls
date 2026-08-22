/**
 * @description Tests DispositionApprovalService — the disposition Submit-for-Approval derivation
 * (design DEV-2) and the two-step offer selection (design D-3), added with the 2026-08-19
 * disposition flow redesign.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * NO 251-RECORD BULK TEST — .claude/rules/bulk-test-rule.md PER-TRANSACTION-SINGLETON
 * EXEMPTION APPLIES TO BOTH PUBLIC METHODS. RECORDED HERE PER THE CLASS HEADER'S OWN
 * INSTRUCTION SO REVIEW DOES NOT DEMAND 251.
 * ─────────────────────────────────────────────────────────────────────────────────────
 * `submitForApproval` and `selectOffer` are both per-transaction-singleton @AuraEnabled
 * operations invoked once per quick-action click: one disposition, no loop over records, no
 * trigger behind either method. There is no second batch chunk for 251 records to force, and a
 * 251-record test would exercise no additional code path while risking unrelated governor limits
 * — the exact anti-pattern the exemption exists to prevent (same shape as
 * DispositionServiceTest's exemption for `initiateAndSubmit` / `findOrCreate`, and
 * RecordStageAdvanceService's own exemption). The exemption is about VOLUME only:
 * `selectOffer` still performs one bulk DML over the disposition's whole offer set, which is
 * proven at 3 offers (enough to exercise the exclusivity swap) rather than 251, because the
 * DML shape does not change with the number of offers.
 *
 * ── WHAT THIS SUITE CANNOT PROVE, SAID OUT LOUD ─────────────────────────────
 * These tests run as the deploying admin test user, who passes
 * DispositionActionPermissionService's gate via the "Modify All Data" bypass — the same
 * assumption RecordStageAdvanceServiceTest's Disposition calls make (it calls `advance()`
 * directly with no persona setup). The permission DENIAL path is pinned once, under a bare
 * Standard User via System.runAs, mirroring DispositionActionPermissionServiceTest's own
 * pattern; the gate's internals (custom-permission resolution, admin bypass, caching) are
 * DispositionActionPermissionServiceTest's job, not this class's.
 *
 * ── ALL_NDAs_SIGNED_BEFORE_PROGRESSION ──────────────────────────────────────
 * `selectOffer` writes the Disposition to `Offer Selection`, which is one of the VR's gated
 * target stages since the 2026-08-19 redesign dropped the rule's Off_Market-only term. Every
 * fixture in this class that reaches `selectOffer` successfully therefore signs a buyer NDA
 * first — see `signBuyerNdaOn`.
 *
 * @see force-app/main/default/classes/DispositionApprovalService.cls
 * @see force-app/main/default/classes/DispositionApprovalAdvanceServiceTest.cls (what an
 *      APPROVAL does afterwards — this class only SUBMITS)
 * @author Unit Testing Agent
 */
@isTest
private class DispositionApprovalServiceTest {

    private static final String STAGE_READINESS = 'Disposition Readiness';
    private static final String STAGE_BOV_OUTREACH = 'BOV Outreach';
    private static final String STAGE_BROKER_SELECTION = 'Broker Selection';
    private static final String STAGE_RELEASE_MATERIALS = 'Release Materials';
    private static final String STAGE_ACTIVE_LISTING = 'Active Listing';
    private static final String STAGE_OFFER_SELECTION = 'Offer Selection';
    private static final String STAGE_CLOSING = 'Closing';

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    /**
     * A satisfying asking price for the 2026-08-22 Disposition-Readiness gate. Any positive
     * number passes; this one is a plausible sale price so a failure message reads like data.
     */
    private static final Decimal ASKING_PRICE = 2500000;

    /**
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ASKING PRICE DEFAULTS TO **BLANK** AND MUST KEEP DEFAULTING TO BLANK.
     * ══════════════════════════════════════════════════════════════════════════════
     * `TestDataFactory.createDispositions` does not populate `Asking_Price__c`, which mirrors
     * production (measured 2026-08-22: 1 of the 3 live dispositions has it, and the one sitting
     * at Disposition Readiness does NOT). The obvious "fix" when the 2026-08-22 gate turned two
     * existing tests red was to teach the FACTORY to set a price — do not do that. Every fixture
     * in the repo would then satisfy the gate by construction, the gate would be unfalsifiable
     * from any other test class, and the three refusal tests below would be the only thing left
     * proving it exists. Instead the price is passed EXPLICITLY at the call sites that need one,
     * so a reader can see at each site whether the gate is being satisfied or exercised.
     */
    private static Disposition__c onMarketAt(String stage) {
        return onMarketAt(stage, null);
    }

    private static Disposition__c onMarketAt(String stage, Decimal askingPrice) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        d.Asking_Price__c = askingPrice;
        insert d;
        return d;
    }

    private static Disposition__c offMarketAt(String stage) {
        return offMarketAt(stage, null);
    }

    private static Disposition__c offMarketAt(String stage, Decimal askingPrice) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_OFF_MARKET, false);
        d.Disposition_Stage__c = stage;
        d.Asking_Price__c = askingPrice;
        insert d;
        return d;
    }

    /** Satisfies All_NDAs_Signed_Before_Progression, which gates BOTH record types since the redesign. */
    private static void signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
    }

    private static Integer pendingApprovalsFor(Id targetId) {
        return [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :targetId AND Status = 'Pending'];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // submitForApproval — TARGET DERIVATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ THIS FIXTURE GAINED AN EXPLICIT ASKING PRICE ON 2026-08-22 AND THE ARGUMENT IS THE TEST.
     * Before the Disposition-Readiness gate this test passed with `Asking_Price__c` blank. It now
     * REQUIRES a price, which is the cheapest available proof that the gate is wired into the
     * production path rather than only into the three refusal tests below: delete the second
     * argument and this test goes red.
     */
    @isTest
    static void submitAtReadiness_withAskingPrice_submitsTheDispositionItself() {
        Disposition__c d = onMarketAt(STAGE_READINESS, ASKING_PRICE);

        Test.startTest();
        String msg = DispositionApprovalService.submitForApproval(d.Id);
        Test.stopTest();

        Assert.areEqual(1, pendingApprovalsFor(d.Id),
            'The Disposition itself must be submitted into Sale_Decision_Approval');
        Assert.isTrue(msg.contains('Sale Decision'), 'The confirmation must name the Sale Decision approval');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ASKING-PRICE GATE, AND WHY IT IS TESTED **HERE** AND NOT AS A RULE.
     * ══════════════════════════════════════════════════════════════════════════════
     * User requirement, 2026-08-22: "asking price should be mandatory before moving to BOV
     * Outreach". The hop off `Disposition Readiness` is written by
     * `DispositionApprovalAdvanceQueueable` in SYSTEM_MODE with `allOrNone = false`, where a
     * validation rule's refusal is DISCARDED — so the gate lives at submission time, which is the
     * last moment a human is present to be told. The sibling proof that no rule was shipped, and
     * that the machine advance is therefore NOT blocked, is
     * `DispositionApprovalProcessesTest.saleDecisionApproved_blankAskingPrice_stillAdvances`;
     * these two suites are complements and neither is sufficient alone.
     */
    @isTest
    static void submitAtReadiness_blankAskingPrice_isRefusedWithTheAuthoredMessage() {
        Disposition__c d = onMarketAt(STAGE_READINESS); // no price — the production default
        Assert.isNull(
            [SELECT Asking_Price__c FROM Disposition__c WHERE Id = :d.Id].Asking_Price__c,
            'PRECONDITION: the fixture must have NO asking price, or this test proves nothing');

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A blank asking price must refuse the Sale Decision submission');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('asking price is required'),
                'The refusal must be the AUTHORED message, not the platform\'s: ' + e.getMessage());
            Assert.isTrue(e.getMessage().contains('Asking Price'),
                'The refusal must name the ON-SCREEN LABEL so the user knows what to fill in: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The gate must refuse, not silently submit');
        Assert.areEqual(0, pendingApprovalsFor(d.Id),
            'Nothing may enter Sale_Decision_Approval — a refusal that still submits would put an '
            + 'unpriced sale in front of an approver and then advance it');
    }

    /**
     * 🔴 THE OFF-MARKET HALF, AND IT IS NOT A COPY OF THE TEST ABOVE. An Off_Market disposition
     * has NO `BOV Outreach` stage — the same approval sends it straight to `Broker Selection`. The
     * user asked for the gate "before moving to BOV Outreach"; scoping it to that stage NAME would
     * have exempted an entire record type permanently, since no later off-market stage asks for
     * this field either. The gate is on LEAVING Disposition Readiness, which is record-type
     * independent, and this test is the only thing that would catch a future record-type guard
     * being added to that branch.
     */
    @isTest
    static void submitAtReadiness_offMarket_blankAskingPrice_isRefusedToo() {
        Disposition__c d = offMarketAt(STAGE_READINESS);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('An off-market sale must not leave Disposition Readiness unpriced either');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('asking price is required'),
                'Same authored message on both record types: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The gate must be record-type independent');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing may be submitted');
    }

    /**
     * ⚠ ZERO IS NOT A PRICE, AND THIS IS THE ONLY TEST THAT SAYS SO. `Asking_Price__c`'s own
     * `description` records that "a blank OR ZERO value makes every BOV score on this sale blank"
     * — so a gate that only checked `!= null` would let through the exact state the field exists
     * to prevent, while LOOKING satisfied on screen. Narrowing the guard to `== null` leaves every
     * other test in this class green.
     */
    @isTest
    static void submitAtReadiness_zeroAskingPrice_isRefusedLikeABlankOne() {
        Disposition__c d = onMarketAt(STAGE_READINESS, 0);
        Assert.areEqual(0, [SELECT Asking_Price__c FROM Disposition__c WHERE Id = :d.Id].Asking_Price__c,
            'PRECONDITION: the fixture must hold a stored ZERO, not a null');

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A zero asking price must be refused exactly like a blank one');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('asking price is required'),
                'Zero must produce the SAME authored message, not a different one: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, '`<= 0` must be refused, not only `== null`');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing may be submitted');
    }

    /** The off-market positive: a priced Off_Market sale submits into the same approval. */
    @isTest
    static void submitAtReadiness_offMarket_withAskingPrice_submitsTheDisposition() {
        Disposition__c d = offMarketAt(STAGE_READINESS, ASKING_PRICE);

        Test.startTest();
        String msg = DispositionApprovalService.submitForApproval(d.Id);
        Test.stopTest();

        Assert.areEqual(1, pendingApprovalsFor(d.Id),
            'A priced Off_Market disposition must enter Sale_Decision_Approval — the gate is on the '
            + 'PRICE, not on the record type');
        Assert.isTrue(msg.contains('Sale Decision'), 'The confirmation must name the Sale Decision approval');
    }

    @isTest
    static void submitAtBovOutreach_noSelectedSubmission_throwsAuthoredError() {
        Disposition__c d = onMarketAt(STAGE_BOV_OUTREACH);
        TestDataFactory.createBovSubmission(d.Id, true); // Backup only, nothing Selected

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('No Selected BOV submission must refuse the submit');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('No broker is marked Selected'),
                'The refusal must name the fix: choose a broker: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'BOV Outreach with no Selected submission must throw');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    @isTest
    static void submitAtBovOutreach_withSelectedSubmission_submitsTheSubmissionNotTheDisposition() {
        Disposition__c d = onMarketAt(STAGE_BOV_OUTREACH);
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(d.Id, false);
        selected.Submission_Status__c = 'Selected';
        insert selected;

        Test.startTest();
        String msg = DispositionApprovalService.submitForApproval(d.Id);
        Test.stopTest();

        Assert.areEqual(1, pendingApprovalsFor(selected.Id),
            '🔴 THE SUBMISSION IS SUBMITTED, NOT THE DISPOSITION — this is the load-bearing line of '
            + 'the whole branch (design decision 3)');
        Assert.areEqual(0, pendingApprovalsFor(d.Id),
            'The Disposition itself must NOT be the target of any pending approval');
        Assert.isTrue(msg.contains('broker'), 'The confirmation must name the broker submission: ' + msg);
    }

    /**
     * 🔴 THE ">1 SELECTED" BACKSTOP (2026-08-21). READ THE SCOPE NOTE BEFORE JUDGING THIS TEST.
     *
     * ── WHY THIS BRANCH EXISTS AT ALL ───────────────────────────────────────────
     * Until 2026-08-21 `BovSubmissionSelector.selectSelectedByDispositionId` carried `LIMIT 1`, so
     * on a disposition with two Selected responses it returned ONE OF THEM and this service
     * submitted it into `Broker_Finalize_Approval` — appointing an arbitrary broker with nothing
     * anywhere reporting that a choice had been made. The fix was to the QUERY, not to an `if`:
     * a `LIMIT 1` cannot express "exactly one", only "at most one".
     *
     * ── AND WHY IT IS NOT REACHABLE THROUGH THE UI ──────────────────────────────
     * `BovSubmissionSelectionGuardService` refuses any INSERT or UPDATE that would create a second
     * Selected row. This is a backstop against data that predates that guard (2026-08-20), against
     * API / data-loader writes, and against the gap this fixture uses.
     *
     * ── THE FIXTURE IS THE REAL PATH, NOT A CONTRIVANCE ─────────────────────────
     * `BovSubmissionTrigger` declares no `after undelete` context and the platform has no BEFORE
     * undelete context at all, so restoring a previously-Selected submission from the Recycle Bin
     * onto a disposition that has since appointed someone else creates a second Selected row NO
     * guard sees. That is residual R-1 in the guard's own header, and it is how this state actually
     * arises in production. 🔴 NO `@TestVisible` BYPASS WAS ADDED TO THE GUARD, and none should be
     * — the guard's header records that trade being considered and rejected, because it would put
     * a production-reachable escape hatch in the class in order to build the state the class exists
     * to prevent.
     */
    @isTest
    static void submitAtBovOutreach_twoSelectedSubmissions_refusesRatherThanPickingOne() {
        Disposition__c d = onMarketAt(STAGE_BOV_OUTREACH);

        // ── The undelete gap, step by step. Reordering these breaks the fixture: swap the
        // second insert and the undelete and the guard correctly refuses the insert.
        BOV_Submission__c first = TestDataFactory.createBovSubmission(d.Id, false);
        first.Submission_Status__c = 'Selected';
        insert first;
        delete first;                                   // SOQL stops seeing it, so the guard does too
        BOV_Submission__c second = TestDataFactory.createBovSubmission(d.Id, false);
        second.Submission_Status__c = 'Selected';
        insert second;                                  // guard counts ZERO committed Selected rows
        undelete first;                                 // no undelete context on the trigger at all

        Assert.areEqual(2, [
            SELECT COUNT() FROM BOV_Submission__c
            WHERE Disposition__c = :d.Id AND Submission_Status__c = 'Selected'
        ], 'PREMISE — two committed Selected rows must really exist. If the guard ever gains an '
            + 'after-undelete context (the right fix for its R-1 residual) this line fails FIRST '
            + 'and says so, instead of the refusal assertion below looking like a service defect.');

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('Two Selected responses must refuse the submit, not submit one of them');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('More than one broker response is marked Selected'),
                'The refusal must NAME the problem: ' + e.getMessage());
            Assert.isTrue(e.getMessage().contains('Backup'),
                'and NAME THE FIX in on-screen terms — set all but one to Backup: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'Two Selected submissions must throw');
        // 🔴 THE FALSIFIER FOR "IT REFUSED RATHER THAN PICKING ONE". Without these two lines the
        // test would still pass if the service threw AFTER submitting — and the whole defect being
        // fixed is a broker silently entering an approval nobody chose.
        Assert.areEqual(0, pendingApprovalsFor(first.Id),
            'Neither Selected response may have been submitted — not even the first one');
        Assert.areEqual(0, pendingApprovalsFor(second.Id), 'nor the second');
    }

    @isTest
    static void submitAtBrokerSelection_onMarket_isRefusedWithTheAdvanceToNdaHint() {
        Disposition__c d = onMarketAt(STAGE_BROKER_SELECTION);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('An on-market disposition must not reach the off-market broker-selection branch');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('Advance to NDA'),
                'The refusal must point at the correct on-market control: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'On-market Broker Selection must refuse the broker-selection-approval branch');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    /**
     * RENAMED from "...blankSelectedBroker..." (unit-testing agent pass, 2026-08-20, off-market
     * broker lookup). The gate no longer reads `Selected_Broker__c` at all — it is now
     * `Broker__c == null` (`DispositionApprovalService.cls:266`) — so a "blank text" fixture would
     * no longer exercise this branch. Retargeted to a null `Broker__c` lookup, and the message
     * assertion follows the class's `NO_BROKER_MESSAGE` re-author (renamed from
     * `NO_SELECTED_BROKER_MESSAGE`, unit-testing agent pass 2026-08-20, code review Suggestion 1):
     * the old substring `'Set the Selected Broker'` no longer exists anywhere in the class.
     */
    @isTest
    static void submitAtBrokerSelection_offMarket_noBrokerSelected_throwsAuthoredError() {
        Disposition__c d = offMarketAt(STAGE_BROKER_SELECTION);
        // Broker__c left null.

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A null Broker__c must refuse the submit');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.areEqual(
                'No broker has been selected on this disposition yet. Choose a broker in the '
                + 'Broker field, then submit for approval.',
                e.getMessage(),
                'The refusal must be the exact re-authored NO_BROKER_MESSAGE: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'Off-market Broker Selection with no broker set must throw');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    /**
     * 🔴 THE NO-FALLBACK PIN (design §1.7). A row that carries a hand-typed `Selected_Broker__c`
     * but no `Broker__c` lookup must still be REFUSED — this is what stops a future change from
     * quietly restoring the retired `String.isBlank(Selected_Broker__c)` `||` fallback. The update
     * touches ONLY `Selected_Broker__c`, never `Broker__c`, so `DispositionBrokerStampService`
     * skips the record (its change-key is `Broker__c`, per that service's own header) and the
     * hand-typed text survives into the read this test exercises — proving the refusal really is
     * about the LOOKUP being null, not about the text being absent.
     */
    @isTest
    static void submitAtBrokerSelection_offMarket_textPopulatedButBrokerNull_stillThrows() {
        Disposition__c d = offMarketAt(STAGE_BROKER_SELECTION);
        d.Selected_Broker__c = 'Hand Typed Name - Not A Real Contact';
        update d;

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A populated Selected_Broker__c text with a null Broker__c must still be '
                + 'refused — there is no || fallback');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('No broker has been selected'),
                'The refusal must be the lookup-based message even though text is populated: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'A populated Selected_Broker__c must NOT satisfy the gate — Broker__c is the only input');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    @isTest
    static void submitAtBrokerSelection_offMarket_withBroker_submitsTheDisposition() {
        Disposition__c d = offMarketAt(STAGE_BROKER_SELECTION);
        d.Broker__c = TestDataFactory.createBrokerContact(null, true).Id;
        update d;

        Test.startTest();
        String msg = DispositionApprovalService.submitForApproval(d.Id);
        Test.stopTest();

        Assert.areEqual(1, pendingApprovalsFor(d.Id),
            'The Disposition must be submitted into Broker_Selection_Approval');
        Assert.isTrue(msg.contains('broker selection'), 'The confirmation must name the approval: ' + msg);
    }

    @isTest
    static void submitAtClosing_wireIncomplete_throwsTheAuthoredReplacementForThePlatformError() {
        Disposition__c d = onMarketAt(STAGE_CLOSING);
        // Wire_Verification_Completed__c left false (default).

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('Wire verification incomplete must refuse the submit');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            // 🔴 THE ENTIRE MITIGATION FOR CLOSING_APPROVAL'S NEW WIRE ENTRY CRITERION. Deleting
            // this pre-check restores the platform's opaque "no applicable approval process".
            Assert.isTrue(e.getMessage().contains('Wire verification must be complete'),
                'The refusal must be the AUTHORED wire message, not the platform\'s opaque one: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'Closing with an incomplete wire must throw before Approval.process runs');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    @isTest
    static void submitAtClosing_wireComplete_submitsTheDisposition() {
        Disposition__c d = onMarketAt(STAGE_CLOSING);
        d.Wire_Verification_Completed__c = true;
        update d;

        Test.startTest();
        String msg = DispositionApprovalService.submitForApproval(d.Id);
        Test.stopTest();

        Assert.areEqual(1, pendingApprovalsFor(d.Id),
            'The Disposition must be submitted into Closing_Approval once the wire is verified');
        Assert.isTrue(msg.contains('Closing'), 'The confirmation must name the Closing approval: ' + msg);
    }

    @isTest
    static void submitAtAStageWithNoApproval_throwsNamingTheFourRealStages() {
        Disposition__c d = onMarketAt('NDA');

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('NDA has no approval at all — Submit must refuse rather than silently no-op');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('No approval applies at the NDA stage'),
                'The refusal must name the stage and the four real approval stages: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A stage with no approval must be refused, not silently ignored');
    }

    @isTest
    static void submitAlreadyPending_refusesADuplicateSubmission() {
        // Priced, because the asking-price gate now runs BEFORE the pending gate — an unpriced
        // fixture would be refused for the wrong reason and this test would assert on a message
        // it never reached.
        Disposition__c d = onMarketAt(STAGE_READINESS, ASKING_PRICE);
        DispositionApprovalService.submitForApproval(d.Id); // first submit succeeds

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A second submit while the first is still pending must be refused');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('already pending approval'),
                'The refusal must name the pending-duplicate rule: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The pending gate must block a duplicate submission');
        Assert.areEqual(1, pendingApprovalsFor(d.Id),
            'Exactly one pending approval must exist — the duplicate attempt created none');
    }

    /**
     * ⚠ THE PENDING GATE IS APPLIED TO THE TARGET, NOT TO THE DISPOSITION. On the BOV Outreach
     * branch the target is the SUBMISSION, so a Disposition with an unrelated pending approval
     * (its own Sale Decision, recalled and resubmitted at a different stage in this fixture's
     * lifetime is out of scope here) must not block a broker submission. This test proves the
     * narrower claim directly reachable from one disposition: submitting the BOV branch twice in
     * a row is refused by the SUBMISSION's own pending state, not by anything on the Disposition.
     */
    @isTest
    static void submitAtBovOutreach_alreadyPendingOnTheSubmission_refusesTheSecondClick() {
        Disposition__c d = onMarketAt(STAGE_BOV_OUTREACH);
        BOV_Submission__c selected = TestDataFactory.createBovSubmission(d.Id, false);
        selected.Submission_Status__c = 'Selected';
        insert selected;
        DispositionApprovalService.submitForApproval(d.Id); // first submit succeeds

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(d.Id);
            Assert.fail('A second submit while the submission is still pending must be refused');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('already pending approval'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The pending gate must fire on the SUBMISSION target');
        Assert.areEqual(1, pendingApprovalsFor(selected.Id), 'Exactly one pending approval on the submission');
    }

    @isTest
    static void submitForApproval_nullDispositionId_throwsTheNoRecordMessage() {
        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.submitForApproval(null);
            Assert.fail('A null Id must be refused before any query runs');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.areEqual('No record was provided.', e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A null dispositionId must throw ApprovalException');
    }

    /**
     * The one permission-denial test in this class. Mirrors
     * DispositionActionPermissionServiceTest's bare-user pattern; the gate's own internals are
     * that class's responsibility, not this one's.
     */
    @isTest
    static void submitForApproval_bareUser_isDeniedBeforeAnyRead() {
        // 🔴 DELIBERATELY UNPRICED. The permission assert is the FIRST statement in
        // submitForApproval, before the selector read and therefore before the asking-price gate,
        // so a bare user must fail with AccessDeniedException and NOT with the price refusal.
        // Pricing this fixture would make the ordering claim untestable.
        Disposition__c d = onMarketAt(STAGE_READINESS);
        User bareUser = buildStandardUser('dast1');
        insert bareUser;

        Test.startTest();
        Boolean denied = false;
        DispositionActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                DispositionApprovalService.submitForApproval(d.Id);
                Assert.fail('A user with no disposition-driver grant must be denied');
            } catch (DispositionActionPermissionService.AccessDeniedException e) {
                denied = true;
            }
        }
        DispositionActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(denied, 'The gate must run BEFORE any read — a bare user must never reach the query');
        Assert.areEqual(0, pendingApprovalsFor(d.Id), 'Nothing should have been submitted');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectOffer — DESIGN D-3
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectOffer_onMarket_advancesStageFlagsExclusivelyAndSubmitsTheOffer() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        signBuyerNdaOn(d.Id);
        List<Disposition_Offer__c> offers = TestDataFactory.createDispositionOffers(2, d.Id, true);
        Id winnerId = offers[0].Id;
        Id loserId = offers[1].Id;

        Test.startTest();
        String msg = DispositionApprovalService.selectOffer(d.Id, winnerId);
        Test.stopTest();

        Disposition__c reread = [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id];
        Assert.areEqual(STAGE_OFFER_SELECTION, reread.Disposition_Stage__c,
            'Selecting an offer must advance the stage to Offer Selection immediately');
        Map<Id, Disposition_Offer__c> offerById = new Map<Id, Disposition_Offer__c>(
            [SELECT Id, Is_Selected__c FROM Disposition_Offer__c WHERE Disposition__c = :d.Id]);
        Assert.isTrue(offerById.get(winnerId).Is_Selected__c, 'The chosen offer must be flagged selected');
        Assert.isFalse(offerById.get(loserId).Is_Selected__c, 'Every other offer must be flagged NOT selected');
        Assert.areEqual(1, pendingApprovalsFor(winnerId), 'The winning offer must be submitted for approval');
        Assert.isTrue(msg.contains('selected'), msg);
    }

    @isTest
    static void selectOffer_offMarket_requiresReleaseMaterialsNotActiveListing() {
        Disposition__c d = offMarketAt(STAGE_RELEASE_MATERIALS);
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);

        Test.startTest();
        String msg = DispositionApprovalService.selectOffer(d.Id, offer.Id);
        Test.stopTest();

        Assert.areEqual(STAGE_OFFER_SELECTION,
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'Off-market collects offers at Release Materials, and selection must still advance');
    }

    @isTest
    static void selectOffer_wrongStage_isRefusedNamingTheRequiredStage() {
        Disposition__c d = onMarketAt(STAGE_RELEASE_MATERIALS); // wrong for on-market — needs Active Listing
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.selectOffer(d.Id, offer.Id);
            Assert.fail('On-market Release Materials must refuse — the on-market collection stage is Active Listing');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('Active Listing'),
                'The refusal must name the stage that IS correct: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'Select Offer at the wrong stage must be refused');
        Assert.areEqual(STAGE_RELEASE_MATERIALS,
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'A refused selection must not move the stage');
    }

    @isTest
    static void selectOffer_offerNotOnThisDisposition_isRefused() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        signBuyerNdaOn(d.Id);
        Disposition__c other = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c foreignOffer = TestDataFactory.createDispositionOffer(other.Id, true);

        Test.startTest();
        Boolean refused = false;
        try {
            DispositionApprovalService.selectOffer(d.Id, foreignOffer.Id);
            Assert.fail('An offer belonging to a DIFFERENT disposition must be refused');
        } catch (DispositionApprovalService.ApprovalException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('does not belong to this disposition'), e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A cross-disposition offer Id must be refused');
        Assert.areEqual(STAGE_ACTIVE_LISTING,
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            'A refused selection must not move the stage');
    }

    /**
     * 🔴 THE SAVEPOINT FALSIFIER. Re-picking an offer that ALREADY carries a pending approval
     * (submitted outside this call, so its own Is_Selected__c does not change and the exclusivity
     * DML is skipped entirely) still moves the Disposition stage — and then `submit()` throws
     * ALREADY_IN_PROCESS. Without the savepoint the stage write would be left committed while the
     * resubmission failed; with it, the whole operation rolls back and the Disposition is found
     * EXACTLY where it started.
     */
    @isTest
    static void selectOffer_submitFailure_rollsBackTheStageAdvance() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        insert offer;
        // Submit it directly (bypassing selectOffer) so it already carries a PENDING approval —
        // the disposition itself is deliberately left at Active Listing, as if selectOffer had
        // never been called, to isolate the failure to submit() alone.
        Approval.ProcessSubmitRequest preSubmit = new Approval.ProcessSubmitRequest();
        preSubmit.setObjectId(offer.Id);
        Approval.process(preSubmit);
        Assert.areEqual(1, pendingApprovalsFor(offer.Id), 'PRECONDITION: the offer must already be pending');

        Test.startTest();
        Boolean threw = false;
        try {
            DispositionApprovalService.selectOffer(d.Id, offer.Id);
            Assert.fail('Re-submitting an already-pending offer must throw, not silently succeed');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The already-pending resubmission must raise an exception');
        Assert.areEqual(STAGE_ACTIVE_LISTING,
            [SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :d.Id].Disposition_Stage__c,
            '🔴 THE STAGE MUST ROLL BACK to Active Listing — a savepoint-less implementation would '
            + 'leave it at Offer Selection despite the failed submit');
        Assert.areEqual(1, pendingApprovalsFor(offer.Id),
            'Still exactly ONE pending approval on the offer — no duplicate was created');
    }

    @isTest
    static void selectOffer_nullIds_throwTheNoRecordMessage() {
        Disposition__c d = onMarketAt(STAGE_ACTIVE_LISTING);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, true);

        Test.startTest();
        Boolean refusedNullDisposition = false;
        try {
            DispositionApprovalService.selectOffer(null, offer.Id);
        } catch (DispositionApprovalService.ApprovalException e) {
            refusedNullDisposition = true;
        }
        Boolean refusedNullOffer = false;
        try {
            DispositionApprovalService.selectOffer(d.Id, null);
        } catch (DispositionApprovalService.ApprovalException e) {
            refusedNullOffer = true;
        }
        Test.stopTest();

        Assert.isTrue(refusedNullDisposition, 'A null dispositionId must throw before any query');
        Assert.isTrue(refusedNullOffer, 'A null offerId must throw before any query');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // helpers
    // ═══════════════════════════════════════════════════════════════════════════

    private static User buildStandardUser(String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            Alias = tag.left(8),
            Email = tag + '@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Test ' + tag,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = tag + '.' + DateTime.now().getTime()
                + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid'
        );
    }
}
