/**
 * @description Tests the before-save flow `NDA_Signed_Status_Sync`, which derives
 * `NDA__c.NDA_Signed__c` from `Status__c`. Added 2026-08-20 (Tranche 2, code review C1) — the
 * flow gained an `Is_Declined` decision that clears the checkbox on `Status__c = 'Declined'`, and
 * before this class existed NOTHING in the repo tested the flow at all (a grep for
 * `NDA_Signed__c` across every `*Test.cls` found only two hits, both incidental fixture setup in
 * `NdaSelectorTest`).
 *
 * ── WHY THIS MATTERS ──────────────────────────────────────────────────────────
 * `NDA_Signed__c` gates FIVE Opportunity stages via
 * `Opportunity.NDA_Signed_Before_Deal_Progression` (Underwriting, LOI, Under Contract (PSA),
 * About to Close, Closed Won), against every live acquisition NDA in the org. The specific hazard
 * this class exists to pin: the acquisition NDA sequence is Pending -> Received -> Signed -> Sent,
 * with 'Sent' as the TERMINAL step — NOT 'Signed'. The flow's safety property is that 'Declined'
 * is exposed ONLY on the Disposition_NDA record type, so the new clearing branch is STRUCTURALLY
 * UNREACHABLE from the acquisition terminal 'Sent'. If that property is ever broken (e.g. by
 * "simplifying" the flow to a blanket `Status != 'Signed' => false` rule, the exact hazard the
 * flow's own in-root XML comment forbids), a live acquisition deal's final Advance Stage click
 * would silently un-sign its NDA and lock the deal out of every stage past the gate, with nothing
 * red anywhere to explain it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 AMENDED 2026-08-27 — THE ACQUISITION SEQUENCE ENDS AT 'Signed'. 'Sent' WAS REMOVED FROM THE
 * Acquisition_NDA RECORD TYPE BY USER DECISION. THE PARAGRAPH ABOVE IS RETAINED VERBATIM AS THE
 * RECORD OF THE HAZARD IT DESCRIBES, WHICH HAS NOT GONE AWAY — IT HAS MOVED.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * Measured live that day (UI API picklist-values, record type 012iw0000009yeZAAQ): Acquisition_NDA
 * offers exactly Pending | Received | Signed. `RecordStageAdvanceService`'s
 * NDA_ACQUISITION_NEXT_STAGE lost its 'Signed' => 'Sent' hop in the same corrective change.
 *
 * ⇒ WHAT THIS DOES TO THE HAZARD. An acquisition NDA no longer moves PAST the value that sets the
 * checkbox, so the flow's latch is no longer what protects the deal gate — the sequence's own
 * shape is. That is a STRONGER guarantee, not a weaker one, and it is why the pin below changed
 * from "the latch holds across Signed -> Sent" to "Signed -> Sent cannot happen at all".
 * 🔴 THE HAZARD IS DORMANT, NOT DEAD, AND THE FLOW WAS NOT TOUCHED. Connecting
 * `NDA_Signed_Status_Sync`'s dead `Set_Signed_False` branch is still forbidden: it would clear the
 * checkbox on `Pending` and `Received`, and it would re-arm the original hazard in full the moment
 * anyone re-adds a hop out of 'Signed'. `dispositionNdaSignedThenDeclined_clearsNdaSigned` and
 * `statusPendingToReceived_leavesCheckboxUntouched` are unaffected and still cover those paths.
 *
 * ── THE TEST THAT MUST NEVER BE DELETED ──────────────────────────────────────
 * `acquisitionNdaSignedThenSent_keepsNdaSignedTrue` is the regression pin for that entire hazard.
 * ⚠ RENAMED 2026-08-27 to `acquisitionNdaCannotLeaveSigned_soTheGateCannotBeUnLatched`. The old
 * name will not resolve against this class; it is written out because this header names it.
 *
 * ── ⚠ BEFORE-SAVE FLOW: ASSERT ON A RE-QUERIED RECORD, NEVER THE IN-MEMORY ONE ──
 * `NDA_Signed_Status_Sync` is `RecordBeforeSave`, so the in-memory `NDA__c` variable used to build
 * the DML never reflects the flow's writes even immediately after `insert`/`update` returns. Every
 * assertion below re-queries.
 *
 * @see force-app/main/default/flows/NDA_Signed_Status_Sync.flow-meta.xml
 * @see force-app/main/default/objects/NDA__c/fields/NDA_Signed__c.field-meta.xml
 * @see force-app/main/default/objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml
 * @author Unit Testing Agent
 */
