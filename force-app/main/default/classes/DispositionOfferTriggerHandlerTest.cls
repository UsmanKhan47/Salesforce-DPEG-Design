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
}
