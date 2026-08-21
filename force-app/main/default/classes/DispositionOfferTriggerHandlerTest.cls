/**
 * @description Tests DispositionOfferTriggerHandler — the offer-acceptance hand-off from
 * `Offer_Selection_Approval` (which runs on the OFFER) back onto the parent Disposition. Added
 * 2026-08-19 with the disposition flow redesign (DEV-5). Sibling of BovSubmissionTriggerHandler,
 * with one extra wrinkle: this handler ALSO writes the offer's own `Offer_Status__c` in the
 * BEFORE context, since the offer is the record the approval locks.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 251-RECORD BULK MANDATE APPLIES — NO EXEMPTION (trigger-driven). .claude/rules/bulk-test-rule.md
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Budget: ONE selector query and ONE `Database.update` per chunk for the AFTER half, PLUS zero
 * statements for the BEFORE-context stamp at any record count. `bulk251AcceptsAtConstantCost`
 * asserts the governor counters directly, snapshotted around the real DML, never across
 * `Test.stopTest()`.
 *
 * ── ALL_NDAs_SIGNED_BEFORE_PROGRESSION ──────────────────────────────────────
 * `LOI` is one of the VR's gated target stages. Every fixture here that legitimately advances the
 * parent from `Offer Selection` to `LOI` signs a buyer NDA first.
 *
 * These tests simulate the approval's own field update (`Approval_Status__c` -> 'Approved') with a
 * direct DML write, exactly as `Set_Offer_Approval_Approved`'s FieldUpdate would produce — the
 * end-to-end Approval.process walk lives in DispositionApprovalProcessesTest.
 *
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls
 * @author Unit Testing Agent
 */