@isTest
private class NdaSignedStatusSyncTest {

    /**
     * 🔴 THE REGRESSION PIN FOR THE ENTIRE HAZARD THE FLOW'S OWN HEADER WARNS ABOUT.
     * An acquisition NDA reaching 'Signed' derives NDA_Signed__c = true; moving it on to 'Sent' —
     * the acquisition sequence's TERMINAL step, reached AFTER 'Signed' — must leave the checkbox
     * TRUE. 'Declined' is exposed only on Disposition_NDA, so the new Is_Declined branch is
     * structurally unreachable from this transition; if this test ever goes false, either that
     * value-named exemption broke or someone connected a blanket "not Signed => false" rule.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 REWRITTEN AND RENAMED 2026-08-27 (was acquisitionNdaSignedThenSent_keepsNdaSignedTrue).
     * THE DOC ABOVE IS RETAINED VERBATIM; IT DESCRIBES A TRANSITION THAT NO LONGER EXISTS.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * The user removed 'Sent' from the Acquisition_NDA record type in Setup, so the old body's
     * `nda.Status__c = 'Sent'; update nda;` no longer proves the latch — it throws
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST at the DML, because NDA__c.Status__c is restricted
     * and its record-type subset IS enforced by Apex DML (measured; see this class's own
     * acquisitionNdaDeclinedViaApiResidual_isRefusedByThePicklistRestrictionItself, which is the
     * measurement this repo cites everywhere else).
     *
     * 🔴 THE PIN IS KEPT AND STRENGTHENED RATHER THAN DELETED, AND THE REASON MATTERS. The hazard
     * was never "the latch might fail"; it was "a live acquisition deal gets un-signed by the
     * click that completes its NDA". That click no longer exists — the buy-side NDA ENDS at
     * 'Signed'. This test now asserts the two facts that make the hazard unreachable, in the
     * order a future reader needs them:
     *   1. 'Signed' still derives NDA_Signed__c = true (the deal gate still opens at all);
     *   2. the record CANNOT be moved to 'Sent' afterwards, by ANY channel — the platform refuses
     *      it, so no flow change, no Advance Stage click and no hand-crafted API write can reach
     *      the transition the old test was guarding.
     * A red on (2) — the update SUCCEEDING — means 'Sent' is back on the Acquisition_NDA record
     * type, at which point the ORIGINAL hazard is live again and this test must be restored to its
     * pre-2026-08-27 body along with the NDA_ACQUISITION_NEXT_STAGE hop. That instruction is the
     * whole reason the old doc paragraph above was not deleted.
     */
    @isTest
    static void acquisitionNdaCannotLeaveSigned_soTheGateCannotBeUnLatched() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, false); // Acquisition_NDA, seeds 'Pending'
        nda.Status__c = 'Signed';
        insert nda;

        NDA__c afterSigned = [SELECT NDA_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isTrue(afterSigned.NDA_Signed__c,
            'PRECONDITION: Status = Signed must derive NDA_Signed__c = true on insert');

        Boolean refused = false;
        String platformMessage = '';
        try {
            update new NDA__c(Id = nda.Id, Status__c = 'Sent');
            Assert.fail('🔴 THE REGRESSION THIS TEST EXISTS TO PIN, IN ITS 2026-08-27 FORM. The '
                + 'platform MUST refuse Sent on an Acquisition_NDA. If this update succeeded, Sent '
                + 'is back on that record type and the ORIGINAL hazard is live again: restore the '
                + 'Signed => Sent hop in RecordStageAdvanceService.NDA_ACQUISITION_NEXT_STAGE AND '
                + 'restore this test\'s pre-2026-08-27 body, which asserted that the flow\'s latch '
                + 'holds across that hop. Do not simply delete this assertion');
        } catch (DmlException e) {
            refused = true;
            platformMessage = e.getMessage();
        }

        Assert.isTrue(refused,
            'An acquisition NDA at Signed has nowhere left to go — Sent left this record type on '
            + '2026-08-27, so the un-signing hazard is structurally unreachable rather than merely '
            + 'guarded by the flow\'s latching false branch');
        Assert.isTrue(platformMessage.contains('restricted picklist'),
            'and the refusal must be the record-type picklist restriction specifically, not a '
            + 'validation rule standing in for it — a rule could be deactivated without anyone '
            + 'noticing this test had stopped proving what it claims; got: ' + platformMessage);

        NDA__c afterRefusal = [SELECT NDA_Signed__c, Status__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual('Signed', afterRefusal.Status__c,
            'and the refused write must leave the record on Signed');
        Assert.isTrue(afterRefusal.NDA_Signed__c,
            'and NDA_Signed__c must still be true — the deal stays unblocked for '
            + 'Underwriting/LOI/PSA/About to Close/Closed Won');
    }

    /**
     * The new clearing branch, on the record type it is actually reachable from. Also pins that
     * Date_Signed__c is NEVER cleared — a declined party keeps a signature date beside a false
     * checkbox, by the flow's own description, so any consumer must gate on Status__c and not on
     * either field alone.
     */
    @isTest
    static void dispositionNdaSignedThenDeclined_clearsNdaSigned() {
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        NDA__c nda = TestDataFactory.createDispositionNda(disp.Id, false); // seeds 'Prepare' (was 'Not Sent' until 2026-08-25)
        nda.Status__c = 'Signed';
        insert nda;

        NDA__c afterSigned = [SELECT NDA_Signed__c, Date_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isTrue(afterSigned.NDA_Signed__c, 'PRECONDITION: Signed must derive true on insert');
        Assert.isNotNull(afterSigned.Date_Signed__c,
            'PRECONDITION: Signed with a blank date must be stamped so there is a date to retain');
        Date dateSigned = afterSigned.Date_Signed__c;

        nda.Status__c = 'Declined';
        update nda;

        NDA__c afterDeclined = [SELECT NDA_Signed__c, Date_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isFalse(afterDeclined.NDA_Signed__c,
            'The new Is_Declined branch must clear NDA_Signed__c when Status becomes Declined');
        Assert.areEqual(dateSigned, afterDeclined.Date_Signed__c,
            'Date_Signed__c must NEVER be cleared — a declined party retains a signature date '
            + 'beside a false checkbox, by design. The flow must never touch this field on the '
            + 'Is_Declined branch');
    }

    /**
     * Neither Is_Signed nor Is_Declined fires for this transition — the checkbox must stay
     * untouched (still false from the seed), not merely "false by coincidence of the default".
     */
    @isTest
    static void statusPendingToReceived_leavesCheckboxUntouched() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, true); // seeds at 'Pending'

        NDA__c afterPending = [SELECT NDA_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isFalse(afterPending.NDA_Signed__c, 'PRECONDITION: Pending must not set the checkbox');

        nda.Status__c = 'Received';
        update nda;

        NDA__c afterReceived = [SELECT NDA_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isFalse(afterReceived.NDA_Signed__c,
            'Neither decision fires for Pending -> Received — the checkbox must stay untouched');
    }

    /**
     * The pre-existing stamp behaviour, which must not regress under the new Is_Declined branch:
     * (a) a blank Date_Signed__c at the moment Status first becomes Signed is stamped to TODAY;
     * (b) an explicit Date_Signed__c is never overwritten, not on the first Signed save and not on
     *     a later unrelated save while Status remains Signed — Needs_Signed_Date re-evaluates on
     *     EVERY save, not just the first.
     */
    @isTest
    static void signedStampsDateSignedWhenBlank_andNeverOverwritesAnExisting() {
        // (a) blank date at Signed-time -> stamped to TODAY.
        Opportunity oppA = TestDataFactory.createOpportunity(null, true);
        NDA__c blankDateNda = TestDataFactory.createNda(oppA.Id, false);
        blankDateNda.Status__c = 'Signed';
        insert blankDateNda;

        NDA__c stampedA = [SELECT Date_Signed__c FROM NDA__c WHERE Id = :blankDateNda.Id];
        Assert.areEqual(Date.today(), stampedA.Date_Signed__c,
            'A blank Date_Signed__c at the moment Status becomes Signed must be stamped to TODAY');

        // (b) explicit date at Signed-time (even on the FIRST save) is left alone.
        Opportunity oppB = TestDataFactory.createOpportunity(null, true);
        NDA__c existingDateNda = TestDataFactory.createNda(oppB.Id, false);
        existingDateNda.Status__c = 'Signed';
        Date historicalDate = Date.today().addDays(-30);
        existingDateNda.Date_Signed__c = historicalDate;
        insert existingDateNda;

        NDA__c stampedB = [SELECT Date_Signed__c FROM NDA__c WHERE Id = :existingDateNda.Id];
        Assert.areEqual(historicalDate, stampedB.Date_Signed__c,
            'An explicit Date_Signed__c must never be overwritten, even on the very first save');

        // (b continued) a LATER unrelated save while still Signed must not overwrite it either.
        existingDateNda.Counterparty_Name__c = 'Renamed Counterparty';
        update existingDateNda;

        NDA__c stampedBAgain = [SELECT Date_Signed__c FROM NDA__c WHERE Id = :existingDateNda.Id];
        Assert.areEqual(historicalDate, stampedBAgain.Date_Signed__c,
            'A later unrelated save while still Signed must not overwrite an already-populated '
            + 'Date_Signed__c either — Needs_Signed_Date runs on every save, not just the first');
    }

    /**
     * The Opportunity-side proof: a deal actually progresses past NDA_Signed_Before_Deal_Progression
     * once its primary NDA's Status__c reaches 'Signed'. Deliberately signs the NDA by Status__c
     * ALONE — never setting NDA_Signed__c directly, unlike TestDataFactory.signPrimaryNda — so this
     * test proves the FLOW is what unblocks the gate, not a fixture shortcut. Same shape as
     * UnderwritingGateTest.ndaGateBlocksUnderwritingEntry, whose linkSignedNda() helper sets
     * NDA_Signed__c directly and would not have caught a broken flow.
     */
    @isTest
    static void signedNdaViaFlowUnblocksOpportunityStageProgression() {
        Opportunity opp = TestDataFactory.createOpportunity(null, false);
        opp.StageName = 'Under Review';
        insert opp; // OpportunityReviewService.ensureNda auto-creates a Pending NDA + stamps Primary_NDA__c

        Opportunity withPrimary = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.isNotNull(withPrimary.Primary_NDA__c,
            'PRECONDITION FAILED, not a flow defect: ensureNda must have stamped a primary NDA');

        update new NDA__c(Id = withPrimary.Primary_NDA__c, Status__c = 'Signed');

        NDA__c primaryAfter =
            [SELECT NDA_Signed__c FROM NDA__c WHERE Id = :withPrimary.Primary_NDA__c];
        Assert.isTrue(primaryAfter.NDA_Signed__c,
            'PRECONDITION: the flow must derive NDA_Signed__c = true from Status = Signed alone');

        Test.startTest();
        opp.StageName = 'Underwriting';
        update opp; // NDA_Signed_Before_Deal_Progression must not fire
        Test.stopTest();

        Assert.areEqual('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName,
            'A deal whose primary NDA was signed — via the FLOW deriving NDA_Signed__c from '
            + 'Status__c alone, not via a manually-set field — must progress past the NDA gate '
            + 'into Underwriting');
    }

    /**
     * 🔴 MEASURED 2026-08-20 ON usman-dpeg, NOT ASSUMED — AND IT CONTRADICTS A CLAIM REPEATED
     * ELSEWHERE IN THIS REPO. Several other files (this object's own Acquisition_NDA record type
     * file, RecordStageAdvanceService's class header, the LOI validation rules' shared rationale)
     * state "record-type picklist restriction is UI-only, it is NOT enforced by Apex DML". This
     * test originally tried to write `Status__c = 'Declined'` directly onto an Acquisition_NDA
     * record via plain Apex DML, exactly as those other files describe as possible — and the
     * platform REFUSED it with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, at the DML layer, not
     * merely in the UI. For THIS specific field (`NDA__c.Status__c`, a `<restricted>true</restricted>`
     * picklist with per-record-type value subsets defined in both record type files), Salesforce
     * enforces the record type's picklist value subset on ANY save, API included.
     *
     * This test is therefore rewritten to pin the MEASURED behaviour rather than repeat the
     * unverified assumption: the Is_Declined flow branch is UNREACHABLE on Acquisition_NDA through
     * every channel checked here — not just the UI, but a hand-crafted Apex/data-loader write too.
     * That is a STRONGER safety property than the task that requested this test anticipated ("if
     * you write this test, label it as testing the API residual") — the measurement shows there is
     * no residual to label. ⚠ This finding is scoped to this one field; it does not by itself prove
     * or disprove the "UI-only" claim for any OTHER restricted picklist in this repo (e.g. LOI__c
     * .Stage__c / Contract_Review__c.Negotiation_Status__c, which RecordStageAdvanceService's own
     * header discusses) — those were not re-measured here and their own tests are the place to
     * verify or correct that claim if it matters there.
     * ✅ UPDATE 2026-08-21 — THOSE TWO WERE SUBSEQUENTLY MEASURED AND BEHAVE IDENTICALLY.
     * `LOI__c.Stage__c` ('Signed' on a Disposition_LOI: refused while the record type lacked it,
     * ACCEPTED once the record type was deployed carrying it) and
     * `Contract_Review__c.Negotiation_Status__c` ('Revised' on a Disposition_PSA: active on the
     * master value set, refused off the record type). Reproductions live in
     * RecordStageAdvanceService's class header. Four restricted fields, four refusals — the
     * "UI-only" claim has now been corrected across `classes/`; remaining sites are in
     * `objects/` and `quickActions/` metadata descriptions and belong to the admin agent.
     */
    @isTest
    static void acquisitionNdaDeclinedViaApiResidual_isRefusedByThePicklistRestrictionItself() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, false); // Acquisition_NDA
        nda.Status__c = 'Signed';
        insert nda;

        NDA__c afterSigned = [SELECT NDA_Signed__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.isTrue(afterSigned.NDA_Signed__c, 'PRECONDITION: Signed must derive true');

        Boolean refused = false;
        try {
            update new NDA__c(Id = nda.Id, Status__c = 'Declined');
        } catch (DmlException e) {
            refused = true;
            Assert.isTrue(e.getMessage().contains('RESTRICTED_PICKLIST'),
                'MEASURED: writing Declined onto an Acquisition_NDA record must be refused by the '
                + 'platform\'s own record-type picklist restriction at the Apex DML layer. Got: '
                + e.getMessage());
        }
        Assert.isTrue(refused,
            '🔴 If this ever starts passing (the write succeeding instead of throwing), the org\'s '
            + 'enforcement of record-type picklist restriction changed, and every file in this repo '
            + 'that claims "Apex DML does not enforce it" should be re-checked against this field');

        NDA__c stillSigned = [SELECT NDA_Signed__c, Status__c FROM NDA__c WHERE Id = :nda.Id];
        Assert.areEqual('Signed', stillSigned.Status__c, 'The refused write must not have committed');
        Assert.isTrue(stillSigned.NDA_Signed__c, 'And the checkbox must remain untouched');
    }
}