@isTest
private class DispositionOfferTriggerHandlerTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    private static void signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
    }

    /** Bulk twin of signBuyerNdaOn — ONE insert for the whole set, never one per record. */
    private static void signBuyerNdasOn(List<Disposition__c> dispositions) {
        List<NDA__c> ndas = new List<NDA__c>();
        for (Disposition__c d : dispositions) {
            NDA__c nda = TestDataFactory.createDispositionNda(d.Id, false);
            nda.Status__c = 'Signed';
            ndas.add(nda);
        }
        insert ndas;
    }

    private static Disposition__c reread(Id dispositionId) {
        return [
            SELECT Disposition_Stage__c, Accepted_Offer_Price__c
            FROM Disposition__c
            WHERE Id = :dispositionId
        ];
    }

    @isTest
    static void approvedAndSelectedAtOfferSelection_acceptsOfferAndAdvancesParent() {
        Disposition__c d = dispositionAt('Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 5250000;
        insert offer;

        Test.startTest();
        update new Disposition_Offer__c(Id = offer.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition_Offer__c offerAfter = [SELECT Offer_Status__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual('Accepted', offerAfter.Offer_Status__c,
            'The BEFORE-context stamp must mark the offer Accepted');
        Disposition__c after = reread(d.Id);
        Assert.areEqual('LOI', after.Disposition_Stage__c,
            'Offer Selection must advance to LOI on an Approved+Selected offer');
        Assert.areEqual(5250000, after.Accepted_Offer_Price__c,
            'The parent must be stamped with the accepted offer\'s amount');
    }

    /**
     * 🔴 A REJECTED-THEN-RESUBMITTED-LATE APPROVAL MUST NOT DRAG A SALE BACKWARDS OUT OF LOI/PSA.
     * The disposition has already moved past Offer Selection (a second offer's approval, or a
     * manual Advance, got there first); this offer's own late approval must stamp the price but
     * not move the stage.
     */
    @isTest
    static void guardBlocksALateApprovalAfterTheStageAlreadyAdvanced() {
        Disposition__c d = dispositionAt('PSA'); // already advanced well past Offer Selection
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 4800000;
        insert offer;

        Test.startTest();
        update new Disposition_Offer__c(Id = offer.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('PSA', after.Disposition_Stage__c,
            'The stage must NOT move backwards — the guard is out-of, and only out-of, Offer Selection');
        Assert.areEqual(4800000, after.Accepted_Offer_Price__c,
            '🔴 THE PRICE STAMP IS UNCONDITIONAL EVEN THOUGH THE STAGE MOVE IS NOT');
    }

    @isTest
    static void approvedButNoLongerSelected_doesNothing() {
        Disposition__c d = dispositionAt('Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = false; // de-selected before the approval could complete
        insert offer;

        Test.startTest();
        update new Disposition_Offer__c(Id = offer.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Assert.areEqual('Offer Selection', reread(d.Id).Disposition_Stage__c,
            'Approved-but-no-longer-Selected must not accept an offer the business has since abandoned');
        Disposition_Offer__c offerAfter = [SELECT Offer_Status__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areNotEqual('Accepted', offerAfter.Offer_Status__c,
            'The BEFORE-context stamp must also skip a no-longer-selected offer');
    }

    /**
     * The BEFORE stamp and the AFTER parent write share ONE detection test on purpose — two
     * copies would let an offer end up Accepted with a parent that never moved.
     */
    @isTest
    static void notATransition_alreadyApprovedBeforeThisSave_doesNotReStamp() {
        Disposition__c d = dispositionAt('Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        offer.Approval_Status__c = 'Approved'; // set at INSERT — beforeUpdate never sees this save
        insert offer;
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = 'LOI'); // as a real approval would have left it

        Test.startTest();
        update new Disposition_Offer__c(Id = offer.Id, Buyer_Name__c = 'Renamed Buyer');
        Test.stopTest();

        Assert.areEqual('LOI', reread(d.Id).Disposition_Stage__c,
            'An unrelated save on an already-approved offer must not re-advance the parent');
    }

    /** 🔴 GOVERNOR ASSERTION, THE POINT OF THIS TEST. Never across Test.stopTest(). */
    @isTest
    static void bulk251AcceptsAtConstantCost() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'Offer Selection';
        }
        insert dispositions;
        signBuyerNdasOn(dispositions);
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            Disposition_Offer__c o = TestDataFactory.createDispositionOffer(d.Id, false);
            o.Is_Selected__c = true;
            offers.add(o);
        }
        insert offers;
        List<Disposition_Offer__c> approvals = new List<Disposition_Offer__c>();
        for (Disposition_Offer__c o : offers) {
            approvals.add(new Disposition_Offer__c(Id = o.Id, Approval_Status__c = 'Approved'));
        }

        Test.startTest();
        update approvals; // 251 rows -> TWO trigger chunks
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Disposition_Stage__c = 'LOI'],
            'Every one of the 251 dispositions must have advanced — a total below 251 means the '
            + 'second trigger chunk was dropped');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition_Offer__c WHERE Id IN :offers AND Offer_Status__c = 'Accepted'],
            'And every one of the 251 offers must be marked Accepted by the BEFORE-context stamp');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE NON-OWNER APPROVER — THE UAT DEFECT OF 2026-08-21 (`DISP-0011` / `OFFER-0007`)
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ⚠ EVERY TEST ABOVE THIS LINE PASSED AGAINST THE BROKEN CODE, AND THAT IS THE REAL FINDING.
    // They run as the admin test-running user, who OWNS every fixture record they insert. On an
    // OWD-Private object an owner always holds record-level edit, so the `with sharing`
    // `Database.update` in `advanceParents` was never once asked the question that failed in
    // production. The defect was not missed by these tests; it was UNREACHABLE from them.
    //
    // The fixtures below fix that by separating two identities that every earlier test conflated:
    //   PARENT OWNER  = the admin test user (as an analyst would be in production)
    //   RUNNING USER  = a Minimum-Access principal holding `DPEG_Disposition_View`, who can SEE
    //                   every disposition (`viewAllRecords = true`) and EDIT none of them
    //                   (no `modifyAllRecords`, not in `DPEG_Acquisitions_Team`, no role).
    //
    // ⚠ THE OFFER'S OWNERSHIP IS TRANSFERRED TO THE APPROVER AND THE PARENT'S IS NOT. That is
    // scaffolding, not the subject: it makes the simulated approval field update unambiguously
    // performable in the persona's context (in production the PLATFORM performs that write, so
    // ownership of the offer is irrelevant there). The PARENT's ownership is what is under test and
    // it deliberately stays with someone else.

    /**
     * Builds the approver and hands the OFFER to them, leaving the parent Disposition with the
     * admin test user.
     *
     * @param offerIds Offers to transfer; one bulk update, never one per row.
     * @return The approver.
     */
    private static User approverOwning(String aliasSeed, List<Id> offerIds) {
        User approver = TestDataFactory.createNonOwnerDispositionApprover(aliasSeed);
        List<Disposition_Offer__c> transfers = new List<Disposition_Offer__c>();
        for (Id offerId : offerIds) {
            transfers.add(new Disposition_Offer__c(Id = offerId, OwnerId = approver.Id));
        }
        update transfers;
        return approver;
    }

    /**
     * 🔴 THE PRECONDITION THAT KEEPS EVERY TEST BELOW HONEST. Run INSIDE `System.runAs`, against
     * `UserInfo.getUserId()`, so it needs no "View All Data" on the test-running user and cannot
     * silently answer for the wrong principal.
     *
     * If this ever stops holding — because someone adds `modifyAllRecords` to
     * `DPEG_Disposition_View`, gives the fixture a role, or widens `Disposition_Team_RW` — the
     * tests below would go green while proving NOTHING, which is precisely the state this whole
     * section exists to escape. Failing here says "the fixture stopped being a fixture", which is a
     * different and much more useful message than "the parent did not advance".
     */
    private static void assertReadableButNotEditable(Id dispositionId) {
        // ⚠ `RecordId` MUST BE IN THE SELECT even though nothing below reads it — `UserRecordAccess`
        // rejects a query without it at COMPILE time ("RecordId field must be selected"). Do not
        // "tidy" it away.
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :dispositionId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the approver must be able to READ the parent Disposition — '
            + 'that is what `DPEG_Disposition_View.viewAllRecords` grants, and it is why the '
            + 'idempotency read in advanceParents succeeds and hides the write failure. If this is '
            + 'false the test below would fail at the READ and would not be testing the write.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the approver must NOT be able to EDIT the parent Disposition. '
            + 'This is the entire defect (measured on DISP-0011, 2026-08-21: HasReadAccess = true, '
            + 'HasEditAccess = false). If this is true, the persona has acquired record-level edit '
            + 'from somewhere — modifyAllRecords on DPEG_Disposition_View, a role, or a widened '
            + 'Disposition_Team_RW sharing rule — and every assertion after it is vacuous. '
            + 'Investigate the org, do NOT delete this assertion.');
    }

    /**
     * 🔴 THE HIGHEST-VALUE TEST IN THIS FILE. It fails RED against the pre-2026-08-21 code, in
     * which `advanceParents` ended with a bare `Database.update(parentUpdates, false,
     * AccessLevel.SYSTEM_MODE)` inside this `with sharing` class.
     *
     * WHAT IT PINS: `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing
     * (ARCHITECTURE.md §2), so the parent write must go through
     * `DispositionOfferTriggerHandler.ParentAdvanceWrites` — a `private without sharing` inner
     * class holding that one statement — or an approver who does not own the sale silently fails to
     * advance it.
     */
    @isTest
    static void nonOwnerApprover_advancesTheParentAndStampsThePrice() {
        Disposition__c d = dispositionAt('Offer Selection');
        signBuyerNdaOn(d.Id);
        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(d.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 6100000;
        insert offer;
        User approver = approverOwning('doa1', new List<Id>{ offer.Id });

        System.runAs(approver) {
            assertReadableButNotEditable(d.Id);
            Test.startTest();
            // 🔴 `AccessLevel.SYSTEM_MODE`, NOT A PLAIN `update`, AND IT IS FAITHFUL RATHER THAN A
            // CONVENIENCE. MEASURED: a plain `update` here fails with `System.DmlException:
            // Operation failed due to fields being inaccessible on Sobject Disposition_Offer__c` —
            // the persona has no FLS EDIT on `Approval_Status__c`, and neither does the real
            // approver. In production this write is performed by `Offer_Selection_Approval`'s
            // `finalApprovalActions` FIELD UPDATE, which runs in system context and consults no
            // FLS. SYSTEM_MODE is what reproduces that.
            // ⚠ IT DOES NOT WEAKEN THE TEST. SYSTEM_MODE lifts CRUD and FLS and NEVER sharing —
            // which is the whole finding — so the parent write below is still sharing-scoped and
            // still refused unless `ParentAdvanceWrites` escapes it. Same idiom, same reason, as
            // `DispositionApprovalAdvanceServiceTest`'s semaphore writes.
            Database.update(
                new Disposition_Offer__c(Id = offer.Id, Approval_Status__c = 'Approved'),
                AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            DispositionOfferTriggerHandler.lastRunParentWriteFailures,
            '🔴 THE PARENT WRITE WAS REFUSED. This list carries the platform StatusCode, so read it '
            + 'in the failure message above rather than guessing. INSUFFICIENT_ACCESS_OR_READONLY '
            + 'means the `without sharing` escape (ParentAdvanceWrites) has been removed or bypassed '
            + '— SYSTEM_MODE alone cannot satisfy a record-level check.');
        Disposition__c after = reread(d.Id);
        Assert.areEqual('LOI', after.Disposition_Stage__c,
            'An approver who can SEE but not EDIT the sale must still advance it out of Offer '
            + 'Selection — this is the DISP-0011 defect. Still reading Offer Selection means the '
            + 'parent update was swallowed by allOrNone = false exactly as it was in production.');
        Assert.areEqual(6100000, after.Accepted_Offer_Price__c,
            'and the accepted price must be stamped by the same write');
        Disposition_Offer__c offerAfter =
            [SELECT Offer_Status__c FROM Disposition_Offer__c WHERE Id = :offer.Id];
        Assert.areEqual('Accepted', offerAfter.Offer_Status__c,
            'The BEFORE-context stamp is an in-memory assignment and was never affected by sharing '
            + '— asserted so a future failure can be localised to the AFTER half, which is the half '
            + 'that broke. Both halves reading correctly is what makes the two records agree.');
    }

    /**
     * The 251-record twin, per `.claude/rules/bulk-test-rule.md` — this is a trigger-driven path and
     * there is no exemption to claim.
     *
     * ⚠ IT IS NOT A DUPLICATE OF `bulk251AcceptsAtConstantCost`. That one proves the SECOND trigger
     * chunk is not dropped, as the owner. This one proves the sharing escape holds across BOTH
     * chunks — a fix applied per-record, or a `without sharing` helper instantiated once and
     * captured in a way that did not survive the second chunk, would pass at N=1 and fail here.
     */
    @isTest
    static void nonOwnerApproverAt251_advancesEveryParent() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'Offer Selection';
        }
        insert dispositions;
        signBuyerNdasOn(dispositions);

        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Disposition__c d : dispositions) {
            Disposition_Offer__c o = TestDataFactory.createDispositionOffer(d.Id, false);
            o.Is_Selected__c = true;
            o.Offer_Amount__c = 1000000;
            offers.add(o);
        }
        insert offers;

        List<Id> offerIds = new List<Id>();
        for (Disposition_Offer__c o : offers) {
            offerIds.add(o.Id);
        }
        User approver = approverOwning('doa2', offerIds);

        List<Disposition_Offer__c> approvals = new List<Disposition_Offer__c>();
        for (Disposition_Offer__c o : offers) {
            approvals.add(new Disposition_Offer__c(Id = o.Id, Approval_Status__c = 'Approved'));
        }

        System.runAs(approver) {
            assertReadableButNotEditable(dispositions[0].Id);
            Test.startTest();
            // SYSTEM_MODE for the FLS reason argued at the single-record twin above. Sharing is
            // untouched by it, which is what keeps this a real test of the escape.
            Database.update(approvals, AccessLevel.SYSTEM_MODE); // 251 rows -> TWO trigger chunks
            Test.stopTest();
        }

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c
             WHERE Id IN :dispositions AND Disposition_Stage__c = 'LOI'],
            'Every one of the 251 parents must advance for a NON-OWNER approver. A count of 0 means '
            + 'the sharing escape is gone; a count below 251 but above 0 means it is present but '
            + 'the second trigger chunk lost it.');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c
             WHERE Id IN :dispositions AND Accepted_Offer_Price__c = 1000000],
            'and all 251 accepted prices must be stamped by the same write');
    }
}
